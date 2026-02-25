import React, { useState } from "react";
import { RadarChart, Radar, PolarGrid, PolarAngleAxis, ResponsiveContainer, Tooltip } from "recharts";

const MOCK_ASSETS = [
  { id: "A-001", name: "Gas Turbine GT-4A",    site: "Site Alpha", regime: "stressed",     health: 34, failProb: 0.82, rul: 47,  status: "critical" },
  { id: "A-002", name: "Feed Pump P-22",        site: "Site Beta",  regime: "normal",       health: 71, failProb: 0.31, rul: 280, status: "degraded"  },
  { id: "A-003", name: "Transformer TX-7",      site: "Site Alpha", regime: "normal",       health: 88, failProb: 0.12, rul: 510, status: "healthy"   },
  { id: "A-004", name: "Compressor Station C5", site: "Site Gamma", regime: "transitional", health: 51, failProb: 0.61, rul: 120, status: "degraded"  },
  { id: "A-005", name: "Pipeline Segment P9",   site: "Site Beta",  regime: "normal",       health: 92, failProb: 0.06, rul: 720, status: "healthy"   },
  { id: "A-006", name: "Heat Exchanger HX-3",   site: "Site Gamma", regime: "offline",      health: 0,  failProb: 0,    rul: 0,   status: "offline"   },
];

// Maps internal API `regime` values to user-facing Asset Health Category labels and colors
const HEALTH_CATEGORY_COLOR: Record<string, string> = {
  normal: "#22c55e", stressed: "#ef4444", transitional: "#eab308", maintenance: "#60a5fa", offline: "#484f58",
};

const HEALTH_CATEGORY_LABEL: Record<string, string> = {
  normal:       "Normal Operations",
  stressed:     "Stressed",
  transitional: "Transitional",
  maintenance:  "Maintenance Mode",
  offline:      "Offline",
};

const STATUS_COLOR: Record<string, string> = {
  healthy: "#22c55e", degraded: "#eab308", critical: "#ef4444",
};

function HealthBar({ value }: { value: number }) {
  const color = value > 70 ? "#22c55e" : value > 40 ? "#eab308" : "#ef4444";
  return (
    <div style={{ background: "#0f1117", borderRadius: 4, height: 6, width: 120, overflow: "hidden" }}>
      <div style={{ width: `${value}%`, height: "100%", background: color, borderRadius: 4, transition: "width 0.3s" }} />
    </div>
  );
}

export default function AssetHealthPage() {
  const [selected, setSelected] = useState(MOCK_ASSETS[0]);

  const radarData = [
    { axis: "Vibration",    value: 100 - selected.health * 0.6 },
    { axis: "Temperature",  value: selected.failProb * 60       },
    { axis: "Pressure",     value: 30                           },
    { axis: "Lubrication",  value: 100 - selected.health        },
    { axis: "Electrical",   value: selected.failProb * 40       },
  ];

  const healthCategoryLabel = HEALTH_CATEGORY_LABEL[selected.regime] ?? selected.regime;
  const healthCategoryColor = HEALTH_CATEGORY_COLOR[selected.regime];

  return (
    <div style={{ maxWidth: 1400 }}>
      <div style={{ marginBottom: 24 }}>
        <h1 style={{ fontSize: 24, fontWeight: 700, color: "#f1f5f9", margin: 0 }}>Asset Health Monitor</h1>
        <p style={{ fontSize: 14, color: "#64748b", marginTop: 4 }}>Asset health category · Failure probability · Remaining useful life</p>
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "1.5fr 1fr", gap: 16 }}>
        {/* Asset table */}
        <div style={{ background: "#161b27", borderRadius: 12, border: "1px solid #1e2d40", overflow: "hidden" }}>
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead>
              <tr style={{ color: "#64748b", fontSize: 12, textTransform: "uppercase", background: "#0f1117" }}>
                {["Asset", "Site", "Asset Health Category", "Health", "Fail Prob", "RUL (days)"].map(h => (
                  <th key={h} style={{ textAlign: "left", padding: "12px 16px" }}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {MOCK_ASSETS.map(a => (
                <tr
                  key={a.id}
                  onClick={() => setSelected(a)}
                  style={{
                    borderBottom: "1px solid #1e2d40", cursor: "pointer",
                    background: selected.id === a.id ? "rgba(59,130,246,0.08)" : "transparent",
                  }}
                >
                  <td style={{ padding: "14px 16px" }}>
                    <div style={{ fontSize: 13, fontWeight: 600, color: "#f1f5f9" }}>{a.name}</div>
                    <div style={{ fontSize: 11, color: "#64748b" }}>{a.id}</div>
                  </td>
                  <td style={{ padding: "14px 16px", fontSize: 13, color: "#94a3b8" }}>{a.site}</td>
                  <td style={{ padding: "14px 16px" }}>
                    <span style={{ color: HEALTH_CATEGORY_COLOR[a.regime], fontSize: 12, fontWeight: 600 }}>
                      ● {HEALTH_CATEGORY_LABEL[a.regime] ?? a.regime}
                    </span>
                  </td>
                  <td style={{ padding: "14px 16px" }}>
                    <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                      <HealthBar value={a.health} />
                      <span style={{ fontSize: 12, color: "#94a3b8" }}>{a.health}%</span>
                    </div>
                  </td>
                  <td style={{ padding: "14px 16px" }}>
                    <span style={{ color: a.regime === "offline" ? "#484f58" : a.failProb > 0.6 ? "#ef4444" : a.failProb > 0.3 ? "#eab308" : "#22c55e", fontWeight: 700, fontSize: 13 }}>
                      {a.regime === "offline" ? "—" : `${(a.failProb * 100).toFixed(0)}%`}
                    </span>
                  </td>
                  <td style={{ padding: "14px 16px", fontSize: 13, color: "#94a3b8" }}>{a.regime === "offline" ? "—" : `${a.rul} days`}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        {/* Asset detail */}
        <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
          <div style={{ background: "#161b27", borderRadius: 12, padding: 24, border: "1px solid #1e2d40" }}>
            <h3 style={{ margin: "0 0 4px", fontSize: 16, color: "#f1f5f9" }}>{selected.name}</h3>
            <div style={{ fontSize: 12, color: "#64748b", marginBottom: 20 }}>{selected.id} · {selected.site}</div>

            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12, marginBottom: 20 }}>
              {[
                { label: "Health Score",          value: selected.regime === "offline" ? "—" : `${selected.health}%`,                    color: selected.regime === "offline" ? "#484f58" : STATUS_COLOR[selected.status] },
                { label: "Failure Prob",           value: selected.regime === "offline" ? "—" : `${(selected.failProb*100).toFixed(0)}%`, color: selected.regime === "offline" ? "#484f58" : selected.failProb > 0.6 ? "#ef4444" : "#eab308" },
                { label: "RUL",                    value: selected.regime === "offline" ? "—" : `${selected.rul} days`,                   color: selected.regime === "offline" ? "#484f58" : "#60a5fa" },
                { label: "Asset Health Category",  value: healthCategoryLabel,                      color: healthCategoryColor },
              ].map(({ label, value, color }) => (
                <div key={label} style={{ background: "#0f1117", borderRadius: 8, padding: "12px 16px" }}>
                  <div style={{ fontSize: 11, color: "#64748b", marginBottom: 4, textTransform: "uppercase" }}>{label}</div>
                  <div style={{ fontSize: 20, fontWeight: 700, color }}>{value}</div>
                </div>
              ))}
            </div>

            <ResponsiveContainer width="100%" height={200}>
              <RadarChart data={radarData}>
                <PolarGrid stroke="#1e2d40" />
                <PolarAngleAxis dataKey="axis" tick={{ fontSize: 11, fill: "#64748b" }} />
                <Radar dataKey="value" stroke="#3b82f6" fill="#3b82f6" fillOpacity={0.2} />
                <Tooltip contentStyle={{ background: "#1e293b", border: "1px solid #334155", borderRadius: 8 }} />
              </RadarChart>
            </ResponsiveContainer>
          </div>

          <div style={{ background: "#161b27", borderRadius: 12, padding: 20, border: "1px solid #1e2d40" }}>
            <h4 style={{ fontSize: 13, fontWeight: 600, color: "#f1f5f9", margin: "0 0 12px" }}>AI Explanation</h4>
            <p style={{ fontSize: 13, color: "#94a3b8", lineHeight: 1.6, margin: 0 }}>
              {selected.regime === "offline"
                ? "Asset is currently offline and not producing sensor data. No failure prediction is available. Verify operational status before resuming monitoring."
                : selected.status === "critical"
                ? `⚠️ HIGH RISK — ${(selected.failProb*100).toFixed(0)}% probability of failure within 90 days. Asset health category: ${healthCategoryLabel}. Primary contributing factors: vibration anomaly (+3.2σ), bearing temperature trend. Immediate capital action recommended.`
                : `Asset health category: ${healthCategoryLabel}. Health trajectory is stable. Recommend continued monitoring. Next scheduled inspection in 45 days.`}
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}
