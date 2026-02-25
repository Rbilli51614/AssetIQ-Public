import React, { createContext, useContext, useState, useCallback, useEffect, useRef } from "react";
import { colors, radius, shadow, SEVERITY, SeverityKey } from "./tokens";

export interface Toast {
  id:       string;
  message:  string;
  detail?:  string;
  kind:     SeverityKey | "success";
  duration: number;
}

interface ToastCtx {
  addToast: (t: Omit<Toast, "id">) => void;
  success:  (message: string, detail?: string) => void;
  error:    (message: string, detail?: string) => void;
  warn:     (message: string, detail?: string) => void;
  info:     (message: string, detail?: string) => void;
}

const Ctx = createContext<ToastCtx | null>(null);

export function ToastProvider({ children }: { children: React.ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);

  const addToast = useCallback((t: Omit<Toast, "id">) => {
    const id = Math.random().toString(36).slice(2);
    setToasts(prev => [...prev.slice(-4), { ...t, id }]); // max 5 visible
    setTimeout(() => setToasts(prev => prev.filter(x => x.id !== id)), t.duration);
  }, []);

  const success = (message: string, detail?: string) => addToast({ message, detail, kind: "success", duration: 4000 });
  const error   = (message: string, detail?: string) => addToast({ message, detail, kind: "critical", duration: 6000 });
  const warn    = (message: string, detail?: string) => addToast({ message, detail, kind: "medium",   duration: 5000 });
  const info    = (message: string, detail?: string) => addToast({ message, detail, kind: "info",     duration: 4000 });

  return (
    <Ctx.Provider value={{ addToast, success, error, warn, info }}>
      {children}
      <ToastStack toasts={toasts} onDismiss={id => setToasts(prev => prev.filter(x => x.id !== id))} />
    </Ctx.Provider>
  );
}

export function useToast() {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error("useToast must be used inside <ToastProvider>");
  return ctx;
}

const KIND_COLOR: Record<string, string> = {
  success:  colors.green,
  critical: colors.red,
  high:     colors.orange,
  medium:   colors.yellow,
  low:      colors.green,
  info:     colors.blue,
};

const KIND_ICON: Record<string, string> = {
  success: "✓", critical: "⚠", high: "⚠", medium: "●", low: "●", info: "ℹ",
};

function ToastStack({ toasts, onDismiss }: { toasts: Toast[]; onDismiss: (id: string) => void }) {
  return (
    <div style={{
      position: "fixed", bottom: 24, right: 24, zIndex: 9999,
      display: "flex", flexDirection: "column", gap: 10, pointerEvents: "none",
    }}>
      {toasts.map(t => (
        <ToastItem key={t.id} toast={t} onDismiss={onDismiss} />
      ))}
    </div>
  );
}

function ToastItem({ toast, onDismiss }: { toast: Toast; onDismiss: (id: string) => void }) {
  const color = KIND_COLOR[toast.kind] ?? colors.blue;
  const icon  = KIND_ICON[toast.kind] ?? "●";
  const [visible, setVisible] = useState(false);

  useEffect(() => { requestAnimationFrame(() => setVisible(true)); }, []);

  return (
    <div
      onClick={() => onDismiss(toast.id)}
      style={{
        pointerEvents: "all", cursor: "pointer",
        background: colors.bgCard,
        border: `1px solid ${color}44`,
        borderLeft: `3px solid ${color}`,
        borderRadius: radius.md,
        padding: "12px 16px",
        minWidth: 300, maxWidth: 420,
        boxShadow: shadow.elevated,
        display: "flex", gap: 12, alignItems: "flex-start",
        opacity: visible ? 1 : 0,
        transform: visible ? "translateX(0)" : "translateX(24px)",
        transition: "opacity 0.25s ease, transform 0.25s ease",
        fontFamily: "'DM Sans', system-ui, sans-serif",
      }}
    >
      <span style={{ color, fontWeight: 700, fontSize: 14, marginTop: 1, flexShrink: 0 }}>{icon}</span>
      <div style={{ flex: 1 }}>
        <div style={{ fontSize: 13, fontWeight: 600, color: colors.textPrimary }}>{toast.message}</div>
        {toast.detail && <div style={{ fontSize: 12, color: colors.textSecondary, marginTop: 3 }}>{toast.detail}</div>}
      </div>
      <span style={{ color: colors.textMuted, fontSize: 12, flexShrink: 0 }}>×</span>
    </div>
  );
}
