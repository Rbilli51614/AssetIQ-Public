/**
 * AssetIQ Design Tokens
 * Single source of truth for colors, spacing, typography, and animation.
 * Industrial utility aesthetic: precise, high-density, confident.
 */

export const colors = {
  // Backgrounds
  bg:        "#090d14",
  bgPanel:   "#0e1420",
  bgCard:    "#131c2e",
  bgHover:   "#1a2540",
  bgActive:  "rgba(56,139,253,0.10)",

  // Borders
  border:    "#1e2d44",
  borderMid: "#253654",

  // Text
  textPrimary:   "#e6edf3",
  textSecondary: "#7d8590",
  textMuted:     "#484f58",

  // Accent
  blue:    "#388bfd",
  blueDim: "rgba(56,139,253,0.15)",

  // Semantic
  green:   "#3fb950",
  greenDim:"rgba(63,185,80,0.12)",
  yellow:  "#d29922",
  yellowDim:"rgba(210,153,34,0.12)",
  orange:  "#e3702a",
  orangeDim:"rgba(227,112,42,0.12)",
  red:     "#f85149",
  redDim:  "rgba(248,81,73,0.12)",
  purple:  "#bc8cff",
  purpleDim:"rgba(188,140,255,0.12)",
  teal:    "#39c5cf",
} as const;

export const font = {
  mono: "'JetBrains Mono', 'Fira Code', 'Cascadia Code', monospace",
  sans: "'DM Sans', 'Instrument Sans', system-ui, sans-serif",
  display: "'DM Sans', system-ui, sans-serif",
} as const;

export const radius = {
  sm: "4px",
  md: "8px",
  lg: "12px",
  xl: "16px",
  pill: "999px",
} as const;

export const shadow = {
  card: "0 1px 3px rgba(0,0,0,0.4), 0 1px 2px rgba(0,0,0,0.3)",
  elevated: "0 4px 16px rgba(0,0,0,0.5), 0 2px 4px rgba(0,0,0,0.3)",
  glow: (color: string) => `0 0 12px ${color}40, 0 0 24px ${color}20`,
} as const;

// Severity → color/label mapping (shared across Alerts + Recommendations)
export const SEVERITY = {
  critical: { color: colors.red,    dim: colors.redDim,    label: "Critical"    },
  high:     { color: colors.orange, dim: colors.orangeDim, label: "High"        },
  medium:   { color: colors.yellow, dim: colors.yellowDim, label: "Medium"      },
  low:      { color: colors.green,  dim: colors.greenDim,  label: "Low"         },
  info:     { color: colors.blue,   dim: colors.blueDim,   label: "Info"        },
} as const;

export type SeverityKey = keyof typeof SEVERITY;

// Health category display
export const HEALTH_CATEGORY = {
  normal:       { color: colors.green,  label: "Normal Operations" },
  stressed:     { color: colors.red,    label: "Stressed"          },
  transitional: { color: colors.yellow, label: "Transitional"      },
  maintenance:  { color: colors.blue,   label: "Maintenance Mode"  },
  offline:      { color: colors.textMuted, label: "Offline"           },
} as const;
