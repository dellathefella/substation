import { useMemo, useRef, useState } from 'react';
import { fmtNum } from '../format.js';
import { useStore } from '../store.js';
import type { Tier } from '../types.js';
import { Panel, TIER_COLORS } from './ui.js';

type TierSel = Tier | 'all';
const SELS: readonly TierSel[] = ['all', 'fast', 'balanced', 'smart'] as const;
const SERIES_COLOR: Record<TierSel, string> = {
  all: '#3b82f6',
  fast: TIER_COLORS['fast'] ?? '#2dd4bf',
  balanced: TIER_COLORS['balanced'] ?? '#f5a524',
  smart: TIER_COLORS['smart'] ?? '#a78bfa',
};

interface Pt {
  t: number;
  v: number;
}

function fmtTime(unixSec: number): string {
  const d = new Date(unixSec * 1000);
  const p = (n: number): string => String(n).padStart(2, '0');
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

function Sparkline({ pts, color }: { pts: Pt[]; color: string }): React.JSX.Element | null {
  const plotRef = useRef<HTMLDivElement | null>(null);
  const [hover, setHover] = useState<number | null>(null);

  const n = pts.length;
  const max = useMemo(() => Math.max(1, ...pts.map((p) => p.v)) * 1.12, [pts]);
  const W = 600;
  const H = 150;

  const paths = useMemo(() => {
    if (n < 2) return null;
    const x = (i: number): number => (i / (n - 1)) * W;
    const y = (v: number): number => (1 - v / max) * H;
    const line = pts.map((p, i) => `${i === 0 ? 'M' : 'L'}${x(i).toFixed(1)} ${y(p.v).toFixed(1)}`).join(' ');
    return { line, area: `${line} L ${W} ${H} L 0 ${H} Z` };
  }, [pts, n, max]);

  if (n < 2) return null;

  const onMove = (e: React.MouseEvent<HTMLDivElement>): void => {
    const el = plotRef.current;
    if (!el) return;
    const r = el.getBoundingClientRect();
    const ratio = Math.min(1, Math.max(0, (e.clientX - r.left) / r.width));
    setHover(Math.round(ratio * (n - 1)));
  };

  const gid = `spark-grad-${color.slice(1)}`;
  const hoverPt = hover !== null && hover >= 0 && hover < n ? pts[hover] : null;

  return (
    <div className="spark-wrap">
      <div className="spark-y">
        <span>{max.toFixed(0)}</span>
        <span>{(max / 2).toFixed(0)}</span>
        <span>0</span>
      </div>
      <div
        className="spark-plot"
        ref={plotRef}
        onMouseMove={onMove}
        onMouseLeave={() => setHover(null)}
      >
        <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" aria-hidden="true">
          {[0.25, 0.5, 0.75].map((f) => (
            <line
              key={f}
              x1={0}
              x2={W}
              y1={f * H}
              y2={f * H}
              vectorEffect="non-scaling-stroke"
              strokeWidth={1}
              stroke="rgba(61,77,105,0.14)"
            />
          ))}
          <defs>
            <linearGradient id={gid} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor={color} stopOpacity={0.34} />
              <stop offset="100%" stopColor={color} stopOpacity={0.02} />
            </linearGradient>
          </defs>
          {paths ? <path d={paths.area} fill={`url(#${gid})`} /> : null}
          {paths ? (
            <path
              d={paths.line}
              fill="none"
              stroke={color}
              strokeWidth={1.6}
              vectorEffect="non-scaling-stroke"
              strokeLinejoin="round"
            />
          ) : null}
          {hoverPt ? (
            <circle
              cx={(hover! / (n - 1)) * W}
              cy={(1 - hoverPt.v / max) * H}
              r={0.9}
              fill={color}
              vectorEffect="non-scaling-stroke"
            />
          ) : null}
        </svg>
        {hoverPt ? (
          <div
            className="spark-tip"
            style={{ left: `${(hover! / (n - 1)) * 100}%` }}
          >
            {fmtNum(hoverPt.v, 1)} tok/s
            <span className="spark-tip-t">{fmtTime(hoverPt.t)}</span>
          </div>
        ) : null}
      </div>
    </div>
  );
}

export function ThroughputPanel(): React.JSX.Element {
  const live = useStore((s) => s.live);
  const [sel, setSel] = useState<TierSel>('all');

  const pts = useMemo<Pt[]>(
    () => live.slice(-240).map((p) => ({ t: p.t, v: sel === 'all' ? p.all : p[sel] })),
    [live, sel],
  );

  const latest = live.length > 0 ? live[live.length - 1] : undefined;
  const latestVal = latest ? (sel === 'all' ? latest.all : latest[sel]) : null;
  const first = pts.length > 0 ? pts[0] : undefined;

  return (
    <Panel
      title="Throughput"
      className="panel-throughput"
      right={
        <div className="seg" role="group" aria-label="tier filter">
          {SELS.map((t) => (
            <button
              key={t}
              className={`seg-btn${sel === t ? ' on' : ''}`}
              onClick={() => setSel(t)}
              style={sel === t && t !== 'all' ? { color: SERIES_COLOR[t] } : undefined}
            >
              {t}
            </button>
          ))}
          <span className="seg-val" style={{ color: SERIES_COLOR[sel] }}>
            {fmtNum(latestVal, 1)} tok/s
          </span>
        </div>
      }
    >
      <Sparkline pts={pts} color={SERIES_COLOR[sel]} />
      {pts.length <= 1 ? (
        <div className="chart-empty">{live.length === 0 ? 'waiting for stream.tick…' : 'warming up…'}</div>
      ) : (
        <div className="spark-x">
          <span>{first ? fmtTime(first.t) : ''}</span>
          <span>now</span>
        </div>
      )}
    </Panel>
  );
}
