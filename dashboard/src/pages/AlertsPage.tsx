import React, { useState, useEffect } from "react";
import { colors, radius, font, SEVERITY, SeverityKey } from "../components/tokens";
import { ConfirmDialog } from "../components/ConfirmDialog";
import { EmptyState } from "../components/StateViews";
import { useToast } from "../components/Toast";

interface Alert {
  id: string; severity: SeverityKey; assetId: string; assetName: string; site: string;
  type: "failure_probability" | "rul_threshold" | "health_drop" | "budget_overrun" | "model_drift";
  title: string; detail: string; value: string; threshold: string;
  triggeredAt: Date; status: "active" | "acknowledged" | "resolved";
  acknowledgedBy?: string; acknowledgedAt?: Date;
}

const INITIAL_ALERTS: Alert[] = [
  { id:"ALT-001", severity:"critical", assetId:"A-001", assetName:"Gas Turbine GT-4A", site:"Site Alpha",
    type:"failure_probability", title:"Critical failure probability threshold exceeded",
    detail:"Failure probability has crossed 80%. Vibration readings are 3.2σ above baseline. Immediate capital action required.",
    value:"82%", threshold:"80%", triggeredAt:new Date(Date.now()-8*60000), status:"active" },
  { id:"ALT-002", severity:"critical", assetId:"A-001", assetName:"Gas Turbine GT-4A", site:"Site Alpha",
    type:"rul_threshold", title:"Remaining useful life below critical limit",
    detail:"RUL dropped to 47 days, below the 60-day critical threshold. Replacement lead time is 90 days — procurement must begin immediately.",
    value:"47 days", threshold:"60 days", triggeredAt:new Date(Date.now()-23*60000), status:"active" },
  { id:"ALT-003", severity:"high", assetId:"A-004", assetName:"Compressor Station C5", site:"Site Gamma",
    type:"health_drop", title:"Rapid health score degradation detected",
    detail:"Health score dropped 18 points over 72 hours — the fastest decline in this asset class. Asset entered transitional health category.",
    value:"51% (−18 pts)", threshold:"−10 pts / 72h", triggeredAt:new Date(Date.now()-2.1*3600000), status:"active" },
  { id:"ALT-004", severity:"high", assetId:"A-002", assetName:"Feed Pump P-22", site:"Site Beta",
    type:"failure_probability", title:"Failure probability rising trend",
    detail:"Failure probability increased from 12% to 31% over 14 days. Trajectory will breach 40% threshold within 8 days.",
    value:"31%", threshold:"40%", triggeredAt:new Date(Date.now()-5.5*3600000), status:"acknowledged",
    acknowledgedBy:"J. Martinez", acknowledgedAt:new Date(Date.now()-4*3600000) },
  { id:"ALT-005", severity:"medium", assetId:"portfolio", assetName:"Portfolio", site:"All Sites",
    type:"budget_overrun", title:"Capital budget utilization approaching limit",
    detail:"Portfolio CapEx commitments at 84% of annual budget. 3 critical assets still require capital decisions.",
    value:"84%", threshold:"85%", triggeredAt:new Date(Date.now()-14*3600000), status:"active" },
  { id:"ALT-006", severity:"medium", assetId:"model", assetName:"Prediction Model", site:"Global",
    type:"model_drift", title:"Prediction confidence declining — sensor data quality",
    detail:"Average prediction confidence dropped to 0.71 across Site Beta assets. 2 sensors show stale readings.",
    value:"0.71", threshold:"0.80", triggeredAt:new Date(Date.now()-26*3600000), status:"resolved" },
];

const TYPE_ICONS: Record<Alert["type"], string> = {
  failure_probability:"⚡", rul_threshold:"⏱", health_drop:"↘", budget_overrun:"$", model_drift:"⊘",
};
const TYPE_LABELS: Record<Alert["type"], string> = {
  failure_probability:"Failure Risk", rul_threshold:"RUL Alert", health_drop:"Health Drop",
  budget_overrun:"Budget", model_drift:"Model Quality",
};

function formatAge(d: Date) {
  const ms = Date.now()-d.getTime(), min = Math.floor(ms/60000);
  if (min<60) return `${min}m ago`;
  const hr = Math.floor(min/60);
  if (hr<24) return `${hr}h ago`;
  return `${Math.floor(hr/24)}d ago`;
}

function SummaryCard({ label, count, color }: { label:string; count:number; color:string }) {
  return (
    <div style={{ background:colors.bgCard, border:`1px solid ${colors.border}`, borderTop:`2px solid ${color}`, borderRadius:radius.lg, padding:"16px 20px", flex:1 }}>
      <div style={{ fontSize:28, fontWeight:800, color, lineHeight:1 }}>{count}</div>
      <div style={{ fontSize:12, color:colors.textSecondary, marginTop:4, textTransform:"uppercase", letterSpacing:"0.06em" }}>{label}</div>
    </div>
  );
}

function AlertDetail({ alert }: { alert: Alert | null }) {
  if (!alert) return (
    <div style={{ height:"100%", display:"flex", alignItems:"center", justifyContent:"center", color:colors.textMuted, fontSize:13 }}>
      Select an alert to view details
    </div>
  );
  const sev = SEVERITY[alert.severity];
  return (
    <div style={{ padding:24, display:"flex", flexDirection:"column", gap:20 }}>
      <div>
        <div style={{ display:"inline-flex", alignItems:"center", gap:6, padding:"4px 12px", borderRadius:radius.pill, background:sev.dim, color:sev.color, fontSize:11, fontWeight:700, textTransform:"uppercase", letterSpacing:"0.08em", marginBottom:12 }}>
          {TYPE_ICONS[alert.type]} {TYPE_LABELS[alert.type]}
        </div>
        <div style={{ fontSize:15, fontWeight:700, color:colors.textPrimary, lineHeight:1.4 }}>{alert.title}</div>
        <div style={{ fontSize:13, color:colors.textSecondary, marginTop:8, lineHeight:1.7 }}>{alert.detail}</div>
      </div>
      <div style={{ display:"grid", gridTemplateColumns:"1fr 1fr", gap:10 }}>
        {[
          { label:"Current value", value:alert.value,     color:sev.color },
          { label:"Threshold",     value:alert.threshold, color:colors.textSecondary },
          { label:"Asset",         value:alert.assetName, color:colors.textPrimary },
          { label:"Site",          value:alert.site,      color:colors.textPrimary },
        ].map(({ label, value, color }) => (
          <div key={label} style={{ background:colors.bg, borderRadius:radius.md, padding:"12px 14px", border:`1px solid ${colors.border}` }}>
            <div style={{ fontSize:11, color:colors.textMuted, textTransform:"uppercase", letterSpacing:"0.06em", marginBottom:4 }}>{label}</div>
            <div style={{ fontSize:15, fontWeight:700, color, fontFamily:font.mono }}>{value}</div>
          </div>
        ))}
      </div>
      <div style={{ background:colors.bg, borderRadius:radius.md, padding:"14px 16px", border:`1px solid ${colors.border}` }}>
        <div style={{ fontSize:12, color:colors.textMuted, textTransform:"uppercase", letterSpacing:"0.06em", marginBottom:10 }}>Status Timeline</div>
        {[
          { show:true, label:"Triggered", time:alert.triggeredAt, color:sev.color },
          { show:!!alert.acknowledgedBy, label:`Acknowledged by ${alert.acknowledgedBy}`, time:alert.acknowledgedAt!, color:colors.blue },
          { show:alert.status==="resolved", label:"Resolved", time:new Date(), color:colors.green },
        ].filter(x=>x.show).map(({ label, time, color }) => (
          <div key={label} style={{ display:"flex", justifyContent:"space-between", marginBottom:8 }}>
            <span style={{ fontSize:13, color:colors.textSecondary, display:"flex", gap:8, alignItems:"center" }}>
              <span style={{ width:8, height:8, borderRadius:"50%", background:color, display:"inline-block" }} />{label}
            </span>
            <span style={{ fontSize:12, color:colors.textMuted, fontFamily:font.mono }}>{time?.toLocaleTimeString("en-US",{hour:"2-digit",minute:"2-digit"})}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

export default function AlertsPage() {
  const [alerts, setAlerts]       = useState<Alert[]>(INITIAL_ALERTS);
  const [selected, setSelected]   = useState<Alert|null>(null);
  const [statusFilter, setStatus] = useState<"all"|"active"|"acknowledged"|"resolved">("all");
  const [sevFilter, setSev]       = useState<"all"|SeverityKey>("all");
  const [dialog, setDialog]       = useState<{ alert:Alert; action:"acknowledge"|"resolve" }|null>(null);
  const toast = useToast();

  useEffect(() => {
    const t = setTimeout(() => {
      const a: Alert = { id:`ALT-NEW`, severity:"high", assetId:"A-003", assetName:"Transformer TX-7", site:"Site Alpha",
        type:"health_drop", title:"Health score declined below warning threshold",
        detail:"Health score dropped from 88% to 79% over 6 hours.", value:"79%", threshold:"80%",
        triggeredAt:new Date(), status:"active" };
      setAlerts(prev => [a, ...prev]);
      toast.warn("New alert triggered", "Transformer TX-7 — health score below 80%");
    }, 30000);
    return () => clearTimeout(t);
  }, []);

  const visible = alerts.filter(a =>
    (statusFilter==="all"||a.status===statusFilter) && (sevFilter==="all"||a.severity===sevFilter)
  );

  const counts = {
    active:       alerts.filter(a=>a.status==="active").length,
    critical:     alerts.filter(a=>a.severity==="critical"&&a.status==="active").length,
    acknowledged: alerts.filter(a=>a.status==="acknowledged").length,
    resolved:     alerts.filter(a=>a.status==="resolved").length,
  };

  function handleConfirm() {
    if (!dialog) return;
    const { alert, action } = dialog;
    setAlerts(prev => prev.map(a => a.id!==alert.id ? a : {
      ...a, status: action==="acknowledge"?"acknowledged":"resolved",
      ...(action==="acknowledge" ? { acknowledgedBy:"Current User", acknowledgedAt:new Date() } : {}),
    }));
    if (selected?.id===alert.id) setSelected(null);
    setDialog(null);
    if (action==="acknowledge") toast.info("Alert acknowledged", alert.title);
    else toast.success("Alert resolved", alert.title);
  }

  return (
    <div style={{ maxWidth:1400, fontFamily:font.sans }}>
      <style>{`@keyframes aiq-pulse-dot{0%,100%{opacity:1}50%{opacity:0.4}}`}</style>

      {/* Header */}
      <div style={{ display:"flex", justifyContent:"space-between", alignItems:"flex-start", marginBottom:24 }}>
        <div>
          <h1 style={{ fontSize:24, fontWeight:700, color:colors.textPrimary, margin:0 }}>Alert Center</h1>
          <p style={{ fontSize:14, color:colors.textSecondary, marginTop:4 }}>Real-time risk threshold monitoring across all assets</p>
        </div>
        {counts.critical>0 && (
          <div style={{ padding:"6px 14px", borderRadius:radius.pill, background:colors.redDim, border:`1px solid ${colors.red}44`, fontSize:13, fontWeight:700, color:colors.red, display:"flex", alignItems:"center", gap:6 }}>
            <div style={{ width:7, height:7, borderRadius:"50%", background:colors.red, animation:"aiq-pulse-dot 1.2s ease-in-out infinite" }} />
            {counts.critical} Critical
          </div>
        )}
      </div>

      {/* Summary strip */}
      <div style={{ display:"flex", gap:12, marginBottom:24 }}>
        <SummaryCard label="Active"       count={counts.active}       color={colors.red}    />
        <SummaryCard label="Critical"     count={counts.critical}     color={colors.orange} />
        <SummaryCard label="Acknowledged" count={counts.acknowledged} color={colors.blue}   />
        <SummaryCard label="Resolved"     count={counts.resolved}     color={colors.green}  />
      </div>

      {/* Main grid */}
      <div style={{ display:"grid", gridTemplateColumns:"1fr 340px", gap:16 }}>
        {/* List */}
        <div style={{ background:colors.bgCard, border:`1px solid ${colors.border}`, borderRadius:radius.lg, overflow:"hidden" }}>
          {/* Filters */}
          <div style={{ display:"flex", gap:6, padding:"12px 16px", borderBottom:`1px solid ${colors.border}`, background:colors.bgPanel, flexWrap:"wrap", alignItems:"center" }}>
            <span style={{ fontSize:12, color:colors.textMuted }}>Status:</span>
            {(["all","active","acknowledged","resolved"] as const).map(s => {
              const active = statusFilter===s;
              return <button key={s} onClick={()=>setStatus(s)} style={{ fontSize:12, fontWeight:active?600:400, padding:"3px 10px", borderRadius:radius.pill, border:`1px solid ${active?colors.blue:colors.border}`, background:active?colors.blueDim:"transparent", color:active?colors.blue:colors.textSecondary, cursor:"pointer", textTransform:"capitalize" }}>{s}</button>;
            })}
            <div style={{ width:1, background:colors.border, height:16, margin:"0 4px" }} />
            <span style={{ fontSize:12, color:colors.textMuted }}>Severity:</span>
            {(["all","critical","high","medium","low"] as const).map(s => {
              const active = sevFilter===s;
              const c = s==="all" ? colors.blue : SEVERITY[s]?.color ?? colors.blue;
              return <button key={s} onClick={()=>setSev(s)} style={{ fontSize:12, fontWeight:active?600:400, padding:"3px 10px", borderRadius:radius.pill, border:`1px solid ${active?c:colors.border}`, background:active?`${c}18`:"transparent", color:active?c:colors.textSecondary, cursor:"pointer", textTransform:"capitalize" }}>{s}</button>;
            })}
          </div>

          {visible.length===0
            ? <EmptyState icon="✓" title="No alerts match filters" detail="All clear for selected filters." height={260} />
            : visible.map(alert => {
              const sev = SEVERITY[alert.severity];
              const isActive = alert.status==="active";
              return (
                <div key={alert.id} onClick={()=>setSelected(alert)} style={{ display:"grid", gridTemplateColumns:"4px 1fr auto", borderBottom:`1px solid ${colors.border}`, background:selected?.id===alert.id?colors.bgActive:"transparent", cursor:"pointer", transition:"background 0.12s" }}>
                  <div style={{ width:4, alignSelf:"stretch", background:isActive?sev.color:colors.textMuted, opacity:alert.status==="resolved"?0.25:1 }} />
                  <div style={{ padding:"14px 16px" }}>
                    <div style={{ display:"flex", alignItems:"center", gap:8, flexWrap:"wrap", marginBottom:3 }}>
                      <span style={{ fontSize:13, fontWeight:600, color:alert.status==="resolved"?colors.textMuted:colors.textPrimary, textDecoration:alert.status==="resolved"?"line-through":"none" }}>{alert.title}</span>
                      <span style={{ fontSize:11, fontWeight:700, padding:"2px 7px", borderRadius:radius.pill, background:sev.dim, color:sev.color, textTransform:"uppercase", letterSpacing:"0.05em" }}>{sev.label}</span>
                      {alert.status!=="active" && <span style={{ fontSize:11, padding:"2px 7px", borderRadius:radius.pill, background:colors.bgHover, color:colors.textMuted, textTransform:"capitalize" }}>{alert.status}</span>}
                    </div>
                    <div style={{ fontSize:12, color:colors.textSecondary }}>{alert.assetName} · {alert.site} · {TYPE_LABELS[alert.type]}</div>
                    <div style={{ display:"flex", gap:16, marginTop:5 }}>
                      <span style={{ fontSize:12, fontFamily:font.mono, color:sev.color }}>{alert.value}</span>
                      <span style={{ fontSize:12, color:colors.textMuted }}>threshold: <span style={{ fontFamily:font.mono }}>{alert.threshold}</span></span>
                      <span style={{ fontSize:12, color:colors.textMuted }}>{formatAge(alert.triggeredAt)}</span>
                    </div>
                  </div>
                  <div style={{ padding:"0 14px", display:"flex", gap:8, alignItems:"center" }} onClick={e=>e.stopPropagation()}>
                    {alert.status==="active" && <>
                      <button onClick={()=>setDialog({alert,action:"acknowledge"})} style={{ fontSize:12, fontWeight:600, padding:"5px 10px", borderRadius:radius.md, border:`1px solid ${colors.blue}44`, background:"transparent", color:colors.blue, cursor:"pointer" }}>Acknowledge</button>
                      <button onClick={()=>setDialog({alert,action:"resolve"})}     style={{ fontSize:12, fontWeight:600, padding:"5px 10px", borderRadius:radius.md, border:`1px solid ${colors.green}44`, background:"transparent", color:colors.green, cursor:"pointer" }}>Resolve</button>
                    </>}
                    {alert.status==="acknowledged" && (
                      <button onClick={()=>setDialog({alert,action:"resolve"})} style={{ fontSize:12, fontWeight:600, padding:"5px 10px", borderRadius:radius.md, border:`1px solid ${colors.green}44`, background:"transparent", color:colors.green, cursor:"pointer" }}>Resolve</button>
                    )}
                    {alert.status==="resolved" && <span style={{ fontSize:12, color:colors.textMuted, whiteSpace:"nowrap" }}>Closed</span>}
                  </div>
                </div>
              );
            })
          }
        </div>

        {/* Detail panel */}
        <div style={{ background:colors.bgCard, border:`1px solid ${colors.border}`, borderRadius:radius.lg, overflow:"hidden", minHeight:400 }}>
          <div style={{ padding:"13px 24px", borderBottom:`1px solid ${colors.border}`, background:colors.bgPanel, fontSize:12, fontWeight:600, color:colors.textMuted, textTransform:"uppercase", letterSpacing:"0.08em" }}>Alert Detail</div>
          <AlertDetail alert={selected} />
        </div>
      </div>

      {/* Confirm */}
      <ConfirmDialog
        open={!!dialog}
        variant={dialog?.action==="resolve"?"success":"info"}
        title={dialog?.action==="acknowledge"?"Acknowledge this alert?":"Mark alert as resolved?"}
        message={dialog ? (
          <div>
            <strong style={{ color:colors.textPrimary }}>{dialog.alert.assetName}</strong>
            <span style={{ color:colors.textSecondary }}> · {dialog.alert.title}</span>
            <div style={{ marginTop:10, fontSize:14, color:colors.textSecondary }}>
              {dialog.action==="acknowledge"
                ? "This will mark the alert as acknowledged and log your user ID. The alert remains until resolved."
                : "This will close the alert and remove it from the active queue. Logged in audit trail."}
            </div>
          </div>
        ) : ""}
        confirmLabel={dialog?.action==="acknowledge"?"Acknowledge":"Mark Resolved"}
        onConfirm={handleConfirm}
        onCancel={()=>setDialog(null)}
      />
    </div>
  );
}
