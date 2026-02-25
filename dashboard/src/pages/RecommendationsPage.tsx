import React, { useState } from "react";
import { colors, radius, font, SEVERITY, SeverityKey } from "../components/tokens";
import { ConfirmDialog } from "../components/ConfirmDialog";
import { AuditLog, AuditEntry } from "../components/AuditLog";
import { EmptyState } from "../components/StateViews";
import { useToast } from "../components/Toast";

// ── Types ─────────────────────────────────────────────────────────────────────
type RecStatus = "pending" | "approved" | "rejected" | "deferred";
type RecAction = "replace" | "overhaul" | "monitor" | "decommission";

interface Recommendation {
  id:                 string;
  priorityRank:       number;
  assetId:            string;
  assetName:          string;
  site:               string;
  action:             RecAction;
  urgency:            SeverityKey;
  estimatedCapex:     number;
  npv:                number;
  roiPct:             number;
  paybackYears:       number;
  riskScore:          number;
  riskReduction:      number;
  failureProbability: number;
  rulDays:            number;
  rationale:          string;
  alternatives:       string;
  status:             RecStatus;
  runId:              string;
  generatedAt:        Date;
}

// ── Mock data ─────────────────────────────────────────────────────────────────
const INITIAL_RECS: Recommendation[] = [
  {
    id: "R-001", priorityRank: 1,
    assetId: "A-001", assetName: "Gas Turbine GT-4A", site: "Site Alpha",
    action: "replace", urgency: "critical",
    estimatedCapex: 3_200_000, npv: 4_200_000, roiPct: 38.2, paybackYears: 2.6,
    riskScore: 0.78, riskReduction: 64, failureProbability: 0.82, rulDays: 47,
    rationale: "Failure probability of 82% exceeds the critical 80% threshold with only 47 days of remaining useful life. Replacement lead time is 90 days — procurement must be initiated immediately to avoid unplanned outage. Expected NPV uplift of $4.2M accounts for avoided downtime costs ($1.8M), OpEx savings ($1.2M/yr), and salvage value.",
    alternatives: "Overhaul considered but rejected: projected failure probability post-overhaul still 51% given age of secondary components. Deferral not viable — RUL is below procurement lead time.",
    status: "pending", runId: "OPT-2024-Q4-001", generatedAt: new Date(Date.now() - 2 * 3600000),
  },
  {
    id: "R-002", priorityRank: 2,
    assetId: "A-004", assetName: "Compressor Station C5", site: "Site Gamma",
    action: "replace", urgency: "high",
    estimatedCapex: 1_850_000, npv: 2_100_000, roiPct: 31.4, paybackYears: 3.2,
    riskScore: 0.58, riskReduction: 49, failureProbability: 0.61, rulDays: 120,
    rationale: "Failure probability of 61% and rapid 18-point health drop over 72 hours indicate accelerating degradation. 120-day RUL provides procurement window. Replacement ROI of 31.4% is top quartile for this asset class.",
    alternatives: "Major overhaul ($640K) would extend useful life ~18 months but ROI is 12.1% vs 31.4% for replacement. Given degradation trajectory, replacement is the superior capital allocation.",
    status: "pending", runId: "OPT-2024-Q4-001", generatedAt: new Date(Date.now() - 2 * 3600000),
  },
  {
    id: "R-003", priorityRank: 3,
    assetId: "A-002", assetName: "Feed Pump P-22", site: "Site Beta",
    action: "overhaul", urgency: "high",
    estimatedCapex: 185_000, npv: 890_000, roiPct: 22.1, paybackYears: 4.5,
    riskScore: 0.30, riskReduction: 28, failureProbability: 0.31, rulDays: 280,
    rationale: "Rising failure probability (12% → 31% in 14 days) and bearing temperature trend suggest impending component failure. Targeted overhaul of bearing assembly and seal replacement recommended. Cost-effective at $185K vs $450K replacement.",
    alternatives: "Full replacement ($450K) would yield 38% vs 22% ROI but is not warranted given 280-day RUL and contained failure scope.",
    status: "approved", runId: "OPT-2024-Q4-001", generatedAt: new Date(Date.now() - 2 * 3600000),
  },
  {
    id: "R-004", priorityRank: 4,
    assetId: "A-005", assetName: "Pipeline Segment P9", site: "Site Beta",
    action: "monitor", urgency: "low",
    estimatedCapex: 12_000, npv: 110_000, roiPct: 8.3, paybackYears: 1.4,
    riskScore: 0.06, riskReduction: 4, failureProbability: 0.06, rulDays: 720,
    rationale: "Asset in Normal Operations health category with 720-day RUL and 6% failure probability. Enhanced monitoring program ($12K/yr sensor upgrades) recommended to maintain data quality.",
    alternatives: "No capital action required at this time. Monitoring is the optimal allocation given low risk score and long RUL.",
    status: "pending", runId: "OPT-2024-Q4-001", generatedAt: new Date(Date.now() - 2 * 3600000),
  },
  {
    id: "R-005", priorityRank: 5,
    assetId: "A-003", assetName: "Transformer TX-7", site: "Site Alpha",
    action: "monitor", urgency: "medium",
    estimatedCapex: 28_000, npv: 210_000, roiPct: 14.2, paybackYears: 1.9,
    riskScore: 0.12, riskReduction: 9, failureProbability: 0.12, rulDays: 510,
    rationale: "Asset recently flagged for minor thermal signature changes. Predictive sensor package upgrade recommended to improve early-warning fidelity. No capital replacement required within planning horizon.",
    alternatives: "Deferral of monitoring upgrade acceptable if budget constrained — risk increase is minimal over 6-month window.",
    status: "rejected", runId: "OPT-2024-Q4-001", generatedAt: new Date(Date.now() - 2 * 3600000),
  },
];

const INITIAL_AUDIT: AuditEntry[] = [
  { id: "AU-001", timestamp: new Date(Date.now() - 90 * 60000), actor: "System",     action: "created",  target: "Optimization run OPT-2024-Q4-001", notes: "5 recommendations generated from 200-asset portfolio" },
  { id: "AU-002", timestamp: new Date(Date.now() - 85 * 60000), actor: "S. Chen",    action: "viewed",   target: "R-001 — Gas Turbine GT-4A replacement" },
  { id: "AU-003", timestamp: new Date(Date.now() - 70 * 60000), actor: "S. Chen",    action: "approved", target: "R-003 — Feed Pump P-22 overhaul", notes: "Approved at weekly ops review. PO to be raised by end of week." },
  { id: "AU-004", timestamp: new Date(Date.now() - 45 * 60000), actor: "J. Martinez",action: "rejected", target: "R-005 — Transformer TX-7 monitoring upgrade", notes: "Deferred to Q1 budget cycle. Not urgent given 510-day RUL." },
];

// ── Style helpers ─────────────────────────────────────────────────────────────
const ACTION_STYLE: Record<RecAction, { color: string; label: string; icon: string }> = {
  replace:      { color: colors.red,    label: "Replace",      icon: "↺" },
  overhaul:     { color: colors.orange, label: "Overhaul",     icon: "⚙" },
  monitor:      { color: colors.blue,   label: "Monitor",      icon: "◎" },
  decommission: { color: colors.purple, label: "Decommission", icon: "✗" },
};

const STATUS_STYLE: Record<RecStatus, { color: string; label: string }> = {
  pending:  { color: colors.yellow, label: "Pending"  },
  approved: { color: colors.green,  label: "Approved" },
  rejected: { color: colors.red,    label: "Rejected" },
  deferred: { color: colors.blue,   label: "Deferred" },
};

const fmt = (v: number) =>
  v >= 1_000_000 ? `$${(v / 1_000_000).toFixed(1)}M`
  : v >= 1_000   ? `$${(v / 1_000).toFixed(0)}K`
  : `$${v}`;

// ── Sub-components ────────────────────────────────────────────────────────────
function Chip({ color, children }: { color: string; children: React.ReactNode }) {
  return (
    <span style={{
      fontSize: 11, fontWeight: 700, padding: "3px 10px", borderRadius: radius.pill,
      background: `${color}18`, color, border: `1px solid ${color}30`,
      textTransform: "uppercase" as const, letterSpacing: "0.06em",
    }}>{children}</span>
  );
}

function SectionLabel({ children }: { children: React.ReactNode }) {
  return <div style={{ fontSize: 11, fontWeight: 700, color: colors.textMuted, textTransform: "uppercase" as const, letterSpacing: "0.08em", marginBottom: 10 }}>{children}</div>;
}

function StatMini({ label, value, color = colors.textPrimary, mono = false }: { label: string; value: string; color?: string; mono?: boolean }) {
  return (
    <div style={{ background: colors.bg, borderRadius: radius.md, padding: "12px 14px", border: `1px solid ${colors.border}` }}>
      <div style={{ fontSize: 11, color: colors.textMuted, textTransform: "uppercase" as const, letterSpacing: "0.06em", marginBottom: 4 }}>{label}</div>
      <div style={{ fontSize: 17, fontWeight: 700, color, fontFamily: mono ? font.mono : font.sans }}>{value}</div>
    </div>
  );
}

// ── Row component ─────────────────────────────────────────────────────────────
function RecRow({ rec, selected, onClick, onApprove, onReject }: {
  rec: Recommendation; selected: boolean;
  onClick: () => void; onApprove: () => void; onReject: () => void;
}) {
  const act = ACTION_STYLE[rec.action];
  const sev = SEVERITY[rec.urgency];
  const sts = STATUS_STYLE[rec.status];
  const canAct = rec.status === "pending";

  return (
    <div onClick={onClick} style={{
      display: "grid", gridTemplateColumns: "4px 1fr auto",
      borderBottom: `1px solid ${colors.border}`,
      background: selected ? colors.bgActive : "transparent",
      cursor: "pointer", transition: "background 0.12s",
    }}>
      <div style={{ background: sev.color, opacity: rec.status !== "pending" ? 0.25 : 1, width: 4, alignSelf: "stretch" }} />
      <div style={{ padding: "14px 16px" }}>
        <div style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" as const, marginBottom: 4 }}>
          <span style={{ fontSize: 11, color: colors.textMuted, fontFamily: font.mono }}>#{rec.priorityRank}</span>
          <span style={{ fontSize: 13, fontWeight: 600, color: colors.textPrimary }}>{rec.assetName}</span>
          <Chip color={act.color}>{act.icon} {act.label}</Chip>
          <Chip color={sts.color}>{sts.label}</Chip>
        </div>
        <div style={{ fontSize: 12, color: colors.textSecondary, marginBottom: 6 }}>{rec.site}</div>
        <div style={{ display: "flex", gap: 16 }}>
          <span style={{ fontSize: 12, color: colors.green, fontFamily: font.mono, fontWeight: 600 }}>{fmt(rec.npv)} NPV</span>
          <span style={{ fontSize: 12, color: colors.textSecondary }}>{fmt(rec.estimatedCapex)} CapEx</span>
          <span style={{ fontSize: 12, color: sev.color, fontFamily: font.mono }}>{(rec.failureProbability * 100).toFixed(0)}% fail</span>
        </div>
      </div>
      {canAct && (
        <div style={{ padding: "0 14px", display: "flex", gap: 6, alignItems: "center" }} onClick={e => e.stopPropagation()}>
          <button onClick={onApprove} style={{ width: 28, height: 28, borderRadius: radius.md, border: `1px solid ${colors.green}44`, background: `${colors.green}12`, color: colors.green, fontSize: 14, fontWeight: 700, cursor: "pointer" }}>✓</button>
          <button onClick={onReject}  style={{ width: 28, height: 28, borderRadius: radius.md, border: `1px solid ${colors.red}44`,   background: `${colors.red}12`,   color: colors.red,   fontSize: 14, fontWeight: 700, cursor: "pointer" }}>✗</button>
        </div>
      )}
    </div>
  );
}

// ── Detail panel ──────────────────────────────────────────────────────────────
function RecDetail({ rec, onApprove, onReject, onDefer }: {
  rec: Recommendation | null;
  onApprove: (r: Recommendation) => void;
  onReject:  (r: Recommendation) => void;
  onDefer:   (r: Recommendation) => void;
}) {
  if (!rec) return (
    <div style={{ height: "100%", display: "flex", alignItems: "center", justifyContent: "center", flexDirection: "column" as const, gap: 8, color: colors.textMuted, fontSize: 13 }}>
      <div style={{ fontSize: 28 }}>←</div>
      <div>Select a recommendation to review</div>
    </div>
  );

  const act = ACTION_STYLE[rec.action];
  const sev = SEVERITY[rec.urgency];
  const sts = STATUS_STYLE[rec.status];

  return (
    <div style={{ padding: 24, display: "flex", flexDirection: "column" as const, gap: 20, overflowY: "auto" as const, maxHeight: "100%" }}>
      <div>
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap" as const, marginBottom: 12 }}>
          <Chip color={act.color}>{act.icon} {act.label}</Chip>
          <Chip color={sev.color}>{sev.label}</Chip>
          <Chip color={sts.color}>● {sts.label}</Chip>
        </div>
        <div style={{ fontSize: 17, fontWeight: 700, color: colors.textPrimary, lineHeight: 1.3 }}>{rec.assetName}</div>
        <div style={{ fontSize: 13, color: colors.textSecondary, marginTop: 4 }}>{rec.assetId} · {rec.site} · Priority #{rec.priorityRank}</div>
      </div>

      <div>
        <SectionLabel>Financial Case</SectionLabel>
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8 }}>
          <StatMini label="Est. CapEx"    value={fmt(rec.estimatedCapex)} />
          <StatMini label="Projected NPV" value={fmt(rec.npv)}            color={colors.green} />
          <StatMini label="ROI"           value={`${rec.roiPct.toFixed(1)}%`} color={colors.green} />
          <StatMini label="Payback"       value={`${rec.paybackYears.toFixed(1)} yrs`} color={colors.blue} />
        </div>
      </div>

      <div>
        <SectionLabel>Risk Profile</SectionLabel>
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8 }}>
          <StatMini label="Failure Prob"   value={`${(rec.failureProbability * 100).toFixed(0)}%`} color={colors.red}    mono />
          <StatMini label="RUL"            value={`${rec.rulDays} days`}                           color={colors.orange} mono />
          <StatMini label="Risk Score"     value={rec.riskScore.toFixed(2)}                        color={colors.yellow} mono />
          <StatMini label="Risk Reduction" value={`−${rec.riskReduction}%`}                        color={colors.green}  mono />
        </div>
      </div>

      <div>
        <SectionLabel>AI Rationale</SectionLabel>
        <div style={{ fontSize: 13, color: colors.textSecondary, lineHeight: 1.8, background: colors.bg, borderRadius: radius.md, padding: "14px 16px", border: `1px solid ${colors.border}` }}>
          {rec.rationale}
        </div>
      </div>

      <div>
        <SectionLabel>Alternatives Considered</SectionLabel>
        <div style={{ fontSize: 13, color: colors.textSecondary, lineHeight: 1.8, background: colors.bg, borderRadius: radius.md, padding: "14px 16px", border: `1px solid ${colors.border}`, fontStyle: "italic" }}>
          {rec.alternatives}
        </div>
      </div>

      {rec.status === "pending" && (
        <div style={{ display: "flex", gap: 10, paddingTop: 4 }}>
          <button onClick={() => onApprove(rec)} style={{ flex: 1, padding: "10px 0", borderRadius: radius.md, background: colors.green, border: "none", color: "#fff", fontSize: 13, fontWeight: 700, cursor: "pointer" }}>✓ Approve</button>
          <button onClick={() => onDefer(rec)}   style={{ padding: "10px 18px", borderRadius: radius.md, background: "transparent", border: `1px solid ${colors.border}`, color: colors.textSecondary, fontSize: 13, fontWeight: 600, cursor: "pointer" }}>Defer</button>
          <button onClick={() => onReject(rec)}  style={{ padding: "10px 18px", borderRadius: radius.md, background: colors.redDim, border: `1px solid ${colors.red}33`, color: colors.red, fontSize: 13, fontWeight: 600, cursor: "pointer" }}>✗ Reject</button>
        </div>
      )}
    </div>
  );
}

// ── Main page ─────────────────────────────────────────────────────────────────
type DialogState = { rec: Recommendation; action: "approve" | "reject" | "defer" } | null;

export default function RecommendationsPage() {
  const [recs, setRecs]           = useState<Recommendation[]>(INITIAL_RECS);
  const [audit, setAudit]         = useState<AuditEntry[]>(INITIAL_AUDIT);
  const [selected, setSelected]   = useState<Recommendation | null>(INITIAL_RECS[0]);
  const [dialog, setDialog]       = useState<DialogState>(null);
  const [notesInput, setNotesInput] = useState("");
  const [statusFilter, setStatusFilter] = useState<RecStatus | "all">("all");
  const [showAudit, setShowAudit] = useState(false);
  const toast = useToast();

  const visible = recs.filter(r => statusFilter === "all" || r.status === statusFilter);

  const counts = {
    pending:     recs.filter(r => r.status === "pending").length,
    approved:    recs.filter(r => r.status === "approved").length,
    rejected:    recs.filter(r => r.status === "rejected").length,
    totalCapex:  recs.filter(r => r.status === "approved").reduce((s, r) => s + r.estimatedCapex, 0),
    totalNpv:    recs.filter(r => r.status === "approved").reduce((s, r) => s + r.npv, 0),
  };

  function handleConfirm() {
    if (!dialog) return;
    const { rec, action } = dialog;
    const newStatus: RecStatus = action === "approve" ? "approved" : action === "reject" ? "rejected" : "deferred";
    const updatedRec = { ...rec, status: newStatus };

    setRecs(prev => prev.map(r => r.id !== rec.id ? r : updatedRec));
    if (selected?.id === rec.id) setSelected(updatedRec);

    setAudit(prev => [{
      id: `AU-${Date.now()}`,
      timestamp: new Date(),
      actor: "Current User",
      action: action === "approve" ? "approved" : "rejected",
      target: `${rec.id} — ${rec.assetName} ${rec.action}`,
      notes: notesInput || undefined,
    }, ...prev]);

    setDialog(null);
    setNotesInput("");

    if (action === "approve") toast.success("Recommendation approved", `${rec.assetName} — ${fmt(rec.estimatedCapex)} CapEx authorized`);
    else if (action === "reject") toast.error("Recommendation rejected", `${rec.assetName} removed from capital plan`);
    else toast.info("Recommendation deferred", `${rec.assetName} moved to next planning cycle`);
  }

  function exportCSV() {
    const rows = [
      ["Rank","Asset","Site","Action","Urgency","CapEx","NPV","ROI%","Payback","Status"],
      ...recs.map(r => [r.priorityRank, r.assetName, r.site, r.action, r.urgency, r.estimatedCapex, r.npv, r.roiPct, r.paybackYears, r.status]),
    ];
    const csv = rows.map(r => r.join(",")).join("\n");
    const blob = new Blob([csv], { type: "text/csv" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a"); a.href = url; a.download = "assetiq-recommendations.csv"; a.click();
    URL.revokeObjectURL(url);
    setAudit(prev => [{ id: `AU-${Date.now()}`, timestamp: new Date(), actor: "Current User", action: "exported", target: "Recommendations report" }, ...prev]);
    toast.info("Export complete", "assetiq-recommendations.csv downloaded");
  }

  const dialogVariant = dialog?.action === "approve" ? "success" : dialog?.action === "reject" ? "danger" : "info";
  const dialogLabel   = dialog?.action === "approve" ? "Approve & Authorize" : dialog?.action === "reject" ? "Reject" : "Defer";

  return (
    <div style={{ maxWidth: 1400, fontFamily: font.sans }}>
      {/* Header */}
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", marginBottom: 24 }}>
        <div>
          <h1 style={{ fontSize: 24, fontWeight: 700, color: colors.textPrimary, margin: 0 }}>Capital Recommendations</h1>
          <p style={{ fontSize: 14, color: colors.textSecondary, marginTop: 4 }}>AI-optimized capital plan · Run OPT-2024-Q4-001 · {INITIAL_RECS[0].generatedAt.toLocaleDateString()}</p>
        </div>
        <div style={{ display: "flex", gap: 10 }}>
          <button onClick={() => setShowAudit(v => !v)} style={{ fontSize: 13, padding: "8px 16px", borderRadius: radius.md, border: `1px solid ${colors.border}`, background: showAudit ? colors.bgHover : "transparent", color: colors.textSecondary, cursor: "pointer", fontWeight: 600 }}>
            {showAudit ? "Hide" : "Show"} Audit Trail
          </button>
          <button onClick={exportCSV} style={{ fontSize: 13, padding: "8px 16px", borderRadius: radius.md, background: colors.blueDim, border: `1px solid ${colors.blue}44`, color: colors.blue, cursor: "pointer", fontWeight: 600 }}>
            ↗ Export CSV
          </button>
        </div>
      </div>

      {/* Summary strip */}
      <div style={{ display: "flex", gap: 12, marginBottom: 20, flexWrap: "wrap" as const }}>
        {[
          { label: "Pending Review",   value: counts.pending,           color: colors.yellow },
          { label: "Approved",         value: counts.approved,          color: colors.green  },
          { label: "Rejected",         value: counts.rejected,          color: colors.red    },
          { label: "Authorized CapEx", value: fmt(counts.totalCapex),   color: colors.blue   },
          { label: "Authorized NPV",   value: fmt(counts.totalNpv),     color: colors.teal   },
        ].map(({ label, value, color }) => (
          <div key={label} style={{ background: colors.bgCard, border: `1px solid ${colors.border}`, borderTop: `2px solid ${color}`, borderRadius: radius.lg, padding: "14px 18px", flex: 1, minWidth: 120 }}>
            <div style={{ fontSize: typeof value === "number" ? 26 : 20, fontWeight: 800, color, lineHeight: 1 }}>{value}</div>
            <div style={{ fontSize: 11, color: colors.textSecondary, marginTop: 4, textTransform: "uppercase" as const, letterSpacing: "0.06em" }}>{label}</div>
          </div>
        ))}
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "1fr 380px", gap: 16 }}>
        {/* Left column */}
        <div style={{ display: "flex", flexDirection: "column" as const, gap: 16 }}>
          {/* List */}
          <div style={{ background: colors.bgCard, borderRadius: radius.lg, border: `1px solid ${colors.border}`, overflow: "hidden" }}>
            {/* Filter tabs */}
            <div style={{ display: "flex", gap: 6, padding: "12px 16px", borderBottom: `1px solid ${colors.border}`, background: colors.bgPanel }}>
              {(["all", "pending", "approved", "rejected", "deferred"] as const).map(s => {
                const active = statusFilter === s;
                const c = s === "all" ? colors.blue : STATUS_STYLE[s]?.color ?? colors.blue;
                return (
                  <button key={s} onClick={() => setStatusFilter(s)} style={{
                    fontSize: 12, fontWeight: active ? 600 : 400, padding: "4px 12px", borderRadius: radius.pill,
                    border: `1px solid ${active ? c : colors.border}`,
                    background: active ? `${c}18` : "transparent",
                    color: active ? c : colors.textSecondary,
                    cursor: "pointer", textTransform: "capitalize" as const,
                  }}>{s}</button>
                );
              })}
            </div>
            {visible.length === 0
              ? <EmptyState icon="✓" title="No recommendations match filter" height={200} />
              : visible.map(rec => (
                <RecRow key={rec.id} rec={rec} selected={selected?.id === rec.id}
                  onClick={() => setSelected(rec)}
                  onApprove={() => setDialog({ rec, action: "approve" })}
                  onReject={()  => setDialog({ rec, action: "reject"  })}
                />
              ))
            }
          </div>

          {/* Audit trail */}
          {showAudit && (
            <div style={{ background: colors.bgCard, borderRadius: radius.lg, border: `1px solid ${colors.border}`, overflow: "hidden" }}>
              <div style={{ padding: "13px 20px", borderBottom: `1px solid ${colors.border}`, background: colors.bgPanel, fontSize: 12, fontWeight: 600, color: colors.textMuted, textTransform: "uppercase" as const, letterSpacing: "0.08em" }}>Audit Trail</div>
              <div style={{ padding: "16px 20px" }}><AuditLog entries={audit} maxHeight={400} /></div>
            </div>
          )}
        </div>

        {/* Right: detail panel */}
        <div style={{ background: colors.bgCard, borderRadius: radius.lg, border: `1px solid ${colors.border}`, display: "flex", flexDirection: "column" as const, maxHeight: "calc(100vh - 220px)", position: "sticky" as const, top: 24 }}>
          <div style={{ padding: "13px 24px", borderBottom: `1px solid ${colors.border}`, background: colors.bgPanel, fontSize: 12, fontWeight: 600, color: colors.textMuted, textTransform: "uppercase" as const, letterSpacing: "0.08em", flexShrink: 0 }}>Recommendation Detail</div>
          <div style={{ flex: 1, overflow: "hidden" }}>
            <RecDetail rec={selected}
              onApprove={r => setDialog({ rec: r, action: "approve" })}
              onReject={r  => setDialog({ rec: r, action: "reject"  })}
              onDefer={r   => setDialog({ rec: r, action: "defer"   })}
            />
          </div>
        </div>
      </div>

      {/* Confirm dialog */}
      <ConfirmDialog
        open={!!dialog}
        variant={dialogVariant}
        title={
          dialog?.action === "approve" ? `Approve: ${dialog.rec.assetName}?` :
          dialog?.action === "reject"  ? "Reject this recommendation?" :
          "Defer to next planning cycle?"
        }
        message={dialog ? (
          <div style={{ display: "flex", flexDirection: "column" as const, gap: 14 }}>
            <div style={{ background: colors.bg, borderRadius: radius.md, padding: "12px 14px", border: `1px solid ${colors.border}`, display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8 }}>
              <div>
                <div style={{ fontSize: 11, color: colors.textMuted, textTransform: "uppercase" as const }}>Action</div>
                <div style={{ fontSize: 14, fontWeight: 600, color: colors.textPrimary, marginTop: 2 }}>{ACTION_STYLE[dialog.rec.action].label}</div>
              </div>
              <div>
                <div style={{ fontSize: 11, color: colors.textMuted, textTransform: "uppercase" as const }}>Est. CapEx</div>
                <div style={{ fontSize: 14, fontWeight: 600, color: colors.textPrimary, marginTop: 2 }}>{fmt(dialog.rec.estimatedCapex)}</div>
              </div>
            </div>
            <div style={{ fontSize: 14, color: colors.textSecondary }}>
              {dialog.action === "approve" ? "This will authorize the capital expenditure and log your approval in the audit trail."
               : dialog.action === "reject" ? "This recommendation will be removed from the active capital plan. Your decision is recorded."
               : "This recommendation will be deferred to the next quarterly planning cycle."}
            </div>
            <div>
              <div style={{ fontSize: 12, color: colors.textSecondary, marginBottom: 6 }}>Notes for audit trail (optional)</div>
              <textarea value={notesInput} onChange={e => setNotesInput(e.target.value)}
                placeholder="Add context..." rows={2}
                style={{ width: "100%", boxSizing: "border-box" as const, background: colors.bg, border: `1px solid ${colors.border}`, borderRadius: radius.md, padding: "8px 12px", color: colors.textPrimary, fontSize: 13, fontFamily: font.sans, resize: "none" as const, outline: "none" }}
              />
            </div>
          </div>
        ) : ""}
        confirmLabel={dialogLabel}
        onConfirm={handleConfirm}
        onCancel={() => { setDialog(null); setNotesInput(""); }}
      />
    </div>
  );
}
