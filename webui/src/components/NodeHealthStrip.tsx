import { useEffect, useState } from 'react';
import { api, getStatus } from '../api.js';
import { useStore } from '../store.js';
import type { DaemonStatus, NodeInfo } from '../types.js';
import { Bar, Pill } from './ui.js';

function agoShort(sec: number): string {
  if (sec < 2) return 'now';
  if (sec < 60) return `${Math.round(sec)}s`;
  const m = Math.floor(sec / 60);
  if (m < 60) return `${m}m`;
  return `${Math.floor(m / 60)}h`;
}

interface Card {
  name: string;
  ramUsed: number;
  ramTotal: number;
  rpcUp?: boolean;
  healthy: boolean;
  ts?: number;
  link?: { kind?: string; mbps?: number } | null;
  runners: number;
}

function mapNodes(list: NodeInfo[]): Card[] {
  return list.map((n) => ({
    name: n.id,
    ramUsed: n.health?.ram_used_gb ?? 0,
    ramTotal: n.health?.ram_total_gb ?? 0,
    rpcUp: n.health?.rpc_up,
    healthy: n.healthy,
    ts: undefined,
    link: n.link ?? null,
    runners: n.health?.runners?.length ?? 0,
  }));
}

export function NodeHealthStrip(): React.JSX.Element | null {
  const storeStatus = useStore((s) => s.status);
  const nodes = useStore((s) => s.nodes);
  const discovery = useStore((s) => s.discovery);
  const now = useStore((s) => s.now);
  const [live, setLive] = useState<DaemonStatus | null>(null);
  const [apiNodes, setApiNodes] = useState<Card[]>([]);

  useEffect(() => {
    let stop = false;
    const tick = async (): Promise<void> => {
      const st = await getStatus();
      const ns = await api.nodes();
      if (stop) return;
      if (st) setLive(st);
      setApiNodes(mapNodes(ns));
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
  const list: Card[] =
    apiNodes.length > 0
      ? apiNodes.map((c) => ({ ...c, ts: nodes[c.name]?.ts }))
      : Object.values(nodes)
          .sort((a, b) => a.node.localeCompare(b.node))
          .map((n) => ({
            name: n.node,
            ramUsed: n.ram_used_gb,
            ramTotal: n.ram_total_gb,
            rpcUp: n.rpc_up,
            healthy: true,
            ts: n.ts,
            link: discovery.find((p) => p.node_id === n.node || p.name === n.node)?.link ?? null,
            runners: n.runners.length,
          }));
  const pTone = mem?.pressure === 'critical' ? 'err' : mem?.pressure === 'warn' ? 'warn' : 'ok';

  return (
    <div className="health-strip">
      <div className="hc-card hc-local">
        <div className="hc-head">
          <span className="hc-name">⬢ this Mac</span>
          {mem ? (
            <Pill tone={pTone} title={`memory pressure: ${mem.pressure} · min-free guard ${(mem.min_free_gb ?? 0).toFixed(0)} GB · used = app+wire+compressed (file cache excluded)`}>
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
              <span className="dim">avail {mem.free_gb.toFixed(1)}</span>
              {mem.resident_gb ? <span className="dim">models {mem.resident_gb.toFixed(1)}</span> : null}
              {mem.gpu_wired_limit_gb ? <span className="dim">gpu cap {mem.gpu_wired_limit_gb.toFixed(0)}</span> : null}
            </div>
          </>
        ) : null}
      </div>

      {list.map((n) => {
        const age = n.ts ? Math.max(0, (now - n.ts) / 1000) : null;
        const heart: 'ok' | 'warn' | 'err' = !n.healthy ? 'err' : age !== null && age > 30 ? 'err' : age !== null && age > 10 ? 'warn' : 'ok';
        const ratio = n.ramTotal > 0 ? n.ramUsed / n.ramTotal : 0;
        const ramTone: 'ok' | 'warn' | 'err' = ratio > 0.92 ? 'err' : ratio > 0.8 ? 'warn' : 'ok';
        return (
          <div className={`hc-card${heart === 'err' ? ' hc-dead' : ''}`} key={n.name}>
            <div className="hc-head">
              <span className="hc-name">{n.name}</span>
              <Pill tone={heart} title={age !== null ? `last heartbeat ${agoShort(age)} ago` : n.healthy ? 'healthy' : 'unhealthy'}>
                ♥ {age !== null ? agoShort(age) : n.healthy ? 'ok' : 'down'}
              </Pill>
              <Pill tone={n.rpcUp === false ? 'err' : 'ok'} title="ggml-rpc worker">
                rpc {n.rpcUp === false ? 'down' : 'up'}
              </Pill>
            </div>
            <Bar value={n.ramUsed} max={n.ramTotal} height={9} title={`RAM ${n.ramUsed.toFixed(1)} / ${n.ramTotal.toFixed(0)} GB`} />
            <div className="hc-foot">
              <span className={ramTone === 'err' ? 'hc-bad' : ''}>{n.ramUsed.toFixed(1)} / {n.ramTotal.toFixed(0)} GB</span>
              <span className="dim">{n.link?.kind ?? 'no link'}</span>
              {n.link?.mbps ? <span className="dim">{(n.link.mbps / 1000).toFixed(1)} Gbps</span> : null}
              {n.runners > 0 ? <span className="dim">{n.runners} runner{n.runners > 1 ? 's' : ''}</span> : <span className="dim">idle</span>}
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
          <div className="hc-name hc-head"><span className="hc-name">cluster</span><Pill tone="muted">off</Pill></div>
          <div className="hc-foot"><span className="dim">local Mac only · enable in Settings</span></div>
        </div>
      ) : null}
    </div>
  );
}
