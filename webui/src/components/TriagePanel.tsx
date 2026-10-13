import { fmtPct } from '../format.js';
import { useStore } from '../store.js';
import { TIERS } from '../types.js';
import { Bar, Donut, Gauge, Panel, TIER_COLORS } from './ui.js';

export function TriagePanel(): React.JSX.Element {
  const tierCounts = useStore((s) => s.tierCounts);
  const methodModel = useStore((s) => s.methodModel);
  const methodHeuristic = useStore((s) => s.methodHeuristic);
  const confSum = useStore((s) => s.confSum);
  const confN = useStore((s) => s.confN);

  const totalTriages = methodModel + methodHeuristic;
  const avgConf = confN > 0 ? confSum / confN : null;
  const segments = TIERS.map((t) => ({ label: t, value: tierCounts[t], color: TIER_COLORS[t] ?? '#64748b' }));
  const totalTier = segments.reduce((s, x) => s + x.value, 0);
  const modelPct = totalTriages > 0 ? methodModel / totalTriages : 0;

  return (
    <Panel title="Triage" className="panel-triage">
      <div className="triage-grid">
        <div className="triage-donut">
          <Donut
            segments={segments}
            centerTop={totalTier > 0 ? String(totalTier) : '—'}
            centerSub="decisions"
          />
          <ul className="legend">
            {segments.map((seg) => (
              <li key={seg.label}>
                <span className="legend-dot" style={{ background: seg.color }} />
                <span className="legend-label">{seg.label}</span>
                <span className="legend-val">
                  {totalTier > 0 ? fmtPct(seg.value / totalTier, 0) : '—'}
                  <span className="legend-n"> {seg.value}</span>
                </span>
              </li>
            ))}
          </ul>
        </div>
        <div className="triage-side">
          <div className="triage-method">
            <div className="kv-head">
              <span>method split</span>
              <span className="dim">{totalTriages > 0 ? `${fmtPct(modelPct, 0)} model` : '—'}</span>
            </div>
            <Bar value={methodModel} max={Math.max(1, totalTriages)} color="#2dd4bf" height={8} title="model triage share" />
            <Bar value={methodHeuristic} max={Math.max(1, totalTriages)} color="#f5a524" height={8} title="heuristic triage share" />
            <div className="kv-row">
              <span className="kv-k"><span className="legend-dot" style={{ background: '#2dd4bf' }} />model</span>
              <span className="kv-v">{methodModel}</span>
            </div>
            <div className="kv-row">
              <span className="kv-k"><span className="legend-dot" style={{ background: '#f5a524' }} />heuristic</span>
              <span className="kv-v">{methodHeuristic}</span>
            </div>
          </div>
          <div className="triage-conf">
            <Gauge ratio={avgConf} label={avgConf === null ? '—' : avgConf.toFixed(2)} color="#a78bfa" size={118} />
            <div className="conf-caption">avg confidence</div>
          </div>
        </div>
      </div>
    </Panel>
  );
}
