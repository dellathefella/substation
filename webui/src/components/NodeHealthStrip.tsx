import { useEffect, useState } from 'react';
import { getStatus } from '../api.js';
import { useStore } from '../store.js';
import type { DaemonStatus } from '../types.js';
import { Bar, Pill } from './ui.js';

function agoShort(sec: number): string {
  if (sec < 2) return 'now';
  if (sec < 60) return `${Math.round(sec)}s`;
  const m = Math.floor(sec / 60);
  if (m < 60) return `${m}m`;
  return `${Math.floor(m / 60)}h`;
}

export function NodeHealthStrip(): React.JSX.Element | null {
  const storeStatus = useStore((s) => s.status);
  const nodes = useStore((s) => s.nodes);
  const discovery = useStore((s) => s.discovery);
  const now = useStore((s) => s.now);
  const [live, setLive] = useState<DaemonStatus | null>(null);

  useEffect(() => {
    let stop = false;
    const tick = async (): Promise<void> => {
      const st = await getStatus();
      if (!stop && st) setLive(st);
    };
    void tick();
    const t = setInterval(() => void tick(), 2500);
    return () => {
      stop = true;
      clearInterval(t);
    };
  }, []);

  const st = live ?? storeStatus;
  if (!st) return null;
  const mem = st.memory;
  const clusterOn = st.cluster_enabled === true;
  const list = Object.values(nodes).sort((a, b) => a.node.localeCompare(b.node));
  const pTone = mem?.pressure === 'critical' ? 'err' : mem?.pressure === 'warn' ? 'warn' : 'ok';

  return (
    <div className="health-strip">
      <div className="hc-card hc-local">
        <div className="hc-head">
          <span className="hc-name">⬢ this Mac</span>
          {mem ? (
            <Pill tone={pTone} title={`memory pressure: ${mem.pressure} · min-free guard ${(mem.min_free_gb ?? 0).toFixed(0)} GB`}>
              {mem.pressure ?? 'ok'}
            </Pill>
          ) : (
            <Pill tone="muted">no metrics</Pill>
          )}
        </div>
        {mem ? (
          <>
            <Bar value={mem.used_gb} max={mem.total_gb} height={9} title={`RAM ${mem.used_gb.toFixed(1)} / ${mem.total_gb.toFixed(0)} GB`} />
            <div className="hc-foot">
              <span>{mem.used_gb.toFixed(1)} / {mem.total_gb.toFixed(0)} GB</span>
              <span className="dim">free {mem.free_gb.toFixed(1)}</span>
              {mem.resident_gb ? <span className="dim">models {mem.resident_gb.toFixed(1)}</span> : null}
              {mem.gpu_wired_limit_gb ? <span className="dim">gpu cap {mem.gpu_wired_limit_gb.toFixed(0)}</span> : null}
            </div>
          </>
        ) : null}
      </div>

      {list.map((n) => {
        const age = Math.max(0, (now - n.ts) / 1000);
        const heart: 'ok' | 'warn' | 'err' = age > 30 ? 'err' : age > 10 ? 'warn' : 'ok';
        const link = discovery.find((p) => p.node_id === n.node || p.name === n.node)?.link;
        const ratio = n.ram_total_gb > 0 ? n.ram_used_gb / n.ram_total_gb : 0;
        const ramTone: 'ok' | 'warn' | 'err' = ratio > 0.92 ? 'err' : ratio > 0.8 ? 'warn' : 'ok';
        return (
          <div className={`hc-card${heart === 'err' ? ' hc-dead' : ''}`} key={n.node}>
            <div className="hc-head">
              <span className="hc-name">{n.node}</span>
              <Pill tone={heart} title={`last heartbeat ${agoShort(age)} ago`}>♥ {agoShort(age)}</Pill>
              <Pill tone={n.rpc_up === false ? 'err' : 'ok'} title="ggml-rpc worker">
                rpc {n.rpc_up === false ? 'down' : 'up'}
              </Pill>
            </div>
            <Bar value={n.ram_used_gb} max={n.ram_total_gb} height={9} title={`RAM ${n.ram_used_gb.toFixed(1)} / ${n.ram_total_gb.toFixed(0)} GB`} />
            <div className="hc-foot">
              <span className={ramTone === 'err' ? 'hc-bad' : ''}>{n.ram_used_gb.toFixed(1)} / {n.ram_total_gb.toFixed(0)} GB</span>
              <span className="dim">{link?.kind ?? 'no link'}</span>
              {link ? <span className="dim">{(link.mbps / 1000).toFixed(1)} Gbps</span> : null}
              {n.runners.length ? <span className="dim">{n.runners.length} runner{n.runners.length > 1 ? 's' : ''}</span> : <span className="dim">idle</span>}
            </div>
          </div>
        );
      })}

      {clusterOn && list.length === 0 ? (
        <div className="hc-card hc-muted">
          <div className="hc-head"><span className="hc-name">cluster</span><Pill tone="warn">no nodes</Pill></div>
          <div className="hc-foot"><span className="dim">clustering on · waiting for node.health heartbeats…</span></div>
        </div>
      ) : null}
      {!clusterOn ? (
        <div className="hc-card hc-muted">
          <div className="hc-head"><span className="hc-name">cluster</span><Pill tone="muted">off</Pill></div>
          <div className="hc-foot"><span className="dim">local Mac only · enable in Settings</span></div>
        </div>
      ) : null}
    </div>
  );
}
