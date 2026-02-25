"""
Predictions route — forwards requests to AssetIQ Intelligence API.
Caches results locally to avoid redundant API calls.
Contains ZERO ML logic.
"""
from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field
from typing import Optional
import hashlib
import json

from assetiq import AssetIQClient, HEALTH_CATEGORY_LABEL
from client_config import client_settings

router = APIRouter()

# SDK client — all intelligence calls go through here
_client = AssetIQClient(
    api_key=client_settings.assetiq_api_key,
    base_url=client_settings.assetiq_api_url,
)

# Simple in-memory cache (replace with Redis for production deployments)
_cache: dict[str, dict] = {}


class PredictRequest(BaseModel):
    asset_id:     str
    features:     list[list[float]] = Field(..., description="Sensor feature matrix")
    horizon_days: int = Field(90, ge=1, le=365)
    use_cache:    bool = True


@router.post("/predict")
async def predict(body: PredictRequest):
    """
    Request a failure prediction from the AssetIQ Intelligence API.
    Results are cached by feature hash to avoid redundant API calls.
    """
    cache_key = None
    if body.use_cache:
        feature_hash = hashlib.md5(json.dumps(body.features).encode()).hexdigest()
        cache_key = f"{body.asset_id}:{feature_hash}:{body.horizon_days}"
        if cache_key in _cache:
            return {**_cache[cache_key], "cached": True}

    try:
        result = _client.predict(
            asset_id=body.asset_id,
            features=body.features,
            horizon_days=body.horizon_days,
        )
    except PermissionError as e:
        raise HTTPException(status_code=401, detail=str(e))
    except RuntimeError as e:
        raise HTTPException(status_code=502, detail=f"AssetIQ API error: {e}")

    response = {
        "asset_id":              result.asset_id,
        "failure_probability":   result.failure_probability,
        "rul_days":              result.rul_days,
        "regime":                result.regime,           # internal field, kept for API compatibility
        "health_category":       result.health_category,  # user-facing label; set to "offline" client-side for assets not running
        "regime_confidence":     result.regime_confidence,
        "prediction_confidence": result.prediction_confidence,
        "explanation":           result.explanation,
        "risk_level":            result.risk_level,
        "request_id":            result.request_id,
        "cached":                False,
    }

    if cache_key:
        _cache[cache_key] = response

    return response


@router.post("/batch-predict")
async def batch_predict(requests: list[PredictRequest]):
    """Run predictions for multiple assets in sequence."""
    results = []
    for req in requests:
        try:
            result = await predict(req)
            results.append(result)
        except HTTPException as e:
            results.append({"asset_id": req.asset_id, "error": e.detail})
    return {"predictions": results, "count": len(results)}
