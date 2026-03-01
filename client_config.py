"""
AssetIQ Client Configuration
All settings read from environment variables.
No proprietary logic here — just connection and deployment config.

COMPRESSOR PILOT CHANGES (v2.1):
  - default_budget: 12M → 8M (typical compressor station CapEx budget)
  - default_planning_horizon: 5 → 7yr (compressor planning cycles are longer)
  - default_discount_rate: 0.08 → 0.09 (upstream O&G rate)
  - default_horizon_days: 90 → 120 (compressor maintenance intervals)
  - alert thresholds tightened for compressor asset class
  - CompressorAssetTypes added for asset registry validation
  - COMPRESSOR_FEATURE_SPEC_V1 column list for client-side validation before API call
"""
import os
from dataclasses import dataclass, field


def _env(key, default=""): return os.environ.get(key, default)
def _env_int(key, default): return int(os.environ.get(key, default))
def _env_float(key, default): return float(os.environ.get(key, default))
def _env_list(key, default=""): return [v.strip() for v in os.environ.get(key, default).split(",") if v.strip()]


@dataclass
class ClientSettings:
    # AssetIQ Intelligence API connection
    assetiq_api_key:  str  = field(default_factory=lambda: _env("ASSETIQ_API_KEY"))
    assetiq_api_url:  str  = field(default_factory=lambda: _env("ASSETIQ_API_URL", "https://api.assetiq.io"))
    assetiq_timeout:  int  = field(default_factory=lambda: _env_int("ASSETIQ_TIMEOUT_S", 30))

    # Local proxy API
    api_port:         int  = field(default_factory=lambda: _env_int("API_PORT", 8000))
    api_host:         str  = field(default_factory=lambda: _env("API_HOST", "0.0.0.0"))
    cors_origins:     list = field(default_factory=lambda: _env_list("CORS_ORIGINS", "http://localhost:3000"))

    # Local DB
    db_host:          str  = field(default_factory=lambda: _env("DB_HOST", "localhost"))
    db_port:          int  = field(default_factory=lambda: _env_int("DB_PORT", 5432))
    db_name:          str  = field(default_factory=lambda: _env("DB_NAME", "assetiq_client"))
    db_user:          str  = field(default_factory=lambda: _env("DB_USER", ""))
    db_password:      str  = field(default_factory=lambda: _env("DB_PASSWORD", ""))

    # Redis cache
    redis_url:        str  = field(default_factory=lambda: _env("REDIS_URL", ""))
    cache_ttl_s:      int  = field(default_factory=lambda: _env_int("CACHE_TTL_S", 300))

    # CHANGED v2.1: compressor pilot financial defaults
    # Budget: typical compressor station CapEx is $5-12M depending on unit count
    default_budget:           float = field(default_factory=lambda: _env_float("DEFAULT_BUDGET",           8_000_000.0))
    # Planning horizon: compressors have 3-5yr overhaul cycles, 10-15yr replacement cycles
    default_planning_horizon: int   = field(default_factory=lambda: _env_int("DEFAULT_PLANNING_HORIZON",   7))
    # Discount rate: upstream O&G is typically 9-12%
    default_discount_rate:    float = field(default_factory=lambda: _env_float("DEFAULT_DISCOUNT_RATE",    0.09))
    # Prediction horizon: aligns with quarterly maintenance inspection cycle
    default_horizon_days:     int   = field(default_factory=lambda: _env_int("DEFAULT_HORIZON_DAYS",       120))

    # CHANGED v2.1: alert thresholds tightened for compressor asset class.
    # Valve lead times (8-16 weeks) and unplanned outage costs ($200-500K/day)
    # justify earlier intervention than generic industrial assets.
    alert_failure_prob_threshold: float = field(default_factory=lambda: _env_float("ALERT_FAIL_PROB",   0.70))
    alert_rul_days_threshold:     int   = field(default_factory=lambda: _env_int("ALERT_RUL_DAYS",      90))
    alert_health_drop_threshold:  int   = field(default_factory=lambda: _env_int("ALERT_HEALTH_DROP",   12))
    alert_budget_utilization_pct: int   = field(default_factory=lambda: _env_int("ALERT_BUDGET_PCT",    85))

    # Feature spec version — must match what the proprietary model was trained on
    feature_spec: str = field(default_factory=lambda: _env("FEATURE_SPEC", "compressor_v1"))

    @property
    def db_url(self):
        return f"postgresql+asyncpg://{self.db_user}:{self.db_password}@{self.db_host}:{self.db_port}/{self.db_name}"


client_settings = ClientSettings()


# ── Compressor Asset Taxonomy ─────────────────────────────────────────────────
# ADDED v2.1: canonical asset types for this pilot.
# asset_id in the client DB should include the type prefix for clarity,
# e.g. "COMP-K101A" for a compressor, "CS-STATION-3" for a station.

COMPRESSOR_ASSET_TYPES = {
    "reciprocating_compressor":  "Reciprocating Compressor Package",
    "centrifugal_compressor":    "Centrifugal Compressor Package",
    "compressor_station":        "Compressor Station (multi-unit)",
    "scrubber":                  "Scrubber / Separator",
    "intercooler":               "Intercooler / Aftercooler",
    "gas_engine_driver":         "Gas Engine Driver",
    "electric_motor_driver":     "Electric Motor Driver",
}


# ── Feature Spec ──────────────────────────────────────────────────────────────
# ADDED v2.1: client-side copy of the feature spec for validation before
# calling the API. Prevents silent feature ordering errors.
# The gateway also validates this — this is a second line of defence.

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

FEATURE_SPECS = {
    "compressor_v1": COMPRESSOR_FEATURE_SPEC_V1,
}