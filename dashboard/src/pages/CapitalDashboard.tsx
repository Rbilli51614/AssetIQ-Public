import React, { useState, useEffect } from "react";
import { LoadingState, ErrorState, SkeletonRow } from "../components/StateViews";
import { colors } from "../components/tokens";
import {
  AreaChart, Area, BarChart, Bar, XAxis, YAxis,
  CartesianGrid, Tooltip, ResponsiveContainer, PieChart, Pie, Cell, Legend,
} from "recharts";
import { config } from "../config";

// Budget is driven by VITE_DEFAULT_BUDGET env var — no hardcoding
const ANNUAL_BUDGET = config.defaultBudget;

// ── Mock data (replace with React Query hooks against apiClient) ──────────────
const capitalTrend = [
  { month: "Jan", budget: ANNUAL_BUDGET, committed: ANNUAL_BUDGET * 0.817, projected_savings: ANNUAL_BUDGET * 0.267 },
  { month: "Feb", budget: ANNUAL_BUDGET, committed: ANNUAL_BUDGET * 0.850, projected_savings: ANNUAL_BUDGET * 0.342 },
  { month: "Mar", budget: ANNUAL_BUDGET, committed: ANNUAL_BUDGET * 0.925, projected_savings: ANNUAL_BUDGET * 0.467 },
  { month: "Apr", budget: ANNUAL_BUDGET, committed: ANNUAL_BUDGET * 0.725, projected_savings: ANNUAL_BUDGET * 0.242 },
  { month: "May", budget: ANNUAL_BUDGET, committed: ANNUAL_BUDGET * 0.783, projected_savings: ANNUAL_BUDGET * 0.317 },
  { month: "Jun", budget: ANNUAL_BUDGET, committed: ANNUAL_BUDGET * 0.900, projected_savings: ANNUAL_BUDGET * 0.392 },
];

const riskDistribution = [
  { name: "Critical",    value: 8,  color: "#ef4444" },
  { name: "High",        value: 23, color: "#f97316" },
  { name: "Medium",      value: 61, color: "#eab308" },
  { name: "Low",         value: 108, color: "#22c55e" },
];

const recentRecommendations = [
  { id: "R-001", asset: "Turbine 4A", action: "Replace",   npv: 4200000, roi: 38, urgency: "critical" },
  { id: "R-002", asset: "Pump P-22",  action: "Overhaul",  npv: 890000,  roi: 22, urgency: "high"     },
  { id: "R-003", asset: "TX-7 Grid",  action: "Monitor",   npv: 110000,  roi: 8,  urgency: "medium"   },
  { id: "R-004", asset: "Comp. C-5",  action: "Replace",   npv: 2100000, roi: 31, urgency: "high"     },
];

const URGENCY_COLOR: Record<string, string> = {
  critical: "#ef4444",
  high:     "#f97316",
  medium:   "#eab308",
  low:      "#22c55e",
};

const fmt = (v: number) =>
  v >= 1_000_000 ? `$${(v / 1_000_000).toFixed(1)}M`
  : v >= 1_000   ? `$${(v / 1_000).toFixed(0)}K`
  : `$${v}`;


// ── KPI Card ─────────────────────────────────────────────────────────────────
function KPICard({ title, value, sub, color = "#60a5fa", delta }: any) {
  return (
    <div style={{
      background: "#161b27", borderRadius: 12, padding: "20px 24px",
      border: "1px solid #1e2d40", flex: 1,
    }}>
      <div style={{ fontSize: 12, color: "#64748b", marginBottom: 8, textTransform: "uppercase", letterSpacing: "0.08em" }}>{title}</div>
      <div style={{ fontSize: 28, fontWeight: 700, color, lineHeight: 1 }}>{value}</div>
      {sub   && <div style={{ fontSize: 12, color: "#64748b", marginTop: 6 }}>{sub}</div>}
      {delta && <div style={{ fontSize: 12, color: delta > 0 ? "#22c55e" : "#ef4444", marginTop: 4 }}>
        {delta > 0 ? "▲" : "▼"} {Math.abs(delta)}% vs last quarter
      </div>}
    </div>
  );
}


// ── Main ──────────────────────────────────────────────────────────────────────
export default function CapitalDashboard() {
  const [loading, setLoading] = useState(true);
  const [error, setError]     = useState<string | null>(null);
  const [lastUpdated, setLastUpdated] = useState(new Date());

  // Simulate data fetch on mount
  useEffect(() => {
    const t = setTimeout(() => setLoading(false), 900);
    return () => clearTimeout(t);
  }, []);

  function retry() {
    setError(null);
    setLoading(true);
    setTimeout(() => setLoading(false), 900);
  }

  if (loading) return <LoadingState message="Loading capital data..." detail="Fetching portfolio metrics from AssetIQ API" height={500} />;
  if (error)   return <ErrorState  message="Failed to load capital data" detail={error} onRetry={retry} height={500} />;

  return (
    <div style={{ maxWidth: 1400 }}>
      <div style={{ marginBottom: 24 }}>
        <h1 style={{ fontSize: 24, fontWeight: 700, color: "#f1f5f9", margin: 0 }}>Capital Intelligence Overview</h1>
        <p style={{ fontSize: 14, color: colors.textSecondary, marginTop: 4 }}>AI-optimized capital allocation across 200 assets · Updated {lastUpdated.toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit" })}</p>
      </div>

      {/* KPIs */}
      <div style={{ display: "flex", gap: 16, marginBottom: 24 }}>
        <KPICard title="Annual CapEx Budget"      value="$12.0M"  sub="FY 2025"                   delta={5}   color="#60a5fa" />
        <KPICard title="Committed"                value="$10.1M"  sub="84% utilized"               delta={-3}  color="#a78bfa" />
        <KPICard title="Projected NPV Uplift"     value="$4.2M"   sub="From AI recommendations"    delta={18}  color="#34d399" />
        <KPICard title="Assets at Risk"           value="31"      sub="Critical + High risk"        delta={-8}  color="#f97316" />
        <KPICard title="Portfolio Risk Score"     value="0.23"    sub="Lower is better"             delta={-12} color="#22c55e" />
      </div>

      {/* Charts row */}
      <div style={{ display: "grid", gridTemplateColumns: "2fr 1fr", gap: 16, marginBottom: 24 }}>
        {/* Capital trend */}
        <div style={{ background: "#161b27", borderRadius: 12, padding: 24, border: "1px solid #1e2d40" }}>
          <h3 style={{ fontSize: 14, fontWeight: 600, color: "#f1f5f9", marginBottom: 20, marginTop: 0 }}>Capital Committed vs Budget</h3>
          <ResponsiveContainer width="100%" height={220}>
            <AreaChart data={capitalTrend}>
              <defs>
                <linearGradient id="budget" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="5%"  stopColor="#3b82f6" stopOpacity={0.2} />
                  <stop offset="95%" stopColor="#3b82f6" stopOpacity={0}   />
                </linearGradient>
                <linearGradient id="committed" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="5%"  stopColor="#8b5cf6" stopOpacity={0.25} />
                  <stop offset="95%" stopColor="#8b5cf6" stopOpacity={0}   />
                </linearGradient>
              </defs>
              <CartesianGrid strokeDasharray="3 3" stroke="#1e2d40" />
              <XAxis dataKey="month" tick={{ fontSize: 12, fill: "#64748b" }} axisLine={false} tickLine={false} />
              <YAxis tickFormatter={v => `$${v/1e6}M`} tick={{ fontSize: 12, fill: "#64748b" }} axisLine={false} tickLine={false} />
              <Tooltip formatter={(v: any) => fmt(v)} contentStyle={{ background: "#1e293b", border: "1px solid #334155", borderRadius: 8, fontSize: 13 }} />
              <Area type="monotone" dataKey="budget"    stroke="#3b82f6" fill="url(#budget)"    strokeWidth={2} name="Budget"    />
              <Area type="monotone" dataKey="committed" stroke="#8b5cf6" fill="url(#committed)" strokeWidth={2} name="Committed" />
            </AreaChart>
          </ResponsiveContainer>
        </div>

        {/* Risk distribution */}
        <div style={{ background: "#161b27", borderRadius: 12, padding: 24, border: "1px solid #1e2d40" }}>
          <h3 style={{ fontSize: 14, fontWeight: 600, color: "#f1f5f9", marginBottom: 20, marginTop: 0 }}>Asset Risk Distribution</h3>
          <ResponsiveContainer width="100%" height={220}>
            <PieChart>
              <Pie data={riskDistribution} dataKey="value" cx="50%" cy="50%" innerRadius={60} outerRadius={90} paddingAngle={3}>
                {riskDistribution.map((entry, i) => <Cell key={i} fill={entry.color} />)}
              </Pie>
              <Legend formatter={(v) => <span style={{ color: "#94a3b8", fontSize: 12 }}>{v}</span>} />
              <Tooltip contentStyle={{ background: "#1e293b", border: "1px solid #334155", borderRadius: 8 }} />
            </PieChart>
          </ResponsiveContainer>
        </div>
      </div>

      {/* Recommendations table */}
      <div style={{ background: "#161b27", borderRadius: 12, padding: 24, border: "1px solid #1e2d40" }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 20 }}>
          <h3 style={{ fontSize: 14, fontWeight: 600, color: "#f1f5f9", margin: 0 }}>Top Capital Recommendations</h3>
          <button style={{ fontSize: 13, color: "#60a5fa", background: "none", border: "none", cursor: "pointer" }}>View All →</button>
        </div>
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <thead>
            <tr style={{ color: "#64748b", fontSize: 12, textTransform: "uppercase", letterSpacing: "0.06em" }}>
              {["ID", "Asset", "Recommended Action", "Projected NPV", "ROI", "Urgency", "Actions"].map(h => (
                <th key={h} style={{ textAlign: "left", padding: "8px 12px", borderBottom: "1px solid #1e2d40" }}>{h}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {recentRecommendations.map(r => (
              <tr key={r.id} style={{ borderBottom: "1px solid #1e2d40" }}>
                <td style={{ padding: "14px 12px", fontSize: 13, color: "#64748b" }}>{r.id}</td>
                <td style={{ padding: "14px 12px", fontSize: 13, color: "#f1f5f9", fontWeight: 500 }}>{r.asset}</td>
                <td style={{ padding: "14px 12px", fontSize: 13 }}>
                  <span style={{ background: "rgba(59,130,246,0.15)", color: "#60a5fa", padding: "3px 10px", borderRadius: 20, fontSize: 12 }}>
                    {r.action}
                  </span>
                </td>
                <td style={{ padding: "14px 12px", fontSize: 13, color: "#34d399", fontWeight: 600 }}>{fmt(r.npv)}</td>
                <td style={{ padding: "14px 12px", fontSize: 13, color: "#f1f5f9" }}>{r.roi}%</td>
                <td style={{ padding: "14px 12px" }}>
                  <span style={{ background: `${URGENCY_COLOR[r.urgency]}22`, color: URGENCY_COLOR[r.urgency], padding: "3px 10px", borderRadius: 20, fontSize: 12, textTransform: "capitalize" }}>
                    {r.urgency}
                  </span>
                </td>
                <td style={{ padding: "14px 12px", display: "flex", gap: 8 }}>
                  <button style={{ fontSize: 12, color: "#22c55e", background: "rgba(34,197,94,0.1)", border: "none", padding: "4px 12px", borderRadius: 6, cursor: "pointer" }}>Approve</button>
                  <button style={{ fontSize: 12, color: "#ef4444", background: "rgba(239,68,68,0.1)", border: "none", padding: "4px 12px", borderRadius: 6, cursor: "pointer" }}>Reject</button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
