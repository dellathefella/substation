# Substation — Product Brief

Local-first AI compute: one Mac (or an optional Mac cluster) that **automatically**
loads and runs the right model for every request, orchestrated by a small
triage model on the head node, with a web console for real-time insight.
**Final deliverable: a single macOS app** (`Substation.app`) whose menu bar UI
bundles and supervises the Rust control-plane daemon (helper binary) and the
llama.cpp engine binaries.

## Core: Auto mode
- A **small head-node model** (triage/orchestrator model, always resident)
  reads each request's context and dynamically **routes, loads, and switches**
  between smaller and smarter models — tier selection is per-request,
  context-aware (window pressure, code/complexity signals, session history).
- **Configurable context window** (`default_ctx`, per-model `ctx`) governs
  headroom and when context pressure forces tier escalation or eviction.
- **Small models download** to local disk and load directly (llama-server).
- **Large models require RPC streaming**: placed on cluster peers / split via
  llama.cpp GGML RPC (`rpc-server` + `--rpc --tensor-split`) when they don't
  fit the head node. Clustering is OPTIONAL — standalone mode fully works with
  the head node's own models.

## Prompt cache system (concurrency)
- llama.cpp prefix cache per engine: `--cache-reuse` (prefix match reuse) +
  `--parallel N` shared KV slots → concurrent sessions sharing a prefix skip
  re-prefill; big TTFT win for agents/tool loops and chat continuations.
- Session affinity pins a session to the engine+slot so its cached prefix is
  reused (upgrade = replay, see transparency invariants).
- Daemon response cache (LRU, configurable pool: max entries/bytes) in front.
- Dashboard surfaces cache hit ratio, prefix reuse depth, slot utilization.

## Inspiration & differentiation (vs Inferencer)
Inferencer proves the market: local SOTA models on Mac, Mac-to-Mac distributed
compute, OpenAI-compat APIs for coding tools, prompt caching, token inspection.
Substation's core difference: **model selection is machine-decided, not
user-decided**. Clients call `auto`; the orchestrator routes by
intelligence-per-watt-per-µs. Everything Inferencer does manually,
Substation does automatically, and exposes WHY via the dashboard.

## Feature map (v1 = build now, v1.5 = fast follow, v2 = later)
| Feature | Status | How |
|---|---|---|
| **Auto mode** (head-node small model: route/load/switch by context) | v1 | triage llama-server (resident) → tier → router → engine |
| Configurable context window | v1 | `default_ctx` + per-model `ctx`; window pressure feeds escalation |
| Transparent model switching (`auto`) | v1 | response.model always echoes virtual name |
| **Prompt cache** (prefix reuse, concurrency) | v1 | `--cache-reuse` + `--parallel` slots + daemon LRU + affinity |
| Real-time metrics web console | v1 | daemon /ws → React dashboard |
| Optional cluster + **RPC streaming for large models** | v1 | GGML RPC `rpc-server` + `--rpc --tensor-split`; off by default |
| Model download (small/local) | v1 | HF downloader for catalog GGUFs → models/ |
| Menu bar mini-monitor | v1 | Substation.app: Swift UI + Rust helper binary |
| **Desktop chat app** (chat + model switching) | v1 | SwiftUI window in Substation.app; `auto` chats tagged with real model/node per message; pin/switch tiers per chat |
| **Auto-discovery + join codes** | v1 | UDP beacon/mDNS on LAN; 6-digit join code; one-click pair two nodes |
| **Thunderbolt link plumb-up** | v1 | detect bridge0/en1-3, guided + scripted `networksetup -setmanual` both ends, link probe |
| **RDMA warnings** | v1 | probe RTT/bandwidth + TB/RDMA heuristics; warn "RDMA not enabled" when cluster runs TCP-bound |
| Token inspection (probs/top-k) | v1 | /completion token_probs passthrough → UI |
| Tools/function calling | v1.5 | llama-server tool parsing passthrough |
| Coding-tool presets (Xcode/VS Code) | v1.5 | server settings + SSL option |
| Multimodal / prefill control / Shortcuts | v2 | mmproj / infill / URL scheme |

## Hard requirements (from user)
1. Orchestrator model optimizes intelligence AND speed.
2. Clustering with a second machine — **optional**; RPC for large models when on.
3. WebUI: metrics + real-time insight into operations.
4. Model switching transparent to clients.
5. Baseline: app runs standalone on studio0 and studio1.
6. All options configurable via UI, CLI, and config file.

## Auto-router switch (single-model mode)

`orchestrator.enabled = false` disables triage/tiers/stickiness. Every
`auto`/`auto-fast`/`auto-smart` request routes straight to
`orchestrator.default_model` (or the only catalog model) with the usual
placement + RPC resource checks; `/api/status` reports
`auto_router:"disabled"` and the menu bar shows a neutral "Auto-router
disabled" banner instead of the degraded warning. Toggle via WebUI
Settings, `substationd admin config set orchestrator.enabled false`, or MCP.

## Model profile (catalog) fields

| field | meaning |
|---|---|
| `name` | catalog name (real model; hidden from clients) |
| `gguf` or `dir`+`file` | weights path; `~` and `$VAR` expanded; any drive/network share |
| `tier` | fast / balanced / smart |
| `size_gb`, `ctx`, `kv_mb_per_1k_ctx`, `parallel_slots` | resource estimate inputs |
| `node` | non-RPC home node — a non-RPC profile covers exactly ONE node (`node = "studio0"`) |
| `placement` | `local` \| `node:<id>` \| `split[:id+id…]`; a bare `split` RPC profile spans the head plus every eligible (healthy, joined) node — one profile can cover 2+ nodes |
| `flags` | extra llama-server arguments, appended verbatim (last flag wins) |

RPC (`split:`) profiles stream weights head→workers over GGML RPC; worker
`ggml-rpc-server`s run WITHOUT `-c`, so weights are never cached on workers.
