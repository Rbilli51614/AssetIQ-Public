import React, { useState } from "react";
import { colors, radius, font } from "../components/tokens";
import { useToast } from "../components/Toast";

type Section = "api" | "thresholds" | "notifications" | "account";

function SectionTab({ label, active, onClick }: { label: string; active: boolean; onClick: () => void }) {
  return (
    <button onClick={onClick} style={{
      fontSize: 13, fontWeight: active ? 600 : 400,
      padding: "8px 16px", borderRadius: radius.md,
      border: `1px solid ${active ? colors.blue : "transparent"}`,
      background: active ? colors.bgActive : "transparent",
      color: active ? colors.blue : colors.textSecondary,
      cursor: "pointer", textAlign: "left", width: "100%",
      fontFamily: font.sans,
    }}>{label}</button>
  );
}

function Field({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <div style={{ marginBottom: 24 }}>
      <label style={{ fontSize: 13, fontWeight: 600, color: colors.textPrimary, display: "block", marginBottom: 6 }}>{label}</label>
      {hint && <div style={{ fontSize: 12, color: colors.textSecondary, marginBottom: 8 }}>{hint}</div>}
      {children}
    </div>
  );
}

const inputStyle: React.CSSProperties = {
  width: "100%", boxSizing: "border-box",
  background: colors.bg, border: `1px solid ${colors.border}`,
  borderRadius: radius.md, padding: "9px 12px",
  color: colors.textPrimary, fontSize: 13,
  fontFamily: font.mono, outline: "none",
};

function Toggle({ value, onChange, label }: { value: boolean; onChange: (v: boolean) => void; label: string }) {
  return (
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "12px 0", borderBottom: `1px solid ${colors.border}` }}>
      <span style={{ fontSize: 13, color: colors.textPrimary }}>{label}</span>
      <div
        onClick={() => onChange(!value)}
        style={{
          width: 40, height: 22, borderRadius: 11, cursor: "pointer",
          background: value ? colors.green : colors.bgHover,
          position: "relative", transition: "background 0.2s",
          border: `1px solid ${value ? colors.green : colors.border}`,
        }}
      >
        <div style={{
          position: "absolute", top: 2,
          left: value ? 18 : 2,
          width: 16, height: 16, borderRadius: "50%",
          background: "#fff", transition: "left 0.2s",
        }} />
      </div>
    </div>
  );
}

function ThresholdRow({ label, value, unit, onChange }: { label: string; value: number; unit: string; onChange: (v: number) => void }) {
  return (
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "10px 0", borderBottom: `1px solid ${colors.border}` }}>
      <span style={{ fontSize: 13, color: colors.textPrimary }}>{label}</span>
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        <input
          type="number"
          value={value}
          onChange={e => onChange(Number(e.target.value))}
          style={{ ...inputStyle, width: 80, textAlign: "right", fontFamily: font.mono }}
        />
        <span style={{ fontSize: 12, color: colors.textMuted, width: 40 }}>{unit}</span>
      </div>
    </div>
  );
}

export default function SettingsPage() {
  const [section, setSection] = useState<Section>("api");
  const toast = useToast();

  // API settings
  const [apiUrl, setApiUrl]     = useState("https://api.assetiq.io");
  const [apiKey, setApiKey]     = useState("aiq_••••••••••••••••••••••••••••••••");
  const [timeout, setTimeout_]  = useState(30);

  // Thresholds
  const [criticalFailProb, setCritical] = useState(80);
  const [highFailProb, setHigh]         = useState(60);
  const [rulCritical, setRulCritical]   = useState(60);
  const [rulHigh, setRulHigh]           = useState(180);
  const [healthDropWindow, setDropWin]  = useState(72);
  const [healthDropPts, setDropPts]     = useState(10);
  const [budgetWarnPct, setBudget]      = useState(85);

  // Notifications
  const [emailAlerts, setEmailAlerts]   = useState(true);
  const [criticalPush, setCriticalPush] = useState(true);
  const [highPush, setHighPush]         = useState(true);
  const [mediumPush, setMediumPush]     = useState(false);
  const [dailyDigest, setDailyDigest]   = useState(true);
  const [weeklyReport, setWeeklyReport] = useState(true);
  const [emailAddress, setEmailAddress] = useState("ops-team@yourcompany.com");

  function save() {
    toast.success("Settings saved", "Changes will take effect immediately");
  }

  const SECTIONS: { key: Section; label: string }[] = [
    { key: "api",           label: "API Connection"  },
    { key: "thresholds",    label: "Alert Thresholds" },
    { key: "notifications", label: "Notifications"   },
    { key: "account",       label: "Account"         },
  ];

  return (
    <div style={{ maxWidth: 900, fontFamily: font.sans }}>
      <div style={{ marginBottom: 24 }}>
        <h1 style={{ fontSize: 24, fontWeight: 700, color: colors.textPrimary, margin: 0 }}>Settings</h1>
        <p style={{ fontSize: 14, color: colors.textSecondary, marginTop: 4 }}>Configure your AssetIQ integration and alert preferences</p>
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "180px 1fr", gap: 24 }}>
        {/* Nav */}
        <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
          {SECTIONS.map(({ key, label }) => (
            <SectionTab key={key} label={label} active={section === key} onClick={() => setSection(key)} />
          ))}
        </div>

        {/* Panel */}
        <div style={{ background: colors.bgCard, border: `1px solid ${colors.border}`, borderRadius: radius.lg, padding: 28 }}>

          {section === "api" && (
            <div>
              <h2 style={{ fontSize: 16, fontWeight: 700, color: colors.textPrimary, marginTop: 0, marginBottom: 20 }}>API Connection</h2>
              <Field label="API Base URL" hint="The AssetIQ Intelligence API endpoint provided during onboarding.">
                <input value={apiUrl} onChange={e => setApiUrl(e.target.value)} style={inputStyle} />
              </Field>
              <Field label="API Key" hint="Your tenant API key. Rotate this in the AssetIQ portal if compromised.">
                <div style={{ display: "flex", gap: 10 }}>
                  <input value={apiKey} onChange={e => setApiKey(e.target.value)} type="password" style={{ ...inputStyle, flex: 1 }} />
                  <button onClick={() => toast.info("Contact support to rotate your API key", "support@assetiq.io")} style={{ padding: "9px 14px", borderRadius: radius.md, border: `1px solid ${colors.border}`, background: "transparent", color: colors.textSecondary, fontSize: 13, cursor: "pointer" }}>Rotate</button>
                </div>
              </Field>
              <Field label="Request Timeout (seconds)">
                <input type="number" value={timeout} onChange={e => setTimeout_(Number(e.target.value))} style={{ ...inputStyle, width: 120 }} />
              </Field>
              <div style={{ padding: "16px", background: colors.bg, borderRadius: radius.md, border: `1px solid ${colors.border}`, marginBottom: 24 }}>
                <div style={{ fontSize: 12, color: colors.textMuted, marginBottom: 10, textTransform: "uppercase", letterSpacing: "0.06em" }}>Connection Status</div>
                <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                  <div style={{ width: 8, height: 8, borderRadius: "50%", background: colors.green }} />
                  <span style={{ fontSize: 13, color: colors.textPrimary }}>Connected</span>
                  <span style={{ fontSize: 12, color: colors.textMuted, marginLeft: 8 }}>Last ping: 4s ago · 42ms latency</span>
                </div>
              </div>
            </div>
          )}

          {section === "thresholds" && (
            <div>
              <h2 style={{ fontSize: 16, fontWeight: 700, color: colors.textPrimary, marginTop: 0, marginBottom: 4 }}>Alert Thresholds</h2>
              <p style={{ fontSize: 13, color: colors.textSecondary, marginBottom: 20 }}>Customize when alerts are triggered for your fleet. Changes apply to new predictions only.</p>
              <div style={{ fontSize: 12, fontWeight: 700, color: colors.textMuted, textTransform: "uppercase", letterSpacing: "0.08em", marginBottom: 8 }}>Failure Probability</div>
              <ThresholdRow label="Critical threshold" value={criticalFailProb} unit="%" onChange={setCritical} />
              <ThresholdRow label="High threshold"     value={highFailProb}     unit="%" onChange={setHigh}     />
              <div style={{ fontSize: 12, fontWeight: 700, color: colors.textMuted, textTransform: "uppercase", letterSpacing: "0.08em", margin: "20px 0 8px" }}>Remaining Useful Life</div>
              <ThresholdRow label="Critical RUL floor" value={rulCritical} unit="days" onChange={setRulCritical} />
              <ThresholdRow label="High RUL floor"     value={rulHigh}     unit="days" onChange={setRulHigh}     />
              <div style={{ fontSize: 12, fontWeight: 700, color: colors.textMuted, textTransform: "uppercase", letterSpacing: "0.08em", margin: "20px 0 8px" }}>Health Score Drop</div>
              <ThresholdRow label="Detection window" value={healthDropWindow} unit="hours" onChange={setDropWin} />
              <ThresholdRow label="Point threshold"  value={healthDropPts}   unit="pts"   onChange={setDropPts} />
              <div style={{ fontSize: 12, fontWeight: 700, color: colors.textMuted, textTransform: "uppercase", letterSpacing: "0.08em", margin: "20px 0 8px" }}>Budget</div>
              <ThresholdRow label="Budget utilization warning" value={budgetWarnPct} unit="%" onChange={setBudget} />
            </div>
          )}

          {section === "notifications" && (
            <div>
              <h2 style={{ fontSize: 16, fontWeight: 700, color: colors.textPrimary, marginTop: 0, marginBottom: 20 }}>Notifications</h2>
              <Field label="Notification email">
                <input value={emailAddress} onChange={e => setEmailAddress(e.target.value)} style={inputStyle} type="email" />
              </Field>
              <div style={{ fontSize: 12, fontWeight: 700, color: colors.textMuted, textTransform: "uppercase", letterSpacing: "0.08em", marginBottom: 4 }}>Alert Channels</div>
              <Toggle value={criticalPush} onChange={setCriticalPush} label="Push notifications — Critical alerts"  />
              <Toggle value={highPush}     onChange={setHighPush}     label="Push notifications — High alerts"      />
              <Toggle value={mediumPush}   onChange={setMediumPush}   label="Push notifications — Medium alerts"    />
              <Toggle value={emailAlerts}  onChange={setEmailAlerts}  label="Email — All active alerts"             />
              <div style={{ fontSize: 12, fontWeight: 700, color: colors.textMuted, textTransform: "uppercase", letterSpacing: "0.08em", margin: "20px 0 4px" }}>Reports</div>
              <Toggle value={dailyDigest}  onChange={setDailyDigest}  label="Daily digest — Alert summary"         />
              <Toggle value={weeklyReport} onChange={setWeeklyReport} label="Weekly report — Capital recommendations" />
            </div>
          )}

          {section === "account" && (
            <div>
              <h2 style={{ fontSize: 16, fontWeight: 700, color: colors.textPrimary, marginTop: 0, marginBottom: 20 }}>Account</h2>
              <div style={{ background: colors.bg, borderRadius: radius.md, border: `1px solid ${colors.border}`, padding: "16px 20px", marginBottom: 20 }}>
                {[
                  { label: "Tenant ID",   value: "ten_a1b2c3d4e5f6" },
                  { label: "Tier",        value: "Professional" },
                  { label: "API calls this month", value: "4,821 / 100,000" },
                  { label: "Assets",      value: "200 / 1,000" },
                  { label: "Optimize calls today", value: "3 / 50" },
                ].map(({ label, value }) => (
                  <div key={label} style={{ display: "flex", justifyContent: "space-between", padding: "8px 0", borderBottom: `1px solid ${colors.border}` }}>
                    <span style={{ fontSize: 13, color: colors.textSecondary }}>{label}</span>
                    <span style={{ fontSize: 13, color: colors.textPrimary, fontFamily: font.mono }}>{value}</span>
                  </div>
                ))}
              </div>
              <p style={{ fontSize: 13, color: colors.textSecondary, lineHeight: 1.6 }}>
                To upgrade your tier, rotate API keys, or manage users, visit the <a href="https://app.assetiq.io" target="_blank" style={{ color: colors.blue }}>AssetIQ portal</a> or contact <a href="mailto:support@assetiq.io" style={{ color: colors.blue }}>support@assetiq.io</a>.
              </p>
            </div>
          )}

          {/* Save button */}
          {section !== "account" && (
            <div style={{ borderTop: `1px solid ${colors.border}`, paddingTop: 20, marginTop: 8, display: "flex", justifyContent: "flex-end", gap: 10 }}>
              <button onClick={() => toast.info("Changes discarded")} style={{ padding: "9px 20px", borderRadius: radius.md, border: `1px solid ${colors.border}`, background: "transparent", color: colors.textSecondary, fontSize: 13, cursor: "pointer", fontWeight: 600 }}>Discard</button>
              <button onClick={save} style={{ padding: "9px 22px", borderRadius: radius.md, background: colors.blue, border: "none", color: "#fff", fontSize: 13, cursor: "pointer", fontWeight: 700 }}>Save Changes</button>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
