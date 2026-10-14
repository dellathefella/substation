# Substation Wire Protocol v2 (llama.cpp backend)

Layers:
- **substationd** (Swift/Vapor control plane): public OpenAI-compatible API, orchestration
  (triage → tier → route → schedule), cluster placement, metrics/WebSocket. Serves webui.
- **llama.cpp engines** (Metal): `llama-server` (one loaded GGUF model per process)
  and `rpc-server` (layer-split worker). Supervised by substationd.
- **consumers**: webui dashboard, menu bar app, any OpenAI client.

## 1. Public API (substationd controller, default :8800)

Auth: `Authorization: Bearer <token>` (config `auth_token`; empty = no auth).

### POST /v1/chat/completions — OpenAI-compatible. **Model switching is transparent.**
```json
{"model":"auto","messages":[{"role":"user","content":"..."}],"stream":true,
 "temperature":0.7,"max_tokens":512,"user":"session-id-optional"}
```
Virtual models (clients only use these): `auto` | `auto-fast` | `auto-smart`.
- `auto`/omitted → orchestrator triages and picks tier + model + placement.
- Response `model` ALWAYS echoes the requested virtual name. Real model/node
  NEVER appears in response bodies — only in `/api/*`, `/ws`, dashboard.
- Never 503 on "model loading": admission control + prefetch; client sees TTFT only.
- Session stickiness: `user` or `X-Substation-Session` → sticky (session→model)
  `session_stick_seconds` (300). Mid-session tier upgrade allowed at
  triage confidence ≥ 0.8; history is replayed (chat stateless) → transparent.
Headers always: `X-Substation-Request-Id`, `X-Substation-Tier`.

### GET /v1/models — virtual models + real catalog (owned_by: substation-virtual|substation).

### Admin/observability — every option is settable via config file, REST, CLI, UI
- `GET /api/status` → {state, uptime_s, requests_active, requests_per_min,
  tokens_per_sec, models_loaded, models_total, nodes[]}
- `GET /api/metrics` → counters, percentiles (ttft_ms, total_ms, tok_s per
  tier/model/node), queue depth, cache hit ratio, triage distribution, memory.
- `GET /api/events?limit=200` → recent routing log (newest first).
- `GET /api/models` | `POST /api/models/{name}/load` | `POST /api/models/{name}/unload`
- `GET /api/nodes` → cluster nodes: health, ram, gpu, runners, rpc peers.
- `POST /api/admin/pause` | `/api/admin/resume` | `/api/admin/reload`
- `GET /api/config` → effective runtime config (JSON).
- `PUT /api/config` → partial JSON patch of mutable fields; daemon applies,
  persists to config TOML, broadcasts `{type:"config.changed", data:{keys:[]}}`.
  Mutable: cluster.enabled, tiers→models map, session_stick_seconds,
  max_concurrent_requests, triage (gguf/timeout/upgrade confidence),
  cache (enabled/max), engine evict settings, per-model placement/ctx, auth_token.
  Requiring restart: bind/port/agent ports.
- CLI mirrors REST via `substationd admin` (see §5).
- `GET /ws` → JSON frames {"type","ts","data":{...}}:

| type | data |
|------|------|
| `request.received` | {id, virtual_model, bytes, session} |
| `triage.decision` | {id, tier, confidence, method:"model"\|"heuristic", ms} |
| `route.selected` | {id, model, node, split:bool, rpc_peers:[], reason} |
| `engine.wait` | {id, ms, reason:"loading"\|"queued"\|"cache"} |
| `stream.first_token` | {id, ttft_ms} |
| `stream.tick` | {id, tokens, tok_per_s} (batched ~250ms) |
| `stream.done` | {id, total_tokens, ms, cached} |
| `cache.hit` | {id, model} |
| `model.loading`/`model.loaded`/`model.unloaded` | {model, node, gb, ms} |
| `node.health` | {node, ram_used_gb, ram_total_gb, gpu_pct, runners:[...]} |
| `rpc.sample` | {node, rpc_ms_last, tok_s} (split models) |

### GET / (root) — serves built webui (webui/dist).

## 2. Engine adapters (localhost only, supervised by substationd)

### llama-server (one per loaded model)
```
llama-server --model <gguf> --alias <name> --host 127.0.0.1 --port 89xx \
  --alias <name> -c <ctx> --cache-reuse 256 --flash-attn [-ngl 99] \
  [--rpc <peer:50052,...> --tensor-split <w0,w1>] --metrics
```
Used endpoints: `GET /health` ({"status":"ok"|"loading"}),
`POST /v1/chat/completions` (SSE), `POST /completion` (`token_probs:true` for
token inspection), `GET /props`, `GET /metrics` (Prometheus text — parse
`llama:.*` counters: keep_alive/vocab, mean/p50/p95/p99 eval seconds,
`llama:decode_tokens`, `llama:decode_seconds`, `llama:prompt_tokens`…),
`GET /slots`.

### rpc-server (one per node, cluster only) — llama.cpp GGML RPC
```
rpc-server --host 0.0.0.0 --port 50052   # on each cluster node
```
Controller starts split models by passing all participant `--rpc` endpoints to
llama-server; `--tensor-split` weights layer distribution per device. The
controller treats the split model like any engine (same /v1 API) — splitting
is a placement concern, invisible to clients (transparency invariant).

### triage engine (always resident)
Small GGUF (default `Qwen2.5-1.5B-Instruct-Q4_K_M`) llama-server on
`127.0.0.1:8931`. Controller posts a compact classification prompt with
`response_format:{"type":"json_object"}`, temp 0, ≤40 tokens; must return
`{"tier":"fast"|"balanced"|"smart","confidence":0..1,"signals":[...]}` in
<250 ms, else heuristic fallback (length/code/keywords).

### Token inspection passthrough (v1, read-only)
`GET /api/inspect/{request_id}?topk=8` → per-step top-k token probabilities
captured when the request ran with `token_probs` (opt-in `?inspect=1`).

## 3. Node agent (`substationd --role node`, default :8801)

Same binary, node role. Bearer-authed:
- `GET /api/node/health` → {ram_used_gb, ram_total_gb, gpu_pct, runners:[{model,port,state,tok_s}], rpc_up:bool}
- `POST /api/node/runner/spawn` {model, port, rpc:[], tensor_split:[]} → spawn llama-server
- `POST /api/node/runner/kill` {model}
- `POST /api/node/rpc/start` | `/api/node/rpc/stop`
Controller polls node health every 2s; spawns runners remotely for placement.

## 4. Config — see config/substation.toml

## 5. Chat API (desktop app + dashboard chat tab)

Stateless at the engine layer (chat is replayed on tier switch — transparency
invariant); the DAEMON persists conversations for the desktop app.

- `GET /api/chat/sessions` → [{id,title,updated_at,model_hint,messages:n}]
- `POST /api/chat/sessions` {title?} → {id}
- `GET /api/chat/sessions/{id}/messages` → [{role,content,ts,tier,model,node,tok_s}]
- `POST /api/chat/sessions/{id}/send` {content, pin:"auto"|"auto-fast"|"auto-smart"|<model>} →
  streams via SSE exactly like /v1/chat/completions; persisted assistant message
  carries REAL model/node/tier (desktop app shows the tag; public API never does).
- `DELETE /api/chat/sessions/{id}` | `DELETE /api/chat/sessions/{id}/messages/{i}`
  (message delete = "keep the model focused" affordance)
- Storage: `state/conversations/<id>.json` (atomic write; configurable dir).

## 6. Discovery & join (optional clustering)

- **Discovery**: each node agent multicasts a beacon every 5s to
  `224.0.1.87:8810` (+ 255.255.255.255 broadcast): JSON
  {magic:"SUBJ", node_id, name, ip, agent_port, version, join_hash, rpc_port, secret_hash}
  where join_hash = SHA256(join_code + node_id) truncated 16 hex, and
  secret_hash = SHA256("substation-auto:" + auth_token + node_id) truncated 32 hex
  (empty when `auth_token` is empty). Decoders tolerate beacons missing the newer
  fields, so mixed daemon versions still interoperate.
- Controller lists peers: `GET /api/discovery` → [{node_id,name,ip,agent_port,
  seen_ms_ago, link:{lan_kind:"ethernet"|"wifi"|..., rtt_ms, mbps,
  tb:{reachable, rtt_ms, mbps}}}]. `tb` is the Thunderbolt (`rpc_host`) probe.
- **Join code**: `POST /api/admin/join-code` → 6-digit code (controller),
  TTL 10min. Peer joins: `POST /api/cluster/join` {controller_ip, code} (on peer's
  node agent) OR CLI `substationd join --controller <ip> --code 123456` OR UI.
  Controller validates code (constant-time), adds node, starts heartbeat,
  starts rpc-server on both ends (cluster enabled automatically).
- **Auto-discovery** (`cluster.auto_discover = true` + non-empty `auth_token`):
  the controller auto-registers any beacon whose `secret_hash` matches
  SHA256("substation-auto:" + auth_token + node_id), joining that node with no
  manual join code. Stays disabled while `auth_token` is empty (no shared secret).
  Emits `{type:"cluster.node_autojoined", data:{node, name, ip}}`.
- **Thunderbolt plumb-up** (`POST /api/cluster/{node}/plumb-thunderbolt`):
  controller returns the exact `networksetup -setmanual "Thunderbolt Bridge"
  10.99.<n>.1 255.255.255.0` command per node; executes locally for the head
  node, returns copy-paste command for the peer (or runs via peer agent if it
  runs as admin user). Then probes RTT/bandwidth over the bridge and rewrites
  link.kind=thunderbolt.
- **RDMA warnings** (event `{type:"cluster.warning", data:{node, level, code, msg}}`):
  - `rdma_unavailable`: no Thunderbolt/RDMA path detected (Wi-Fi/Ethernet only)
    → "RPC split will be TCP-bound; connect a Thunderbolt cable for RDMA."
  - `rdma_not_enabled`: TB link present but measured RTT > 1.5 ms or
    < 3 Gbps → "RDMA not enabled — llama.cpp RPC over TCP. Expect degraded
    split-model throughput." (RDMA-over-TB requires TB4/ILB2 + recent macOS.)
  - `high_latency`: rtt > 8 ms on active split placements.
  - Link probe on join and every 60s while cluster enabled.
  - **Non-Thunderbolt clustering is ALLOWED but warned heavily**: joining over
    Ethernet/Wi-Fi (or any link probing < 3 Gbps / > 8 ms) shows an amber
    warning in dashboard + menu bar and the daemon logs a loud `cluster.warning`;
    split placements remain permitted (UI shows an "unsafe link" badge and
    suggests solo placement for big models).
- **RPC cache**: `ggml-rpc-server` is ALWAYS launched without `-c/--cache`
  (no file cache → no SSD wear; matches fleet convention). If a future build
  enables caching, any request whose first RPC step hits a cold cache emits
  `{type:"engine.wait", reason:"rpc_cache_load"}` + persistent "loading weights
  over RPC" progress in dashboard/menu bar.
- **Sleep prevention while engines online**: while ≥1 llama-server is loaded,
  substationd holds an `IOKit IOPMAssertion(kIOPMAssertionTypePreventUserIdleSystemSleep)`
  and disk-sleep assertion (`PreventDiskIdle` via `IODiskArbitration`/caffeinate
  child — daemon picks IOKit natively). Released when last engine unloads/pauses;
  node agents hold the same assertion while hosting runners/rpc.

## 7. CLI (`substationd admin`, defaults to http://127.0.0.1:8800; `SUBSTATION_URL` overrides)
```
substationd admin status | metrics | events [n]
substationd admin models list | model load <name> | model unload <name>
substationd admin cluster enable | disable
substationd admin config get | config set <dotted.key> <json-value>
substationd admin pause | resume | reload
substationd admin chat "prompt" [--model auto] [--stream]   # smoke-test helper
```
CLI = thin client over the same REST endpoints the UI uses (parity by construction).

## 6. Transparency invariants (MUST hold)
1. Client-visible `model` = virtual name, always.
2. No client ever sees "model loading" errors — admission control + prefetch.
3. Session stickiness prevents quality jitter; upgrades one-way per session.
4. Real model/node/split identity only in daemon observability (WS/API/UI).
5. Split vs single-node is invisible to clients; only dashboard shows it.
