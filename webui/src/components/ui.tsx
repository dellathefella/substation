import type { ReactNode } from 'react';

export const TIER_COLORS: Record<string, string> = {
  fast: '#2dd4bf',
  balanced: '#f5a524',
  smart: '#a78bfa',
  unknown: '#64748b',
};

export function Panel(props: { title: string; right?: ReactNode; children: ReactNode; className?: string; sparse?: boolean }): ReactNode {
  return (
    <section className={`panel${props.className ? ` ${props.className}` : ''}`}>
      <header className="panel-head">
        <h2>{props.title}</h2>
        {props.right ? <div className="panel-actions">{props.right}</div> : null}
      </header>
      <div className={`panel-body${props.sparse ? ' sparse' : ''}`}>{props.children}</div>
    </section>
  );
}

export function Pill(props: { tone: 'ok' | 'warn' | 'err' | 'info' | 'muted'; children: ReactNode; title?: string }): ReactNode {
  return (
    <span className={`pill pill-${props.tone}`} title={props.title}>
      <span className="pill-dot" aria-hidden="true" />
      {props.children}
    </span>
  );
}

export function Sparkline(props: { values: readonly number[]; width?: number; height?: number; color?: string }): ReactNode {
  const { values } = props;
  const w = props.width ?? 140;
  const h = props.height ?? 30;
  if (values.length < 2) {
    return <div className="spark-empty" style={{ width: w, height: h }} title="no samples yet" />;
  }
  let min = Infinity;
  let max = -Infinity;
  for (const v of values) {
    if (v < min) min = v;
    if (v > max) max = v;
  }
  if (max - min < 1e-9) {
    max = max + 1;
    min = min - 1;
  }
  const pad = 2;
  const pts: string[] = [];
  for (let i = 0; i < values.length; i += 1) {
    const x = pad + (i / (values.length - 1)) * (w - pad * 2);
    const y = h - pad - ((values[i] ?? 0) - min) / (max - min) * (h - pad * 2);
    pts.push(`${x.toFixed(1)},${y.toFixed(1)}`);
  }
  const color = props.color ?? '#3b82f6';
  const first = pts[0] ?? '0,0';
  const last = pts[pts.length - 1] ?? `${w},${h}`;
  const [fx] = first.split(',');
  const [lx] = last.split(',');
  const fillPath = `M ${first} L ${pts.slice(1).join(' L ')} L ${lx ?? w},${h - pad} L ${fx ?? 0},${h - pad} Z`;
  return (
    <svg className="spark" width={w} height={h} viewBox={`0 0 ${w} ${h}`} aria-hidden="true">
      <path d={fillPath} fill={color} fillOpacity={0.12} stroke="none" />
      <polyline points={pts.join(' ')} fill="none" stroke={color} strokeWidth={1.5} strokeLinejoin="round" strokeLinecap="round" />
    </svg>
  );
}

export function Bar(props: { value: number; max: number; color?: string; track?: string; height?: number; title?: string }): ReactNode {
  const ratio = props.max > 0 ? Math.max(0, Math.min(1, props.value / props.max)) : 0;
  const h = props.height ?? 6;
  const color = props.color ?? (ratio > 0.85 ? '#ef4444' : ratio > 0.65 ? '#f5a524' : '#2dd4bf');
  return (
    <svg className="bar" width="100%" height={h} viewBox="0 0 100 8" preserveAspectRatio="none" role="img" aria-label={props.title ?? `${Math.round(ratio * 100)}%`}>
      <rect x="0" y="1" width="100" height="6" rx="2" fill={props.track ?? '#1b2333'} />
      <rect x="0" y="1" width={Math.max(ratio > 0 ? 1.5 : 0, ratio * 100)} height="6" rx="2" fill={color} />
    </svg>
  );
}

export interface DonutSegment {
  label: string;
  value: number;
  color: string;
}

export function Donut(props: { segments: readonly DonutSegment[]; size?: number; thickness?: number; centerTop?: string; centerSub?: string }): ReactNode {
  const size = props.size ?? 128;
  const thickness = props.thickness ?? 16;
  const r = (size - thickness) / 2 - 2;
  const cx = size / 2;
  const cy = size / 2;
  const c = 2 * Math.PI * r;
  const total = props.segments.reduce((s, seg) => s + seg.value, 0);
  let offset = 0;
  return (
    <svg className="donut" width={size} height={size} viewBox={`0 0 ${size} ${size}`} role="img" aria-label="tier distribution">
      <g transform={`rotate(-90 ${cx} ${cy})`}>
        <circle cx={cx} cy={cy} r={r} fill="none" stroke="#161d2b" strokeWidth={thickness} />
        {total > 0 &&
          props.segments.map((seg) => {
            if (seg.value <= 0) return null;
            const len = (seg.value / total) * c;
            const el = (
              <circle
                key={seg.label}
                cx={cx}
                cy={cy}
                r={r}
                fill="none"
                stroke={seg.color}
                strokeWidth={thickness}
                strokeDasharray={`${len.toFixed(2)} ${(c - len).toFixed(2)}`}
                strokeDashoffset={(-offset).toFixed(2)}
              >
                <title>{`${seg.label}: ${seg.value}`}</title>
              </circle>
            );
            offset += len;
            return el;
          })}
      </g>
      {props.centerTop ? (
        <text x="50%" y="47%" textAnchor="middle" className="donut-num">
          {props.centerTop}
        </text>
      ) : null}
      {props.centerSub ? (
        <text x="50%" y="63%" textAnchor="middle" className="donut-sub">
          {props.centerSub}
        </text>
      ) : null}
    </svg>
  );
}

export function Gauge(props: { ratio: number | null; size?: number; color?: string; label: string }): ReactNode {
  const size = props.size ?? 120;
  const stroke = 10;
  const r = (size - stroke) / 2 - 4;
  const cx = size / 2;
  const cy = size / 2;
  const arc = Math.PI * r;
  const ratio = props.ratio === null || !Number.isFinite(props.ratio) ? 0 : Math.max(0, Math.min(1, props.ratio));
  const color = props.color ?? '#3b82f6';
  return (
    <svg className="gauge" width={size} height={size / 2 + 14} viewBox={`0 0 ${size} ${size / 2 + 14}`} role="img" aria-label={props.label}>
      <path d={`M ${cx - r} ${cy} A ${r} ${r} 0 0 1 ${cx + r} ${cy}`} fill="none" stroke="#161d2b" strokeWidth={stroke} strokeLinecap="round" />
      <path
        d={`M ${cx - r} ${cy} A ${r} ${r} 0 0 1 ${cx + r} ${cy}`}
        fill="none"
        stroke={props.ratio === null ? '#334155' : color}
        strokeWidth={stroke}
        strokeLinecap="round"
        strokeDasharray={`${(ratio * arc).toFixed(2)} ${arc.toFixed(2)}`}
      />
      <text x="50%" y={cy - 4} textAnchor="middle" className="gauge-num">
        {props.label}
      </text>
    </svg>
  );
}

export function Stat(props: { label: string; value: string; unit?: string; sub?: string; big?: boolean; tone?: 'ok' | 'warn' | 'err' | 'info' | 'muted' }): ReactNode {
  return (
    <div className={`stat${props.big ? ' stat-big' : ''}`}>
      <div className="stat-label">{props.label}</div>
      <div className={`stat-value${props.tone ? ` tone-${props.tone}` : ''}`}>
        {props.value}
        {props.unit ? <span className="stat-unit">{props.unit}</span> : null}
      </div>
      {props.sub ? <div className="stat-sub">{props.sub}</div> : null}
    </div>
  );
}

export function Empty(props: { text: string }): ReactNode {
  return <div className="empty">{props.text}</div>;
}
