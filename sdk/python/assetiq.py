"""
AssetIQ Python SDK

Provides a clean, typed interface to the AssetIQ Intelligence API.
This is the ONLY way client code interacts with AssetIQ's algorithms.
No proprietary code is included here — all intelligence runs server-side.

COMPRESSOR PILOT CHANGES (v2.1):
  - HEALTH_CATEGORY_LABEL: added "surge" regime label
  - HEALTH_CATEGORY_COLORS: added surge color
  - PredictRequest now accepts asset_type and feature_spec
  - client.predict() validates feature vector against FEATURE_SPECS before sending
  - CompressorFeatureVector helper dataclass — build features by name, not position
  - optimize() now accepts CompressorAssetInput with throughput_cost and valve fields

Usage:
    from assetiq import AssetIQClient, CompressorFeatureVector

    client = AssetIQClient(api_key="aiq_...", base_url="https://api.assetiq.io")

    fv = CompressorFeatureVector(
        suction_pressure_bar=45.2,
        discharge_pressure_bar=92.1,
        ...
    )
    result = client.predict(asset_id="COMP-K101A", features=fv.to_matrix())
    print(result.failure_probability)
    print(result.health_category)
"""
from __future__ import annotations

import os
import time
import logging
from dataclasses import dataclass, field, asdict
from typing import Optional

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

logger = logging.getLogger(__name__)

DEFAULT_BASE_URL = "https://ironpeaktest.com"
SDK_VERSION      = "2.1.0"


# ── Health category display ───────────────────────────────────────────────────

# Maps the internal API `regime` value to a user-facing Asset Health Category label
HEALTH_CATEGORY_LABEL: dict[str, str] = {
    "normal":       "Normal Operations",
    "stressed":     "Stressed",
    "transitional": "Transitional",
    "maintenance":  "Maintenance Mode",
    "offline":      "Offline",
    # ADDED v2.1: surge regime specific to compressor asset class
    "surge":        "Near-Surge",
}

# ADDED v2.1: colors for dashboard rendering
HEALTH_CATEGORY_COLORS: dict[str, str] = {
    "normal":       "#3fb950",   # green
    "transitional": "#d29922",   # yellow
    "stressed":     "#f85149",   # red
    "maintenance":  "#388bfd",   # blue
    "offline":      "#484f58",   # muted
    "surge":        "#e3702a",   # orange — distinct from stressed
}


# ── Feature spec ──────────────────────────────────────────────────────────────

# Canonical column ordering for compressor_v1.
# ALWAYS use CompressorFeatureVector to build features — never build the list
# manually, as column order matters and silent ordering bugs give garbage predictions.
COMPRESSOR_FEATURE_SPEC_V1 = [
    "suction_pressure_bar",
    "discharge_pressure_bar",
    "compression_ratio",
    "suction_temp_c",
    "discharge_temp_c",
    "interstage_temp_c",
    "vibration_rms_mms",
    "shaft_speed_rpm",
    "motor_current_a",
    "lube_oil_pressure_bar",
    "lube_oil_temp_c",
    "seal_gas_pressure_bar",
    "hours_since_last_overhaul",
    "hours_since_last_valve_inspection",
    "load_factor_pct",
    "antisurge_valve_position_pct",
]

FEATURE_SPECS: dict[str, list[str]] = {
    "compressor_v1": COMPRESSOR_FEATURE_SPEC_V1,
}


# ── CompressorFeatureVector ───────────────────────────────────────────────────

@dataclass
class CompressorFeatureVector:
    """
    ADDED v2.1: Named fields for all 16 compressor features.
    Use this instead of building raw lists — it prevents column ordering errors.

    Units:
        pressures:           bar
        temperatures:        °C
        vibration:           mm/s RMS
        shaft_speed:         RPM
        motor_current:       Amps
        hours:               hours (float, can be fractional)
        load_factor:         0–100 (percent)
        antisurge_valve:     0–100 (percent open)
        compression_ratio:   dimensionless (discharge / suction pressure)
    """
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

    def to_matrix(self) -> list[list[float]]:
        """Return [[f1, f2, ...]] in the exact column order expected by the API."""
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

    @classmethod
    def from_dict(cls, d: dict) -> "CompressorFeatureVector":
        """Build from a dict keyed by column name."""
        return cls(**{k: float(d[k]) for k in COMPRESSOR_FEATURE_SPEC_V1})

    @classmethod
    def from_scada_row(cls, row: dict, column_map: Optional[dict] = None) -> "CompressorFeatureVector":
        """
        Build from a SCADA historian row using an optional column name mapping.
        column_map: {scada_tag: feature_name} — use when your SCADA tags differ
        from the AssetIQ column names, e.g. {"PT-101": "suction_pressure_bar"}.
        """
        if column_map:
            mapped = {feature_name: row[scada_tag] for scada_tag, feature_name in column_map.items()}
        else:
            mapped = row
        return cls.from_dict(mapped)


# ── Response dataclasses ──────────────────────────────────────────────────────

@dataclass
class PredictionResult:
    asset_id:              str
    failure_probability:   float
    rul_days:              float
    regime:                str
    regime_confidence:     float
    prediction_confidence: float
    explanation:           str
    request_id:            str

    @property
    def health_category(self) -> str:
        return HEALTH_CATEGORY_LABEL.get(self.regime, self.regime.capitalize())

    @property
    def health_color(self) -> str:
        return HEALTH_CATEGORY_COLORS.get(self.regime, "#7d8590")

    @property
    def risk_level(self) -> str:
        # CHANGED v2.1: critical threshold lowered to 0.70 to match compressor config
        if self.failure_probability >= 0.70:
            return "CRITICAL"
        elif self.failure_probability >= 0.40:
            return "HIGH"
        elif self.failure_probability >= 0.20:
            return "MEDIUM"
        return "LOW"

    @property
    def is_surge(self) -> bool:
        """ADDED v2.1: True if compressor is operating in near-surge regime."""
        return self.regime == "surge"


@dataclass
class RecommendationItem:
    asset_id:        str
    action:          str
    priority_rank:   int
    estimated_capex: float
    npv:             float
    roi_pct:         float
    payback_years:   float
    risk_score:      float
    rationale:       str


@dataclass
class OptimizationResult:
    run_id:            str
    total_capex:       float
    projected_npv:     float
    reliability_score: float
    risk_score:        float
    esg_score:         float
    recommendations:   list[RecommendationItem]


@dataclass
class UsageInfo:
    tenant_id:      str
    api_calls:      int
    optimize_calls: int
    asset_count:    int
    limits:         dict
    tier:           str


# ── CompressorAssetInput ──────────────────────────────────────────────────────

@dataclass
class CompressorAssetInput:
    """
    ADDED v2.1: typed asset input for optimize() with compressor-specific fields.
    Use this instead of raw dicts to ensure all required fields are present.
    """
    asset_id:             str
    asset_type:           str            # one of COMPRESSOR_ASSET_TYPES keys
    replacement_cost:     float          # USD
    current_book_value:   float          # USD
    failure_probability:  float          # from predict()
    rul_days:             float          # from predict()
    criticality:          float = 0.7   # 0–1; compressors default higher than generic assets
    reliability_impact:   float = 0.7   # 0–1
    annual_opex_current:  float = 0.0   # USD/yr current maintenance spend
    annual_opex_new:      float = 0.0   # USD/yr expected maintenance after action
    esg_score:            float = 0.5   # 0–1
    # Compressor-specific
    annual_throughput_cost: float = 0.0  # USD/day lost throughput if unit is down
    valve_overhaul_cost:    float = 0.0  # USD — set for reciprocating compressors
    last_overhaul_hours:    float = 0.0  # hours since last major overhaul

    def to_dict(self) -> dict:
        return asdict(self)


# ── Client ────────────────────────────────────────────────────────────────────

class AssetIQClient:
    """
    Thread-safe HTTP client for the AssetIQ Intelligence API.
    Handles authentication, retries, response parsing, and
    client-side feature validation.
    """

    def __init__(
        self,
        api_key:     Optional[str] = None,
        base_url:    Optional[str] = None,
        timeout:     int = 30,
        max_retries: int = 3,
        feature_spec: str = "compressor_v1",
    ):
        self.api_key      = api_key  or os.environ.get("ASSETIQ_API_KEY", "")
        self.base_url     = (base_url or os.environ.get("ASSETIQ_API_URL", DEFAULT_BASE_URL)).rstrip("/")
        self.timeout      = timeout
        self.feature_spec = feature_spec

        if not self.api_key:
            raise ValueError(
                "AssetIQ API key is required. Pass api_key= or set ASSETIQ_API_KEY env var."
            )

        self._session = requests.Session()
        retry = Retry(
            total=max_retries,
            backoff_factor=0.5,
            status_forcelist=[429, 500, 502, 503, 504],
            allowed_methods=["GET", "POST"],
        )
        self._session.mount("https://", HTTPAdapter(max_retries=retry))
        self._session.headers.update({
            "X-API-Key": self.api_key,
            "Content-Type": "application/json",
            "User-Agent": f"assetiq-python-sdk/{SDK_VERSION}",
        })

    def predict(
        self,
        asset_id:     str,
        features:     list[list[float]],
        horizon_days: int = 120,
        asset_type:   Optional[str] = None,
        feature_spec: Optional[str] = None,
    ) -> PredictionResult:
        """
        Predict failure probability and remaining useful life for a single asset.

        Args:
            asset_id:     Your internal asset identifier (e.g. "COMP-K101A")
            features:     Sensor feature matrix — use CompressorFeatureVector.to_matrix()
            horizon_days: Prediction horizon (default 120 days for compressors)
            asset_type:   Optional asset type for logging (e.g. "reciprocating_compressor")
            feature_spec: Feature spec version (default "compressor_v1")

        Returns:
            PredictionResult with failure_probability, rul_days, regime, explanation
        """
        spec_name = feature_spec or self.feature_spec
        self._validate_features(features, spec_name)

        payload = {
            "asset_id":     asset_id,
            "features":     features,
            "horizon_days": horizon_days,
            "feature_spec": spec_name,
        }
        if asset_type:
            payload["asset_type"] = asset_type

        data = self._post("/v1/predict", payload)
        return PredictionResult(**data)

    def optimize(
        self,
        assets:              list[dict | CompressorAssetInput],
        budget:              float,
        planning_horizon_yr: int  = 7,
        objectives:          Optional[dict] = None,
    ) -> OptimizationResult:
        """
        Run multi-objective capital portfolio optimization.

        Args:
            assets: List of CompressorAssetInput objects or dicts.
            budget: Total available capital (USD)
            planning_horizon_yr: Planning horizon in years (default 7 for compressors)
            objectives: Optional weight overrides

        Returns:
            OptimizationResult with ranked recommendations
        """
        payload = {
            "assets": [
                a.to_dict() if isinstance(a, CompressorAssetInput) else a
                for a in assets
            ],
            "budget":              budget,
            "planning_horizon_yr": planning_horizon_yr,
        }
        if objectives:
            payload["objectives"] = objectives

        data = self._post("/v1/optimize", payload)
        recs = [RecommendationItem(**r) for r in data.pop("recommendations", [])]
        return OptimizationResult(recommendations=recs, **data)

    def submit_feedback(
        self,
        run_id:            str,
        recommendation_id: str,
        action:            str,
        notes:             Optional[str] = None,
    ) -> dict:
        params = {
            "run_id":            run_id,
            "recommendation_id": recommendation_id,
            "action":            action,
        }
        if notes:
            params["notes"] = notes
        return self._post("/v1/feedback", params)

    def get_feature_spec(self, spec_name: str = "compressor_v1") -> dict:
        """
        ADDED v2.1: fetch the canonical feature column list from the API.
        Call once during onboarding to verify your SCADA column mapping.
        """
        return self._get(f"/v1/feature-spec/{spec_name}")

    def get_usage(self) -> UsageInfo:
        data = self._get("/v1/usage")
        return UsageInfo(**data)

    def health_check(self) -> bool:
        try:
            data = self._get("/health")
            return data.get("status") == "ok"
        except Exception:
            return False

    # ── Private ───────────────────────────────────────────────────────────────

    def _validate_features(self, features: list[list[float]], spec_name: str) -> None:
        """
        ADDED v2.1: client-side validation before sending to API.
        Catches column count mismatches locally — avoids a round-trip to find out.
        """
        spec = FEATURE_SPECS.get(spec_name)
        if spec is None:
            raise ValueError(
                f"Unknown feature_spec '{spec_name}'. Available: {list(FEATURE_SPECS)}. "
                f"Use CompressorFeatureVector.to_matrix() to build features safely."
            )
        expected = len(spec)
        for i, row in enumerate(features):
            if len(row) != expected:
                raise ValueError(
                    f"Feature row {i} has {len(row)} values but spec '{spec_name}' "
                    f"expects {expected}. \n"
                    f"Expected columns: {spec}\n"
                    f"Tip: use CompressorFeatureVector.to_matrix() to avoid this error."
                )

    def _post(self, path: str, payload: dict) -> dict:
        url = f"{self.base_url}{path}"
        resp = self._session.post(url, json=payload, timeout=self.timeout)
        return self._handle(resp)

    def _get(self, path: str, params: Optional[dict] = None) -> dict:
        url = f"{self.base_url}{path}"
        resp = self._session.get(url, params=params, timeout=self.timeout)
        return self._handle(resp)

    @staticmethod
    def _handle(resp: requests.Response) -> dict:
        if resp.status_code == 401:
            raise PermissionError("Invalid or missing API key. Check your ASSETIQ_API_KEY.")
        if resp.status_code == 429:
            raise RuntimeError(f"Rate limit exceeded. Retry-After: {resp.headers.get('Retry-After')}s")
        if resp.status_code == 403:
            raise PermissionError(f"Access denied: {resp.json().get('detail')}")
        if resp.status_code == 422:
            detail = resp.json().get("detail", resp.text)
            raise ValueError(f"Validation error: {detail}")
        if not resp.ok:
            raise RuntimeError(f"AssetIQ API error {resp.status_code}: {resp.text}")
        return resp.json()