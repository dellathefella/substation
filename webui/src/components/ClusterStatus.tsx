import { useEffect, useState } from 'react';
import { api, getStatus, type AdminResult } from '../api.js';
import { fmtAgo, fmtNum, truncate } from '../format.js';
import { useStore } from '../store.js';
import type { DaemonStatus, DiscoveryPeer, NodeHealth, ThunderboltLink } from '../types.js';
import { Bar, Empty, Panel, Pill } from './ui.js';

function linkTone(kind: string | undefined): 'ok' | 'info' | 'muted' {
  if (kind === 'thunderbolt') return 'ok';
  if (kind === 'ethernet') return 'info';
  return 'muted';
}

interface LinkLite {
  kind?: string;
  rtt_ms?: number;
  mbps?: number;
  rdma?: boolean;
  tb?: ThunderboltLink | null;
}

function linkRow(link: LinkLite | null | undefined): React.JSX.Element {
  const kind = link?.kind;
  return (
    <div className="nc-link">
      <Pill tone={linkTone(kind)} title={`link kind: ${kind ?? 'unknown'}`}>{kind ?? 'no link'}</Pill>
      <span className="nc-metric">{link ? `rtt ${fmtNum(link.rtt_ms, 2)}ms` : 'rtt —'}</span>
      <span className="nc-metric">{link ? `${fmtNum((link.mbps ?? 0) / 1000, 1)} Gbps` : '—'}</span>
      {link ? <span className={`badge ${link.rdma ? 'badge-rdma' : 'badge-tcp'}`}>{link.rdma ? 'RDMA' : 'TCP'}</span> : null}
    </div>
  );
}

function tbRow(tb: ThunderboltLink | null | undefined): React.JSX.Element | null {
  if (!tb) return null;
  const up = tb.reachable === true;
  return (
    <div className="nc-link nc-tb" title="Thunderbolt link (RPC path)">
      <Pill tone={up ? 'ok' : 'err'} title={up ? 'Thunderbolt link up' : 'Thunderbolt link down'}>⚡ TB {up ? 'up' : 'down'}</Pill>
      {up ? (
        <>
          <span className="nc-metric">rtt {fmtNum(tb.rtt_ms, 2)}ms</span>
          <span className="nc-metric">{fmtNum((tb.mbps ?? 0) / 1000, 1)} Gbps</span>
        </>
      ) : (
        <span className="nc-metric dim">no TB link</span>
      )}
    </div>
  );
}

function ResourceBars(props: { ramUsed: number; ramTotal: number; cpu?: number; gpu?: number }): React.JSX.Element {
  const { ramUsed, ramTotal, cpu, gpu } = props;
  return (
    <div className="rbars">
      <div className="rbar">
        <span className="rbar-k">RAM</span>
        <Bar value={ramUsed} max={Math.max(1, ramTotal)} height={7} title={`RAM ${fmtNum(ramUsed, 1)} / ${fmtNum(ramTotal, 0)} GB`} />
        <span className="rbar-v">{ramTotal > 0 ? `${((ramUsed / ramTotal) * 100).toFixed(0)}%` : '—'}</span>
      </div>
      {cpu !== undefined ? (
        <div className="rbar">
          <span className="rbar-k">CPU</span>
          <Bar value={cpu} max={100} height={7} title={`CPU ${cpu.toFixed(0)}%`} />
          <span className="rbar-v">{cpu.toFixed(0)}%</span>
        </div>
      ) : null}
      {gpu !== undefined ? (
        <div className="rbar">
          <span className="rbar-k">GPU</span>
          <Bar value={gpu} max={100} height={7} title={`GPU ${gpu.toFixed(0)}%`} />
          <span className="rbar-v">{gpu.toFixed(0)}%</span>
        </div>
      ) : null}
    </div>
  );
}

function NodeCard(props: {
  node: NodeHealth;
  peer: DiscoveryPeer | undefined;
  now: number;
  rpcBusy?: boolean;
  onRpc?: (id: string, start: boolean) => Promise<void>;
  removeBusy?: boolean;
  onRemove?: (id: string) => Promise<void>;
}): React.JSX.Element {
  const { node, peer } = props;
  const age = props.now - node.ts;
  const stale = age > 10_000;
  const ramUsed = node.health?.ram_used_gb ?? node.ram_used_gb ?? 0;
  const ramTotal = node.health?.ram_total_gb ?? node.ram_total_gb ?? 0;
  const cpu = node.health?.system?.cpu_pct;
  const gpu = node.health?.system?.gpu_pct ?? node.health?.gpu_pct ?? node.gpu_pct;
  const rx = node.health?.system?.rx_bps;
  const tx = node.health?.system?.tx_bps;
  const runners = node.health?.runners ?? node.runners ?? [];
  return (
    <div className={`node-card${stale ? ' stale' : ''}`}>
      <div className="nc-head">
        <span className="nc-name">{node.node}</span>
        <Pill tone={node.rpc_up === false ? 'err' : 'ok'} title={node.rpc_up === false ? 'rpc-server down' : 'rpc-server up'}>
          rpc {node.rpc_up === false ? 'down' : 'up'}
        </Pill>
        <Pill tone={stale ? 'warn' : 'ok'} title={`last heartbeat ${fmtAgo(age)} ago`}>♥ {fmtAgo(age)}</Pill>
        {props.onRpc ? (
          <button className="btn btn-sm nc-rpc" disabled={props.rpcBusy} onClick={() => void props.onRpc?.(node.node, node.rpc_up === false)}>
            {node.rpc_up === false ? 'RPC ▶' : 'RPC ⏹'}
          </button>
        ) : null}
        {props.onRemove ? (
          <button
            className="btn btn-sm nc-remove"
            title={`remove ${node.node} from the cluster`}
            disabled={props.removeBusy}
            onClick={() => {
              if (window.confirm(`Remove ${node.node} from the cluster? Its engines will be untracked and it will need to rejoin.`)) {
                void props.onRemove?.(node.node);
              }
            }}
          >
            ✕
          </button>
        ) : null}
      </div>
      <ResourceBars ramUsed={ramUsed} ramTotal={ramTotal} cpu={cpu} gpu={gpu} />
      {linkRow(node.link ?? peer?.link)}
      {tbRow((node.link ?? peer?.link)?.tb)}
      <div className="hc-foot">
        {rx !== undefined ? <span className="dim">↓ {(rx / 1_048_576).toFixed(1)} MB/s</span> : null}
        {tx !== undefined ? <span className="dim">↑ {(tx / 1_048_576).toFixed(1)} MB/s</span> : null}
        {runners.length > 0 ? (
          <span className="dim" title={runners.map((r) => `${r.model}:${r.port} ${r.state}`).join('\n')}>
            {runners.map((r) => truncate(r.model, 14)).join(', ')}
          </span>
        ) : (
          <span className="dim">no runners</span>
        )}
      </div>
    </div>
  );
}

export function ClusterStatus(): React.JSX.Element {
  const storeStatus = useStore((s) => s.status);
  const config = useStore((s) => s.config);
  const nodes = useStore((s) => s.nodes);
  const discovery = useStore((s) => s.discovery);
  const warnings = useStore((s) => s.warnings);
  const joinCode = useStore((s) => s.joinCode);
  const now = useStore((s) => s.now);
  const pushToast = useStore((s) => s.pushToast);
  const setJoinCode = useStore((s) => s.setJoinCode);
  const [live, setLive] = useState<DaemonStatus | null>(null);
  const [apiNodes, setApiNodes] = useState<NodeHealth[]>([]);
  const [busy, setBusy] = useState(false);
  const [rpcBusy, setRpcBusy] = useState(false);
  const [removeBusy, setRemoveBusy] = useState(false);

  const enabled = (live ?? storeStatus)?.cluster_enabled === true || config?.cluster?.enabled === true;

  useEffect(() => {
    let stop = false;
    const tick = async (): Promise<void> => {
      const [st, ns] = await Promise.all([getStatus(), api.nodes()]);
      if (stop) return;
      if (st) setLive(st);
      setApiNodes(ns.map((n) => ({
        node: n.id,
        ts: Date.now(),
        healthy: n.healthy,
        rpc_up: n.health?.rpc_up,
        link: n.link,
        health: n.health ?? null,
      })));
    };
    void tick();
    const t = setInterval(() => void tick(), 2500);
    return () => {
      stop = true;
      clearInterval(t);
    };
  }, []);

  const st = live ?? storeStatus;

  const setEnabled = async (next: boolean): Promise<void> => {
    setBusy(true);
    const res = await api.putConfig({ cluster: { enabled: next } });
    setBusy(false);
    if (res.ok) {
      useStore.getState().patchConfigLocal({ cluster: { enabled: next } });
      pushToast('success', next ? 'Cluster enabled' : 'Cluster disabled', next ? 'rpc-server + heartbeats starting on peers' : 'standalone mode');
    } else {
      pushToast('error', 'Cluster toggle failed', String(res.status || 'daemon unreachable'));
    }
  };

  const genJoinCode = async (): Promise<void> => {
    setBusy(true);
    const res: AdminResult = await api.joinCode();
    setBusy(false);
    const body = res.body as { code?: string; ttl_s?: number } | null;
    if (res.ok && body && typeof body.code === 'string') {
      setJoinCode({ code: body.code, ttl_s: typeof body.ttl_s === 'number' ? body.ttl_s : 600, at: Date.now() });
    } else {
      pushToast('error', 'Join code request failed', String(res.status || 'daemon unreachable'));
    }
  };

  const rpcPeer = async (id: string, start: boolean): Promise<void> => {
    setRpcBusy(true);
    const res = await api.rpcPeer(id, start);
    setRpcBusy(false);
    if (res.ok) pushToast('success', `rpc/${start ? 'start' : 'stop'} on ${id}`, 'worker acknowledged');
    else pushToast('error', `rpc toggle failed on ${id}`, String(res.status || 'daemon unreachable'));
  };

  const removeNode = async (id: string): Promise<void> => {
    setRemoveBusy(true);
    const res = await api.unjoin(id);
    setRemoveBusy(false);
    if (res.ok) {
      setApiNodes((prev) => prev.filter((n) => n.node !== id));
      useStore.getState().removeNodeLocal?.(id);
      pushToast('success', `${id} removed from cluster`, 'it must rejoin with a join code to return');
    } else {
      pushToast('error', `remove failed for ${id}`, String(res.status || 'daemon unreachable'));
    }
  };

  const peerFor = (node: string): DiscoveryPeer | undefined =>
    discovery.find((p) => p.node_id === node || p.name === node);

  const nodeList: NodeHealth[] = apiNodes.length > 0
    ? apiNodes
    : Object.values(nodes).sort((a, b) => a.node.localeCompare(b.node));

  const joined = discovery.filter((p) => peerFor(p.node_id) !== undefined);
  const beaconing = discovery.filter((p) => peerFor(p.node_id) === undefined);

  const mem = st?.memory;
  const memRatio = mem && mem.total_gb > 0 ? mem.used_gb / mem.total_gb : 0;

  return (
    <Panel
      title="Cluster status"
      className="panel-cluster"
      right={
        <div className="hc-right">
          <Pill tone={enabled ? 'ok' : 'muted'}>{enabled ? 'enabled' : 'disabled'}</Pill>
          {enabled ? (
            <button className="btn btn-sm" onClick={() => void setEnabled(false)} disabled={busy}>Disable</button>
          ) : (
            <button className="btn btn-sm btn-primary" onClick={() => void setEnabled(true)} disabled={busy}>{busy ? '…' : 'Enable'}</button>
          )}
        </div>
      }
    >
      {warnings.map((w) => (
        <div key={`${w.node}-${w.code}`} className={`banner banner-${w.level === 'error' ? 'err' : 'warn'}`} role="alert">
          <span className="banner-code">{w.code}</span>
          <span className="banner-node">{w.node}</span>
          <span className="banner-msg">{w.msg}{w.repeated ? ` · ×${w.repeated + 1}` : ''}</span>
          <button
            className="banner-x"
            aria-label="dismiss"
            onClick={() => useStore.setState({ warnings: useStore.getState().warnings.filter((x) => x !== w) })}
          >
            ✕
          </button>
        </div>
      ))}
      {st?.gpu_budget ? (
        <div className="gpu-budget" title="Metal GPU wired-memory budget across all resident models" style={{ display: 'flex', alignItems: 'center', gap: 8, margin: '4px 0 10px' }}>
          <span className="dim" style={{ minWidth: 28 }}>GPU</span>
          <div style={{ flex: 1, height: 8, background: '#232b3a', borderRadius: 4, overflow: 'hidden' }}>
            <div style={{
              height: '100%',
              width: `${Math.min(100, (st.gpu_budget.resident_gb / Math.max(1, st.gpu_budget.wired_limit_gb)) * 100)}%`,
              background: st.gpu_budget.headroom_gb < 8 ? '#e5534b' : st.gpu_budget.headroom_gb < 24 ? '#d99a2b' : '#3fb950',
            }} />
          </div>
          <span className="dim" style={{ whiteSpace: 'nowrap' }}>
            {st.gpu_budget.resident_gb.toFixed(0)} / {st.gpu_budget.wired_limit_gb.toFixed(0)} GB · headroom {st.gpu_budget.headroom_gb.toFixed(0)} GB
          </span>
        </div>
      ) : null}
      {st?.catalog_reconciliation && st.catalog_reconciliation.unservable.length > 0 ? (
        <div className="banner banner-warn" role="alert">
          <span className="banner-code">catalog</span>
          <span className="banner-msg">
            No node can serve: {st.catalog_reconciliation.unservable.join(', ')} — add the GGUF to a node's catalog or remove the profile
          </span>
        </div>
      ) : null}
      <div className="node-grid">
        {mem && mem.local_enabled !== false ? (
          <div className="node-card">
            <div className="nc-head">
              <span className="nc-name">⬢ this Mac</span>
              <Pill tone={mem.pressure === 'critical' ? 'err' : mem.pressure === 'warn' ? 'warn' : 'ok'}>{mem.pressure ?? 'ok'}</Pill>
              {mem.gpu_wired_limit_gb ? <span className="nc-metric">gpu cap {mem.gpu_wired_limit_gb.toFixed(0)}</span> : null}
            </div>
            <ResourceBars
              ramUsed={mem.used_gb ?? 0}
              ramTotal={mem.total_gb ?? 0}
              cpu={st?.system?.cpu_pct}
              gpu={st?.system?.gpu_pct}
            />
            <div className="hc-foot">
              <span className="dim">{(mem.used_gb ?? 0).toFixed(1)} / {(mem.total_gb ?? 0).toFixed(0)} GB · avail {(mem.free_gb ?? 0).toFixed(1)}{memRatio > 0 ? ` · ${(memRatio * 100).toFixed(0)}%` : ''}</span>
              {st?.system?.rx_bps !== undefined ? <span className="dim">↓ {(st.system.rx_bps / 1_048_576).toFixed(1)} MB/s</span> : null}
              {st?.system?.tx_bps !== undefined ? <span className="dim">↑ {(st.system.tx_bps / 1_048_576).toFixed(1)} MB/s</span> : null}
            </div>
          </div>
        ) : null}
        {nodeList.length === 0 ? <Empty text="no nodes joined yet" /> : null}
        {nodeList.map((n) => (
          <NodeCard key={n.node} node={n} peer={peerFor(n.node)} now={now} rpcBusy={rpcBusy} onRpc={enabled ? rpcPeer : undefined} removeBusy={removeBusy} onRemove={enabled ? removeNode : undefined} />
        ))}
      </div>
      {enabled ? (
        <div className="discovery-block">
          <div className="kv-head">
            <span>Discovery</span>
            <span className="dim">{discovery.length} peer{discovery.length === 1 ? '' : 's'} beaconing</span>
          </div>
          {discovery.length === 0 ? <div className="dim kv-note">no discovery beacons received</div> : null}
          <ul className="peer-list">
            {[...joined, ...beaconing].map((p) => (
              <li key={p.node_id} className="peer-row">
                <span className={`peer-dot${peerFor(p.node_id) ? ' joined' : ''}`} aria-hidden="true" />
                <span className="peer-name">{p.name}</span>
                <span className="peer-ip">{p.ip}:{p.agent_port}</span>
                <Pill tone={linkTone(p.link?.kind)}>{p.link?.kind ?? 'link?'}</Pill>
                <span className="nc-metric">{p.link ? `${fmtNum(p.link.rtt_ms, 2)}ms · ${fmtNum((p.link.mbps ?? 0) / 1000, 1)}Gbps` : '—'}</span>
                <span className={`badge ${p.link?.rdma ? 'badge-rdma' : 'badge-tcp'}`}>{p.link?.rdma ? 'RDMA' : 'TCP'}</span>
                <span className="peer-age">seen {fmtAgo(p.seen_ms_ago)} ago</span>
              </li>
            ))}
          </ul>
          <div className="join-row">
            <button className="btn btn-primary" onClick={() => void genJoinCode()} disabled={busy}>Generate join code</button>
            <span className="dim">6-digit code · 10 min TTL</span>
          </div>
          {joinCode ? (
            <div className="join-code-box" role="status">
              <span className="join-code-label">JOIN CODE</span>
              <span className="join-code-value">{joinCode.code}</span>
              <span className="join-code-ttl">expires in {Math.max(0, Math.ceil((joinCode.at + joinCode.ttl_s * 1000 - now) / 1000))}s</span>
              <button className="banner-x" aria-label="dismiss join code" onClick={() => setJoinCode(null)}>✕</button>
            </div>
          ) : null}
        </div>
      ) : null}
    </Panel>
  );
}
