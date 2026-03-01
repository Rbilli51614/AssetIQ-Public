"""
AssetIQ Compressor Pilot — Quick Start Example

Demonstrates:
  1. Feature spec verification (confirm your SCADA column mapping)
  2. Single compressor failure prediction using CompressorFeatureVector
  3. Batch prediction across a compressor station
  4. Portfolio optimization with compressor-specific fields
  5. Interpreting surge regime
  6. Submitting feedback

Run:
    export ASSETIQ_API_KEY=aiq_your_key_here
    python examples/quickstart_compressor.py
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../sdk/python"))
from assetiq import (
    AssetIQClient,
    CompressorFeatureVector,
    CompressorAssetInput,
    HEALTH_CATEGORY_LABEL,
    HEALTH_CATEGORY_COLORS,
)

client = AssetIQClient(
    api_key=os.environ["ASSETIQ_API_KEY"],
    base_url=os.environ.get("ASSETIQ_API_URL", "https://api.assetiq.io"),
    feature_spec="compressor_v1",
)

# ── 1. Health check ─────────────────────────────────────────────────────────────
print("Checking API health...")
if not client.health_check():
    print("❌ API is not reachable. Check your network and API key.")
    sys.exit(1)
print("✅ API is healthy\n")

# ── 2. Verify feature spec ──────────────────────────────────────────────────────
# Call this once during onboarding to confirm the column order matches your SCADA export.
print("Fetching feature spec for compressor_v1...")
spec = client.get_feature_spec("compressor_v1")
print(f"  {spec['n_features']} features expected:")
for i, col in enumerate(spec["columns"], 1):
    print(f"    {i:02d}. {col}")
print()

# ── 3. Single asset prediction ──────────────────────────────────────────────────
# Use CompressorFeatureVector — never build the raw list manually.
# Column ordering is enforced by the dataclass, not by you.
print("Running failure prediction for COMP-K101A (reciprocating compressor)...")

fv = CompressorFeatureVector(
    suction_pressure_bar=44.8,
    discharge_pressure_bar=94.2,
    compression_ratio=2.10,
    suction_temp_c=28.5,
    discharge_temp_c=142.0,          # elevated — watch this
    interstage_temp_c=85.3,
    vibration_rms_mms=6.8,           # above normal (normal < 4.0 mm/s)
    shaft_speed_rpm=990,
    motor_current_a=187.0,
    lube_oil_pressure_bar=3.1,
    lube_oil_temp_c=68.4,
    seal_gas_pressure_bar=48.0,
    hours_since_last_overhaul=14_200,  # approaching 18,000hr overhaul interval
    hours_since_last_valve_inspection=3_800,
    load_factor_pct=87.0,
    antisurge_valve_position_pct=12.0,
)

result = client.predict(
    asset_id="COMP-K101A",
    features=fv.to_matrix(),
    horizon_days=120,
    asset_type="reciprocating_compressor",
)

print(f"  Asset:                 {result.asset_id}")
print(f"  Health category:       {result.health_category}  ({result.regime})")
print(f"  Failure probability:   {result.failure_probability * 100:.1f}%")
print(f"  Risk level:            {result.risk_level}")
print(f"  Remaining useful life: {result.rul_days:.0f} days")
print(f"  Regime confidence:     {result.regime_confidence * 100:.0f}%")
print(f"  Prediction confidence: {result.prediction_confidence * 100:.0f}%")
print(f"  In surge regime:       {result.is_surge}")
print(f"  Explanation:           {result.explanation}")
print()

# Surge-specific handling
if result.is_surge:
    print("  ⚠ Near-surge detected — check antisurge valve response and throughput demand.")
    print("    Consider loading reduction or bypass valve adjustment before next inspection.\n")

# ── 4. Batch prediction — full compressor station ───────────────────────────────
print("Running batch prediction for all units at CS-STATION-3...")

station_assets = [
    ("COMP-K101A", "reciprocating_compressor", CompressorFeatureVector(
        suction_pressure_bar=44.8, discharge_pressure_bar=94.2, compression_ratio=2.10,
        suction_temp_c=28.5, discharge_temp_c=142.0, interstage_temp_c=85.3,
        vibration_rms_mms=6.8, shaft_speed_rpm=990, motor_current_a=187.0,
        lube_oil_pressure_bar=3.1, lube_oil_temp_c=68.4, seal_gas_pressure_bar=48.0,
        hours_since_last_overhaul=14_200, hours_since_last_valve_inspection=3_800,
        load_factor_pct=87.0, antisurge_valve_position_pct=12.0,
    )),
    ("COMP-K101B", "reciprocating_compressor", CompressorFeatureVector(
        suction_pressure_bar=45.1, discharge_pressure_bar=93.8, compression_ratio=2.08,
        suction_temp_c=27.9, discharge_temp_c=128.0, interstage_temp_c=82.1,
        vibration_rms_mms=3.2, shaft_speed_rpm=995, motor_current_a=182.0,
        lube_oil_pressure_bar=3.4, lube_oil_temp_c=65.2, seal_gas_pressure_bar=48.5,
        hours_since_last_overhaul=8_400, hours_since_last_valve_inspection=1_200,
        load_factor_pct=84.0, antisurge_valve_position_pct=8.0,
    )),
    ("COMP-K102A", "centrifugal_compressor", CompressorFeatureVector(
        suction_pressure_bar=22.0, discharge_pressure_bar=68.0, compression_ratio=3.09,
        suction_temp_c=32.0, discharge_temp_c=98.0, interstage_temp_c=70.0,
        vibration_rms_mms=2.1, shaft_speed_rpm=8_800, motor_current_a=310.0,
        lube_oil_pressure_bar=4.2, lube_oil_temp_c=58.0, seal_gas_pressure_bar=25.0,
        hours_since_last_overhaul=5_100, hours_since_last_valve_inspection=0,  # N/A for centrifugal
        load_factor_pct=72.0, antisurge_valve_position_pct=5.0,
    )),
]

predictions = {}
for asset_id, asset_type, fv in station_assets:
    r = client.predict(asset_id=asset_id, features=fv.to_matrix(), asset_type=asset_type)
    predictions[asset_id] = r
    print(f"  {asset_id:14s}  {r.health_category:20s}  fail={r.failure_probability*100:.0f}%  RUL={r.rul_days:.0f}d  {r.risk_level}")
print()

# ── 5. Portfolio optimization ───────────────────────────────────────────────────
print("Running portfolio optimization for CS-STATION-3...")

assets = [
    CompressorAssetInput(
        asset_id="COMP-K101A",
        asset_type="reciprocating_compressor",
        replacement_cost=1_800_000,
        current_book_value=420_000,
        failure_probability=predictions["COMP-K101A"].failure_probability,
        rul_days=predictions["COMP-K101A"].rul_days,
        criticality=0.90,
        reliability_impact=0.85,
        annual_opex_current=210_000,
        annual_opex_new=95_000,
        annual_throughput_cost=320_000,   # $320K/day lost throughput if K101A is down
        valve_overhaul_cost=85_000,       # cost of full valve set replacement
        last_overhaul_hours=14_200,
    ),
    CompressorAssetInput(
        asset_id="COMP-K101B",
        asset_type="reciprocating_compressor",
        replacement_cost=1_800_000,
        current_book_value=680_000,
        failure_probability=predictions["COMP-K101B"].failure_probability,
        rul_days=predictions["COMP-K101B"].rul_days,
        criticality=0.85,
        reliability_impact=0.80,
        annual_opex_current=180_000,
        annual_opex_new=90_000,
        annual_throughput_cost=320_000,
        valve_overhaul_cost=85_000,
        last_overhaul_hours=8_400,
    ),
    CompressorAssetInput(
        asset_id="COMP-K102A",
        asset_type="centrifugal_compressor",
        replacement_cost=3_200_000,
        current_book_value=2_100_000,
        failure_probability=predictions["COMP-K102A"].failure_probability,
        rul_days=predictions["COMP-K102A"].rul_days,
        criticality=0.75,
        reliability_impact=0.70,
        annual_opex_current=145_000,
        annual_opex_new=80_000,
        annual_throughput_cost=280_000,
        valve_overhaul_cost=0,            # no valves on centrifugal
        last_overhaul_hours=5_100,
    ),
]

opt = client.optimize(
    assets=assets,
    budget=2_500_000,
    planning_horizon_yr=7,
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
print()

# ── 6. Submit feedback ──────────────────────────────────────────────────────────
if opt.recommendations:
    top = opt.recommendations[0]
    print(f"Approving recommendation for {top.asset_id}...")
    client.submit_feedback(
        run_id=opt.run_id,
        recommendation_id=top.asset_id,
        action="approve",
        notes="Approved at Q3 capital planning meeting. Valve overhaul scheduled for next shutdown.",
    )
    print("  ✅ Feedback submitted\n")

# ── 7. Usage check ──────────────────────────────────────────────────────────────
usage = client.get_usage()
print(f"Usage this month:")
print(f"  API calls:       {usage.api_calls:,} / {usage.limits['api_calls_per_month']:,}")
print(f"  Optimize calls:  {usage.optimize_calls:,} / {usage.limits['optimize_per_day']:,} per day")
print(f"  Tier:            {usage.tier}")