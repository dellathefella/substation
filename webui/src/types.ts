export type Tier = 'fast' | 'balanced' | 'smart';
export type WsStatus = 'connecting' | 'connected' | 'offline';
export type Phase = 'received' | 'triaged' | 'routed' | 'waiting' | 'streaming' | 'done' | 'cache';

export interface RunnerState {
  model: string;
  port: number;
  state: string;
  tok_s?: number;
}

export interface NodeHealth {
  node: string;
  ram_used_gb?: number;
  ram_total_gb?: number;
  gpu_pct?: number;
  runners?: RunnerState[];
  rpc_up?: boolean;
  rpc_ms_last?: number;
  tok_s?: number;
  ts: number;
  healthy?: boolean;
  link?: { kind?: string; rtt_ms?: number; mbps?: number; rdma?: boolean } | null;
  health?: {
    ram_used_gb?: number;
    ram_total_gb?: number;
    gpu_pct?: number;
    rpc_up?: boolean;
    runners?: RunnerState[];
    system?: SystemStats;
  } | null;
}

export interface LogFile {
  name: string;
  bytes: number;
  mtime_ms: number;
}

export interface SystemStats {
  cpu_pct?: number;
  gpu_pct?: number;
  rx_bps?: number;
  tx_bps?: number;
  rx_total?: number;
  tx_total?: number;
}

export interface NodeInfo {
  id: string;
  name: string;
  ip: string;
  agent_port: number;
  rpc_port: number;
  healthy: boolean;
  joined_ms: number;
  health?: {
    ram_used_gb?: number;
    ram_total_gb?: number;
    gpu_pct?: number;
    rpc_up?: boolean;
    runners?: RunnerState[];
    system?: SystemStats;
  } | null;
  link?: { kind?: string; rtt_ms?: number; mbps?: number; rdma?: boolean } | null;
}

export interface DaemonStatus {
  state: string;
  uptime_s: number;
  requests_active: number;
  requests_per_min: number;
  tokens_per_sec: number;
  models_loaded: number;
  models_total: number;
  cache_hit_ratio?: number;
  nodes?: NodeHealth[];
  requests_queued?: number;
  system?: SystemStats;
  cluster_enabled?: boolean;
  auto_router?: string;
  auto_available?: boolean;
  orchestrator_up?: boolean;
  memory?: {
    free_gb: number;
    used_gb: number;
    total_gb: number;
    min_free_gb?: number;
    resident_gb?: number;
    gpu_wired_limit_gb?: number;
    pressure?: string;
  };
}

export interface ModelMetrics {
  requests_total?: number;
  cache_hit_ratio?: number;
  queue_depth?: number;
  percentiles?: {
    ttft_ms?: { p50?: number; p95?: number; p99?: number };
    total_ms?: { p50?: number; p95?: number; p99?: number };
  };
  triage?: Partial<Record<Tier, number>>;
}

export interface ModelCard {
  name: string;
  state: 'loaded' | 'loading' | 'unloaded';
  kind?: 'local' | 'external' | 'remote';
  tier?: string;
  node?: string;
  placement?: string;
  flags?: string[];
  base_url?: string;
  remote_model?: string;
  protocol?: string;
  api_key_masked?: string | null;
  size_gb?: number;
  ctx?: number;
  split?: boolean;
  rpc_peers?: string[];
}

export interface CacheSlot {
  engine: string;
  used: number;
  total: number;
}

export interface CacheInfo {
  hit_ratio: number;
  entries: number;
  max_entries: number;
  bytes: number;
  max_bytes: number;
  kv_slots?: CacheSlot[];
}

export interface PeerLink {
  kind: string;
  rtt_ms: number;
  mbps: number;
  rdma: boolean;
}

export interface DiscoveryPeer {
  node_id: string;
  name: string;
  ip: string;
  agent_port: number;
  seen_ms_ago: number;
  link?: PeerLink;
}

export interface ClusterWarning {
  node: string;
  level: string;
  code: string;
  msg: string;
  ts: number;
}

export interface RuntimeConfig {
  [key: string]: unknown;
  cluster?: { enabled?: boolean; heartbeat_ms?: number; controller_id?: string };
  daemon?: {
    auth_token?: string;
    bind?: string;
    port?: number;
    session_stick_seconds?: number;
    max_concurrent_requests?: number;
    start_on_login?: boolean;
    webui_dist?: string;
  };
  orchestrator?: {
    enabled?: boolean;
    triage_gguf?: string;
    triage_port?: number;
    triage_timeout_ms?: number;
    triage_upgrade_confidence?: number;
    cache_enabled?: boolean;
    cache_max_entries?: number;
    default_model?: string;
    idle_load_only?: boolean;
    default_ctx?: number;
    tiers?: Record<string, { models?: string[]; priority?: number; desc?: string }>;
  };
  engines?: {
    llama_server?: string;
    rpc_server?: string;
    models_dir?: string;
    base_port?: number;
    default_ctx?: number;
    idle_evict_seconds?: number;
    min_free_ram_gb?: number;
    startup_timeout_s?: number;
  };
  models?: {
    name: string;
    kind?: 'local' | 'external' | 'remote';
    tier?: string;
    size_gb?: number;
    ctx?: number;
    placement?: string;
    node?: string;
    flags?: string[];
    gguf?: string;
    dir?: string;
    file?: string;
    base_url?: string;
    api_key?: string;
    model?: string;
    remote_model?: string;
    protocol?: 'openai' | 'anthropic';
  }[];
}

export type ConfigPatch = { [key: string]: string | number | boolean | ConfigPatch };

export interface FeedRow {
  id: string;
  id8: string;
  ts: number;
  virtual: string;
  phase: Phase;
  tier?: Tier;
  confidence?: number;
  method?: 'model' | 'heuristic';
  triageMs?: number;
  model?: string;
  node?: string;
  split: boolean;
  rpc_peers: string[];
  reason?: string;
  waitReason?: string;
  waitMs?: number;
  ttft?: number;
  tokens?: number;
  ms?: number;
  tokPerS?: number;
  cached: boolean;
}

export interface ThrBucket {
  t: number;
  sum: Record<Tier, number>;
  n: Record<Tier, number>;
}

export interface ThrPoint {
  t: number;
  all: number;
  fast: number;
  balanced: number;
  smart: number;
}

export interface Toast {
  id: number;
  level: 'info' | 'success' | 'warn' | 'error';
  title: string;
  msg?: string;
  ts: number;
}

export interface JoinCodeInfo {
  code: string;
  ttl_s: number;
  at: number;
}

export interface JoinCodeResponse {
  code?: string;
  ttl_s?: number;
}

/* ---------- WS frames (docs/PROTOCOL.md §1) ---------- */

export interface FrameBase {
  type: string;
  ts: number;
  data: unknown;
}

export interface RequestReceivedFrame extends FrameBase {
  type: 'request.received';
  data: { id: string; virtual_model: string; bytes: number; session?: string };
}
export interface TriageDecisionFrame extends FrameBase {
  type: 'triage.decision';
  data: { id: string; tier: Tier; confidence: number; method: 'model' | 'heuristic'; ms: number };
}
export interface RouteSelectedFrame extends FrameBase {
  type: 'route.selected';
  data: { id: string; model: string; node: string; split: boolean; rpc_peers: string[]; reason: string };
}
export interface EngineWaitFrame extends FrameBase {
  type: 'engine.wait';
  data: { id: string; ms: number; reason: 'loading' | 'queued' | 'cache' };
}
export interface FirstTokenFrame extends FrameBase {
  type: 'stream.first_token';
  data: { id: string; ttft_ms: number };
}
export interface StreamTickFrame extends FrameBase {
  type: 'stream.tick';
  data: { id: string; tokens: number; tok_per_s: number };
}
export interface StreamDoneFrame extends FrameBase {
  type: 'stream.done';
  data: { id: string; total_tokens: number; ms: number; cached: boolean };
}
export interface CacheHitFrame extends FrameBase {
  type: 'cache.hit';
  data: { id: string; model: string };
}
export interface ModelLifecycleFrame extends FrameBase {
  type: 'model.loading' | 'model.loaded' | 'model.unloaded';
  data: { model: string; node: string; gb: number; ms: number };
}
export interface NodeHealthFrame extends FrameBase {
  type: 'node.health';
  data: {
    node: string;
    ram_used_gb: number;
    ram_total_gb: number;
    gpu_pct: number;
    runners: RunnerState[];
    rpc_up?: boolean;
  };
}
export interface RpcSampleFrame extends FrameBase {
  type: 'rpc.sample';
  data: { node: string; rpc_ms_last: number; tok_s: number };
}
export interface ConfigChangedFrame extends FrameBase {
  type: 'config.changed';
  data: { keys: string[] };
}
export interface ClusterWarningFrame extends FrameBase {
  type: 'cluster.warning';
  data: { node: string; level: 'info' | 'warning' | 'error'; code: string; msg: string };
}

export type WsFrame =
  | RequestReceivedFrame
  | TriageDecisionFrame
  | RouteSelectedFrame
  | EngineWaitFrame
  | FirstTokenFrame
  | StreamTickFrame
  | StreamDoneFrame
  | CacheHitFrame
  | ModelLifecycleFrame
  | NodeHealthFrame
  | RpcSampleFrame
  | ConfigChangedFrame
  | ClusterWarningFrame
  | FrameBase;

export const TIERS: readonly Tier[] = ['fast', 'balanced', 'smart'] as const;

export function isTier(v: unknown): v is Tier {
  return v === 'fast' || v === 'balanced' || v === 'smart';
}

export function isWsFrame(v: unknown): v is WsFrame {
  if (typeof v !== 'object' || v === null) return false;
  const o = v as { type?: unknown; ts?: unknown; data?: unknown };
  return typeof o.type === 'string' && typeof o.ts === 'number' && typeof o.data === 'object' && o.data !== null;
}
