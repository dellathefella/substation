import { useCallback, useEffect, useState } from 'react';
import { apiBase, authHeaders } from '../api.js';

interface Iface {
  name: string;
  ip: string;
  netmask: string;
  up: boolean;
  running: boolean;
  kind: string;
}
interface Peer {
  id?: string;
  name?: string;
  ip?: string;
  port?: number;
  role?: string;
}
interface Node {
  id: string;
  name?: string;
  ip: string;
  healthy?: boolean;
  link?: { kind?: string; rtt_ms?: number; mbps?: number; warnings?: string[] };
  ram?: { used_gb?: number; total_gb?: number };
}
interface Wizard {
  hostname: string;
  cluster_enabled: boolean;
  controller_id: string;
  base: string;
  agent_port: number;
  rpc_port: number;
  interfaces: Iface[];
  thunderbolt_active: boolean;
  thunderbolt_down: boolean;
  plumb: { head: string; peer: string };
  discovered: Peer[];
  nodes: Node[];
}

const KIND_ICON: Record<string, string> = {
  'thunderbolt-bridge': '⚡',
  thunderbolt: '⚡',
  wifi: '📶',
  ethernet: '🔌',
  loopback: '↺',
  vpn: '🛡',
  other: '▫',
};

function code(key: string, val: string, copied: string | null, onCopy: (k: string, v: string) => void): React.JSX.Element {
  return (
    <div className="wiz-code-row">
      <code className="wiz-code">{val}</code>
      <button className="btn btn-sm" onClick={() => onCopy(key, val)}>
        {copied === key ? '✓' : 'Copy'}
      </button>
    </div>
  );
}

export function ClusterWizard(): React.JSX.Element {
  const [step, setStep] = useState(0);
  const [wiz, setWiz] = useState<Wizard | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [copied, setCopied] = useState<string | null>(null);
  const [controller, setController] = useState('');
  const [codeVal, setCodeVal] = useState('');
  const [keyVal, setKeyVal] = useState('');
  const [joinMsg, setJoinMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async (): Promise<void> => {
    try {
      const res = await fetch(`${apiBase()}/api/cluster/wizard`, { headers: authHeaders() });
      if (!res.ok) {
        setErr(`daemon returned ${res.status}`);
        return;
      }
      setWiz((await res.json()) as Wizard);
      setErr(null);
    } catch (e) {
      setErr(String(e));
    }
  }, []);

  useEffect(() => {
    void load();
    const t = setInterval(() => void load(), 4000);
    return () => clearInterval(t);
  }, [load]);

  const copy = (k: string, v: string): void => {
    void navigator.clipboard.writeText(v).then(() => {
      setCopied(k);
      setTimeout(() => setCopied((c) => (c === k ? null : c)), 1200);
    });
  };

  const genCode = async (): Promise<void> => {
    setBusy(true);
    try {
      const res = await fetch(`${apiBase()}/api/admin/join-code`, { method: 'POST', headers: authHeaders(), body: '{}' });
      const j = (await res.json()) as { code?: string; expires_in?: number };
      if (j.code) setCodeVal(j.code);
      else setJoinMsg(`join-code failed: ${res.status}`);
    } catch (e) {
      setJoinMsg(String(e));
    }
    setBusy(false);
  };

  const joinAsPeer = async (): Promise<void> => {
    if (!controller || !codeVal || !wiz) return;
    setBusy(true);
    setJoinMsg(null);
    const myIp =
      wiz.interfaces.find((i) => (i.kind === 'thunderbolt-bridge' || i.kind === 'thunderbolt') && i.ip && i.running)?.ip ??
      wiz.interfaces.find((i) => (i.kind === 'wifi' || i.kind === 'ethernet') && i.ip && i.running)?.ip ??
      '';
    const nodeId = (wiz.hostname.split('.')[0] ?? 'peer').toLowerCase();
    const url = `${controller.startsWith('http') ? controller : `http://${controller}`}${controller.startsWith('http') ? '' : ':8800'}/api/cluster/join-relay`;
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: authHeaders({ 'content-type': 'application/json' }),
        ...(keyVal ? { headers: authHeaders({ 'content-type': 'application/json', authorization: `Bearer ${keyVal}` }) } : {}),
        body: JSON.stringify({ code: codeVal, node_id: nodeId, name: nodeId, ip: myIp, agent_port: wiz.agent_port, rpc_port: wiz.rpc_port }),
      });
      const j = (await res.json()) as { joined?: boolean; error?: { message?: string } };
      setJoinMsg(j.joined ? `✓ joined via controller — waiting for health/beat…` : `join failed: ${j.error?.message ?? res.status}`);
      if (j.joined) void load();
    } catch (e) {
      setJoinMsg(String(e));
    }
    setBusy(false);
  };

  if (err) {
    return (
      <div className="wiz-wrap">
        <div className="connect-err">
          Cluster wizard: daemon unreachable ({err})
          <button className="btn btn-sm" onClick={() => void load()}>Retry</button>
        </div>
      </div>
    );
  }
  if (!wiz) return <div className="wiz-wrap"><div className="chat-empty">Scanning this Mac…</div></div>;

  const tbs = wiz.interfaces.filter((i) => i.kind === 'thunderbolt-bridge' || i.kind === 'thunderbolt');

  return (
    <div className="wiz-wrap">
      <div className="wiz-steps">
        {['This Mac', 'Thunderbolt', 'Discover', 'Join', 'Verify'].map((s, i) => (
          <button key={s} className={`wiz-step${i === step ? ' active' : ''}${i < step ? ' done' : ''}`} onClick={() => setStep(i)}>
            <span className="wiz-step-n">{i + 1}</span>
            {s}
          </button>
        ))}
      </div>

      {step === 0 ? (
        <section className="wiz-card">
          <h3>This machine · {wiz.hostname}</h3>
          <p className="wiz-note">
            Controller <code>{wiz.controller_id}</code> · clustering{' '}
            <b>{wiz.cluster_enabled ? 'enabled' : 'disabled'}</b> · web <code>{wiz.base}</code> · agent :{wiz.agent_port} · rpc :{wiz.rpc_port}
          </p>
          <table className="wiz-ifaces">
            <thead>
              <tr><th>interface</th><th>kind</th><th>IPv4</th><th>state</th></tr>
            </thead>
            <tbody>
              {wiz.interfaces.map((i) => (
                <tr key={i.name} className={i.kind.startsWith('thunderbolt') ? 'wiz-tb' : ''}>
                  <td>{KIND_ICON[i.kind] ?? '▫'} {i.name}</td>
                  <td>{i.kind}</td>
                  <td>{i.ip || '—'}</td>
                  <td>{i.running ? 'up' : i.up ? 'no cable' : 'down'}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="wiz-note">
            {wiz.thunderbolt_active
              ? '⚡ Thunderbolt link is active — use it for the cluster interconnect.'
              : wiz.thunderbolt_down
                ? '⚡ Thunderbolt bridge exists but the cable is not detected. Check the cable, then Next.'
                : 'No Thunderbolt bridge found. Cable the two Macs directly (TB3/4/5) and enable the bridge in System Settings → Network → ⋯ → Manage Virtual Interfaces → New Thunderbolt Bridge.'}
          </p>
          <button className="btn btn-primary" onClick={() => setStep(1)}>Next: wiring Thunderbolt →</button>
        </section>
      ) : null}

      {step === 1 ? (
        <section className="wiz-card">
          <h3>⚡ Thunderbolt interconnect</h3>
          <p className="wiz-note">
            Direct cable between the Macs, static IPs on <b>Thunderbolt Bridge</b> (admin needed on both ends). The controller re-probes
            links every ~60 s once joined.
          </p>
          {tbs.map((i) => (
            <p key={i.name} className="wiz-note">
              {i.name}: <code>{i.ip || 'no IPv4'}</code> · {i.running ? 'link up' : 'no cable / port asleep'}
            </p>
          ))}
          {code('head', wiz.plumb.head, copied, copy)}
          {code('peer', wiz.plumb.peer, copied, copy)}
          <p className="wiz-note">
            GGML RPC runs over TCP; RDMA is not used by llama.cpp — expected ~2–3 GB/s one-way on TB4, plenty for tensor-split
            streaming with worker-side weight caching disabled.
          </p>
          <div className="wiz-nav">
            <button className="btn" onClick={() => setStep(0)}>← Back</button>
            <button className="btn btn-primary" onClick={() => setStep(2)}>Next: discover →</button>
          </div>
        </section>
      ) : null}

      {step === 2 ? (
        <section className="wiz-card">
          <h3>Discovered peers</h3>
          {wiz.discovered.length === 0 ? (
            <p className="wiz-note">
              No peers beaconed in yet (224.0.1.87:8810 UDP multicast — must share a L2 segment or mDNS-relayed VLAN; over the
              Thunderbolt cable they show up within seconds).
            </p>
          ) : (
            <ul className="wiz-list">
              {wiz.discovered.map((p, i) => (
                <li key={p.id ?? i}>
                  <b>{p.name ?? p.id}</b> · <code>{p.ip}</code>{p.port ? `:${p.port}` : ''} {p.role ? `· ${p.role}` : ''}
                  <button className="btn btn-sm" onClick={() => setController(p.ip ?? '')}>use as controller</button>
                </li>
              ))}
            </ul>
          )}
          <div className="wiz-nav">
            <button className="btn" onClick={() => setStep(1)}>← Back</button>
            <button className="btn btn-primary" onClick={() => setStep(3)}>Next: join →</button>
          </div>
        </section>
      ) : null}

      {step === 3 ? (
        <section className="wiz-card">
          <h3>Join</h3>
          <p className="wiz-note">Two ways — pick the one this machine should do:</p>
          <div className="wiz-two">
            <div className="wiz-col">
              <h4>A · This machine is the controller</h4>
              <button className="btn btn-primary" onClick={() => void genCode()} disabled={busy}>
                {busy ? '…' : 'Generate join code'}
              </button>
              {codeVal ? (
                <>
                  <div className="wiz-code-big">{codeVal}</div>
                  <p className="wiz-note">On the peer Mac, open its Substation wizard → step 4B and enter this code + this controller&apos;s address ({wiz.base.replace(/:8800$/, '')}), or run:</p>
                  {code('cli', `substationd join --controller ${wiz.base.replace('http://', '')} --code ${codeVal}`, copied, copy)}
                </>
              ) : null}
            </div>
            <div className="wiz-col">
              <h4>B · Join this machine to a controller</h4>
              <label className="field">
                <span className="field-label">Controller host</span>
                <input type="text" placeholder="10.99.1.1 or studio0.local" value={controller} onChange={(e) => setController(e.target.value)} />
              </label>
              <label className="field">
                <span className="field-label">Join code</span>
                <input type="text" placeholder="from the controller wizard" value={codeVal} onChange={(e) => setCodeVal(e.target.value)} />
              </label>
              <label className="field">
                <span className="field-label">Controller API key (if set)</span>
                <input type="text" value={keyVal} onChange={(e) => setKeyVal(e.target.value)} />
              </label>
              <button className="btn btn-primary" onClick={() => void joinAsPeer()} disabled={busy || !controller || !codeVal}>
                {busy ? 'Joining…' : 'Join cluster'}
              </button>
            </div>
          </div>
          {joinMsg ? <p className={`wiz-msg${joinMsg.startsWith('✓') ? ' ok' : ''}`}>{joinMsg}</p> : null}
          <div className="wiz-nav">
            <button className="btn" onClick={() => setStep(2)}>← Back</button>
            <button className="btn btn-primary" onClick={() => setStep(4)}>Next: verify →</button>
          </div>
        </section>
      ) : null}

      {step === 4 ? (
        <section className="wiz-card">
          <h3>Cluster status</h3>
          <p className="wiz-note">
            clustering <b>{wiz.cluster_enabled ? 'enabled' : 'disabled'}</b> · {wiz.nodes.length} node(s) joined · live via WS{' '}
            <code>node.health</code> / <code>node.link</code>
          </p>
          {wiz.nodes.length === 0 ? <p className="wiz-note">No nodes yet — finish step 3 or run the CLI join on a peer.</p> : null}
          <ul className="wiz-list">
            {wiz.nodes.map((n) => (
              <li key={n.id}>
                <b>{n.name ?? n.id}</b> · <code>{n.ip}</code> · {n.healthy ? '✓ healthy' : 'unreachable'}
                {n.link ? (
                  <>
                    {' '}· link <b>{n.link.kind}</b>
                    {n.link.rtt_ms !== undefined && n.link.rtt_ms >= 0 ? ` · RTT ${n.link.rtt_ms.toFixed(1)} ms` : ''}
                    {n.link.mbps !== undefined && n.link.mbps >= 0 ? ` · ${(n.link.mbps / 1000).toFixed(1)} Gb/s` : ''}
                    {(n.link.warnings?.length ?? 0) > 0 ? (
                      <div className="wiz-warn">{n.link.warnings!.join(' · ')}</div>
                    ) : null}
                  </>
                ) : (
                  ' · probing…'
                )}
              </li>
            ))}
          </ul>
          <p className="wiz-note">
            {wiz.thunderbolt_active
              ? '⚡ Thunderbolt link active — split models will stream over it.'
              : '⚠ Traffic will ride Wi-Fi/Ethernet — expect 10–100× worse split latency than Thunderbolt.'}
          </p>
          <div className="wiz-nav">
            <button className="btn" onClick={() => setStep(3)}>← Back</button>
            <button className="btn" onClick={() => void load()}>⟳ Re-check</button>
          </div>
        </section>
      ) : null}
    </div>
  );
}
