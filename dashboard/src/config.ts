/**
 * AssetIQ Dashboard — Client Configuration
 * Points to the local client proxy API (which in turn calls the AssetIQ Intelligence API).
 * No proprietary logic here — just connection and UX configuration.
 *
 * COMPRESSOR PILOT CHANGES (v2.1):
 *   - defaultBudget: 12M → 8M  (typical compressor station CapEx)
 *   - defaultPlanningHorizon: 5 → 7yr
 *   - defaultDiscountRate: 0.08 → 0.09
 *   - defaultHorizonDays: 90 → 120 (aligns with quarterly inspection cycle)
 *   - appName: "AssetIQ" → "AssetIQ — Compression"
 *   - alertThresholds: tightened for compressor asset class
 *   - featureSpec: "compressor_v1" added
 *   - pollingIntervalMs: 30s → 900s (15min — SCADA poll interval for compressors)
 */
export const config = {
  apiBaseUrl:         import.meta.env.VITE_API_BASE_URL         ?? "http://localhost:8000",
  // CHANGED v2.1
  appName:            import.meta.env.VITE_APP_NAME             ?? "AssetIQ — Compression",
  environment:        import.meta.env.VITE_ENVIRONMENT          ?? "development",
  // CHANGED v2.1: match SCADA 15-minute poll interval
  pollingIntervalMs:  Number(import.meta.env.VITE_POLL_INTERVAL_MS  ?? 900_000),
  maxTableRows:       Number(import.meta.env.VITE_MAX_TABLE_ROWS     ?? 100),
  // CHANGED v2.1: compressor station CapEx budget
  defaultBudget:      Number(import.meta.env.VITE_DEFAULT_BUDGET              ?? 8_000_000),
  // CHANGED v2.1: compressor planning cycle
  defaultPlanningHorizon: Number(import.meta.env.VITE_DEFAULT_PLANNING_HORIZON ?? 7),
  // CHANGED v2.1: upstream O&G discount rate
  defaultDiscountRate:    Number(import.meta.env.VITE_DEFAULT_DISCOUNT_RATE    ?? 0.09),
  // ADDED v2.1: prediction horizon aligned to quarterly inspection
  defaultHorizonDays: Number(import.meta.env.VITE_DEFAULT_HORIZON_DAYS        ?? 120),
  // ADDED v2.1: feature spec version — must match proprietary model
  featureSpec:        import.meta.env.VITE_FEATURE_SPEC                        ?? "compressor_v1",
} as const;

/**
 * ADDED v2.1: Alert thresholds for compressor asset class.
 * These are tighter than generic industrial defaults because:
 *   - Valve and seal lead times are 8-16 weeks
 *   - Unplanned outage costs $200K-$500K/day in lost throughput
 *   - Reciprocating compressor MTBF on valves is 6-18 months
 */
export const alertThresholds = {
  // CHANGED v2.1: 80% → 70% — compressor components need procurement lead time
  failureProbability: Number(import.meta.env.VITE_ALERT_FAIL_PROB   ?? 0.70),
  // CHANGED v2.1: 60d → 90d — valve lead times can exceed 60 days
  rulDays:            Number(import.meta.env.VITE_ALERT_RUL_DAYS    ?? 90),
  // CHANGED v2.1: 10pts → 12pts — compressor health degrades less linearly
  healthDrop:         Number(import.meta.env.VITE_ALERT_HEALTH_DROP ?? 12),
  budgetUtilization:  Number(import.meta.env.VITE_ALERT_BUDGET_PCT  ?? 85),
} as const;

/**
 * ADDED v2.1: Compressor asset taxonomy for the dashboard asset registry.
 * Used to populate asset-type dropdowns and colour-code the asset table.
 */
export const COMPRESSOR_ASSET_TYPES: Record<string, string> = {
  reciprocating_compressor: "Reciprocating Compressor Package",
  centrifugal_compressor:   "Centrifugal Compressor Package",
  compressor_station:       "Compressor Station (multi-unit)",
  scrubber:                 "Scrubber / Separator",
  intercooler:              "Intercooler / Aftercooler",
  gas_engine_driver:        "Gas Engine Driver",
  electric_motor_driver:    "Electric Motor Driver",
};