"""
AssetIQ Quick Start Example

Demonstrates:
  1. Single asset failure prediction
  2. Portfolio optimization
  3. Submitting feedback

Run:
    export ASSETIQ_API_KEY=aiq_your_key_here
    python examples/quickstart.py
"""
import os
import sys

# Add SDK to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../sdk/python"))
from assetiq import AssetIQClient

client = AssetIQClient(
    api_key=os.environ["ASSETIQ_API_KEY"],
    base_url=os.environ.get("ASSETIQ_API_URL", "https://api.assetiq.io"),
)

# ── 1. Health check ────────────────────────────────────────────────────────────
print("Checking API health...")
if not client.health_check():
    print("❌ API is not reachable. Check your network and API key.")
    sys.exit(1)
print("✅ API is healthy\n")

# ── 2. Single asset prediction ─────────────────────────────────────────────────
print("Running failure prediction for Pump P-22...")

# Features must match the column spec provided during onboarding
# Typical features: [vibration_rms, bearing_temp, flow_rate, pressure_in, pressure_out, hours_since_maintenance, ...]
features = [[
    2.34,    # vibration_rms (mm/s)
    87.3,    # bearing_temperature (°C)
    145.2,   # flow_rate (m³/h)
    4.1,     # inlet_pressure (bar)
    3.8,     # outlet_pressure (bar)
    342,     # hours_since_last_maintenance
    0.82,    # load_factor (0-1)
    0.91,    # efficiency (0-1)
]]

result = client.predict(
    asset_id="pump-P22",
    features=features,
    horizon_days=90,
)

print(f"  Asset:               {result.asset_id}")
print(f"  Failure probability: {result.failure_probability * 100:.1f}%")
print(f"  Risk level:          {result.risk_level}")
print(f"  Remaining useful life: {result.rul_days:.0f} days")
print(f"  Asset health category: {result.health_category} (confidence: {result.regime_confidence*100:.0f}%)")
print(f"  Prediction confidence: {result.prediction_confidence*100:.0f}%")
print(f"  Explanation: {result.explanation}\n")

# ── 3. Portfolio optimization ──────────────────────────────────────────────────
print("Running portfolio optimization...")

assets = [
    {
        "asset_id":            "pump-P22",
        "replacement_cost":    450_000,
        "current_book_value":  120_000,
        "failure_probability": result.failure_probability,
        "rul_days":            result.rul_days,
        "criticality":         0.85,
        "reliability_impact":  0.70,
        "annual_opex_current": 85_000,
        "annual_opex_new":     42_000,
    },
    {
        "asset_id":            "turbine-GT4A",
        "replacement_cost":    3_200_000,
        "current_book_value":  800_000,
        "failure_probability": 0.82,
        "rul_days":            47,
        "criticality":         0.95,
        "reliability_impact":  0.90,
        "annual_opex_current": 420_000,
        "annual_opex_new":     180_000,
    },
    {
        "asset_id":            "transformer-TX7",
        "replacement_cost":    680_000,
        "current_book_value":  520_000,
        "failure_probability": 0.12,
        "rul_days":            510,
        "criticality":         0.60,
        "reliability_impact":  0.55,
        "annual_opex_current": 45_000,
        "annual_opex_new":     30_000,
    },
]

opt = client.optimize(
    assets=assets,
    budget=4_000_000,
    planning_horizon_yr=5,
)

print(f"  Run ID:            {opt.run_id}")
print(f"  Total CapEx:       ${opt.total_capex:,.0f}")
print(f"  Projected NPV:     ${opt.projected_npv:,.0f}")
print(f"  Reliability score: {opt.reliability_score:.2%}")
print(f"  Portfolio risk:    {opt.risk_score:.4f}\n")
print(f"  Recommendations ({len(opt.recommendations)}):")
for rec in opt.recommendations:
    print(f"    #{rec.priority_rank} {rec.asset_id}: {rec.action.upper()}")
    print(f"       CapEx: ${rec.estimated_capex:,.0f} | NPV: ${rec.npv:,.0f} | ROI: {rec.roi_pct:.1f}%")
    print(f"       {rec.rationale}")

# ── 4. Submit feedback (approve top recommendation) ────────────────────────────
if opt.recommendations:
    top = opt.recommendations[0]
    print(f"\nApproving recommendation for {top.asset_id}...")
    client.submit_feedback(
        run_id=opt.run_id,
        recommendation_id=top.asset_id,
        action="approve",
        notes="Approved at Q3 capital planning meeting.",
    )
    print("  ✅ Feedback submitted — this will improve future recommendations.")

# ── 5. Usage check ─────────────────────────────────────────────────────────────
usage = client.get_usage()
print(f"\nUsage this month:")
print(f"  API calls:        {usage.api_calls:,} / {usage.limits['api_calls_per_month']:,}")
print(f"  Optimize calls:   {usage.optimize_calls:,} / {usage.limits['optimize_per_day']:,} per day")
print(f"  Tier:             {usage.tier}")
