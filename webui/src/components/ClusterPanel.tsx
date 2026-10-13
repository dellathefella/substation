import { useState } from 'react';
import { api, type AdminResult } from '../api.js';
import { fmtAgo, fmtNum, truncate } from '../format.js';
import { useStore } from '../store.js';
import type { DiscoveryPeer, NodeHealth } from '../types.js';
import { Bar, Empty, Panel, Pill } from './ui.js';

function linkTone(kind: string | undefined): 'ok' | 'info' | 'muted' {
  if (kind === 'thunderbolt') return 'ok';
  if (kind === 'ethernet') return 'info';
  return 'muted';
}

function NodeCard(props: { node: NodeHealth; peer: DiscoveryPeer | undefined; now: number }): React.JSX.Element {
  const { node, peer } = props;
  const age = props.now - node.ts;
  const stale = age > 10_000;
  const ramRatio = node.ram_total_gb > 0 ? node.ram_used_gb / node.ram_total_gb : 0;
  const rdma = peer?.link?.rdma ?? false;
  const kind = peer?.link?.kind;
  return (
    <div className={`node-card${stale ? ' stale' : ''}`}>
      <div className="nc-head">
        <span className="nc-name">{node.node}</span>
        <Pill tone={node.rpc_up === false ? 'err' : 'ok'} title={node.rpc_up === false ? 'rpc-server down' : 'rpc-server up'}>
          rpc {node.rpc_up === false ? 'down' : 'up'}
        </Pill>
        <Pill tone={stale ? 'warn' : 'ok'} title={`last heartbeat ${fmtAgo(age)} ago`}>
          ♥ {fmtAgo(age)}
        </Pill>
      </div>
      <div className="nc-ram">
        <div className="kv-row">
          <span className="kv-k">RAM</span>
          <span className="kv-v">
            {fmtNum(node.ram_used_gb, 1)} / {fmtNum(node.ram_total_gb, 0)} GB · {(ramRatio * 100).toFixed(0)}%
          </span>
        </div>
        <Bar value={node.ram_used_gb} max={node.ram_total_gb} height={8} title="node RAM pressure" />
      </div>
      <div className="nc-link">
        <Pill tone={linkTone(kind)} title={`link kind: ${kind ?? 'unknown'}`}>
          {kind ?? 'no link'}
        </Pill>
        <span className="nc-metric">rtt {peer?.link ? `${fmtNum(peer.link.rtt_ms, 2)}ms` : '—'}</span>
        <span className="nc-metric">{peer?.link ? `${fmtNum(peer.link.mbps / 1000, 1)} Gbps` : '—'}</span>
        {peer?.link ? (
          <span className={`badge ${rdma ? 'badge-rdma' : 'badge-tcp'}`} title={rdma ? 'RDMA path active' : 'RDMA path unavailable — RPC over TCP'}>
            {rdma ? 'RDMA' : 'TCP'}
          </span>
        ) : null}
        {node.rpc_ms_last !== undefined ? <span className="nc-metric">rpc {fmtNum(node.rpc_ms_last, 1)}ms</span> : null}
        {node.gpu_pct !== undefined ? <span className="nc-metric">gpu {node.gpu_pct.toFixed(0)}%</span> : null}
      </div>
      {node.runners.length > 0 ? (
        <div className="nc-runners" title={node.runners.map((r) => `${r.model}:${r.port} ${r.state}`).join('\n')}>
          {node.runners.map((r) => (
            <span key={`${r.model}-${r.port}`} className="runner-chip">
              {truncate(r.model, 16)}
              {r.tok_s ? <span className="runner-tok">{fmtNum(r.tok_s, 0)}t/s</span> : null}
            </span>
          ))}
        </div>
      ) : (
        <div className="dim kv-note">no runners on this node</div>
      )}
    </div>
  );
}

export function ClusterPanel(): React.JSX.Element {
  const config = useStore((s) => s.config);
  const nodes = useStore((s) => s.nodes);
  const discovery = useStore((s) => s.discovery);
  const warnings = useStore((s) => s.warnings);
  const joinCode = useStore((s) => s.joinCode);
  const now = useStore((s) => s.now);
  const pushToast = useStore((s) => s.pushToast);
  const setJoinCode = useStore((s) => s.setJoinCode);
  const [busy, setBusy] = useState(false);

  const enabled = config?.cluster?.enabled === true;

  const setEnabled = async (next: boolean): Promise<void> => {
    setBusy(true);
    const res = await api.putConfig({ cluster: { enabled: next } });
    setBusy(false);
    if (res.ok) {
      useStore.getState().patchConfigLocal({ cluster: { enabled: next } });
      pushToast('success', 'Cluster enabled', 'rpc-server + heartbeats starting on peers');
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

  const peerFor = (node: string): DiscoveryPeer | undefined =>
    discovery.find((p) => p.node_id === node || p.name === node);

  const nodeList = Object.values(nodes).sort((a, b) => a.node.localeCompare(b.node));
  const joined = discovery.filter((p) => peerFor(p.node_id) !== undefined);
  const beaconing = discovery.filter((p) => peerFor(p.node_id) === undefined);

  return (
    <Panel
      title="Cluster"
      className="panel-cluster"
      right={
        enabled ? (
          <button className="btn btn-sm" onClick={() => void setEnabled(false)} disabled={busy}>
            Disable
          </button>
        ) : (
          <button className="btn btn-sm btn-primary" onClick={() => void setEnabled(true)} disabled={busy}>
            Enable
          </button>
        )
      }
    >
      {!config ? (
        <Empty text="config unavailable — cluster state unknown (daemon offline?)" />
      ) : !enabled ? (
        <div className="cluster-off">
          <span className="cluster-off-text">Cluster disabled — running standalone on this node.</span>
          <button className="btn btn-primary" onClick={() => void setEnabled(true)} disabled={busy}>
            {busy ? '…' : 'Enable'}
          </button>
          <span className="dim">PUT {'{"cluster":{"enabled":true}}'} → starts rpc-server, heartbeats and link probes</span>
        </div>
      ) : (
        <>
          {warnings.map((w) => (
            <div key={`${w.node}-${w.code}-${w.ts}`} className={`banner banner-${w.level === 'error' ? 'err' : 'warn'}`} role="alert">
              <span className="banner-code">{w.code}</span>
              <span className="banner-node">{w.node}</span>
              <span className="banner-msg">{w.msg}</span>
              <button
                className="banner-x"
                aria-label="dismiss"
                onClick={() => useStore.setState({ warnings: useStore.getState().warnings.filter((x) => x !== w) })}
              >
                ✕
              </button>
            </div>
          ))}
          {nodeList.length === 0 ? (
            <Empty text="no nodes reporting yet — waiting for node.health…" />
          ) : (
            <div className="node-grid">{nodeList.map((n) => <NodeCard key={n.node} node={n} peer={peerFor(n.node)} now={now} />)}</div>
          )}
          <div className="discovery-block">
            <div className="kv-head">
              <span>Discovery</span>
              <span className="dim">{discovery.length} peer{discovery.length === 1 ? '' : 's'} beaconing · UDP 224.0.1.87:8810</span>
            </div>
            {discovery.length === 0 ? (
              <div className="dim kv-note">no discovery beacons received</div>
            ) : (
              <ul className="peer-list">
                {[...joined, ...beaconing].map((p) => (
                  <li key={p.node_id} className="peer-row">
                    <span className={`peer-dot${peerFor(p.node_id) ? ' joined' : ''}`} aria-hidden="true" />
                    <span className="peer-name">{p.name}</span>
                    <span className="peer-ip">{p.ip}:{p.agent_port}</span>
                    <Pill tone={linkTone(p.link?.kind)}>{p.link?.kind ?? 'link?'}</Pill>
                    <span className="nc-metric">{p.link ? `${fmtNum(p.link.rtt_ms, 2)}ms · ${fmtNum(p.link.mbps / 1000, 1)}Gbps` : '—'}</span>
                    <span className={`badge ${p.link?.rdma ? 'badge-rdma' : 'badge-tcp'}`}>{p.link?.rdma ? 'RDMA' : 'TCP'}</span>
                    <span className="peer-age">seen {fmtAgo(p.seen_ms_ago)} ago</span>
                  </li>
                ))}
              </ul>
            )}
            <div className="join-row">
              <button className="btn btn-primary" onClick={() => void genJoinCode()} disabled={busy}>
                Generate join code
              </button>
              <span className="dim">POST /api/admin/join-code · 6-digit code, 10 min TTL</span>
            </div>
            {joinCode ? (
              <div className="join-code-box" role="status">
                <span className="join-code-label">JOIN CODE</span>
                <span className="join-code-value">{joinCode.code}</span>
                <span className="join-code-ttl">expires in {Math.max(0, Math.ceil((joinCode.at + joinCode.ttl_s * 1000 - now) / 1000))}s · give this to the peer</span>
                <button className="banner-x" aria-label="dismiss join code" onClick={() => setJoinCode(null)}>
                  ✕
                </button>
              </div>
            ) : null}
          </div>
        </>
      )}
    </Panel>
  );
}
