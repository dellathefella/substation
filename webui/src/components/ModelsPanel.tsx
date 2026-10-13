import { useMemo, useState } from 'react';
import { api } from '../api.js';
import { fmtInt, fmtNum } from '../format.js';
import { useStore } from '../store.js';
import { Empty, Panel } from './ui.js';

const STATE_COLOR: Record<string, string> = {
  loaded: '#2dd4bf',
  loading: '#f5a524',
  unloaded: '#64748b',
};

function ModelCardView(props: { name: string }): React.JSX.Element {
  const name = props.name;
  const models = useStore((s) => s.models);
  const feed = useStore((s) => s.feed);
  const pushToast = useStore((s) => s.pushToast);
  const [busy, setBusy] = useState(false);
  const card = models.find((m) => m.name === name);
  const live = useMemo(() => {
    let tok = 0;
    let inflight = 0;
    let streaming = false;
    for (const r of feed) {
      if (r.model !== name) continue;
      if (r.phase === 'streaming') {
        inflight += 1;
        streaming = true;
        tok += r.tokPerS ?? 0;
      } else if (r.phase === 'received' || r.phase === 'triaged' || r.phase === 'routed' || r.phase === 'waiting') {
        inflight += 1;
      }
    }
    return { tok_s: streaming ? tok : null, inflight };
  }, [feed, name]);
  if (!card) return <li />;
  const stateColor = STATE_COLOR[card.state] ?? '#64748b';

  const toggle = async (): Promise<void> => {
    setBusy(true);
    const res = card.state === 'loaded' ? await api.unloadModel(name) : await api.loadModel(name);
    setBusy(false);
    if (!res.ok) pushToast('error', `${card.state === 'loaded' ? 'Unload' : 'Load'} ${name} failed`, String(res.status || 'daemon unreachable'));
  };

  const actionable = card.state !== 'loading' && !busy;
  return (
    <li className={`model-card st-${card.state}`}>
      <div className="mc-head">
        <span className="mc-dot" style={{ background: stateColor }} aria-hidden="true" />
        <span className="mc-name" title={name}>
          {name}
        </span>
        <span className="mc-state">{card.state}</span>
      </div>
      <div className="mc-grid">
        <div className="mc-cell">
          <span className="mc-k">place</span>
          <span className="mc-v">
            {card.node ?? '—'}
            {card.split ? <span className="badge badge-split mc-badge">SPLIT</span> : null}
          </span>
        </div>
        <div className="mc-cell">
          <span className="mc-k">size</span>
          <span className="mc-v">{card.size_gb ? `${card.size_gb.toFixed(1)}GB` : '—'}</span>
        </div>
        <div className="mc-cell">
          <span className="mc-k">ctx</span>
          <span className="mc-v">{card.ctx ? fmtInt(card.ctx) : '—'}</span>
        </div>
        <div className="mc-cell">
          <span className="mc-k">tok/s</span>
          <span className={`mc-v mc-tok${live.tok_s !== null ? ' hot' : ''}`}>{live.tok_s === null ? 'idle' : fmtNum(live.tok_s, 1)}</span>
        </div>
        <div className="mc-cell">
          <span className="mc-k">in-flight</span>
          <span className="mc-v">{live.inflight}</span>
        </div>
        {card.rpc_peers && card.rpc_peers.length > 0 ? (
          <div className="mc-cell">
            <span className="mc-k">rpc</span>
            <span className="mc-v mc-peers" title={card.rpc_peers.join(', ')}>
              {card.rpc_peers.length} peer{card.rpc_peers.length > 1 ? 's' : ''}
            </span>
          </div>
        ) : null}
      </div>
      <button
        className={`btn mc-btn ${card.state === 'loaded' ? 'btn-danger' : 'btn-primary'}`}
        onClick={() => void toggle()}
        disabled={!actionable}
      >
        {busy ? '…' : card.state === 'loading' ? 'loading…' : card.state === 'loaded' ? 'Unload' : 'Load'}
      </button>
    </li>
  );
}

export function ModelsPanel(): React.JSX.Element {
  const models = useStore((s) => s.models);
  return (
    <Panel title="Models" className="panel-models" right={<span className="dim">{models.filter((m) => m.state === 'loaded').length} loaded / {models.length}</span>}>
      {models.length === 0 ? (
        <Empty text="model catalog unavailable (daemon offline?)" />
      ) : (
        <ul className="model-grid">
          {models.map((m) => (
            <ModelCardView key={m.name} name={m.name} />
          ))}
        </ul>
      )}
    </Panel>
  );
}
