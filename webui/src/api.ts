import type {
  CacheInfo,
  ConfigPatch,
  DaemonStatus,
  DiscoveryPeer,
  ModelCard,
  ModelMetrics,
  NodeInfo,
  RuntimeConfig,
  WsFrame,
} from './types.js';
import { isWsFrame } from './types.js';

export function envValue(key: string): string | undefined {
  // keep `import.meta.env` as a direct member expression so Vite's define
  // can inline it at build time (aliasing import.meta first breaks that)
  const env = (import.meta as unknown as { env?: Record<string, unknown> }).env;
  const v = env?.[key];
  return typeof v === 'string' && v.length > 0 ? v : undefined;
}

export function authToken(): string {
  try {
    return localStorage.getItem('substation.token') ?? '';
  } catch {
    return '';
  }
}

export function setAuthToken(token: string): void {
  try {
    if (token) localStorage.setItem('substation.token', token);
    else localStorage.removeItem('substation.token');
  } catch {
    /* ignore */
  }
}

export function authHeaders(extra?: Record<string, string>): Record<string, string> {
  const h: Record<string, string> = { accept: 'application/json', ...(extra ?? {}) };
  const t = authToken();
  if (t) h['authorization'] = `Bearer ${t}`;
  return h;
}

/* VITE_WS_URL (ws|wss|http|https) → REST base (same origin as daemon) */
export function apiBase(): string {
  const raw = envValue('VITE_WS_URL');
  if (!raw) return '';
  try {
    const u = new URL(raw, 'http://localhost');
    const proto = u.protocol === 'wss:' ? 'https:' : u.protocol === 'ws:' ? 'http:' : u.protocol;
    return `${proto}//${u.host}`;
  } catch {
    return '';
  }
}

export function wsUrl(): string {
  const raw = envValue('VITE_WS_URL');
  if (raw) {
    try {
      const u = new URL(raw, 'http://localhost');
      const proto = u.protocol === 'https:' || u.protocol === 'wss:' ? 'wss:' : 'ws:';
      const path = u.pathname === '' || u.pathname === '/' ? '/ws' : u.pathname;
      return `${proto}//${u.host}${path}`;
    } catch {
      /* fall through to same-origin */
    }
  }
  const loc = typeof location !== 'undefined' ? location : undefined;
  if (loc && typeof loc.protocol === 'string') {
    const proto = loc.protocol === 'https:' ? 'wss:' : 'ws:';
    return `${proto}//${loc.host}/ws`;
  }
  return 'ws://127.0.0.1:8800/ws';
}

async function getJson<T>(path: string): Promise<T | null> {
  try {
    const res = await fetch(`${apiBase()}${path}`, { headers: authHeaders() });
    if (!res.ok) return null;
    return (await res.json()) as T;
  } catch {
    return null;
  }
}

async function getArray<T>(path: string): Promise<T[]> {
  const v = await getJson<unknown>(path);
  return Array.isArray(v) ? (v as T[]) : [];
}

function asRecord(v: unknown): Record<string, unknown> | null {
  return typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
}

export interface Bootstrap {
  status: DaemonStatus | null;
  metrics: ModelMetrics | null;
  events: WsFrame[];
  cache: CacheInfo | null;
  config: RuntimeConfig | null;
  discovery: DiscoveryPeer[];
  models: ModelCard[];
}

export async function bootstrap(): Promise<Bootstrap> {
  const [status, metrics, events, cache, config, discovery, models] = await Promise.all([
    getJson<DaemonStatus>('/api/status'),
    getJson<ModelMetrics>('/api/metrics'),
    getJson<unknown>('/api/events?limit=200'),
    getJson<CacheInfo>('/api/cache'),
    getJson<RuntimeConfig>('/api/config'),
    getArray<DiscoveryPeer>('/api/discovery'),
    getJson<unknown>('/api/models'),
  ]);
  const eventFrames: WsFrame[] = Array.isArray(events)
    ? events.filter((e): e is WsFrame => isWsFrame(e))
    : [];
  let modelCards: ModelCard[] = [];
  const mv = asRecord(models);
  const raw: unknown[] = Array.isArray(models) ? (models as unknown[]) : mv && Array.isArray(mv['models']) ? mv['models'] : [];
  modelCards = raw.map((r) => {
    const o = (asRecord(r) ?? {}) as Record<string, unknown>;
    return {
      ...(o as object),
      name: String(o['name'] ?? ''),
      state: o['loading'] === true ? 'loading' : o['loaded'] === true ? 'loaded' : 'unloaded',
    } as ModelCard;
  });
  return {
    status: asRecord(status) ? status : null,
    metrics: asRecord(metrics) ? metrics : null,
    events: eventFrames,
    cache: asRecord(cache) ? cache : null,
    config: asRecord(config) ? config : null,
    discovery,
    models: modelCards,
  };
}

export async function getStatus(): Promise<DaemonStatus | null> {
  return getJson<DaemonStatus>('/api/status');
}

export async function getConfig(): Promise<RuntimeConfig | null> {
  return getJson<RuntimeConfig>('/api/config');
}

export interface AdminResult {
  ok: boolean;
  status: number;
  body: unknown;
}

async function get(path: string): Promise<AdminResult> {
  try {
    const res = await fetch(`${apiBase()}${path}`, { headers: authHeaders() });
    let parsed: unknown = null;
    try {
      parsed = await res.json();
    } catch {
      parsed = null;
    }
    return { ok: res.ok, status: res.status, body: parsed };
  } catch (e) {
    return { ok: false, status: 0, body: { error: { message: String(e) } } };
  }
}

async function post(path: string, body?: unknown): Promise<AdminResult> {
  try {
    const res = await fetch(`${apiBase()}${path}`, {
      method: 'POST',
      headers: authHeaders({ 'content-type': 'application/json' }),
      body: body === undefined ? '{}' : JSON.stringify(body),
    });
    let parsed: unknown = null;
    try {
      parsed = await res.json();
    } catch {
      parsed = null;
    }
    return { ok: res.ok, status: res.status, body: parsed };
  } catch (e) {
    return { ok: false, status: 0, body: String(e) };
  }
}

async function put(path: string, body: unknown): Promise<AdminResult> {
  try {
    const res = await fetch(`${apiBase()}${path}`, {
      method: 'PUT',
      headers: authHeaders({ 'content-type': 'application/json' }),
      body: JSON.stringify(body),
    });
    let parsed: unknown = null;
    try {
      parsed = await res.json();
    } catch {
      parsed = null;
    }
    return { ok: res.ok, status: res.status, body: parsed };
  } catch (e) {
    return { ok: false, status: 0, body: String(e) };
  }
}

export const api = {
  pause: (): Promise<AdminResult> => post('/api/admin/pause'),
  resume: (): Promise<AdminResult> => post('/api/admin/resume'),
  reload: (): Promise<AdminResult> => post('/api/admin/reload'),
  joinCode: (): Promise<AdminResult> => post('/api/admin/join-code'),
  loadModel: (name: string): Promise<AdminResult> => post(`/api/models/${encodeURIComponent(name)}/load`),
  unloadModel: (name: string): Promise<AdminResult> => post(`/api/models/${encodeURIComponent(name)}/unload`),
  putConfig: (patch: ConfigPatch): Promise<AdminResult> => put('/api/config', patch),
  getConfig: (): Promise<RuntimeConfig | null> => getConfig(),
  rotateKey: (): Promise<AdminResult> => post('/api/admin/rotate-key'),
  resetConfig: (): Promise<AdminResult> => post('/api/admin/reset-config'),
  tuneApply: (): Promise<AdminResult> => post('/api/tune/apply'),
  unjoin: (node: string): Promise<AdminResult> => post(`/api/cluster/unjoin?node=${encodeURIComponent(node)}`),
  rpcSelf: (start: boolean): Promise<AdminResult> => post('/api/cluster/rpc-self', { start: start }),
  rpcPeer: (nodeId: string, start: boolean): Promise<AdminResult> => post('/api/cluster/rpc-peer', { node_id: nodeId, start: start }),
  erase: (path: string): Promise<AdminResult> => post('/api/admin/erase', { path }),
  nodes: (): Promise<NodeInfo[]> => getArray<NodeInfo>('/api/nodes'),
  metrics: (): Promise<AdminResult> => get('/api/metrics'),
  models: (): Promise<AdminResult> => get('/api/models'),
  logs: (): Promise<AdminResult> => get('/api/logs'),
  logFile: (name: string, tail: number): Promise<AdminResult> =>
    get(`/api/logs/${encodeURIComponent(name)}?tail=${tail}`),
  nodeLogs: (node: string, name: string, tail: number): Promise<AdminResult> =>
    get(`/api/cluster/logs?node=${encodeURIComponent(node)}&name=${encodeURIComponent(name)}&tail=${tail}`),
};
