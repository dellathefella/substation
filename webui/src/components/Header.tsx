import { useState } from 'react';
import type { ReactNode } from 'react';
import { api } from '../api.js';
import { fmtInt, fmtNum, fmtPct, fmtUptime } from '../format.js';
import { selectCacheRatio, selectInflight, selectLiveTokPerS, selectUptime, useStore } from '../store.js';
import { Pill } from './ui.js';

function stateTone(state: string | undefined): 'ok' | 'warn' | 'err' | 'info' | 'muted' {
  switch (state) {
    case 'running':
    case 'ok':
      return 'ok';
    case 'paused':
      return 'warn';
    case 'degraded':
    case 'error':
      return 'err';
    default:
      return 'info';
  }
}

export type View = 'dash' | 'chat' | 'connect' | 'cluster' | 'logs';

export function Header(props: { onOpenSettings: () => void; view: View; onView: (v: View) => void }): ReactNode {
  const status = useStore((s) => s.status);
  const ws = useStore((s) => s.ws);
  const wsUrl = useStore((s) => s.wsUrl);
  const liveTok = useStore(selectLiveTokPerS);
  const inflight = useStore(selectInflight);
  const cacheRatio = useStore(selectCacheRatio);
  const uptime = useStore(selectUptime);
  const reqTimes = useStore((s) => s.reqTimes);
  const now = useStore((s) => s.now);
  const pushToast = useStore((s) => s.pushToast);
  const [busy, setBusy] = useState<string | null>(null);

  const reqMin = reqTimes.filter((t) => now - t < 60_000).length;
  const state = status?.state ?? 'unknown';
  const paused = state === 'paused';
  const tokPerS = liveTok > 0 ? liveTok : status?.tokens_per_sec ?? null;

  const act = async (kind: 'pause' | 'resume' | 'reload'): Promise<void> => {
    setBusy(kind);
    const res = kind === 'pause' ? await api.pause() : kind === 'resume' ? await api.resume() : await api.reload();
    setBusy(null);
    if (!res.ok) {
      pushToast('error', `Admin ${kind} failed`, String(res.status || 'daemon unreachable'));
      return;
    }
    if (kind === 'reload') {
      pushToast('success', 'Config reloaded');
      return;
    }
    const body = res.body as { state?: string; uptime_s?: number; requests_active?: number; requests_per_min?: number; tokens_per_sec?: number; models_loaded?: number; models_total?: number } | null;
    if (body && typeof body.state === 'string') {
      useStore.getState().applyFrames([{ type: 'status', ts: Date.now(), data: body }]);
    }
    pushToast('info', kind === 'pause' ? 'Daemon paused' : 'Daemon resumed');
  };

  return (
    <header className="header">
      <div className="header-brand">
        <div className="brand-mark" aria-hidden="true">
          <svg width="22" height="22" viewBox="0 0 22 22">
            <polygon points="11,1 21,6.5 21,15.5 11,21 1,15.5 1,6.5" fill="none" stroke="#3b82f6" strokeWidth="1.6" />
            <circle cx="11" cy="11" r="3" fill="#3b82f6" />
          </svg>
        </div>
        <div className="brand-text">
          <span className="brand-name">SUBSTATION</span>
          <span className="brand-sub">llama.cpp control plane</span>
        </div>
      </div>

      <div className="header-stats">
        <div className="hero-stat">
          <span className="hero-value">{fmtNum(tokPerS, 1)}</span>
          <span className="hero-unit">tok/s</span>
        </div>
        <div className="hero-div" aria-hidden="true" />
        <div className="mini-stat">
          <span className="mini-value">{fmtInt(reqMin)}</span>
          <span className="mini-label">req/min</span>
        </div>
        <div className="mini-stat">
          <span className="mini-value">{fmtInt(inflight)}</span>
          <span className="mini-label">active</span>
        </div>
        <div className="mini-stat">
          <span className="mini-value">{fmtPct(cacheRatio, 1)}</span>
          <span className="mini-label">cache hit</span>
        </div>
        <div className="mini-stat">
          <span className="mini-value">{fmtUptime(uptime)}</span>
          <span className="mini-label">uptime</span>
        </div>
      </div>

      <div className="header-right">
        <nav className="view-nav" aria-label="View">
          <button className={`nav-btn${props.view === 'dash' ? ' active' : ''}`} onClick={() => props.onView('dash')}>
            Dashboard
          </button>
          <button className={`nav-btn${props.view === 'chat' ? ' active' : ''}`} onClick={() => props.onView('chat')}>
            Chat
          </button>
          <button className={`nav-btn${props.view === 'connect' ? ' active' : ''}`} onClick={() => props.onView('connect')}>
            Connect
          </button>
          <button className={`nav-btn${props.view === 'cluster' ? ' active' : ''}`} onClick={() => props.onView('cluster')}>
            Cluster
          </button>
          <button className={`nav-btn${props.view === 'logs' ? ' active' : ''}`} onClick={() => props.onView('logs')}>
            Logs
          </button>
        </nav>
        {paused ? (
          <span className="paused-badge" role="status">
            PAUSED
          </span>
        ) : null}
        <Pill tone={stateTone(state)} title={`daemon state: ${state}`}>
          {state}
        </Pill>
        <Pill tone={ws === 'connected' ? 'ok' : ws === 'connecting' ? 'info' : 'err'} title={wsUrl}>
          ws {ws === 'connected' ? 'live' : ws}
        </Pill>
        <div className="admin-group">
          <button className="btn btn-icon" onClick={() => void act('pause')} disabled={busy !== null} title="POST /api/admin/pause">
            {busy === 'pause' ? '…' : '⏸'}
          </button>
          <button className="btn btn-icon" onClick={() => void act('resume')} disabled={busy !== null} title="POST /api/admin/resume">
            {busy === 'resume' ? '…' : '▶'}
          </button>
          <button className="btn btn-icon" onClick={() => void act('reload')} disabled={busy !== null} title="POST /api/admin/reload">
            {busy === 'reload' ? '…' : '⟳'}
          </button>
        </div>
        <button className="btn btn-icon btn-gear" onClick={props.onOpenSettings} title="Settings" aria-label="Open settings">
          <svg width="15" height="15" viewBox="0 0 16 16" aria-hidden="true">
            <path
              fill="currentColor"
              d="M8 5.5A2.5 2.5 0 1 0 8 10.5 2.5 2.5 0 0 0 8 5.5Zm6.3 2.5c0-.4-.04-.79-.1-1.17l1.6-1.25-1.7-2.95-1.9.77a6.4 6.4 0 0 0-2.02-1.17L9.9 0.2H6.1L5.82 2.23a6.4 6.4 0 0 0-2.02 1.17l-1.9-.77-1.7 2.95 1.6 1.25a6.6 6.6 0 0 0 0 2.34L.2 10.42l1.7 2.95 1.9-.77a6.4 6.4 0 0 0 2.02 1.17L6.1 15.8h3.8l.28-2.03a6.4 6.4 0 0 0 2.02-1.17l1.9.77 1.7-2.95-1.6-1.25c.06-.38.1-.77.1-1.17Z"
              transform="scale(0.94) translate(0.5 0.4)"
            />
          </svg>
        </button>
      </div>
    </header>
  );
}
