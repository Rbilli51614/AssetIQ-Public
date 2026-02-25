"""
AssetIQ Python SDK

Provides a clean, typed interface to the AssetIQ Intelligence API.
This is the ONLY way client code interacts with AssetIQ's algorithms.
No proprietary code is included here — all intelligence runs server-side.

Usage:
    from assetiq import AssetIQClient

    client = AssetIQClient(api_key="aiq_...", base_url="https://api.assetiq.io")

    result = client.predict(
        asset_id="pump-42",
        features=[[vibration, temp, pressure, ...]],
    )
    print(result.failure_probability)
    print(result.explanation)
"""
from __future__ import annotations

import os
import time
import logging
from dataclasses import dataclass
from typing import Optional

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

logger = logging.getLogger(__name__)

DEFAULT_BASE_URL = "https://api.assetiq.io"
SDK_VERSION      = "2.0.0"


# ── Response dataclasses ──────────────────────────────────────────────────────

# Maps the internal API `regime` value to a user-facing Asset Health Category label
HEALTH_CATEGORY_LABEL: dict[str, str] = {
    "normal":       "Normal Operations",
    "stressed":     "Stressed",
    "transitional": "Transitional",
    "maintenance":  "Maintenance Mode",
    # offline: not returned by the model — set client-side for assets not running
    "offline":      "Offline",
}


@dataclass
class PredictionResult:
    asset_id:              str
    failure_probability:   float
    rul_days:              float
    regime:                str   # internal API field
    regime_confidence:     float
    prediction_confidence: float
    explanation:           str
    request_id:            str

    @property
    def health_category(self) -> str:
        """User-facing Asset Health Category label. Use this for display instead of `regime`."""
        return HEALTH_CATEGORY_LABEL.get(self.regime, self.regime.capitalize())

    @property
    def risk_level(self) -> str:
        if self.failure_probability >= 0.70:
            return "CRITICAL"
        elif self.failure_probability >= 0.40:
            return "HIGH"
        elif self.failure_probability >= 0.20:
            return "MEDIUM"
        return "LOW"


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
    tenant_id:     str
    api_calls:     int
    optimize_calls:int
    asset_count:   int
    limits:        dict
    tier:          str


# ── Client ────────────────────────────────────────────────────────────────────

class AssetIQClient:
    """
    Thread-safe HTTP client for the AssetIQ Intelligence API.
    Handles authentication, retries, and response parsing.
    """

    def __init__(
        self,
        api_key:  Optional[str] = None,
        base_url: Optional[str] = None,
        timeout:  int = 30,
        max_retries: int = 3,
    ):
        self.api_key  = api_key  or os.environ.get("ASSETIQ_API_KEY", "")
        self.base_url = (base_url or os.environ.get("ASSETIQ_API_URL", DEFAULT_BASE_URL)).rstrip("/")
        self.timeout  = timeout

        if not self.api_key:
            raise ValueError(
                "AssetIQ API key is required. Pass api_key= or set ASSETIQ_API_KEY env var."
            )

        # Session with automatic retries
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
        horizon_days: int = 90,
    ) -> PredictionResult:
        """
        Predict failure probability and remaining useful life for a single asset.

        Args:
            asset_id:     Your internal asset identifier
            features:     Sensor feature matrix — shape (1, n_features)
                          Column order must match the feature spec in your onboarding docs.
            horizon_days: Prediction horizon (default 90 days)

        Returns:
            PredictionResult with failure_probability, rul_days, regime, explanation
        """
        payload = {
            "asset_id":     asset_id,
            "features":     features,
            "horizon_days": horizon_days,
        }
        data = self._post("/v1/predict", payload)
        return PredictionResult(**data)

    def optimize(
        self,
        assets:              list[dict],
        budget:              float,
        planning_horizon_yr: int  = 5,
        objectives:          Optional[dict] = None,
    ) -> OptimizationResult:
        """
        Run multi-objective capital portfolio optimization.

        Args:
            assets: List of asset dicts. Required keys per asset:
                      asset_id, replacement_cost, current_book_value,
                      failure_probability, rul_days, criticality, reliability_impact
            budget:              Total available capital (USD)
            planning_horizon_yr: Planning horizon in years
            objectives:          Optional weight overrides e.g.
                                 {"npv_weight": 0.5, "reliability_weight": 0.3,
                                  "risk_weight": 0.1, "esg_weight": 0.1}

        Returns:
            OptimizationResult with ranked recommendations
        """
        payload = {
            "assets":              assets,
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
        action:            str,   # "approve" or "reject"
        notes:             Optional[str] = None,
    ) -> dict:
        """
        Submit operator feedback on a recommendation.
        This improves future recommendations for your tenant.
        """
        params = {
            "run_id":            run_id,
            "recommendation_id": recommendation_id,
            "action":            action,
        }
        if notes:
            params["notes"] = notes
        return self._post("/v1/feedback", params)

    def get_usage(self) -> UsageInfo:
        """Return your current-month API usage and tier limits."""
        data = self._get("/v1/usage")
        return UsageInfo(**data)

    def health_check(self) -> bool:
        """Return True if the API is reachable and healthy."""
        try:
            data = self._get("/health")
            return data.get("status") == "ok"
        except Exception:
            return False

    # ── Private ───────────────────────────────────────────────────────────────

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
        if not resp.ok:
            raise RuntimeError(f"AssetIQ API error {resp.status_code}: {resp.text}")
        return resp.json()
