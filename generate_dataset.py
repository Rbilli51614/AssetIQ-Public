#!/usr/bin/env python3
"""
generate_dataset.py — AssetIQ Compressor Pilot Telemetry Generator

Generates physically realistic 15-minute compressor telemetry and either:
  - writes to CSV (for historical backfill / training data)
  - POSTs directly to the client API (for live simulation)
  - prints a single reading (for cron / scheduler integration)

Usage:
    # Generate 6 months of historical CSV (one file per asset)
    python generate_dataset.py --mode csv --days 180 --output ./data

    # Live simulation — POST one reading per asset to the API every 15 mins
    python generate_dataset.py --mode live --api-url http://localhost:8000

    # Single snapshot to stdout (pipe to API, cron job, etc.)
    python generate_dataset.py --mode single --asset COMP-K101A

    # Replay a degradation scenario (for demo / pilot walkthrough)
    python generate_dataset.py --mode csv --days 60 --scenario valve_wear --output ./data

Why values are correlated, not purely random:
    Real compressor sensors are physically coupled. Discharge pressure drives
    discharge temperature. Load factor drives shaft speed. Vibration rises as
    bearings wear. This generator models those relationships so the ML model
    sees realistic feature distributions — pure random noise would produce
    meaningless predictions.

Regimes:
    normal       — steady state, nominal sensor ranges
    transitional — load change in progress, increased sensor variance
    stressed     — elevated vibration, temps above baseline
    surge        — high vibration, discharge temp spike, antisurge valve opening
    maintenance  — reduced speed/load, suppressed features (unit running light)

Degradation scenarios:
    valve_wear   — progressive valve efficiency loss → rising discharge temp, higher motor current
    bearing_wear — progressive vibration increase → regime transitions over weeks
    seal_leak    — seal gas pressure drop → rising discharge temp, possible surge risk
    healthy      — no degradation (baseline / control)
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import random
import sys
import time
from dataclasses import dataclass, asdict, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

try:
    import requests
    _HAS_REQUESTS = True
except ImportError:
    _HAS_REQUESTS = False


# ── Asset definitions ──────────────────────────────────────────────────────────

@dataclass
class AssetProfile:
    """
    Baseline operating parameters for a specific compressor unit.
    All noise/variance is added on top of these baselines.
    Values are physically consistent with each other.
    """
    asset_id:   str
    asset_type: str   # reciprocating_compressor | centrifugal_compressor

    # Design point pressures (bar)
    suction_pressure_nominal:    float
    discharge_pressure_nominal:  float

    # Design point temperatures (°C)
    suction_temp_nominal:        float
    discharge_temp_nominal:      float
    interstage_temp_nominal:     float

    # Mechanical
    shaft_speed_nominal:         float   # RPM
    motor_current_nominal:       float   # Amps

    # Lube oil system
    lube_oil_pressure_nominal:   float   # bar
    lube_oil_temp_nominal:       float   # °C
    seal_gas_pressure_nominal:   float   # bar

    # Maintenance history at simulation start
    hours_since_last_overhaul:        float
    hours_since_last_valve_inspection: float

    # Operating point
    load_factor_nominal:         float   # 0-100%
    antisurge_valve_nominal:     float   # % open (5-15% is normal cracked-open)

    # Physical limits (for clipping)
    discharge_temp_max:  float = 180.0
    vibration_nominal:   float = 2.5    # mm/s RMS — healthy baseline
    vibration_max:       float = 12.0   # alarm limit

    # Sensor noise std devs (% of nominal)
    pressure_noise_pct:  float = 0.008
    temp_noise_pct:      float = 0.012
    vibration_noise_pct: float = 0.05
    current_noise_pct:   float = 0.015


# The three assets from the pilot quickstart
ASSETS: dict[str, AssetProfile] = {
    "COMP-K101A": AssetProfile(
        asset_id="COMP-K101A",
        asset_type="reciprocating_compressor",
        suction_pressure_nominal=45.0,
        discharge_pressure_nominal=92.0,
        suction_temp_nominal=28.0,
        discharge_temp_nominal=128.0,
        interstage_temp_nominal=82.0,
        shaft_speed_nominal=990.0,
        motor_current_nominal=182.0,
        lube_oil_pressure_nominal=3.3,
        lube_oil_temp_nominal=66.0,
        seal_gas_pressure_nominal=48.0,
        hours_since_last_overhaul=14_000.0,
        hours_since_last_valve_inspection=3_600.0,
        load_factor_nominal=85.0,
        antisurge_valve_nominal=10.0,
    ),
    "COMP-K101B": AssetProfile(
        asset_id="COMP-K101B",
        asset_type="reciprocating_compressor",
        suction_pressure_nominal=45.0,
        discharge_pressure_nominal=92.0,
        suction_temp_nominal=28.0,
        discharge_temp_nominal=126.0,
        interstage_temp_nominal=80.0,
        shaft_speed_nominal=995.0,
        motor_current_nominal=180.0,
        lube_oil_pressure_nominal=3.4,
        lube_oil_temp_nominal=64.0,
        seal_gas_pressure_nominal=48.5,
        hours_since_last_overhaul=8_200.0,
        hours_since_last_valve_inspection=1_100.0,
        load_factor_nominal=84.0,
        antisurge_valve_nominal=8.0,
    ),
    "COMP-K102A": AssetProfile(
        asset_id="COMP-K102A",
        asset_type="centrifugal_compressor",
        suction_pressure_nominal=22.0,
        discharge_pressure_nominal=68.0,
        suction_temp_nominal=32.0,
        discharge_temp_nominal=96.0,
        interstage_temp_nominal=70.0,
        shaft_speed_nominal=8_800.0,
        motor_current_nominal=308.0,
        lube_oil_pressure_nominal=4.2,
        lube_oil_temp_nominal=57.0,
        seal_gas_pressure_nominal=25.0,
        hours_since_last_overhaul=5_000.0,
        hours_since_last_valve_inspection=0.0,   # N/A for centrifugal
        load_factor_nominal=72.0,
        antisurge_valve_nominal=5.0,
    ),
}


# ── Regime definitions ────────────────────────────────────────────────────────

REGIME_PARAMS: dict[str, dict] = {
    "normal": {
        "load_factor_delta":   0.0,
        "temp_delta":          0.0,
        "vibration_multiplier":1.0,
        "antisurge_delta":     0.0,
        "pressure_delta":      0.0,
        "current_multiplier":  1.0,
    },
    "transitional": {
        "load_factor_delta":   random.uniform(-8, 8),
        "temp_delta":          random.uniform(3, 10),
        "vibration_multiplier":random.uniform(1.2, 1.6),
        "antisurge_delta":     random.uniform(2, 8),
        "pressure_delta":      random.uniform(-2, 2),
        "current_multiplier":  random.uniform(1.05, 1.15),
    },
    "stressed": {
        "load_factor_delta":   random.uniform(5, 15),
        "temp_delta":          random.uniform(10, 25),
        "vibration_multiplier":random.uniform(1.8, 2.8),
        "antisurge_delta":     random.uniform(5, 15),
        "pressure_delta":      random.uniform(-3, 3),
        "current_multiplier":  random.uniform(1.15, 1.30),
    },
    "surge": {
        "load_factor_delta":   random.uniform(10, 20),
        "temp_delta":          random.uniform(18, 35),
        "vibration_multiplier":random.uniform(2.5, 4.0),
        "antisurge_delta":     random.uniform(20, 45),   # antisurge valve opening hard
        "pressure_delta":      random.uniform(-5, -1),   # suction pressure dropping
        "current_multiplier":  random.uniform(1.20, 1.40),
    },
    "maintenance": {
        "load_factor_delta":   -random.uniform(20, 40),
        "temp_delta":          -random.uniform(5, 15),
        "vibration_multiplier":random.uniform(0.6, 0.9),
        "antisurge_delta":     -random.uniform(2, 5),
        "pressure_delta":      random.uniform(-5, -2),
        "current_multiplier":  random.uniform(0.65, 0.80),
    },
}

# Markov transition matrix between regimes — rows = from, cols = to
# Order: normal, transitional, stressed, surge, maintenance
TRANSITION_MATRIX: dict[str, dict[str, float]] = {
    "normal":       {"normal":0.88, "transitional":0.07, "stressed":0.02, "surge":0.01, "maintenance":0.02},
    "transitional": {"normal":0.35, "transitional":0.40, "stressed":0.18, "surge":0.05, "maintenance":0.02},
    "stressed":     {"normal":0.10, "transitional":0.20, "stressed":0.55, "surge":0.10, "maintenance":0.05},
    "surge":        {"normal":0.10, "transitional":0.15, "stressed":0.25, "surge":0.45, "maintenance":0.05},
    "maintenance":  {"normal":0.20, "transitional":0.05, "stressed":0.02, "surge":0.00, "maintenance":0.73},
}


# ── Degradation scenario definitions ─────────────────────────────────────────

@dataclass
class DegradationScenario:
    """
    Models progressive degradation over time.
    Each scenario returns a dict of feature multipliers/deltas
    as a function of `t` (0.0 = start of scenario, 1.0 = fully degraded).
    """
    name: str

    def apply(self, t: float, profile: AssetProfile) -> dict:
        """Return dict of feature adjustments at degradation level t ∈ [0,1]."""
        raise NotImplementedError


class HealthyScenario(DegradationScenario):
    def apply(self, t: float, profile: AssetProfile) -> dict:
        return {}   # no adjustments


class ValveWearScenario(DegradationScenario):
    """
    Valve wear — #1 failure mode for reciprocating compressors.
    Worn valves → reduced volumetric efficiency → higher discharge temp,
    more motor current to maintain the same throughput.
    Progressive over weeks/months.
    """
    def apply(self, t: float, profile: AssetProfile) -> dict:
        # t=0 → no wear, t=1 → severe wear (~40% efficiency loss)
        efficiency_loss = t * 0.35
        return {
            "discharge_temp_delta":  efficiency_loss * 40.0,   # up to +40°C
            "interstage_temp_delta": efficiency_loss * 20.0,
            "motor_current_delta":   efficiency_loss * profile.motor_current_nominal * 0.18,
            "vibration_delta":       efficiency_loss * 1.5,    # mild vibration increase
            "load_factor_delta":     efficiency_loss * -5.0,   # controller backs off
        }


class BearingWearScenario(DegradationScenario):
    """
    Bearing wear — dominant failure mode for centrifugal compressors.
    Progressive vibration increase, lube oil temp rises as friction increases.
    """
    def apply(self, t: float, profile: AssetProfile) -> dict:
        return {
            "vibration_multiplier":  1.0 + t * 3.5,            # up to 4.5× baseline
            "lube_oil_temp_delta":   t * 15.0,                  # +15°C at full wear
            "lube_oil_pressure_delta": -t * 0.4,                # pressure drops as viscosity changes
            "discharge_temp_delta":  t * 12.0,                  # secondary heating
        }


class SealLeakScenario(DegradationScenario):
    """
    Seal gas leak — seal gas pressure drops, contamination risk increases.
    Can lead to surge if not addressed (reduced gas density in compressor).
    """
    def apply(self, t: float, profile: AssetProfile) -> dict:
        return {
            "seal_gas_pressure_delta": -t * profile.seal_gas_pressure_nominal * 0.30,
            "discharge_temp_delta":    t * 18.0,
            "antisurge_valve_delta":   t * 12.0,                # controller compensating
            "vibration_delta":         t * 1.8,
        }


SCENARIOS: dict[str, DegradationScenario] = {
    "healthy":     HealthyScenario("healthy"),
    "valve_wear":  ValveWearScenario("valve_wear"),
    "bearing_wear": BearingWearScenario("bearing_wear"),
    "seal_leak":   SealLeakScenario("seal_leak"),
}


# ── Telemetry reading ─────────────────────────────────────────────────────────

@dataclass
class TelemetryReading:
    timestamp:                         str
    asset_id:                          str
    asset_type:                        str
    regime:                            str
    scenario:                          str
    degradation_level:                 float
    suction_pressure_bar:              float
    discharge_pressure_bar:            float
    compression_ratio:                 float
    suction_temp_c:                    float
    discharge_temp_c:                  float
    interstage_temp_c:                 float
    vibration_rms_mms:                 float
    shaft_speed_rpm:                   float
    motor_current_a:                   float
    lube_oil_pressure_bar:             float
    lube_oil_temp_c:                   float
    seal_gas_pressure_bar:             float
    hours_since_last_overhaul:         float
    hours_since_last_valve_inspection: float
    load_factor_pct:                   float
    antisurge_valve_position_pct:      float

    def to_feature_matrix(self) -> list[list[float]]:
        """Return [[f1..f16]] in compressor_v1 column order."""
        return [[
            self.suction_pressure_bar,
            self.discharge_pressure_bar,
            self.compression_ratio,
            self.suction_temp_c,
            self.discharge_temp_c,
            self.interstage_temp_c,
            self.vibration_rms_mms,
            self.shaft_speed_rpm,
            self.motor_current_a,
            self.lube_oil_pressure_bar,
            self.lube_oil_temp_c,
            self.seal_gas_pressure_bar,
            self.hours_since_last_overhaul,
            self.hours_since_last_valve_inspection,
            self.load_factor_pct,
            self.antisurge_valve_position_pct,
        ]]

    def to_api_payload(self) -> dict:
        return {
            "asset_id":     self.asset_id,
            "asset_type":   self.asset_type,
            "features":     self.to_feature_matrix(),
            "horizon_days": 120,
            "feature_spec": "compressor_v1",
        }

    def to_dict(self) -> dict:
        return asdict(self)


# ── Generator ─────────────────────────────────────────────────────────────────

class CompressorTelemetryGenerator:
    """
    Stateful telemetry generator for a single compressor asset.

    Each call to next_reading() advances the simulation by 15 minutes and
    returns a TelemetryReading with physically correlated sensor values.

    State carried between readings:
      - current_regime: Markov chain over regimes
      - hours accumulators: overhaul and valve inspection hours
      - degradation_level: 0→1 over the scenario duration
    """

    INTERVAL_HOURS = 0.25   # 15 minutes

    def __init__(
        self,
        profile:   AssetProfile,
        scenario:  DegradationScenario,
        start_time: Optional[datetime] = None,
        scenario_duration_days: int = 60,
        seed: Optional[int] = None,
    ):
        self.profile   = profile
        self.scenario  = scenario
        self.scenario_duration_steps = int(scenario_duration_days * 24 / self.INTERVAL_HOURS)

        self._rng = random.Random(seed)
        self._ts  = start_time or datetime.now(timezone.utc)

        # Mutable simulation state
        self._regime = "normal"
        self._step   = 0
        self._hours_overhaul = profile.hours_since_last_overhaul
        self._hours_valve    = profile.hours_since_last_valve_inspection

        # Regime params are re-sampled each time we enter a new regime
        self._regime_params = dict(REGIME_PARAMS["normal"])
        self._regime_duration = 0   # consecutive steps in current regime

    def next_reading(self) -> TelemetryReading:
        """Advance by 15 minutes and return the next telemetry reading."""
        self._step += 1
        self._ts   += timedelta(hours=self.INTERVAL_HOURS)

        # Advance hours counters
        self._hours_overhaul += self.INTERVAL_HOURS
        self._hours_valve    += self.INTERVAL_HOURS

        # Regime transition (Markov step)
        self._maybe_transition_regime()
        self._regime_duration += 1

        # Degradation level — linear ramp over scenario duration
        t = min(1.0, self._step / max(self.scenario_duration_steps, 1))

        # Build reading
        return self._build_reading(t)

    # ── Private ───────────────────────────────────────────────────────────────

    def _maybe_transition_regime(self):
        """Sample next regime from Markov transition matrix."""
        probs = TRANSITION_MATRIX[self._regime]
        r = self._rng.random()
        cumulative = 0.0
        for next_regime, p in probs.items():
            cumulative += p
            if r <= cumulative:
                if next_regime != self._regime:
                    # Re-sample regime params when entering a new regime
                    base = dict(REGIME_PARAMS[next_regime])
                    # Add small random variation to regime params so readings don't jump in lockstep
                    for k, v in base.items():
                        if isinstance(v, float):
                            base[k] = v * self._rng.uniform(0.85, 1.15)
                    self._regime_params = base
                    self._regime_duration = 0
                self._regime = next_regime
                return

    def _noise(self, value: float, std_pct: float) -> float:
        """Add Gaussian noise proportional to value."""
        return value + self._rng.gauss(0, abs(value) * std_pct)

    def _build_reading(self, t: float) -> TelemetryReading:
        p   = self.profile
        rp  = self._regime_params
        deg = self.scenario.apply(t, p)

        # ── Load factor ───────────────────────────────────────────────────────
        # Drives most other variables downstream — compute it first
        load = p.load_factor_nominal + rp.get("load_factor_delta", 0) + deg.get("load_factor_delta", 0)
        load = self._noise(load, 0.01)
        load = max(20.0, min(100.0, load))
        load_ratio = load / p.load_factor_nominal

        # ── Shaft speed ───────────────────────────────────────────────────────
        # Proportional to load (variable speed drive) + small noise
        speed = p.shaft_speed_nominal * (0.85 + 0.15 * load_ratio)
        speed = self._noise(speed, p.pressure_noise_pct)

        # ── Pressures ─────────────────────────────────────────────────────────
        suction_p = p.suction_pressure_nominal + rp.get("pressure_delta", 0) + deg.get("seal_gas_pressure_delta", 0) * 0.1
        suction_p = self._noise(suction_p, p.pressure_noise_pct)
        suction_p = max(10.0, suction_p)

        # Discharge pressure rises with load; regime stress can cause pressure fluctuation
        discharge_p = p.discharge_pressure_nominal * (0.92 + 0.08 * load_ratio) + rp.get("pressure_delta", 0)
        discharge_p = self._noise(discharge_p, p.pressure_noise_pct)
        discharge_p = max(suction_p + 5.0, discharge_p)

        compression_ratio = round(discharge_p / suction_p, 3)

        # ── Temperatures ──────────────────────────────────────────────────────
        # Discharge temp is physically driven by compression ratio and efficiency loss
        adiabatic_factor = 1.0 + 0.18 * (compression_ratio - p.discharge_pressure_nominal / p.suction_pressure_nominal)
        discharge_temp = p.discharge_temp_nominal * adiabatic_factor
        discharge_temp += rp.get("temp_delta", 0) + deg.get("discharge_temp_delta", 0)
        discharge_temp  = self._noise(discharge_temp, p.temp_noise_pct)
        discharge_temp  = min(p.discharge_temp_max, max(60.0, discharge_temp))

        suction_temp = p.suction_temp_nominal + self._rng.gauss(0, 1.5)

        interstage_temp = p.interstage_temp_nominal + rp.get("temp_delta", 0) * 0.5 + deg.get("interstage_temp_delta", 0)
        interstage_temp = self._noise(interstage_temp, p.temp_noise_pct)

        # ── Vibration ─────────────────────────────────────────────────────────
        # Increases with speed, regime stress, and bearing/valve wear
        vib_base = p.vibration_nominal * (0.7 + 0.3 * load_ratio)
        vib_mult  = rp.get("vibration_multiplier", 1.0) * deg.get("vibration_multiplier", 1.0)
        vib_delta = deg.get("vibration_delta", 0.0)
        vibration = vib_base * vib_mult + vib_delta
        vibration = self._noise(vibration, p.vibration_noise_pct)
        vibration = max(0.1, min(p.vibration_max, vibration))

        # ── Motor current ─────────────────────────────────────────────────────
        current = p.motor_current_nominal * load_ratio * rp.get("current_multiplier", 1.0)
        current += deg.get("motor_current_delta", 0.0)
        current  = self._noise(current, p.current_noise_pct)
        current  = max(10.0, current)

        # ── Lube oil system ───────────────────────────────────────────────────
        lube_p = p.lube_oil_pressure_nominal + deg.get("lube_oil_pressure_delta", 0.0)
        lube_p = self._noise(lube_p, 0.02)
        lube_p = max(1.0, lube_p)

        lube_t = p.lube_oil_temp_nominal + rp.get("temp_delta", 0) * 0.3 + deg.get("lube_oil_temp_delta", 0.0)
        lube_t = self._noise(lube_t, p.temp_noise_pct)

        # ── Seal gas ──────────────────────────────────────────────────────────
        seal_gas_p = p.seal_gas_pressure_nominal + deg.get("seal_gas_pressure_delta", 0.0)
        seal_gas_p = self._noise(seal_gas_p, 0.015)
        seal_gas_p = max(5.0, seal_gas_p)

        # ── Antisurge valve ───────────────────────────────────────────────────
        # Opens when near surge or under regime stress; seal leaks cause controller to open it
        antisurge = p.antisurge_valve_nominal + rp.get("antisurge_delta", 0) + deg.get("antisurge_valve_delta", 0)
        antisurge = self._noise(antisurge, 0.04)
        antisurge = max(0.0, min(100.0, antisurge))

        return TelemetryReading(
            timestamp=self._ts.isoformat(),
            asset_id=p.asset_id,
            asset_type=p.asset_type,
            regime=self._regime,
            scenario=self.scenario.name,
            degradation_level=round(t, 4),
            suction_pressure_bar=round(suction_p, 3),
            discharge_pressure_bar=round(discharge_p, 3),
            compression_ratio=round(compression_ratio, 3),
            suction_temp_c=round(suction_temp, 2),
            discharge_temp_c=round(discharge_temp, 2),
            interstage_temp_c=round(interstage_temp, 2),
            vibration_rms_mms=round(vibration, 3),
            shaft_speed_rpm=round(speed, 1),
            motor_current_a=round(current, 1),
            lube_oil_pressure_bar=round(lube_p, 3),
            lube_oil_temp_c=round(lube_t, 2),
            seal_gas_pressure_bar=round(seal_gas_p, 3),
            hours_since_last_overhaul=round(self._hours_overhaul, 2),
            hours_since_last_valve_inspection=round(self._hours_valve, 2),
            load_factor_pct=round(load, 1),
            antisurge_valve_position_pct=round(antisurge, 1),
        )


# ── CSV writer ────────────────────────────────────────────────────────────────

CSV_COLUMNS = [
    "timestamp", "asset_id", "asset_type", "regime", "scenario", "degradation_level",
    "suction_pressure_bar", "discharge_pressure_bar", "compression_ratio",
    "suction_temp_c", "discharge_temp_c", "interstage_temp_c",
    "vibration_rms_mms", "shaft_speed_rpm", "motor_current_a",
    "lube_oil_pressure_bar", "lube_oil_temp_c", "seal_gas_pressure_bar",
    "hours_since_last_overhaul", "hours_since_last_valve_inspection",
    "load_factor_pct", "antisurge_valve_position_pct",
]


def write_csv(readings: list[TelemetryReading], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_COLUMNS)
        writer.writeheader()
        for r in readings:
            writer.writerow(r.to_dict())
    print(f"  ✅ Wrote {len(readings):,} rows → {path}")


# ── API poster ────────────────────────────────────────────────────────────────

def post_to_api(reading: TelemetryReading, api_url: str, api_key: Optional[str] = None) -> dict:
    if not _HAS_REQUESTS:
        raise ImportError("pip install requests to use --mode live")

    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["X-API-Key"] = api_key

    resp = requests.post(
        f"{api_url.rstrip('/')}/api/v1/assets",
        json={
            "asset_id":   reading.asset_id,
            "asset_type": reading.asset_type,
            "timestamp":  reading.timestamp,
            "features":   reading.to_feature_matrix(),
        },
        headers=headers,
        timeout=10,
    )
    if not resp.ok:
        print(f"  ⚠ API error {resp.status_code}: {resp.text[:200]}", file=sys.stderr)
    return resp.json() if resp.ok else {}


# ── CLI ───────────────────────────────────────────────────────────────────────

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="AssetIQ Compressor Telemetry Generator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("--mode", choices=["csv", "live", "single"], default="csv",
                   help="csv=write files, live=POST to API every 15min, single=one reading to stdout")
    p.add_argument("--days",    type=int,   default=180,
                   help="Number of days to generate (csv mode only, default 180)")
    p.add_argument("--output",  type=str,   default="./data",
                   help="Output directory for CSV files (default ./data)")
    p.add_argument("--asset",   type=str,   default=None,
                   help="Single asset ID (default: all assets)")
    p.add_argument("--scenario", choices=list(SCENARIOS.keys()), default="healthy",
                   help="Degradation scenario to apply (default healthy)")
    p.add_argument("--api-url", type=str,   default="http://localhost:8000",
                   help="Client API base URL for live mode")
    p.add_argument("--api-key", type=str,   default=None,
                   help="API key for live mode (or set ASSETIQ_LOCAL_KEY env var)")
    p.add_argument("--seed",    type=int,   default=None,
                   help="Random seed for reproducibility")
    p.add_argument("--interval", type=int,  default=900,
                   help="Polling interval in seconds for live mode (default 900 = 15min)")
    p.add_argument("--start",   type=str,   default=None,
                   help="Start datetime ISO format e.g. 2024-01-01T00:00:00Z (default: now - days)")
    p.add_argument("--format",  choices=["csv", "json", "jsonl"], default="csv",
                   help="Output format (csv mode only)")
    return p.parse_args()


def resolve_assets(asset_arg: Optional[str]) -> list[AssetProfile]:
    if asset_arg:
        if asset_arg not in ASSETS:
            print(f"❌ Unknown asset '{asset_arg}'. Available: {list(ASSETS)}", file=sys.stderr)
            sys.exit(1)
        return [ASSETS[asset_arg]]
    return list(ASSETS.values())


def main():
    args = parse_args()
    asset_list = resolve_assets(args.asset)
    scenario   = SCENARIOS[args.scenario]
    api_key    = args.api_key or os.environ.get("ASSETIQ_LOCAL_KEY")

    # ── CSV mode ──────────────────────────────────────────────────────────────
    if args.mode == "csv":
        steps_per_day = int(24 / CompressorTelemetryGenerator.INTERVAL_HOURS)
        total_steps   = args.days * steps_per_day

        if args.start:
            start_dt = datetime.fromisoformat(args.start.replace("Z", "+00:00"))
        else:
            start_dt = datetime.now(timezone.utc) - timedelta(days=args.days)

        output_dir = Path(args.output)
        print(f"Generating {args.days} days × {len(asset_list)} assets")
        print(f"  Scenario:  {args.scenario}")
        print(f"  Start:     {start_dt.isoformat()}")
        print(f"  Readings:  {total_steps:,} per asset ({total_steps * len(asset_list):,} total)")
        print(f"  Output:    {output_dir}/\n")

        seed_offset = 0
        for profile in asset_list:
            gen = CompressorTelemetryGenerator(
                profile=profile,
                scenario=scenario,
                start_time=start_dt,
                scenario_duration_days=args.days,
                seed=args.seed + seed_offset if args.seed else None,
            )
            seed_offset += 1

            readings = []
            for i in range(total_steps):
                readings.append(gen.next_reading())
                if (i + 1) % 10_000 == 0:
                    pct = (i + 1) / total_steps * 100
                    print(f"  {profile.asset_id}: {i+1:,}/{total_steps:,} ({pct:.0f}%)", end="\r")

            out_path = output_dir / f"{profile.asset_id}_{args.scenario}_{args.days}d.csv"
            write_csv(readings, out_path)

        print("\nDone.")

    # ── Single mode ───────────────────────────────────────────────────────────
    elif args.mode == "single":
        for profile in asset_list:
            gen     = CompressorTelemetryGenerator(profile=profile, scenario=scenario, seed=args.seed)
            reading = gen.next_reading()
            print(json.dumps(reading.to_dict(), indent=2))

    # ── Live mode ─────────────────────────────────────────────────────────────
    elif args.mode == "live":
        generators = {
            p.asset_id: CompressorTelemetryGenerator(
                profile=p, scenario=scenario, seed=args.seed
            )
            for p in asset_list
        }

        print(f"Live simulation started")
        print(f"  Assets:   {[p.asset_id for p in asset_list]}")
        print(f"  Scenario: {args.scenario}")
        print(f"  API URL:  {args.api_url}")
        print(f"  Interval: {args.interval}s")
        print("  Ctrl+C to stop\n")

        while True:
            for asset_id, gen in generators.items():
                reading = gen.next_reading()
                ts      = reading.timestamp
                regime  = reading.regime
                vib     = reading.vibration_rms_mms
                dt      = reading.discharge_temp_c
                load    = reading.load_factor_pct

                print(f"[{ts}] {asset_id:14s}  regime={regime:12s}  "
                      f"vib={vib:.2f}mm/s  dt={dt:.1f}°C  load={load:.0f}%",
                      end="")

                if args.api_url:
                    try:
                        post_to_api(reading, args.api_url, api_key)
                        print("  → posted ✓")
                    except Exception as e:
                        print(f"  → post failed: {e}")
                else:
                    print()

            time.sleep(args.interval)


if __name__ == "__main__":
    main()