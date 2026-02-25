import React, { useState, Suspense, lazy } from "react";
import { BrowserRouter, Routes, Route, NavLink } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { BarChart2, Activity, DollarSign, AlertTriangle, Settings, Layers } from "lucide-react";
import { ToastProvider } from "./components/Toast";
import { LoadingState } from "./components/StateViews";
import { colors, font, radius } from "./components/tokens";

// Lazy load pages for code splitting
const CapitalDashboard     = lazy(() => import("./pages/CapitalDashboard"));
const AssetHealthPage      = lazy(() => import("./pages/AssetHealthPage"));
const PortfolioPage        = lazy(() => import("./pages/PortfolioPage"));
const RecommendationsPage  = lazy(() => import("./pages/RecommendationsPage"));
const AlertsPage           = lazy(() => import("./pages/AlertsPage"));
const SettingsPage         = lazy(() => import("./pages/SettingsPage"));

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      refetchOnWindowFocus: false,
      retry: 2,
    },
  },
});

const NAV_ITEMS = [
  { to: "/",                icon: BarChart2,     label: "Capital Overview"   },
  { to: "/assets",          icon: Activity,      label: "Asset Health"       },
  { to: "/portfolio",       icon: Layers,        label: "Portfolio"          },
  { to: "/recommendations", icon: DollarSign,    label: "Recommendations"    },
  { to: "/alerts",          icon: AlertTriangle, label: "Alerts"             },
  { to: "/settings",        icon: Settings,      label: "Settings"           },
];

function PageLoader() {
  return <LoadingState message="Loading page..." height={400} />;
}

export default function App() {
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const [alertCount] = useState(3); // active critical+high alerts

  return (
    <QueryClientProvider client={queryClient}>
      <ToastProvider>
        <BrowserRouter>
          <div style={{
            display: "flex", height: "100vh",
            background: colors.bg,
            color: colors.textPrimary,
            fontFamily: font.sans,
          }}>
            {/* Sidebar */}
            <aside style={{
              width: sidebarOpen ? 240 : 64,
              background: colors.bgPanel,
              borderRight: `1px solid ${colors.border}`,
              display: "flex", flexDirection: "column",
              transition: "width 0.2s ease", flexShrink: 0,
            }}>
              {/* Logo */}
              <div style={{
                padding: "20px 16px", borderBottom: `1px solid ${colors.border}`,
                display: "flex", alignItems: "center", gap: 12,
              }}>
                <div style={{
                  width: 36, height: 36, borderRadius: radius.md,
                  background: "linear-gradient(135deg, #388bfd, #bc8cff)",
                  flexShrink: 0, display: "flex", alignItems: "center",
                  justifyContent: "center", fontWeight: 800, fontSize: 15,
                  color: "#fff", fontFamily: font.sans,
                }}>AI</div>
                {sidebarOpen && (
                  <div>
                    <div style={{ fontWeight: 700, fontSize: 16, color: colors.textPrimary }}>AssetIQ</div>
                    <div style={{ fontSize: 11, color: colors.textSecondary }}>Capital Intelligence</div>
                  </div>
                )}
              </div>

              {/* Nav */}
              <nav style={{ padding: "12px 8px", flex: 1 }}>
                {NAV_ITEMS.map(({ to, icon: Icon, label }) => (
                  <NavLink
                    key={to} to={to} end={to === "/"}
                    style={({ isActive }) => ({
                      display: "flex", alignItems: "center", gap: 12,
                      padding: "10px 12px", borderRadius: radius.md,
                      marginBottom: 2, textDecoration: "none",
                      color: isActive ? colors.blue : colors.textSecondary,
                      background: isActive ? colors.bgActive : "transparent",
                      transition: "all 0.15s", position: "relative",
                    })}
                  >
                    {({ isActive }) => (
                      <>
                        <Icon size={18} style={{ flexShrink: 0 }} />
                        {sidebarOpen && (
                          <span style={{ fontSize: 14, fontWeight: isActive ? 600 : 400 }}>{label}</span>
                        )}
                        {/* Alert badge on Alerts nav item */}
                        {label === "Alerts" && alertCount > 0 && (
                          <span style={{
                            marginLeft: "auto",
                            minWidth: 18, height: 18, borderRadius: radius.pill,
                            background: colors.red, color: "#fff",
                            fontSize: 10, fontWeight: 800,
                            display: "flex", alignItems: "center", justifyContent: "center",
                            padding: "0 5px",
                          }}>{alertCount}</span>
                        )}
                      </>
                    )}
                  </NavLink>
                ))}
              </nav>

              {/* Connection indicator */}
              {sidebarOpen && (
                <div style={{
                  padding: "14px 16px", borderTop: `1px solid ${colors.border}`,
                  display: "flex", alignItems: "center", gap: 8,
                }}>
                  <div style={{
                    width: 7, height: 7, borderRadius: "50%",
                    background: colors.green,
                    boxShadow: `0 0 6px ${colors.green}`,
                  }} />
                  <span style={{ fontSize: 12, color: colors.textSecondary }}>API connected</span>
                </div>
              )}
            </aside>

            {/* Main */}
            <div style={{ flex: 1, display: "flex", flexDirection: "column", overflow: "hidden" }}>
              {/* Topbar */}
              <header style={{
                height: 56, padding: "0 24px",
                background: colors.bgPanel,
                borderBottom: `1px solid ${colors.border}`,
                display: "flex", alignItems: "center",
                justifyContent: "space-between", flexShrink: 0,
              }}>
                <button
                  onClick={() => setSidebarOpen(v => !v)}
                  style={{
                    background: "none", border: "none",
                    color: colors.textSecondary, cursor: "pointer",
                    fontSize: 18, padding: 4, lineHeight: 1,
                  }}
                >☰</button>

                <div style={{ display: "flex", gap: 16, alignItems: "center" }}>
                  {/* Live data indicator */}
                  <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                    <div style={{
                      width: 7, height: 7, borderRadius: "50%",
                      background: colors.green,
                      boxShadow: `0 0 6px ${colors.green}`,
                      animation: "aiq-live-pulse 2s ease-in-out infinite",
                    }} />
                    <span style={{ fontSize: 12, color: colors.textSecondary }}>Live</span>
                  </div>
                  <style>{`@keyframes aiq-live-pulse{0%,100%{opacity:1}50%{opacity:0.5}}`}</style>

                  {/* User avatar */}
                  <div style={{
                    width: 30, height: 30, borderRadius: "50%",
                    background: "linear-gradient(135deg, #388bfd, #bc8cff)",
                    display: "flex", alignItems: "center", justifyContent: "center",
                    fontWeight: 700, fontSize: 12, color: "#fff",
                  }}>U</div>
                </div>
              </header>

              {/* Page content */}
              <main style={{ flex: 1, overflow: "auto", padding: 24 }}>
                <Suspense fallback={<PageLoader />}>
                  <Routes>
                    <Route path="/"                index element={<CapitalDashboard />}    />
                    <Route path="/assets"                element={<AssetHealthPage />}     />
                    <Route path="/portfolio"             element={<PortfolioPage />}       />
                    <Route path="/recommendations"       element={<RecommendationsPage />} />
                    <Route path="/alerts"                element={<AlertsPage />}          />
                    <Route path="/settings"              element={<SettingsPage />}        />
                  </Routes>
                </Suspense>
              </main>
            </div>
          </div>
        </BrowserRouter>
      </ToastProvider>
    </QueryClientProvider>
  );
}
