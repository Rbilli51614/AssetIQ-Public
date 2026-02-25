import React, { useEffect, useRef } from "react";
import { colors, radius, shadow, font } from "./tokens";

export interface ConfirmDialogProps {
  open:        boolean;
  title:       string;
  message:     React.ReactNode;
  confirmLabel?: string;
  cancelLabel?:  string;
  variant?:    "danger" | "warning" | "success" | "info";
  onConfirm:   () => void;
  onCancel:    () => void;
}

const VARIANT_COLORS = {
  danger:  { bg: colors.redDim,    border: colors.red,    btn: colors.red,    icon: "⚠" },
  warning: { bg: colors.yellowDim, border: colors.yellow, btn: colors.yellow, icon: "⚠" },
  success: { bg: colors.greenDim,  border: colors.green,  btn: colors.green,  icon: "✓" },
  info:    { bg: colors.blueDim,   border: colors.blue,   btn: colors.blue,   icon: "ℹ" },
};

export function ConfirmDialog({
  open, title, message,
  confirmLabel = "Confirm",
  cancelLabel  = "Cancel",
  variant = "info",
  onConfirm, onCancel,
}: ConfirmDialogProps) {
  const confirmRef = useRef<HTMLButtonElement>(null);
  const v = VARIANT_COLORS[variant];

  // Trap focus on open, restore on close
  useEffect(() => {
    if (open) {
      setTimeout(() => confirmRef.current?.focus(), 50);
    }
  }, [open]);

  // Close on Escape
  useEffect(() => {
    if (!open) return;
    const handler = (e: KeyboardEvent) => { if (e.key === "Escape") onCancel(); };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [open, onCancel]);

  if (!open) return null;

  return (
    <>
      {/* Backdrop */}
      <div
        onClick={onCancel}
        style={{
          position: "fixed", inset: 0, zIndex: 1000,
          background: "rgba(0,0,0,0.65)",
          backdropFilter: "blur(2px)",
          animation: "aiq-fadein 0.15s ease",
        }}
      />
      <style>{`
        @keyframes aiq-fadein  { from { opacity: 0 } to { opacity: 1 } }
        @keyframes aiq-slidein { from { opacity: 0; transform: translate(-50%,-48%) scale(0.97) } to { opacity: 1; transform: translate(-50%,-50%) scale(1) } }
      `}</style>

      {/* Dialog */}
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="confirm-title"
        style={{
          position: "fixed",
          top: "50%", left: "50%",
          transform: "translate(-50%,-50%)",
          zIndex: 1001,
          width: "min(480px, 90vw)",
          background: colors.bgPanel,
          border: `1px solid ${v.border}44`,
          borderRadius: radius.xl,
          boxShadow: shadow.elevated,
          padding: 28,
          fontFamily: font.sans,
          animation: "aiq-slidein 0.18s ease",
        }}
      >
        {/* Icon + title */}
        <div style={{ display: "flex", alignItems: "flex-start", gap: 16, marginBottom: 16 }}>
          <div style={{
            width: 40, height: 40, flexShrink: 0,
            borderRadius: radius.md,
            background: v.bg,
            border: `1px solid ${v.border}44`,
            display: "flex", alignItems: "center", justifyContent: "center",
            fontSize: 18, color: v.border,
          }}>
            {v.icon}
          </div>
          <div>
            <div
              id="confirm-title"
              style={{ fontSize: 16, fontWeight: 700, color: colors.textPrimary, lineHeight: 1.3 }}
            >
              {title}
            </div>
          </div>
        </div>

        {/* Message */}
        <div style={{
          fontSize: 14, color: colors.textSecondary, lineHeight: 1.7,
          marginBottom: 24, paddingLeft: 56,
        }}>
          {message}
        </div>

        {/* Actions */}
        <div style={{ display: "flex", gap: 10, justifyContent: "flex-end" }}>
          <button
            onClick={onCancel}
            style={{
              background: "transparent",
              border: `1px solid ${colors.border}`,
              color: colors.textSecondary,
              borderRadius: radius.md,
              padding: "9px 20px",
              fontSize: 13, fontWeight: 600,
              cursor: "pointer",
              fontFamily: font.sans,
              transition: "border-color 0.15s, color 0.15s",
            }}
          >
            {cancelLabel}
          </button>
          <button
            ref={confirmRef}
            onClick={onConfirm}
            style={{
              background: v.btn,
              border: "none",
              color: variant === "warning" ? "#000" : "#fff",
              borderRadius: radius.md,
              padding: "9px 22px",
              fontSize: 13, fontWeight: 700,
              cursor: "pointer",
              fontFamily: font.sans,
              boxShadow: `0 2px 8px ${v.btn}44`,
              transition: "opacity 0.15s, transform 0.1s",
            }}
          >
            {confirmLabel}
          </button>
        </div>
      </div>
    </>
  );
}
