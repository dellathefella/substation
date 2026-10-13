import { useMemo } from 'react';
import { useStore } from '../store.js';
import { Panel, TIER_COLORS } from './ui.js';

const TIER_FALLBACK: Record<string, string> = { fast: '#2dd4bf', balanced: '#f5a524', smart: '#a78bfa' };
const tierColor = (t: string): string => TIER_COLORS[t as keyof typeof TIER_COLORS] ?? TIER_FALLBACK[t] ?? '#7c8aa5';

interface Edge {
  a: string;
  b: string;
  n: number;
  hot: number;
  tier: string;
  cache?: boolean;
}

export function GraphPanel(): React.JSX.Element {
  const feed = useStore((s) => s.feed);

  const graph = useMemo(() => {
    const now = Date.now();
    const rows = feed.filter((r) => now - r.ts < 30 * 60 * 1000);
    const vCount: Record<string, number> = {};
    const tCount: Record<string, number> = {};
    const mCount: Record<string, number> = {};
    const edges: Edge[] = [];
    const add = (a: string, b: string, tier: string, cache = false): void => {
      const e = edges.find((x) => x.a === a && x.b === b && x.cache === cache);
      if (e) e.n += 1;
      else edges.push({ a, b, n: 1, hot: 0, tier, cache });
    };
    for (const r of rows) {
      const hot = now - r.ts < 8000 ? 1 : 0;
      if (r.phase === 'cache' && r.model) {
        vCount[r.virtual] = (vCount[r.virtual] ?? 0) + 1;
        mCount[r.model] = (mCount[r.model] ?? 0) + 1;
        add(r.virtual, r.model, r.tier ?? 'balanced', true);
        continue;
      }
      if (r.tier) {
        vCount[r.virtual] = (vCount[r.virtual] ?? 0) + 1;
        tCount[r.tier] = (tCount[r.tier] ?? 0) + 1;
        add(r.virtual, `tier:${r.tier}`, r.tier);
      }
      if (r.tier && r.model) {
        mCount[r.model] = (mCount[r.model] ?? 0) + 1;
        add(`tier:${r.tier}`, r.model, r.tier);
      }
      if (r.tier && r.model) {
        const e = edges.find((x) => x.a === `tier:${r.tier}` && x.b === r.model);
        if (e) e.hot += hot;
      }
    }
    const vNames = Object.keys(vCount).sort();
    const tNames = Object.keys(tCount).sort();
    const mNames = Object.keys(mCount).sort();
    const maxEdge = Math.max(1, ...edges.map((e) => e.n));
    return { vNames, tNames, mNames, edges, vCount, tCount, mCount, maxEdge };
  }, [feed]);

  const yAt = (i: number, n: number): number => (n <= 1 ? 50 : 8 + (i / (n - 1)) * 84);
  const pos = (col: 'v' | 't' | 'm', name: string): number | null => {
    if (col === 'v') { const i = graph.vNames.indexOf(name); return i < 0 ? null : yAt(i, graph.vNames.length); }
    if (col === 't') { const t = name.replace('tier:', ''); const i = graph.tNames.indexOf(t); return i < 0 ? null : yAt(i, graph.tNames.length); }
    const i = graph.mNames.indexOf(name); return i < 0 ? null : yAt(i, graph.mNames.length);
  };
  const xOf = (c: 'v' | 't' | 'm'): number => (c === 'v' ? 60 : c === 't' ? 300 : 540);

  const empty = graph.vNames.length === 0;

  return (
    <main className="graph-view">
      <Panel
        title="Routing graph"
        right={<span className="dim">last 30 min · width = requests · glow = live</span>}
      >
        {empty ? (
          <div className="dim">no routed requests in the window yet — send a chat to <code>auto*</code> and watch requests flow client → tier → model.</div>
        ) : (
          <div className="graph-wrap">
            <svg viewBox="0 0 600 420" preserveAspectRatio="none" className="graph-svg">
              {graph.edges.map((e, i) => {
                const ax = xOf(e.a.startsWith('tier:') ? 't' : 'v');
                const bx = xOf(e.b.startsWith('tier:') ? 't' : e.a.startsWith('tier:') ? 'm' : 'm');
                const ay = pos(e.a.startsWith('tier:') ? 't' : 'v', e.a);
                const by = pos(e.b.startsWith('tier:') ? 't' : 'm', e.b);
                if (ay == null || by == null) return null;
                const w = 1 + 5 * Math.sqrt(e.n / graph.maxEdge);
                const col = e.cache ? '#64748b' : tierColor(e.tier);
                const mid = (ax + bx) / 2;
                const d = `M ${ax} ${ay * 4.2} C ${mid} ${ay * 4.2}, ${mid} ${by * 4.2}, ${bx} ${by * 4.2}`;
                return (
                  <g key={i}>
                    <path d={d} fill="none" stroke={col} strokeOpacity={0.18 + 0.5 * (e.n / graph.maxEdge)} strokeWidth={w} vectorEffect="non-scaling-stroke" />
                    {e.hot > 0 ? (
                      <path className={`graph-flow${e.cache ? ' cache' : ''}`} d={d} fill="none" stroke={col} strokeWidth={Math.max(1.4, w * 0.5)} vectorEffect="non-scaling-stroke" strokeDasharray="6 10" />
                    ) : null}
                  </g>
                );
              })}
            </svg>
            <div className="graph-col graph-col-v">
              {graph.vNames.map((v) => (
                <div key={v} className="gnode gnode-v" style={{ top: `${yAt(graph.vNames.indexOf(v), graph.vNames.length)}%` }}>
                  <span className="mono">{v}</span><em>{graph.vCount[v]}</em>
                </div>
              ))}
            </div>
            <div className="graph-col graph-col-t">
              {graph.tNames.map((t) => (
                <div key={t} className="gnode gnode-t" style={{ top: `${yAt(graph.tNames.indexOf(t), graph.tNames.length)}%`, borderColor: tierColor(t) }}>
                  <span style={{ color: tierColor(t) }}>{t}</span><em>{graph.tCount[t]}</em>
                </div>
              ))}
            </div>
            <div className="graph-col graph-col-m">
              {graph.mNames.map((m) => (
                <div key={m} className="gnode gnode-m" style={{ top: `${yAt(graph.mNames.indexOf(m), graph.mNames.length)}%` }}>
                  <span className="mono">{m}</span><em>{graph.mCount[m]}</em>
                </div>
              ))}
            </div>
            <span className="graph-axis graph-axis-v">clients</span>
            <span className="graph-axis graph-axis-t">tiers</span>
            <span className="graph-axis graph-axis-m">models</span>
          </div>
        )}
        <div className="dim" style={{ marginTop: 6 }}>
          dashed grey paths = cache hits (skipped triage + engine).
        </div>
      </Panel>
    </main>
  );
}
