/**
 * AssetIQ Dashboard — Client Configuration
 * Points to the local client proxy API (which in turn calls the AssetIQ Intelligence API).
 * No proprietary logic here — just connection and UX configuration.
 */
export const config = {
  apiBaseUrl:       import.meta.env.VITE_API_BASE_URL       ?? "http://localhost:8000",
  appName:          import.meta.env.VITE_APP_NAME           ?? "AssetIQ",
  environment:      import.meta.env.VITE_ENVIRONMENT        ?? "development",
  pollingIntervalMs:Number(import.meta.env.VITE_POLL_INTERVAL_MS ?? 30_000),
  maxTableRows:     Number(import.meta.env.VITE_MAX_TABLE_ROWS   ?? 100),
  defaultBudget:    Number(import.meta.env.VITE_DEFAULT_BUDGET           ?? 12_000_000),
  defaultPlanningHorizon: Number(import.meta.env.VITE_DEFAULT_PLANNING_HORIZON ?? 5),
  defaultDiscountRate:    Number(import.meta.env.VITE_DEFAULT_DISCOUNT_RATE    ?? 0.08),
} as const;
