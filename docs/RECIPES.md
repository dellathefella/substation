# Substation Recipes (prebaked deployments)

A **recipe** = one TOML file that pins tiers → models (repo + quantization +
files), llama.cpp flags, per-node placement, and deployment knobs. Applying a
recipe (`substationd recipe apply solo-fast`, or the UI "Recipes" tab)
downloads missing GGUFs, writes the catalog, and hot-loads.

Recipes are modeled on `MacStudioLLMAnsiblePlaybooks` conventions (that repo
remains the fleet-wide deployment tool; Substation recipes ride the same
track vocabulary: topology, port, repo, files, deployed, conflicts).

## Bundled recipes
| id | topology | head | peer | tiers |
|----|----------|------|------|-------|
| `solo-fast` | 1 node | any | — | 1.5B / 7B (Q4_K_M) |
| `solo-large` | 1 node (256GB) | studio0 | — | 7B / 32B / 120B-class MoE (Q4/IQ4) |
| `cluster-2` | 2 nodes TB-linked | studio0 | studio1 (rpc-server, TCP, no `-c` cache) | adds split placement for models > head RAM budget |

## Recipe TOML shape
```toml
[recipe]
id = "cluster-2"
description = "Studio0 + Studio1 over Thunderbolt RPC"
[[recipe.nodes]] id = "studio0" ip = "10.0.2.172" ram_budget_gb = 230 head = true
[[recipe.nodes]] id = "studio1" ip = "10.0.4.108" ram_budget_gb = 230

[[recipe.models]]
name = "qwen2.5-7b"; tier = "balanced"; placement = "local"
repo = "ggml-org/Qwen2.5-7B-Instruct-GGUF"; file = "qwen2.5-7b-instruct-q4_k_m.gguf"
size_gb = 4.7; ctx = 8192; flags = ["--cache-reuse", "256", "--parallel", "4"]

[[recipe.models]]
name = "big-moe"; tier = "smart"; placement = "split:studio0+studio1"
repo = "..."; file = "...-IQ4_XS-0000*.gguf"   # multi-shard: point -m at shard 1
```

## Deployment knobs inherited from the Ansible repo (applied by recipe apply)
## Engine pin (ships with the app)
- **Pinned llama.cpp: `b11577` (commit `cbe28bb3cb0758f0c566a9a3561766821aeb0748`)**
  built `-DGGML_METAL=ON -DGGML_RPC=ON`; ships inside Substation.app at
  `Contents/Resources/engine/{llama-server,ggml-rpc-server,libggml-*.dylib}`.
  Version shown in dashboard/menu bar; upgrade = explicit re-pin + rebuild.
- **Pinned llama.cpp** (not a release tag) built with `-DGGML_RPC=ON` —
  Homebrew bottle ships no RPC binary (same convention as the Ansible fleet).
- **RPC**: `ggml-rpc-server` **without** `-c/--cache` (spares the SSD); TCP
  transport, TCP-probe reachability (ICMP blocked on TB link).
- **Single resident model per node** unless `conflicts:` allows co-residency;
  second resident 200 GB-class model → swap thrash. Substation enforces via
  placement budget + eviction before load.
- **Launch style**: app supervises **script-launched** helper processes
  (`run-*.sh` semantics) — avoids launchd/TCC SSD-read prompts.
- **Node prep** (opt-in via app, needs admin): `pmset -a disablesleep 1`,
  `mdutil -i off` on weights volume, `gpu_wired_limit_mb` (230 GiB on 256 GB).
- **Downloads**: HF direct with resume; `hf_transfer`-style multi-stream
  optional; weights dir per-recipe (default `~/Library/Application Support/
  Substation/models`, recipe may point at `/Volumes/SANDISK1TB`).
- **Endpoints**: bind 0.0.0.0 + bearer token on trusted LAN; head dashboard :8800.

## Coexistence with the Ansible fleet
If a track from the Ansible repo is already serving on a node (e.g. studio0
`:8083`), a recipe can declare `external = "http://10.0.2.172:8083/v1"` as a
catalog model (placement `external:<id>`) — Substation routes to it without
owning its lifecycle (health-probed, no spawn/kill).
