import { useEffect, useMemo, useRef, useState } from 'react';
import { AreaSeries, ColorType, createChart } from 'lightweight-charts';
import type { IChartApi, ISeriesApi, UTCTimestamp } from 'lightweight-charts';
import { fmtNum } from '../format.js';
import { useStore } from '../store.js';
import type { Tier } from '../types.js';
import { Empty, Panel, TIER_COLORS } from './ui.js';

type TierSel = Tier | 'all';
const SELS: readonly TierSel[] = ['all', 'fast', 'balanced', 'smart'] as const;
const SERIES_COLOR: Record<TierSel, string> = {
  all: '#3b82f6',
  fast: TIER_COLORS['fast'] ?? '#2dd4bf',
  balanced: TIER_COLORS['balanced'] ?? '#f5a524',
  smart: TIER_COLORS['smart'] ?? '#a78bfa',
};

export function ThroughputPanel(): React.JSX.Element {
  const live = useStore((s) => s.live);
  const [sel, setSel] = useState<TierSel>('all');
  const [chartOk, setChartOk] = useState(true);
  const hostRef = useRef<HTMLDivElement | null>(null);
  const chartRef = useRef<IChartApi | null>(null);
  const seriesRef = useRef<ISeriesApi<'Area'> | null>(null);

  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;
    let chart: IChartApi | null = null;
    try {
      chart = createChart(host, {
        autoSize: true,
        layout: {
          background: { type: ColorType.Solid, color: 'transparent' },
          textColor: '#7c8aa5',
          fontSize: 10,
        },
        grid: {
          vertLines: { color: 'rgba(61,77,105,0.14)' },
          horzLines: { color: 'rgba(61,77,105,0.14)' },
        },
        rightPriceScale: { borderColor: 'rgba(61,77,105,0.35)', scaleMargins: { top: 0.12, bottom: 0.06 } },
        timeScale: { borderColor: 'rgba(61,77,105,0.35)', timeVisible: true, secondsVisible: true, rightOffset: 3 },
        crosshair: { mode: 0 },
        handleScale: { axisPressedMouseMove: { time: true, price: false } },
      });
      const series = chart.addSeries(AreaSeries, {
        lineType: 0,
        lineWidth: 2,
        lineColor: SERIES_COLOR.all,
        topColor: 'rgba(59,130,246,0.34)',
        bottomColor: 'rgba(59,130,246,0.02)',
        priceLineVisible: false,
        lastValueVisible: true,
        crosshairMarkerRadius: 3,
      });
      chartRef.current = chart;
      seriesRef.current = series;
      setChartOk(true);
    } catch {
      setChartOk(false);
    }
    return () => {
      try {
        chart?.remove();
      } catch {
        /* noop */
      }
      chartRef.current = null;
      seriesRef.current = null;
    };
  }, []);

  const points = useMemo(
    () =>
      live.slice(-240).map((p) => ({
        time: p.t as UTCTimestamp,
        value: Number((sel === 'all' ? p.all : p[sel]).toFixed(2)),
      })),
    [live, sel],
  );

  useEffect(() => {
    const series = seriesRef.current;
    const chart = chartRef.current;
    if (!series || !chart) return;
    try {
      const color = SERIES_COLOR[sel];
      series.applyOptions({
        lineColor: color,
        topColor: `${color}52`,
        bottomColor: `${color}06`,
      });
      if (points.length > 1) {
        series.setData(points as Parameters<ISeriesApi<'Area'>['setData']>[0]);
        chart.timeScale().fitContent();
      }
    } catch {
      setChartOk(false);
    }
  }, [points, sel]);

  const latest = live.length > 0 ? live[live.length - 1] : undefined;
  const latestVal = latest ? (sel === 'all' ? latest.all : latest[sel]) : null;

  return (
    <Panel
      title="Throughput"
      className="panel-throughput"
      right={
        <div className="seg" role="group" aria-label="tier filter">
          {SELS.map((t) => (
            <button key={t} className={`seg-btn${sel === t ? ' on' : ''}`} onClick={() => setSel(t)} style={sel === t && t !== 'all' ? { color: SERIES_COLOR[t] } : undefined}>
              {t}
            </button>
          ))}
          <span className="seg-val" style={{ color: SERIES_COLOR[sel] }}>
            {fmtNum(latestVal, 1)} tok/s
          </span>
        </div>
      }
    >
      <div className="chart-host" ref={hostRef} style={{ display: chartOk ? 'block' : 'none' }} />
      {!chartOk ? <Empty text="chart unavailable in this environment" /> : null}
      {points.length <= 1 ? <div className="chart-empty">{live.length === 0 ? 'waiting for stream.tick…' : 'warming up…'}</div> : null}
    </Panel>
  );
}
