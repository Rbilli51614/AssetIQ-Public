/**
 * AssetIQ Dashboard API Client
 * Calls the local client proxy API.
 * The proxy handles authentication to the AssetIQ Intelligence API.
 */
import axios from "axios";
import { config } from "./config";

export const apiClient = axios.create({
  baseURL: config.apiBaseUrl,
  headers: { "Content-Type": "application/json" },
  timeout: 30_000,
});

export const api = {
  assets: {
    list:     (params?: Record<string, string>) => apiClient.get("/api/v1/assets/", { params }),
    get:      (id: string)                       => apiClient.get(`/api/v1/assets/${id}`),
    ingestTelemetry: (id: string, readings: unknown[]) =>
      apiClient.post(`/api/v1/assets/${id}/telemetry`, readings),
    healthHistory: (id: string, days = 30) =>
      apiClient.get(`/api/v1/assets/${id}/health-history`, { params: { days } }),
  },
  predictions: {
    predict: (assetId: string, features: number[][], horizonDays = 90) =>
      apiClient.post("/api/v1/predictions/predict", { asset_id: assetId, features, horizon_days: horizonDays }),
    batchPredict: (requests: unknown[]) =>
      apiClient.post("/api/v1/predictions/batch-predict", requests),
  },
  portfolio: {
    optimize: (body: unknown) => apiClient.post("/api/v1/portfolio/optimize", body),
    getResult: (runId: string) => apiClient.get(`/api/v1/portfolio/optimize/${runId}`),
    approve: (recId: string, runId: string, notes?: string) =>
      apiClient.post(`/api/v1/portfolio/recommendations/${recId}/approve`, {}, { params: { run_id: runId, notes } }),
    reject: (recId: string, runId: string, reason?: string) =>
      apiClient.post(`/api/v1/portfolio/recommendations/${recId}/reject`, {}, { params: { run_id: runId, reason } }),
  },
  health: {
    ping: () => apiClient.get("/health"),
  },
};
