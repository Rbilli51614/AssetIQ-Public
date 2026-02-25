import React from "react";
import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from "recharts";

const data = [
  { site: "Alpha",   npv: 4200000,  capex: 3100000 },
  { site: "Beta",    npv: 1800000,  capex: 1200000 },
  { site: "Gamma",   npv: 2900000,  capex: 2400000 },
  { site: "Delta",   npv: 700000,   capex: 500000  },
];

export default function PortfolioPage() {
  return (
    <div style={{ maxWidth: 1000 }}>
      <h1 style={{ fontSize: 24, fontWeight: 700, color: "#f1f5f9", marginBottom: 8 }}>Capital Portfolio</h1>
      <p style={{ fontSize: 14, color: "#64748b", marginBottom: 24 }}>Multi-objective optimized capital plan across all sites</p>

      <div style={{ background: "#161b27", borderRadius: 12, padding: 24, border: "1px solid #1e2d40" }}>
        <h3 style={{ fontSize: 14, fontWeight: 600, color: "#f1f5f9", marginBottom: 20, marginTop: 0 }}>NPV vs CapEx by Site</h3>
        <ResponsiveContainer width="100%" height={300}>
          <BarChart data={data} barGap={4}>
            <CartesianGrid strokeDasharray="3 3" stroke="#1e2d40" />
            <XAxis dataKey="site" tick={{ fontSize: 12, fill: "#64748b" }} axisLine={false} tickLine={false} />
            <YAxis tickFormatter={v => `$${v/1e6}M`} tick={{ fontSize: 12, fill: "#64748b" }} axisLine={false} tickLine={false} />
            <Tooltip formatter={(v: any) => `$${(v/1e6).toFixed(1)}M`} contentStyle={{ background: "#1e293b", border: "1px solid #334155", borderRadius: 8 }} />
            <Bar dataKey="capex" name="CapEx"        fill="#3b82f6" radius={[4,4,0,0]} />
            <Bar dataKey="npv"   name="Projected NPV" fill="#22c55e" radius={[4,4,0,0]} />
          </BarChart>
        </ResponsiveContainer>
      </div>
    </div>
  );
}
