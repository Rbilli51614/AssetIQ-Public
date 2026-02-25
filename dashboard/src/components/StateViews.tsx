import React from "react";
import { colors, radius, font } from "./tokens";

// ── Spinner ───────────────────────────────────────────────────────────────────
function Spinner({ size = 32, color = colors.blue }: { size?: number; color?: string }) {
  return (
    <div style={{ width: size, height: size, position: "relative" }}>
      <style>{`
        @keyframes aiq-spin {
          to { transform: rotate(360deg); }
        }
        @keyframes aiq-pulse {
          0%, 100% { opacity: 1; }
          50%       { opacity: 0.4; }
        }
      `}</style>
      <div style={{
        width: size, height: size, borderRadius: "50%",
        border: `2px solid ${color}22`,
        borderTop: `2px solid ${color}`,
        animation: "aiq-spin 0.8s linear infinite",
      }} />
    </div>
  );
}

// ── Loading State ─────────────────────────────────────────────────────────────
export function LoadingState({
  message = "Loading...",
  detail,
  height = 320,
}: {
  message?: string;
  detail?: string;
  height?: number;
}) {
  return (
    <div style={{
      height,
      display: "flex",
      flexDirection: "column",
      alignItems: "center",
      justifyContent: "center",
      gap: 16,
      background: colors.bgCard,
      borderRadius: radius.lg,
      border: `1px solid ${colors.border}`,
    }}>
      <Spinner size={36} />
      <div style={{ textAlign: "center" }}>
        <div style={{ fontSize: 14, color: colors.textSecondary, fontFamily: font.sans }}>{message}</div>
        {detail && <div style={{ fontSize: 12, color: colors.textMuted, marginTop: 4, fontFamily: font.sans }}>{detail}</div>}
      </div>
    </div>
  );
}

// ── Skeleton Row ──────────────────────────────────────────────────────────────
export function SkeletonRow({ cols = 5 }: { cols?: number }) {
  return (
    <tr>
      {Array.from({ length: cols }).map((_, i) => (
        <td key={i} style={{ padding: "14px 16px" }}>
          <div style={{
            height: 12,
            width: `${50 + Math.random() * 40}%`,
            background: `linear-gradient(90deg, ${colors.bgHover} 25%, ${colors.borderMid} 50%, ${colors.bgHover} 75%)`,
            backgroundSize: "200% 100%",
            borderRadius: radius.sm,
            animation: "aiq-shimmer 1.5s infinite",
          }} />
          <style>{`
            @keyframes aiq-shimmer {
              0%   { background-position: 200% 0; }
              100% { background-position: -200% 0; }
            }
          `}</style>
        </td>
      ))}
    </tr>
  );
}

// ── Error State ───────────────────────────────────────────────────────────────
export function ErrorState({
  message = "Something went wrong",
  detail,
  onRetry,
  height = 320,
}: {
  message?: string;
  detail?: string;
  onRetry?: () => void;
  height?: number;
}) {
  return (
    <div style={{
      height,
      display: "flex",
      flexDirection: "column",
      alignItems: "center",
      justifyContent: "center",
      gap: 16,
      background: colors.bgCard,
      borderRadius: radius.lg,
      border: `1px solid ${colors.red}33`,
    }}>
      <div style={{
        width: 48, height: 48,
        borderRadius: radius.lg,
        background: colors.redDim,
        display: "flex", alignItems: "center", justifyContent: "center",
        fontSize: 22,
      }}>⚠</div>
      <div style={{ textAlign: "center", maxWidth: 360 }}>
        <div style={{ fontSize: 15, fontWeight: 600, color: colors.textPrimary, fontFamily: font.sans }}>{message}</div>
        {detail && (
          <div style={{ fontSize: 12, color: colors.textSecondary, marginTop: 6, fontFamily: font.mono, lineHeight: 1.6 }}>
            {detail}
          </div>
        )}
      </div>
      {onRetry && (
        <button
          onClick={onRetry}
          style={{
            background: colors.blueDim,
            border: `1px solid ${colors.blue}44`,
            color: colors.blue,
            borderRadius: radius.md,
            padding: "8px 20px",
            fontSize: 13,
            cursor: "pointer",
            fontFamily: font.sans,
            fontWeight: 600,
            transition: "background 0.15s",
          }}
        >
          Retry
        </button>
      )}
    </div>
  );
}

// ── Empty State ───────────────────────────────────────────────────────────────
export function EmptyState({
  icon = "○",
  title,
  detail,
  action,
  onAction,
  height = 320,
}: {
  icon?: string;
  title: string;
  detail?: string;
  action?: string;
  onAction?: () => void;
  height?: number;
}) {
  return (
    <div style={{
      height,
      display: "flex",
      flexDirection: "column",
      alignItems: "center",
      justifyContent: "center",
      gap: 12,
      background: colors.bgCard,
      borderRadius: radius.lg,
      border: `1px dashed ${colors.border}`,
    }}>
      <div style={{
        fontSize: 32,
        color: colors.textMuted,
        lineHeight: 1,
        marginBottom: 4,
      }}>{icon}</div>
      <div style={{ textAlign: "center", maxWidth: 320 }}>
        <div style={{ fontSize: 15, fontWeight: 600, color: colors.textSecondary, fontFamily: font.sans }}>{title}</div>
        {detail && (
          <div style={{ fontSize: 13, color: colors.textMuted, marginTop: 6, fontFamily: font.sans, lineHeight: 1.6 }}>
            {detail}
          </div>
        )}
      </div>
      {action && onAction && (
        <button
          onClick={onAction}
          style={{
            marginTop: 8,
            background: colors.blue,
            border: "none",
            color: "#fff",
            borderRadius: radius.md,
            padding: "9px 22px",
            fontSize: 13,
            fontWeight: 600,
            cursor: "pointer",
            fontFamily: font.sans,
          }}
        >
          {action}
        </button>
      )}
    </div>
  );
}
