# Substation Wire Protocol v2 (llama.cpp backend)

Layers:
- **substationd** (Rust control plane): public OpenAI-compatible API, orchestration
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

### Admin/observability
- `GET /api/status` → {state, uptime_s, requests_active, requests_per_min,
  tokens_per_sec, models_loaded, models_total, nodes[]}
- `GET /api/metrics` → counters, percentiles (ttft_ms, total_ms, tok_s per
  tier/model/node), queue depth, cache hit ratio, triage distribution, memory.
- `GET /api/events?limit=200` → recent routing log (newest first).
- `GET /api/models` | `POST /api/models/{name}/load` | `POST /api/models/{name}/unload`
- `GET /api/nodes` → cluster nodes: health, ram, gpu, runners, rpc peers.
- `POST /api/admin/pause` | `/api/admin/resume` | `/api/admin/reload`
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
Small GGUF (default `Qwen2.5-0.5B-Instruct-Q4_K_M`) llama-server on
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

## 5. Transparency invariants (MUST hold)
1. Client-visible `model` = virtual name, always.
2. No client ever sees "model loading" errors — admission control + prefetch.
3. Session stickiness prevents quality jitter; upgrades one-way per session.
4. Real model/node/split identity only in daemon observability (WS/API/UI).
5. Split vs single-node is invisible to clients; only dashboard shows it.
