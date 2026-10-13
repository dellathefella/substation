import { useEffect, useState } from 'react';
import { bootstrap } from './api.js';
import { CachePanel } from './components/CachePanel.js';
import { ChatPanel } from './components/ChatPanel.js';
import { ClusterStatus } from './components/ClusterStatus.js';
import { ClusterWizard } from './components/ClusterWizard.js';
import { LogsPanel } from './components/LogsPanel.js';
import { CostPanel } from './components/CostPanel.js';
import { ConnectPanel } from './components/ConnectPanel.js';
import { Header } from './components/Header.js';
import type { View } from './components/Header.js';
import { LatencyPanel } from './components/LatencyPanel.js';
import { ModelsPanel } from './components/ModelsPanel.js';
import { RoutingFeed } from './components/RoutingFeed.js';
import { SettingsDrawer } from './components/SettingsDrawer.js';
import { Toasts } from './components/Toasts.js';
import { ThroughputPanel } from './components/ThroughputPanel.js';
import { TriagePanel } from './components/TriagePanel.js';
import { useStore, watchConfigRefresh } from './store.js';
import { connectDashboard } from './ws.js';

export function App(): React.JSX.Element {
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [view, setView] = useState<View>('dash');
  const hydrate = useStore((s) => s.hydrate);
  const booted = useStore((s) => s.booted);
  const ws = useStore((s) => s.ws);

  useEffect(() => {
    let cancelled = false;
    const stop = connectDashboard();
    const unwatch = watchConfigRefresh();
    void bootstrap().then((b) => {
      if (!cancelled) hydrate(b);
    });
    const timer = setInterval(() => useStore.getState().tick(Date.now()), 1000);
    return () => {
      cancelled = true;
      stop();
      unwatch();
      clearInterval(timer);
    };
  }, [hydrate]);

  return (
    <div className="app">
      <Header onOpenSettings={() => setSettingsOpen(true)} view={view} onView={setView} />
      {ws === 'offline' ? (
        <div className="banner banner-warn offline-banner" role="alert">
          <span className="banner-code">WS OFFLINE</span>
          <span className="banner-msg">
            Last known state shown below — {booted ? 'reconnecting…' : 'daemon not reachable; open the mock (scripts/mock-ws.mjs) or set VITE_WS_URL.'}
          </span>
        </div>
      ) : null}
      {view === 'dash' ? (
        <main className="grid">
          <div className="row row-top">
            <ThroughputPanel />
            <TriagePanel />
          </div>
          <div className="row row-mid">
            <LatencyPanel />
            <CachePanel />
          </div>
          <div className="row row-feed">
            <RoutingFeed />
            <ModelsPanel />
          </div>
        </main>
      ) : view === 'chat' ? (
        <main className="chat-view">
          <ChatPanel />
        </main>
      ) : view === 'connect' ? (
        <main className="chat-view">
          <ConnectPanel />
        </main>
      ) : view === 'cluster' ? (
        <main className="cluster-view">
          <ClusterStatus />
          <ClusterWizard />
        </main>
      ) : view === 'cost' ? (
        <main className="chat-view">
          <CostPanel />
        </main>
      ) : (
        <main className="chat-view">
          <LogsPanel />
        </main>
      )}
      <footer className="footer">
        <span>substationd · protocol v2</span>
        <span className="dim">triage → tier → route → schedule · model switching stays transparent to clients</span>
      </footer>
      <SettingsDrawer open={settingsOpen} onClose={() => setSettingsOpen(false)} />
      <Toasts />
    </div>
  );
}
