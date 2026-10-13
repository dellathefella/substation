import { useCallback, useEffect, useState } from 'react';
import { api, apiBase, authHeaders } from '../api.js';
import type { LlamaInfo } from '../api.js';
import { Panel } from './ui.js';

function fmtUp(s: number): string {
  if (s < 90) return `${s}s`;
  if (s < 5400) return `${Math.round(s / 60)}m`;
  return `${(s / 3600).toFixed(1)}h`;
}

export function InfoPanel(): React.JSX.Element {
  const [info, setInfo] = useState<LlamaInfo | null>(null);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const [updState, setUpdState] = useState<{ state?: string; detail?: string } | null>(null);

  const load = useCallback(async (): Promise<void> => {
    const i = await api.llamaInfo();
    if (i) setInfo(i);
    try {
      const r = await fetch(`${apiBase()}/api/events`, { headers: authHeaders() });
      const ev = (await r.json()) as { type: string; data?: { state?: string; detail?: string } }[];
      const last = [...ev].reverse().find((e) => e.type === 'llama.update');
      if (last?.data) setUpdState(last.data);
    } catch {
      /* offline */
    }
  }, []);

  useEffect(() => {
    void load();
    const t = setInterval(() => void load(), 10_000);
    return () => clearInterval(t);
  }, [load]);

  const update = async (): Promise<void> => {
    setBusy(true);
    setNote('updating…');
    await api.llamaUpdate();
    setTimeout(() => setBusy(false), 1500);
  };


  return (
    <main className="info-view">
      <Panel title="llama.cpp" right={
        <span className="row" style={{ gap: 8 }}>
          {updState?.state ? <span className="dim">update: {updState.state}{updState.detail ? ` (${updState.detail})` : ''}</span> : null}
          <button className="btn ghost" onClick={() => void load()}>⟳</button>
          <button className="btn" disabled={busy || !info?.git || updState?.state === 'building'} onClick={() => void update()}>
            {updState?.state === 'building' ? 'building…' : '⬆ Update llama.cpp'}
          </button>
        </span>
      }>
        {info == null ? (
          <div className="dim">loading…</div>
        ) : (
          <div className="info-grid">
            <div><span className="dim">binary</span><div className="mono ellip">{info.binary}</div></div>
            <div><span className="dim">rpc binary</span><div className="mono ellip">{info.rpc_binary}</div></div>
            <div><span className="dim">source</span><div className="mono ellip">{info.src}{info.git ? ` @ ${info.head}` : ' (not a git checkout)'}</div></div>
            <div>
              <span className="dim">version</span>
              <div className="mono">
                {info.version.version ? `v${info.version.version} (${info.version.commit})` : info.version.error ?? '?'}
                {info.rpc_up ? ' · rpc up' : ''}
              </div>
            </div>
          </div>
        )}
        {note ? <div className="dim">{note}</div> : null}
      </Panel>

      <Panel title={`Engines (${info?.engines.length ?? 0})`}>
        {info != null && info.engines.length === 0 ? (
          <div className="dim">no local engines running — route a request to auto* or load a model</div>
        ) : null}
        {info != null && info.engines.length > 0 ? (
          <table className="tbl">
            <thead>
              <tr>
                <th>model</th><th>node</th><th>port</th><th>pid</th>
                <th className="num">size</th><th className="num">prompt cache</th>
                <th className="num">tok/s</th><th className="num">uptime</th><th>split</th>
              </tr>
            </thead>
            <tbody>
              {info.engines.map((e) => (
                <tr key={`${e.model}@${e.node}`}>
                  <td className="mono">{e.model}</td>
                  <td>{e.node}</td>
                  <td className="num mono">{e.port}</td>
                  <td className="num mono">{e.pid > 0 ? e.pid : '—'}</td>
                  <td className="num">{e.size_gb.toFixed(1)} GB</td>
                  <td className="num mono">{e.cache_tokens.toLocaleString()} tok</td>
                  <td className="num">{e.tok_s != null ? e.tok_s.toFixed(1) : '—'}</td>
                  <td className="num">{fmtUp(e.uptime_s)}</td>
                  <td>{e.split ? `rpc → ${e.rpc_peers.join(', ')}` : '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : null}
        <div className="dim" style={{ marginTop: 8 }}>
          prompt cache = dynamic KV budget from current memory headroom (re-balances while the engine is idle)
        </div>
      </Panel>
    </main>
  );
}
