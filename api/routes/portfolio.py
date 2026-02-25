"""
Portfolio route — forwards optimization requests to AssetIQ Intelligence API.
Stores results locally for dashboard display and audit trail.
Contains ZERO optimization logic.
"""
from fastapi import APIRouter, HTTPException, BackgroundTasks
from pydantic import BaseModel, Field
from typing import Optional
import uuid

from assetiq import AssetIQClient
from client_config import client_settings

router = APIRouter()

_client = AssetIQClient(
    api_key=client_settings.assetiq_api_key,
    base_url=client_settings.assetiq_api_url,
)

# Local store of optimization results for the dashboard
_results: dict[str, dict] = {}


class OptimizeRequest(BaseModel):
    budget:              float
    planning_horizon_yr: int = Field(5, ge=1, le=20)
    asset_ids:           Optional[list[str]] = None   # None = all assets
    objectives:          Optional[dict] = None


@router.post("/optimize")
async def optimize(body: OptimizeRequest, background_tasks: BackgroundTasks):
    """
    Request a capital portfolio optimization from the AssetIQ Intelligence API.
    Assets are pulled from the local asset registry and forwarded to the API.
    """
    # TODO: load assets from local DB filtered by body.asset_ids
    # For now: stub with empty list
    assets = []

    if not assets:
        raise HTTPException(400, "No assets found. Ingest asset data first.")

    try:
        result = _client.optimize(
            assets=assets,
            budget=body.budget,
            planning_horizon_yr=body.planning_horizon_yr,
            objectives=body.objectives,
        )
    except PermissionError as e:
        raise HTTPException(401, str(e))
    except RuntimeError as e:
        raise HTTPException(502, f"AssetIQ API error: {e}")

    response = {
        "run_id":            result.run_id,
        "total_capex":       result.total_capex,
        "projected_npv":     result.projected_npv,
        "reliability_score": result.reliability_score,
        "risk_score":        result.risk_score,
        "esg_score":         result.esg_score,
        "recommendations":   [
            {
                "asset_id":        r.asset_id,
                "action":          r.action,
                "priority_rank":   r.priority_rank,
                "estimated_capex": r.estimated_capex,
                "npv":             r.npv,
                "roi_pct":         r.roi_pct,
                "payback_years":   r.payback_years,
                "risk_score":      r.risk_score,
                "rationale":       r.rationale,
                "status":          "pending",
            }
            for r in result.recommendations
        ],
    }
    _results[result.run_id] = response
    return response


@router.get("/optimize/{run_id}")
async def get_result(run_id: str):
    if run_id not in _results:
        raise HTTPException(404, "Run not found")
    return _results[run_id]


@router.post("/recommendations/{recommendation_id}/approve")
async def approve(recommendation_id: str, run_id: str, notes: Optional[str] = None):
    """Approve a recommendation and send feedback to AssetIQ."""
    _client.submit_feedback(
        run_id=run_id,
        recommendation_id=recommendation_id,
        action="approve",
        notes=notes,
    )
    if run_id in _results:
        for r in _results[run_id].get("recommendations", []):
            if r["asset_id"] == recommendation_id:
                r["status"] = "approved"
    return {"status": "approved", "recommendation_id": recommendation_id}


@router.post("/recommendations/{recommendation_id}/reject")
async def reject(recommendation_id: str, run_id: str, reason: Optional[str] = None):
    """Reject a recommendation and send feedback to AssetIQ."""
    _client.submit_feedback(
        run_id=run_id,
        recommendation_id=recommendation_id,
        action="reject",
        notes=reason,
    )
    if run_id in _results:
        for r in _results[run_id].get("recommendations", []):
            if r["asset_id"] == recommendation_id:
                r["status"] = "rejected"
    return {"status": "rejected", "recommendation_id": recommendation_id}
