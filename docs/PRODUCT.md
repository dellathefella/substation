# Substation — Product Brief

Local-first AI compute: one Mac (or a cluster of Macs) that **automatically**
loads and runs the right model for every request, orchestrated by a small
triage model, with a web console for real-time insight.

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
| Transparent model switching (`auto`) | v1 | triage model tier → router → llama-server |
| Real-time metrics web console | v1 | daemon /ws → React dashboard |
| Cluster (2+ Macs) | v1 | llama.cpp GGML RPC (`rpc-server` + `--rpc --tensor-split`) |
| Model load/evict/prefetch | v1 | engine manager, LRU + memory pressure |
| Prompt/prefix caching | v1 | llama-server `--cache-reuse` + daemon response cache |
| OpenAI-compatible API | v1 | daemon proxy over llama-server |
| Token inspection (probs/top-k alts) | v1 | llama-server `/completion` `token_probs` surfaced in UI |
| Triage/orchestrator model | v1 | persistent small llama-server, JSON mode |
| Menu bar mini-monitor | v1 | Swift SPM app |
| HF model browser + downloader | v1.5 | daemon-managed GGUF catalog |
| Tools/function calling | v1.5 | llama-server tool parsing passthrough |
| Coding-tool presets (Xcode/VS Code) | v1.5 | server settings + SSL option |
| Chat UI with per-message model tags | v1.5 | dashboard chat tab, history replay on tier switch |
| Multimodal (image/audio) | v2 | llama.cpp mmproj adapters |
| Prefill/response control passthrough | v2 | infill endpoints |
| Shortcuts automation | v2 | URL scheme |

## Hard requirements (from user)
1. Orchestrator model optimizes intelligence AND speed.
2. Clustering with a second machine — llama.cpp RPC for layer-split.
3. WebUI: metrics + real-time insight into operations.
4. Model switching transparent to clients.
5. Baseline: app runs standalone on studio0 and studio1.
