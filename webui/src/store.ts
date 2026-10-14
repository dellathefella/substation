import { create } from 'zustand';
import type {
  CacheInfo,
  ClusterWarning,
  ConfigPatch,
  DaemonStatus,
  DiscoveryPeer,
  FeedRow,
  JoinCodeInfo,
  ModelCard,
  ModelMetrics,
  NodeHealth,
  RuntimeConfig,
  ThrBucket,
  ThrPoint,
  Tier,
  Toast,
  WsFrame,
  WsStatus,
} from './types.js';
import { isTier, TIERS } from './types.js';
import type { Bootstrap } from './api.js';
import { getConfig } from './api.js';

export const FEED_CAP = 200;
export const THR_CAP = 600;
export const SPARK_CAP = 80;
export const WARN_CAP = 20;

function emptyTierCounts(): Record<Tier, number> {
  return { fast: 0, balanced: 0, smart: 0 };
}

let toastSeq = 1;

export interface DashboardStore {
  ws: WsStatus;
  wsUrl: string;
  booted: boolean;
  now: number;

  status: DaemonStatus | null;
  statusAt: number;
  metrics: ModelMetrics | null;
  config: RuntimeConfig | null;
  configVersion: number;
  cache: CacheInfo | null;
  models: ModelCard[];
  nodes: Record<string, NodeHealth>;
  discovery: DiscoveryPeer[];
  warnings: ClusterWarning[];

  feed: FeedRow[];
  live: ThrPoint[];
  sparkTtft: number[];
  sparkTotal: number[];

  tierCounts: Record<Tier, number>;
  methodModel: number;
  methodHeuristic: number;
  confSum: number;
  confN: number;
  cacheHits: number;
  doneCached: number;
  doneUncached: number;
  reqTimes: number[];

  toasts: Toast[];
  joinCode: JoinCodeInfo | null;

  setWs(url: string, status: WsStatus): void;
  hydrate(b: Bootstrap): void;
  applyFrames(frames: readonly WsFrame[]): void;
  replaceConfig(config: RuntimeConfig | null): void;
  patchConfigLocal(patch: ConfigPatch): void;
  removeNodeLocal(id: string): void;
  pushToast(level: Toast['level'], title: string, msg?: string): void;
  dismissToast(id: number): void;
  setJoinCode(j: JoinCodeInfo | null): void;
  tick(now: number): void;
}

function deepMergeRecord(
  base: Record<string, unknown>,
  patch: Record<string, unknown>,
): Record<string, unknown> {
  const out: Record<string, unknown> = { ...base };
  for (const [k, v] of Object.entries(patch)) {
    const cur = out[k];
    if (
      v !== null && typeof v === 'object' && !Array.isArray(v) &&
      cur !== null && typeof cur === 'object' && !Array.isArray(cur)
    ) {
      out[k] = deepMergeRecord(cur as Record<string, unknown>, v as Record<string, unknown>);
    } else {
      out[k] = v;
    }
  }
  return out;
}

function mergeConfigPatch(cfg: RuntimeConfig | null, patch: ConfigPatch): RuntimeConfig {
  return deepMergeRecord({ ...(cfg ?? {}) }, patch as unknown as Record<string, unknown>) as RuntimeConfig;
}

function rowFromRequest(id: string, virtual: string, ts: number): FeedRow {
  return {
    id,
    id8: id.slice(0, 8),
    ts,
    virtual,
    phase: 'received',
    split: false,
    rpc_peers: [],
    cached: false,
  };
}

function finalizeSparks(ttft: number[], total: number[]): { sparkTtft: number[]; sparkTotal: number[] } {
  return { sparkTtft: ttft.slice(-SPARK_CAP), sparkTotal: total.slice(-SPARK_CAP) };
}

function zeroCounts(): Record<Tier, number> {
  return { fast: 0, balanced: 0, smart: 0 };
}

function bucketPoint(b: ThrBucket): ThrPoint {
  const avg = (t: Tier): number => (b.n[t] > 0 ? b.sum[t] / b.n[t] : 0);
  return { t: b.t, all: TIERS.reduce((s, t) => s + avg(t), 0), fast: avg('fast'), balanced: avg('balanced'), smart: avg('smart') };
}

function pushPoint(live: ThrPoint[], p: ThrPoint): void {
  const last = live[live.length - 1];
  if (last && last.t === p.t) live[live.length - 1] = p;
  else live.push(p);
}

/* flushes all seconds up to (not including) toSec, returns an empty bucket at toSec */
function rollBucket(b: ThrBucket, live: ThrPoint[], toSec: number): ThrBucket {
  let cur = b;
  let guard = 0;
  while (cur.t < toSec && guard < 10) {
    pushPoint(live, bucketPoint(cur));
    cur = { t: cur.t + 1, sum: zeroCounts(), n: zeroCounts() };
    guard += 1;
  }
  return cur;
}

export const useStore = create<DashboardStore>()((set, get) => ({
  ws: 'connecting',
  wsUrl: '',
  booted: false,
  now: Date.now(),

  status: null,
  statusAt: 0,
  metrics: null,
  config: null,
  configVersion: 0,
  cache: null,
  models: [],
  nodes: {},
  discovery: [],
  warnings: [],

  feed: [],
  live: [],
  sparkTtft: [],
  sparkTotal: [],

  tierCounts: emptyTierCounts(),
  methodModel: 0,
  methodHeuristic: 0,
  confSum: 0,
  confN: 0,
  cacheHits: 0,
  doneCached: 0,
  doneUncached: 0,
  reqTimes: [],

  toasts: [],
  joinCode: null,

  setWs: (url, status) => set({ wsUrl: url, ws: status }),

  hydrate: (b) => {
    const nodes: Record<string, NodeHealth> = { ...get().nodes };
    for (const n of b.status?.nodes ?? []) {
      nodes[n.node] = { ...n, ts: Date.now() };
    }
    set({
      booted: true,
      status: b.status ?? get().status,
      statusAt: Date.now(),
      metrics: b.metrics ?? get().metrics,
      config: b.config ?? get().config,
      cache: b.cache ?? get().cache,
      models: b.models.length > 0 ? b.models : get().models,
      discovery: b.discovery.length > 0 ? b.discovery : get().discovery,
      nodes,
    });
    // /api/events is newest-first; replay oldest → newest
    const chrono = [...b.events].reverse();
    const ttft: number[] = [];
    const total: number[] = [];
    applyFramesInner(set, get, chrono, ttft, total);
    if (ttft.length > 0 || total.length > 0) set(finalizeSparks(ttft, total));
  },

  applyFrames: (frames) => {
    const s = get();
    const ttft = [...s.sparkTtft];
    const total = [...s.sparkTotal];
    applyFramesInner(set, get, frames, ttft, total);
    set(finalizeSparks(ttft, total));
  },

  replaceConfig: (config) => set({ config: config ?? get().config }),

  patchConfigLocal: (patch) => set({ config: mergeConfigPatch(get().config, patch) }),
  removeNodeLocal: (id) => {
    const nodes = { ...get().nodes };
    delete nodes[id];
    set({ nodes });
  },

  pushToast: (level, title, msg) => {
    const t: Toast = { id: toastSeq++, level, title, msg, ts: Date.now() };
    set({ toasts: [...get().toasts.slice(-4), t] });
  },

  dismissToast: (id) => set({ toasts: get().toasts.filter((t) => t.id !== id) }),

  setJoinCode: (j) => set({ joinCode: j }),

  tick: (now) => {
    const s = get();
    set({
      now: now,
      toasts: s.toasts.filter((t) => now - t.ts < 6000),
      reqTimes: s.reqTimes.filter((t) => now - t < 60_000),
      joinCode: s.joinCode && now - s.joinCode.at > s.joinCode.ttl_s * 1000 ? null : s.joinCode,
    });
  },
}));

function applyFramesInner(
  set: (partial: Partial<DashboardStore>) => void,
  get: () => DashboardStore,
  frames: readonly WsFrame[],
  sparkTtft: number[],
  sparkTotal: number[],
): void {
  if (frames.length === 0) return;
  const s = get();

  const feed = [...s.feed];
  const rows = new Map(s.feed.map((r) => [r.id, r] as const));
  const live = [...s.live];
  let bucket: ThrBucket | null = null;
  const tierCounts: Record<Tier, number> = { ...s.tierCounts };
  let methodModel = s.methodModel;
  let methodHeuristic = s.methodHeuristic;
  let confSum = s.confSum;
  let confN = s.confN;
  let cacheHits = s.cacheHits;
  let doneCached = s.doneCached;
  let doneUncached = s.doneUncached;
  const reqTimes = [...s.reqTimes];
  const nodes = { ...s.nodes };
  const models = [...s.models];
  let warnings = s.warnings;
  const toasts = [...s.toasts];
  let configVersion = s.configVersion;
  let status = s.status;
  let statusAt = s.statusAt;
  let feedDirty = false;

  const touch = (): void => {
    feedDirty = true;
  };

  const pushWarning = (w: ClusterWarning): void => {
    const dupe = warnings.find((x) => x.node === w.node && x.code === w.code);
    if (dupe) {
      // collapse same (node, code) into one banner; keep the latest repeated count
      warnings = [
        { ...w, repeated: w.repeated ?? dupe.repeated },
        ...warnings.filter((x) => !(x.node === w.node && x.code === w.code)),
      ].slice(0, WARN_CAP);
      return;
    }
    warnings = [w, ...warnings].slice(0, WARN_CAP);
    toasts.push({ id: toastSeq++, level: w.level === 'error' ? 'error' : 'warn', title: w.code, msg: `[${w.node}] ${w.msg}`, ts: w.ts });
  };

  for (const f of frames) {
    const d = f.data as Record<string, unknown>;
    switch (f.type) {
      case 'request.received': {
        const id = String(d['id'] ?? '');
        if (!id) break;
        const existing = rows.get(id);
        if (existing) {
          existing.virtual = String(d['virtual_model'] ?? existing.virtual);
          existing.ts = Math.min(existing.ts, f.ts);
          if (existing.phase === 'received' || existing.phase === 'triaged') existing.phase = existing.phase;
        } else {
          const row = rowFromRequest(id, String(d['virtual_model'] ?? 'auto'), f.ts);
          rows.set(id, row);
          feed.unshift(row);
          feed.splice(FEED_CAP);
          reqTimes.push(f.ts);
        }
        touch();
        break;
      }
      case 'triage.decision': {
        const rid = String(d['id'] ?? '');
        if (rid && !rows.has(rid)) {
          const row = rowFromRequest(rid, 'auto', f.ts);
          rows.set(rid, row);
          feed.unshift(row);
          feed.splice(FEED_CAP);
          reqTimes.push(f.ts);
          touch();
        }
        const row = rows.get(rid);
        const tier = d['tier'];
        if (isTier(tier)) tierCounts[tier] += 1;
        const conf = typeof d['confidence'] === 'number' ? d['confidence'] : null;
        if (conf !== null) {
          confSum += conf;
          confN += 1;
        }
        if (d['method'] === 'model') methodModel += 1;
        else if (d['method'] === 'heuristic') methodHeuristic += 1;
        if (row) {
          if (isTier(tier)) row.tier = tier;
          row.confidence = conf ?? undefined;
          row.method = d['method'] === 'model' || d['method'] === 'heuristic' ? d['method'] : undefined;
          row.triageMs = typeof d['ms'] === 'number' ? d['ms'] : undefined;
          if (row.phase === 'received') row.phase = 'triaged';
          touch();
        }
        break;
      }
      case 'route.selected': {
        const row = rows.get(String(d['id'] ?? ''));
        if (row) {
          row.model = typeof d['model'] === 'string' ? d['model'] : row.model;
          row.node = typeof d['node'] === 'string' ? d['node'] : row.node;
          row.split = d['split'] === true;
          row.rpc_peers = Array.isArray(d['rpc_peers']) ? (d['rpc_peers'] as unknown[]).map(String) : row.rpc_peers;
          row.reason = typeof d['reason'] === 'string' ? d['reason'] : row.reason;
          if (row.phase === 'received' || row.phase === 'triaged') row.phase = 'routed';
          touch();
        }
        break;
      }
      case 'engine.wait': {
        const row = rows.get(String(d['id'] ?? ''));
        if (row) {
          row.waitReason = typeof d['reason'] === 'string' ? d['reason'] : row.waitReason;
          row.waitMs = typeof d['ms'] === 'number' ? d['ms'] : undefined;
          row.phase = 'waiting';
          touch();
        }
        break;
      }
      case 'stream.first_token': {
        const row = rows.get(String(d['id'] ?? ''));
        const ttft = typeof d['ttft_ms'] === 'number' ? d['ttft_ms'] : null;
        if (row) {
          row.ttft = ttft ?? undefined;
          row.phase = 'streaming';
          touch();
        }
        if (ttft !== null) sparkTtft.push(ttft);
        break;
      }
      case 'stream.tick': {
        const row = rows.get(String(d['id'] ?? ''));
        if (!row) break;
        const tps = typeof d['tok_per_s'] === 'number' ? d['tok_per_s'] : 0;
        const tokens = typeof d['tokens'] === 'number' ? d['tokens'] : 0;
        row.tokPerS = tps;
        row.tokens = (row.tokens ?? 0) + tokens;
        if (row.phase !== 'done' && row.phase !== 'cache') row.phase = 'streaming';
        touch();
        {
          const sec = Math.floor(f.ts / 1000);
          if (bucket === null) bucket = { t: sec, sum: zeroCounts(), n: zeroCounts() };
          if (bucket.t < sec) bucket = rollBucket(bucket, live, sec);
          const tier = row.tier ?? 'fast';
          bucket.sum[tier] += tps;
          bucket.n[tier] += 1;
        }
        break;
      }
      case 'stream.done': {
        const row = rows.get(String(d['id'] ?? ''));
        const ms = typeof d['ms'] === 'number' ? d['ms'] : null;
        const cached = d['cached'] === true;
        if (cached) doneCached += 1;
        else doneUncached += 1;
        if (row) {
          row.tokens = typeof d['total_tokens'] === 'number' ? d['total_tokens'] : row.tokens;
          row.ms = ms ?? undefined;
          row.cached = cached;
          row.phase = 'done';
          touch();
        }
        if (ms !== null) sparkTotal.push(ms);
        break;
      }
      case 'cache.hit': {
        cacheHits += 1;
        const id = String(d['id'] ?? '');
        const row = rows.get(id);
        if (row) {
          row.cached = true;
          if (row.phase !== 'done') row.phase = 'cache';
          row.model = typeof d['model'] === 'string' ? d['model'] : row.model;
          touch();
        } else {
          const r = rowFromRequest(id, 'auto', f.ts);
          r.phase = 'cache';
          r.cached = true;
          r.model = typeof d['model'] === 'string' ? d['model'] : undefined;
          rows.set(id, r);
          feed.unshift(r);
          feed.splice(FEED_CAP);
          touch();
        }
        break;
      }
      case 'model.loading':
      case 'model.loaded':
      case 'model.unloaded': {
        const name = String(d['model'] ?? '');
        if (!name) break;
        const idx = models.findIndex((m) => m.name === name);
        const base: ModelCard = idx >= 0 && models[idx] ? models[idx] : { name, state: 'unloaded' };
        const next: ModelCard = {
          ...base,
          state: f.type === 'model.loading' ? 'loading' : f.type === 'model.loaded' ? 'loaded' : 'unloaded',
          node: typeof d['node'] === 'string' ? d['node'] : base.node,
          size_gb: typeof d['gb'] === 'number' ? d['gb'] : base.size_gb,
        };
        if (idx >= 0) models[idx] = next;
        else models.push(next);
        set({ models: [...models] });
        break;
      }
      case 'node.health': {
        const node = String(d['node'] ?? '');
        if (!node) break;
        const prev = nodes[node];
        nodes[node] = {
          node,
          ram_used_gb: typeof d['ram_used_gb'] === 'number' ? d['ram_used_gb'] : prev?.ram_used_gb ?? 0,
          ram_total_gb: typeof d['ram_total_gb'] === 'number' ? d['ram_total_gb'] : prev?.ram_total_gb ?? 0,
          gpu_pct: typeof d['gpu_pct'] === 'number' ? d['gpu_pct'] : prev?.gpu_pct ?? 0,
          runners: Array.isArray(d['runners']) ? (d['runners'] as NodeHealth['runners']) : prev?.runners ?? [],
          rpc_up: typeof d['rpc_up'] === 'boolean' ? d['rpc_up'] : prev?.rpc_up,
          rpc_ms_last: prev?.rpc_ms_last,
          tok_s: prev?.tok_s,
          ts: f.ts,
        };
        set({ nodes: { ...nodes } });
        break;
      }
      case 'rpc.sample': {
        const node = String(d['node'] ?? '');
        const prev = nodes[node];
        if (prev) {
          nodes[node] = {
            ...prev,
            rpc_ms_last: typeof d['rpc_ms_last'] === 'number' ? d['rpc_ms_last'] : prev.rpc_ms_last,
            tok_s: typeof d['tok_s'] === 'number' ? d['tok_s'] : prev.tok_s,
          };
          set({ nodes: { ...nodes } });
        }
        break;
      }
      case 'config.changed': {
        const keys = Array.isArray(d['keys']) ? (d['keys'] as unknown[]).map(String) : [];
        configVersion += 1;
        toasts.push({
          id: toastSeq++,
          level: 'success',
          title: 'Config updated',
          msg: keys.length > 0 ? keys.join(', ') : 'runtime config changed',
          ts: f.ts,
        });
        set({ configVersion, toasts: [...toasts] });
        break;
      }
      case 'cluster.warning': {
        pushWarning({
          node: String(d['node'] ?? '?'),
          level: String(d['level'] ?? 'warning'),
          code: String(d['code'] ?? 'warning'),
          msg: String(d['msg'] ?? ''),
          ts: f.ts,
          repeated: typeof d['repeated'] === 'number' ? d['repeated'] : undefined,
        });
        set({ warnings, toasts: [...toasts] });
        break;
      }
      case 'status': {
        status = f.data as unknown as DaemonStatus;
        statusAt = f.ts;
        set({ status, statusAt });
        break;
      }
      default:
        break;
    }
  }

  if (bucket !== null) {
    pushPoint(live, bucketPoint(bucket));
    live.splice(0, Math.max(0, live.length - THR_CAP));
    set({ live });
  }
  if (feedDirty) set({ feed: [...feed] });
  set({ tierCounts, methodModel, methodHeuristic, confSum, confN, cacheHits, doneCached, doneUncached, reqTimes });
}

/* Re-fetch effective config whenever the daemon broadcasts config.changed */
export function watchConfigRefresh(): () => void {
  let lastVersion = useStore.getState().configVersion;
  return useStore.subscribe((s) => {
    if (s.configVersion !== lastVersion) {
      lastVersion = s.configVersion;
      void getConfig().then((cfg) => {
        if (cfg) useStore.getState().replaceConfig(cfg);
      });
    }
  });
}

/* ---- live selectors (pure helpers used by components) ---- */

export function selectLiveTokPerS(s: DashboardStore): number {
  let sum = 0;
  for (const r of s.feed) {
    if (r.phase === 'streaming' && r.tokPerS) sum += r.tokPerS;
  }
  return sum;
}

export function selectInflight(s: DashboardStore): number {
  let n = 0;
  for (const r of s.feed) {
    if (r.phase === 'received' || r.phase === 'triaged' || r.phase === 'routed' || r.phase === 'waiting' || r.phase === 'streaming') n += 1;
  }
  return n;
}

export function selectCacheRatio(s: DashboardStore): number | null {
  const cached = s.cacheHits + s.doneCached;
  const total = s.cacheHits + s.doneCached + s.doneUncached;
  if (total >= 10) return cached / total;
  const staticRatio = s.metrics?.cache_hit_ratio ?? s.cache?.hit_ratio ?? s.status?.cache_hit_ratio;
  return typeof staticRatio === 'number' ? staticRatio : null;
}

export function selectUptime(s: DashboardStore): number | null {
  if (!s.status) return null;
  return s.status.uptime_s + Math.max(0, (s.now - s.statusAt) / 1000);
}

/* NOTE: model live stats are computed in ModelsPanel with useMemo over s.feed —
   a selector returning a fresh object would re-render-loop under zustand. */
