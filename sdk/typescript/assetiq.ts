/**
 * AssetIQ TypeScript SDK
 *
 * Typed client for the AssetIQ Intelligence API.
 * All intelligence runs server-side — this SDK only handles HTTP transport.
 *
 * Usage:
 *   import { AssetIQClient } from "@assetiq/sdk";
 *   const client = new AssetIQClient({ apiKey: "aiq_..." });
 *   const result = await client.predict({ assetId: "pump-42", features: [[...]] });
 */

const SDK_VERSION = "2.0.0";
const DEFAULT_BASE_URL = "https://api.assetiq.io";

// ── Types ─────────────────────────────────────────────────────────────────────

export interface PredictRequest {
  assetId:     string;
  features:    number[][];   // shape: (1, n_features)
  horizonDays?: number;
}

/** Maps the internal regime value to a user-facing Asset Health Category label. */
export const HEALTH_CATEGORY_LABEL: Record<string, string> = {
  normal:       "Normal Operations",
  stressed:     "Stressed",
  transitional: "Transitional",
  maintenance:  "Maintenance Mode",
  /** Asset is not running — no sensor data, no prediction available. Set client-side. */
  offline:      "Offline",
};

/** Maps the internal regime value to a display color (hex). */
export const HEALTH_CATEGORY_COLORS: Record<string, string> = {
  normal:       "#22c55e",
  stressed:     "#ef4444",
  transitional: "#eab308",
  maintenance:  "#60a5fa",
  offline:      "#484f58",
};

export type HealthCategory = "normal" | "stressed" | "transitional" | "maintenance" | "offline";

export interface PredictResponse {
  asset_id:               string;
  failure_probability:    number;
  rul_days:               number;
  /** Internal API field — use `healthCategory` for display. */
  regime:                 HealthCategory;
  regime_confidence:      number;
  prediction_confidence:  number;
  explanation:            string;
  request_id:             string;
  /** User-facing label derived from `regime`. Use this for display. */
  readonly healthCategory: string;
  readonly healthCategoryColor: string;
}

export interface AssetCapitalInput {
  asset_id:            string;
  replacement_cost:    number;
  current_book_value:  number;
  failure_probability: number;
  rul_days:            number;
  criticality?:        number;
  reliability_impact?: number;
  annual_opex_current?:number;
  annual_opex_new?:    number;
  esg_score?:          number;
}

export interface OptimizeRequest {
  assets:               AssetCapitalInput[];
  budget:               number;
  planning_horizon_yr?: number;
  objectives?: {
    npv_weight?:         number;
    reliability_weight?: number;
    risk_weight?:        number;
    esg_weight?:         number;
  };
}

export interface RecommendationItem {
  asset_id:        string;
  action:          "replace" | "overhaul" | "monitor";
  priority_rank:   number;
  estimated_capex: number;
  npv:             number;
  roi_pct:         number;
  payback_years:   number;
  risk_score:      number;
  rationale:       string;
}

export interface OptimizeResponse {
  run_id:            string;
  total_capex:       number;
  projected_npv:     number;
  reliability_score: number;
  risk_score:        number;
  esg_score:         number;
  recommendations:   RecommendationItem[];
}

export interface UsageResponse {
  tenant_id:      string;
  api_calls:      number;
  optimize_calls: number;
  asset_count:    number;
  tier:           string;
  limits: {
    assets:                number;
    api_calls_per_month:   number;
    optimize_per_day:      number;
  };
}

export interface AssetIQConfig {
  apiKey:    string;
  baseUrl?:  string;
  timeout?:  number;
}

// ── Client ────────────────────────────────────────────────────────────────────

export class AssetIQClient {
  private readonly apiKey:  string;
  private readonly baseUrl: string;
  private readonly timeout: number;

  constructor(config: AssetIQConfig) {
    if (!config.apiKey) {
      throw new Error("AssetIQ API key is required.");
    }
    this.apiKey  = config.apiKey;
    this.baseUrl = (config.baseUrl ?? DEFAULT_BASE_URL).replace(/\/$/, "");
    this.timeout = config.timeout ?? 30_000;
  }

  /** Predict failure probability for a single asset. */
  async predict(req: PredictRequest): Promise<PredictResponse> {
    const raw = await this.post<Omit<PredictResponse, "healthCategory" | "healthCategoryColor">>("/v1/predict", {
      asset_id:     req.assetId,
      features:     req.features,
      horizon_days: req.horizonDays ?? 90,
    });
    // Enrich with user-facing display fields so callers never touch raw `regime`
    return {
      ...raw,
      healthCategory:      HEALTH_CATEGORY_LABEL[raw.regime] ?? raw.regime,
      healthCategoryColor: HEALTH_CATEGORY_COLORS[raw.regime] ?? "#94a3b8",
    };
  }

  /** Run multi-objective capital portfolio optimization. */
  async optimize(req: OptimizeRequest): Promise<OptimizeResponse> {
    return this.post<OptimizeResponse>("/v1/optimize", req);
  }

  /** Submit operator feedback to improve future recommendations. */
  async submitFeedback(params: {
    runId: string;
    recommendationId: string;
    action: "approve" | "reject";
    notes?: string;
  }): Promise<{ status: string; run_id: string }> {
    return this.post("/v1/feedback", {
      run_id:            params.runId,
      recommendation_id: params.recommendationId,
      action:            params.action,
      notes:             params.notes,
    });
  }

  /** Get current-month API usage for your tenant. */
  async getUsage(): Promise<UsageResponse> {
    return this.get<UsageResponse>("/v1/usage");
  }

  /** Returns true if the API is reachable and healthy. */
  async healthCheck(): Promise<boolean> {
    try {
      const data = await this.get<{ status: string }>("/health");
      return data.status === "ok";
    } catch {
      return false;
    }
  }

  // ── Private ─────────────────────────────────────────────────────────────────

  private async post<T>(path: string, body: unknown): Promise<T> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeout);
    try {
      const res = await fetch(`${this.baseUrl}${path}`, {
        method: "POST",
        headers: this.headers(),
        body: JSON.stringify(body),
        signal: controller.signal,
      });
      return this.handle<T>(res);
    } finally {
      clearTimeout(timer);
    }
  }

  private async get<T>(path: string): Promise<T> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeout);
    try {
      const res = await fetch(`${this.baseUrl}${path}`, {
        method: "GET",
        headers: this.headers(),
        signal: controller.signal,
      });
      return this.handle<T>(res);
    } finally {
      clearTimeout(timer);
    }
  }

  private headers(): Record<string, string> {
    return {
      "X-API-Key":    this.apiKey,
      "Content-Type": "application/json",
      "User-Agent":   `assetiq-ts-sdk/${SDK_VERSION}`,
    };
  }

  private async handle<T>(res: Response): Promise<T> {
    if (res.status === 401) throw new Error("Invalid or missing API key.");
    if (res.status === 429) throw new Error(`Rate limit exceeded. Retry-After: ${res.headers.get("Retry-After")}s`);
    if (res.status === 403) throw new Error(`Access denied: ${(await res.json()).detail}`);
    if (!res.ok) throw new Error(`AssetIQ API error ${res.status}: ${await res.text()}`);
    return res.json() as Promise<T>;
  }
}
