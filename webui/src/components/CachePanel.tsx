import { fmtBytes, fmtInt, fmtPct } from '../format.js';
import { useStore } from '../store.js';
import { Bar, Empty, Gauge, Panel } from './ui.js';

function ratioColor(ratio: number): string {
  if (ratio >= 0.75) return '#2dd4bf';
  if (ratio >= 0.45) return '#3b82f6';
  return '#f5a524';
}

export function CachePanel(): React.JSX.Element {
  const cache = useStore((s) => s.cache);
  const hits = useStore((s) => s.cacheHits);
  const doneCached = useStore((s) => s.doneCached);
  const doneUncached = useStore((s) => s.doneUncached);
  const liveHits = hits + doneCached + doneUncached;
  const liveRatio = liveHits > 0 ? (hits + doneCached) / liveHits : null;
  const ratio = liveRatio ?? cache?.hit_ratio ?? null;

  return (
    <Panel
      title="Prompt cache"
      className="panel-cache"
      right={cache ? <span className="dim">llama.cpp prefix reuse + daemon LRU</span> : <span className="dim">offline</span>}
    >
      {!cache && ratio === null ? (
        <Empty text="cache metrics unavailable (daemon offline?)" />
      ) : (
        <div className="cache-grid">
          <div className="cache-gauge">
            <Gauge ratio={ratio} label={fmtPct(ratio, 0)} color={ratio === null ? '#334155' : ratioColor(ratio)} size={132} />
            <div className="cache-caption">hit ratio · live {liveHits > 0 ? `${fmtInt(liveHits)} reqs` : '—'}</div>
          </div>
          <div className="cache-side">
            <div className="kv-row">
              <span className="kv-k">entries</span>
              <span className="kv-v">
                {fmtInt(cache?.entries)} / {fmtInt(cache?.max_entries)}
              </span>
            </div>
            <Bar value={cache?.entries ?? 0} max={cache?.max_entries ?? 1} color="#3b82f6" height={7} title="cache entries vs max" />
            <div className="kv-row">
              <span className="kv-k">bytes</span>
              <span className="kv-v">
                {fmtBytes(cache?.bytes)} / {fmtBytes(cache?.max_bytes)}
              </span>
            </div>
            <Bar value={cache?.bytes ?? 0} max={cache?.max_bytes ?? 1} color="#818cf8" height={7} title="cache bytes vs max" />
            <div className="kv-head cache-slots-head">
              <span>KV slots</span>
              <span className="dim">per engine</span>
            </div>
            {cache && cache.kv_slots && cache.kv_slots.length > 0 ? (
              <ul className="slot-list">
                {cache.kv_slots.map((slot) => (
                  <li key={slot.engine} className="slot-row">
                    <span className="slot-name" title={slot.engine}>
                      {slot.engine}
                    </span>
                    <span className="slot-bar">
                      <Bar value={slot.used} max={slot.total} color={slot.used / Math.max(1, slot.total) > 0.85 ? '#f5a524' : '#2dd4bf'} height={6} title={`${slot.used}/${slot.total} slots`} />
                    </span>
                    <span className="slot-n">
                      {slot.used}/{slot.total}
                    </span>
                  </li>
                ))}
              </ul>
            ) : (
              <div className="dim kv-note">no KV slot telemetry</div>
            )}
          </div>
        </div>
      )}
    </Panel>
  );
}
