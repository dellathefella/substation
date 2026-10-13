import { useMemo } from 'react';
import { fmtMs, percentile } from '../format.js';
import { useStore } from '../store.js';
import { Panel, Sparkline } from './ui.js';

function LatCard(props: { title: string; samples: readonly number[]; color: string }): React.JSX.Element {
  const stats = useMemo(() => {
    const sorted = [...props.samples].sort((a, b) => a - b);
    return { p50: percentile(sorted, 50), p95: percentile(sorted, 95), p99: percentile(sorted, 99), n: sorted.length };
  }, [props.samples]);
  return (
    <div className="lat-card">
      <div className="lat-head">
        <span className="lat-title">{props.title}</span>
        <span className="lat-n">n={stats.n}</span>
      </div>
      <div className="lat-rows">
        <div className="lat-row">
          <span className="lat-k">p50</span>
          <span className="lat-v">{fmtMs(stats.p50)}</span>
        </div>
        <div className="lat-row">
          <span className="lat-k">p95</span>
          <span className="lat-v">{fmtMs(stats.p95)}</span>
        </div>
        <div className="lat-row">
          <span className="lat-k">p99</span>
          <span className="lat-v">{fmtMs(stats.p99)}</span>
        </div>
      </div>
      <Sparkline values={props.samples} color={props.color} width={170} height={34} />
    </div>
  );
}

export function LatencyPanel(): React.JSX.Element {
  const sparkTtft = useStore((s) => s.sparkTtft);
  const sparkTotal = useStore((s) => s.sparkTotal);
  return (
    <Panel title="Latency" className="panel-latency">
      <div className="lat-grid">
        <LatCard title="TTFT (time to first token)" samples={sparkTtft} color="#22d3ee" />
        <LatCard title="Total request time" samples={sparkTotal} color="#818cf8" />
      </div>
    </Panel>
  );
}
