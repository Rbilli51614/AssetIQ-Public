import React from "react";
import { colors, radius, font } from "./tokens";

export interface AuditEntry {
  id:        string;
  timestamp: Date;
  actor:     string;
  action:    "approved" | "rejected" | "flagged" | "viewed" | "exported" | "created";
  target:    string;
  notes?:    string;
}

const ACTION_STYLE: Record<AuditEntry["action"], { color: string; label: string; icon: string }> = {
  approved: { color: colors.green,  label: "Approved", icon: "✓" },
  rejected: { color: colors.red,    label: "Rejected",  icon: "✗" },
  flagged:  { color: colors.yellow, label: "Flagged",   icon: "⚑" },
  viewed:   { color: colors.blue,   label: "Viewed",    icon: "◎" },
  exported: { color: colors.teal,   label: "Exported",  icon: "↗" },
  created:  { color: colors.purple, label: "Created",   icon: "+" },
};

function formatTime(d: Date): string {
  const now = new Date();
  const diffMs = now.getTime() - d.getTime();
  const diffMin = Math.floor(diffMs / 60000);
  if (diffMin < 1)  return "just now";
  if (diffMin < 60) return `${diffMin}m ago`;
  const diffHr = Math.floor(diffMin / 60);
  if (diffHr < 24)  return `${diffHr}h ago`;
  return d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
}

export function AuditLog({ entries, maxHeight = 320 }: { entries: AuditEntry[]; maxHeight?: number }) {
  if (entries.length === 0) {
    return (
      <div style={{
        padding: 24, textAlign: "center",
        color: colors.textMuted, fontSize: 13, fontFamily: font.sans,
      }}>
        No activity yet
      </div>
    );
  }

  return (
    <div style={{
      maxHeight,
      overflowY: "auto",
      scrollbarWidth: "thin",
      scrollbarColor: `${colors.border} transparent`,
    }}>
      {entries.map((entry, i) => {
        const s = ACTION_STYLE[entry.action];
        return (
          <div
            key={entry.id}
            style={{
              display: "flex",
              gap: 12,
              padding: "12px 0",
              borderBottom: i < entries.length - 1 ? `1px solid ${colors.border}` : "none",
            }}
          >
            {/* Timeline dot */}
            <div style={{ display: "flex", flexDirection: "column", alignItems: "center", flexShrink: 0 }}>
              <div style={{
                width: 28, height: 28,
                borderRadius: "50%",
                background: `${s.color}18`,
                border: `1px solid ${s.color}44`,
                display: "flex", alignItems: "center", justifyContent: "center",
                fontSize: 12, color: s.color, fontWeight: 700,
                fontFamily: font.mono,
              }}>
                {s.icon}
              </div>
              {i < entries.length - 1 && (
                <div style={{ width: 1, flex: 1, background: colors.border, marginTop: 6 }} />
              )}
            </div>

            {/* Content */}
            <div style={{ flex: 1, paddingBottom: 12 }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start" }}>
                <div>
                  <span style={{ fontSize: 13, fontWeight: 600, color: s.color }}>{s.label}</span>
                  <span style={{ fontSize: 13, color: colors.textSecondary }}> · {entry.target}</span>
                </div>
                <span style={{
                  fontSize: 11, color: colors.textMuted,
                  fontFamily: font.mono, flexShrink: 0, marginLeft: 12,
                }}>
                  {formatTime(entry.timestamp)}
                </span>
              </div>
              <div style={{ fontSize: 12, color: colors.textMuted, marginTop: 2 }}>
                by <span style={{ color: colors.textSecondary }}>{entry.actor}</span>
              </div>
              {entry.notes && (
                <div style={{
                  fontSize: 12, color: colors.textSecondary,
                  marginTop: 6, fontStyle: "italic",
                  lineHeight: 1.5,
                }}>
                  "{entry.notes}"
                </div>
              )}
            </div>
          </div>
        );
      })}
    </div>
  );
}
