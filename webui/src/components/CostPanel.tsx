import { useEffect, useState } from 'react';
import { api } from '../api.js';
import { Panel, Pill } from './ui.js';

interface Usage {
  prompt_total: number;
  completion_total: number;
  total: number;
  cache_hits: number;
  by_tier: Record<string, { prompt: number; completion: number }>;
  by_model: Record<string, { prompt: number; completion: number }>;
  hourly: { hour: number; prompt: number; completion: number }[];
  cloud_cost_estimate: { provider: string; model: string; usd: number }[];
}

interface MetricsResp {
  token_usage?: Usage;
  by_key?: Record<string, { p50?: number; n?: number } | null>;
}

interface ModelRow { name: string; tier?: string; kind?: string }

interface Provider { id: string; label: string; inp: number; out: number }

const PROVIDERS: Provider[] = [
  { id: 'nano', label: 'GPT-4.1 nano (OpenAI)', inp: 0.1, out: 0.4 },
  { id: 'mini', label: 'GPT-4.1 mini (OpenAI)', inp: 0.4, out: 1.6 },
  { id: 'gpt41', label: 'GPT-4.1 (OpenAI)', inp: 2.0, out: 8.0 },
  { id: 'gpt4o', label: 'GPT-4o (OpenAI)', inp: 2.5, out: 10.0 },
  { id: 'haiku', label: 'Claude Haiku 4.5', inp: 1.0, out: 5.0 },
  { id: 'sonnet', label: 'Claude Sonnet 4.5', inp: 3.0, out: 15.0 },
  { id: 'opus', label: 'Claude Opus 4.1', inp: 15.0, out: 75.0 },
  { id: 'gflash', label: 'Gemini 2.5 Flash', inp: 0.3, out: 2.5 },
  { id: 'gpro', label: 'Gemini 2.5 Pro', inp: 1.25, out: 10.0 },
  { id: 'deepseek', label: 'DeepSeek chat', inp: 0.27, out: 1.1 },
  { id: 'groq70', label: 'Groq Llama-3.3-70B', inp: 0.59, out: 0.79 },
];

interface CostPrefs {
  sel: Record<string, string>;
  custom: Record<string, { inp: number; out: number }>;
  watts: Record<string, number>;
  rate: number;
}

const DEFAULT_RATE = 0.25;

function tierSeed(tier?: string): string {
  if (tier === 'smart') return 'sonnet';
  if (tier === 'balanced') return 'mini';
  return 'nano';
}

function tierWatts(tier?: string, kind?: string): number {
  if (tier === 'smart') return 220;
  if (tier === 'balanced') return 70;
  if (kind === 'external') return 120;
  return 40;
}

function tierTps(tier?: string): number {
  if (tier === 'smart') return 35;
  if (tier === 'balanced') return 45;
  return 85;
}

function fmtTok(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`;
  return `${Math.round(n)}`;
}

function fmtUsd(n: number): string {
  if (n >= 100) return `$${n.toFixed(0)}`;
  if (n >= 1) return `$${n.toFixed(2)}`;
  return `$${n.toFixed(4)}`;
}

export function CostPanel(): React.JSX.Element {
  const [metrics, setMetrics] = useState<MetricsResp | null>(null);
  const [models, setModels] = useState<ModelRow[]>([]);
  const [prefs, setPrefs] = useState<CostPrefs>(() => {
    try {
      const raw = localStorage.getItem('substation.cost');
      if (raw) return JSON.parse(raw) as CostPrefs;
    } catch { /* seed */ }
    return { sel: {}, custom: {}, watts: {}, rate: DEFAULT_RATE };
  });

  useEffect(() => {
    localStorage.setItem('substation.cost', JSON.stringify(prefs));
  }, [prefs]);

  useEffect(() => {
    let stop = false;
    const tick = async (): Promise<void> => {
      const [m, mods] = await Promise.all([api.metrics(), api.models()]);
      if (stop) return;
      if (m.ok) setMetrics(m.body as MetricsResp);
      if (mods.ok && Array.isArray(mods.body)) setModels(mods.body as ModelRow[]);
    };
    void tick();
    const t = setInterval(() => void tick(), 3000);
    return () => {
      stop = true;
      clearInterval(t);
    };
  }, []);

  const usage = metrics?.token_usage;
  const names = Array.from(new Set([...Object.keys(usage?.by_model ?? {}), ...models.map((m) => m.name)])).sort();
  const meta = new Map(models.map((m) => [m.name, m]));

  const priceFor = (name: string): { label: string; inp: number; out: number } => {
    const sel = prefs.sel[name] ?? tierSeed(meta.get(name)?.tier);
    if (sel === 'custom') {
      const c = prefs.custom[name] ?? { inp: 0, out: 0 };
      return { label: 'Custom', inp: c.inp, out: c.out };
    }
    const p = PROVIDERS.find((x) => x.id === sel) ?? PROVIDERS[0]!;
    return { label: p.label, inp: p.inp, out: p.out };
  };

  const tpsFor = (name: string, tier?: string): number => {
    const ring = metrics?.by_key?.[`tok_s.${name}`];
    const v = (ring?.p50 ?? 0) > 0 ? (ring?.p50 ?? 0) : 0;
    return v > 0 ? v : tierTps(tier);
  };

  let cloudTotal = 0;
  let localTotal = 0;
  const rows = names.map((name) => {
    const u = usage?.by_model?.[name] ?? { prompt: 0, completion: 0 };
    const total = u.prompt + u.completion;
    const price = priceFor(name);
    const cloud = (u.prompt / 1e6) * price.inp + (u.completion / 1e6) * price.out;
    const tier = meta.get(name)?.tier;
    const watts = prefs.watts[name] ?? tierWatts(tier, meta.get(name)?.kind);
    const tps = tpsFor(name, tier);
    const hours = total > 0 ? total / (tps * 3600) : 0;
    const local = hours * (watts / 1000) * prefs.rate;
    cloudTotal += cloud;
    localTotal += local;
    return { name, tier, u, total, price, cloud, watts, tps, local };
  });
  const saved = cloudTotal - localTotal;

  const hourly = usage?.hourly ?? [];
  const hourMax = Math.max(1, ...hourly.map((h) => h.prompt + h.completion));

  return (
    <div className="cost-wrap">
      <div className="cost-cards">
        <div className="cost-card">
          <div className="cc-k">would cost on cloud APIs</div>
          <div className="cc-v">{fmtUsd(cloudTotal)}</div>
          <div className="cc-s">at selected equivalents</div>
        </div>
        <div className="cost-card">
          <div className="cc-k">local energy estimate</div>
          <div className="cc-v">{fmtUsd(localTotal)}</div>
          <div className="cc-s">{fmtTok(usage?.total ?? 0)} tok · ${prefs.rate.toFixed(2)}/kWh</div>
        </div>
        <div className="cost-card cost-card-ok">
          <div className="cc-k">saved vs cloud</div>
          <div className="cc-v">{fmtUsd(Math.max(0, saved))}</div>
          <div className="cc-s">{cloudTotal > 0 ? `${((saved / cloudTotal) * 100).toFixed(1)}% cheaper` : '—'}</div>
        </div>
        <div className="cost-card">
          <div className="cc-k">cache hits saved</div>
          <div className="cc-v">{usage?.cache_hits ?? 0}</div>
          <div className="cc-s">no tokens generated</div>
        </div>
      </div>

      <Panel title="Per model — cloud equivalent vs local watts">
        <table className="cost-table">
          <thead>
            <tr>
              <th>model</th><th>in / out / Σ tok</th><th>cloud equivalent</th>
              <th className="num">cloud $</th><th className="num">W</th><th className="num">local $</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.name}>
                <td>
                  <code>{r.name}</code>{r.tier ? <span className="cost-tier">{r.tier}</span> : null}
                </td>
                <td className="dim">{fmtTok(r.u.prompt)} / {fmtTok(r.u.completion)} / {fmtTok(r.total)}</td>
                <td>
                  <select
                    value={prefs.sel[r.name] ?? tierSeed(r.tier)}
                    onChange={(e) => setPrefs({ ...prefs, sel: { ...prefs.sel, [r.name]: e.target.value } })}
                  >
                    {PROVIDERS.map((p) => (
                      <option key={p.id} value={p.id}>{p.label} · ${p.inp}/${p.out}/M</option>
                    ))}
                    <option value="custom">Custom…</option>
                  </select>
                  {(prefs.sel[r.name] ?? tierSeed(r.tier)) === 'custom' ? (
                    <span className="cost-custom">
                      <input
                        type="number" step="0.1" min="0" placeholder="in $/M"
                        value={prefs.custom[r.name]?.inp ?? ''}
                        onChange={(e) => setPrefs({
                          ...prefs,
                          custom: { ...prefs.custom, [r.name]: { inp: Number(e.target.value) || 0, out: prefs.custom[r.name]?.out ?? 0 } },
                        })}
                      />
                      <input
                        type="number" step="0.1" min="0" placeholder="out $/M"
                        value={prefs.custom[r.name]?.out ?? ''}
                        onChange={(e) => setPrefs({
                          ...prefs,
                          custom: { ...prefs.custom, [r.name]: { inp: prefs.custom[r.name]?.inp ?? 0, out: Number(e.target.value) || 0 } },
                        })}
                      />
                    </span>
                  ) : null}
                </td>
                <td className="num cost-cloud">{fmtUsd(r.cloud)}</td>
                <td className="num">
                  <input
                    className="cost-watts" type="number" min="0" step="10"
                    value={r.watts}
                    onChange={(e) => setPrefs({ ...prefs, watts: { ...prefs.watts, [r.name]: Number(e.target.value) || 0 } })}
                  />
                </td>
                <td className="num cost-local">{fmtUsd(r.local)}</td>
              </tr>
            ))}
            {rows.length === 0 ? (
              <tr><td colSpan={6} className="dim">no usage yet — route a few requests through auto</td></tr>
            ) : null}
          </tbody>
        </table>
      </Panel>

      <div className="cost-grid">
        <Panel title="Blended catalog estimate (daemon)">
          {(usage?.cloud_cost_estimate ?? []).map((c) => (
            <div className="cost-blend" key={`${c.provider}-${c.model}`}>
              <span className="cost-blend-k">{c.provider} <code>{c.model}</code></span>
              <span className="cost-blend-v">{fmtUsd(c.usd)}</span>
            </div>
          ))}
        </Panel>
        <Panel title="Tokens per hour (last 24h)">
          <div className="cost-hours">
            {hourly.length === 0 ? <span className="dim">no history yet</span> : null}
            {hourly.map((h, i) => (
              <div className="cost-hour" key={i} title={`+${fmtTok(h.prompt)} in / +${fmtTok(h.completion)} out`}>
                <div className="cost-hour-bar" style={{ height: `${Math.max(2, ((h.prompt + h.completion) / hourMax) * 100)}%` }} />
              </div>
            ))}
          </div>
        </Panel>
      </div>

      <div className="cost-note">
        <Pill tone="muted">estimates</Pill>
        <span className="dim">
          cloud prices are editable public list prices ($/M tokens, left as of Oct 2026 — verify before budgeting);
          local $ = tok/s-based GPU/CPU time × watts × ${prefs.rate.toFixed(2)}/kWh.
        </span>
        <input
          className="cost-rate" type="number" step="0.05" min="0"
          value={prefs.rate}
          onChange={(e) => setPrefs({ ...prefs, rate: Number(e.target.value) || 0 })}
          title="$/kWh"
        />
        <span className="dim">$/kWh</span>
      </div>
    </div>
  );
}
