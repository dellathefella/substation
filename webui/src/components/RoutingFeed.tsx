import { fmtClock, fmtMs, truncate } from '../format.js';
import { useStore } from '../store.js';
import type { FeedRow, Phase } from '../types.js';
import { Empty, Panel, TIER_COLORS } from './ui.js';

const PHASE_LABEL: Record<Phase, string> = {
  received: 'recv',
  triaged: 'triage',
  routed: 'routed',
  waiting: 'wait',
  streaming: 'stream',
  done: 'done',
  cache: 'cache',
};

const PHASE_CLASS: Record<Phase, string> = {
  received: 'ph-received',
  triaged: 'ph-triaged',
  routed: 'ph-routed',
  waiting: 'ph-waiting',
  streaming: 'ph-streaming',
  done: 'ph-done',
  cache: 'ph-cache',
};

function Row(props: { row: FeedRow }): React.JSX.Element {
  const r = props.row;
  const tierColor = r.tier ? (TIER_COLORS[r.tier] ?? '#64748b') : 'var(--tx-dim)';
  const live = r.phase === 'streaming';
  return (
    <li className={`feed-row ${PHASE_CLASS[r.phase]}${live ? ' is-live' : ''}`} data-phase={r.phase}>
      <span className="feed-ts">{fmtClock(r.ts)}</span>
      <span className="feed-id" title={r.id}>
        {r.id8}
      </span>
      <span className="feed-chain">
        <span className="feed-virtual">{r.virtual}</span>
        <span className="feed-arrow">→</span>
        <span className="feed-tier" style={{ color: tierColor }}>
          {r.tier ?? '…'}
        </span>
        <span className="feed-arrow">→</span>
        <span className="feed-model" title={r.model}>
          {r.model ? truncate(r.model, 22) : '…'}
        </span>
        {r.node ? (
          <>
            <span className="feed-arrow">→</span>
            <span className="feed-node">{r.node}</span>
          </>
        ) : null}
      </span>
      <span className="feed-badges">
        {r.split ? (
          <span className="badge badge-split" title={r.rpc_peers.length > 0 ? `rpc peers: ${r.rpc_peers.join(', ')}` : 'layer-split placement'}>
            SPLIT
          </span>
        ) : null}
        {r.rpc_peers.length > 0 ? (
          <span className="badge badge-rpc" title={r.rpc_peers.join(', ')}>
            RPC×{r.rpc_peers.length}
          </span>
        ) : null}
        {r.cached ? <span className="badge badge-cache">CACHE</span> : null}
        {r.waitReason ? (
          <span className="badge badge-wait" title={`engine ${r.waitReason} for ${fmtMs(r.waitMs)}`}>
            {r.waitReason === 'loading' ? 'LOAD' : r.waitReason === 'queued' ? 'QUEUED' : 'HIT'}
          </span>
        ) : null}
      </span>
      <span className="feed-reason" title={r.reason}>
        {r.reason ? truncate(r.reason, 34) : ''}
      </span>
      <span className="feed-ms">
        {live && r.tokPerS ? <span className="feed-live">{r.tokPerS.toFixed(0)}t/s</span> : null}
        {r.ms ? fmtMs(r.ms) : r.ttft ? fmtMs(r.ttft) : ''}
      </span>
      <span className="feed-phase">{PHASE_LABEL[r.phase]}</span>
    </li>
  );
}

export function RoutingFeed(): React.JSX.Element {
  const feed = useStore((s) => s.feed);
  return (
    <Panel
      title="Routing feed"
      className="panel-feed"
      right={<span className="dim">{feed.length}/200 events · newest first</span>}
    >
      {feed.length === 0 ? (
        <Empty text="no requests yet — waiting for WS events…" />
      ) : (
        <ol className="feed" role="log" aria-label="routing decisions feed">
          {feed.map((r) => (
            <Row key={r.id} row={r} />
          ))}
        </ol>
      )}
    </Panel>
  );
}
