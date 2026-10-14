# Substation

Local-first AI compute. One Mac — or an optional Mac cluster — that **automatically**
loads and runs the right model for every request, orchestrated by a small triage
model on the head node, with a web console and a menu-bar app for real-time insight.

Everything runs on your own hardware. No cloud, no per-token billing.

---

## What it does

- **Auto-routing** — every request is triaged and sent to the right model tier
  (`fast` / `balanced` / `smart`) without you picking a model.
- **Model management** — download, cache, hot-load, and unload GGUF models on demand.
- **Cluster-aware** — run a controller on one Mac and node agents on others; the
  controller places engines where there is room (RAM/VRAM) and can split layers over
  Thunderbolt RPC.
- **OpenAI-compatible** — point any OpenAI client at `http://<host>:8800/v1`.
- **Web console** — live dashboard for engines, models, nodes, memory, and logs.
- **Menu-bar app** — a single macOS `.app` that bundles and supervises the daemon.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  Substation.app (menu bar)  ── supervises ──▶  substationd     │
│                                               (control plane) │
│   • OpenAI-compatible API  • triage → tier → route → schedule  │
│   • model catalog / cache  • metrics + WebSocket  • webui      │
└───────────────┬───────────────────────────┬──────────────────┘
                │ spawns / supervises          │ places on remote nodes
                ▼                            ▼
        ┌───────────────┐            ┌──────────────────┐
        │ llama-server  │            │  node agent       │  (other Macs)
        │ (Metal GGUF)  │            │  (substationd     │
        └───────────────┘            │   --role node)    │
                                   └──────────────────┘
```

- **`substationd`** — the control-plane daemon. Public API, orchestration, catalog,
  metrics, and the web console. Runs as `controller` (default) or `node`.
- **llama.cpp engines** — `llama-server` (one loaded GGUF per process) and
  `rpc-server` (layer-split worker), supervised by the daemon.
- **Consumers** — the web console, the menu-bar app, and any OpenAI client.

See [`docs/PRODUCT.md`](docs/PRODUCT.md), [`docs/PROTOCOL.md`](docs/PROTOCOL.md),
and [`docs/RECIPES.md`](docs/RECIPES.md) for the full design.

---

## Requirements

- macOS 13 (Ventura) or later, Apple Silicon (arm64).
- Enough RAM/VRAM for the models you load (a 35B Q4 model needs ~24 GB+).
- For clusters: Macs reachable over the network; Thunderbolt is recommended for RPC.

## Install (DMG)

1. Download `Substation-<version>.dmg` and open it.
2. Drag **Substation** to **Applications**.
3. Launch **Substation** from Applications (or Spotlight).

> The app is ad-hoc signed. If Gatekeeper blocks it, right-click → **Open** the
> first time, or run `xattr -dr com.apple.quarantine /Applications/Substation.app`.

### First run

On first launch the menu-bar app starts the bundled daemon against
`~/Library/Application Support/Substation/` (state, models, logs, `config.toml`).

- **Web console:** <http://127.0.0.1:8800>
- **OpenAI endpoint:** `http://127.0.0.1:8800/v1`

Open the menu-bar menu to see engine status, load models, and toggle **Launch at Login**.

---

## Using it

### OpenAI-compatible API

```bash
curl http://127.0.0.1:8800/v1/chat/completions \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "auto",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": true
  }'
```

- `"model": "auto"` lets the orchestrator pick the tier.
- Name a specific model (e.g. `"qwen3.5-35b-a3b"`) to pin it.
- The token is set in `daemon.auth_token` (config) or `SUBSTATION_TOKEN` (env).

### Web console

Open <http://127.0.0.1:8800> to watch engines, models, nodes, memory, and logs in
real time, and to load/unload models.

### Menu-bar app

Click the menu-bar icon for a live summary, quick model controls, and settings
(controller URL, launch-at-login).

---

## Configuration

The controller reads a TOML file (`config/controller.toml` for a deployed
controller, or `~/Library/Application Support/Substation/config.toml` for the
bundled app). Key sections:

```toml
[daemon]
auth_token = "..."          # API bearer token
startup_timeout_s = 180     # fail fast if a model won't load

[tiers]
fast     = ["qwen3.5-35b-a3b"]
balanced = ["ornith-1.5-35b"]
smart    = ["qwen3.8-flash-next", "glm-5.3-flash"]

[models.qwen3.5-35b-a3b]
path = "/path/to/Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf"
ctx  = 262144

[nodes.studio0]
host     = "192.168.7.248"     # agent / LAN
rpc_host = "192.168.100.1"     # engine RPC / Thunderbolt
```

- **`host`** is where the node agent is reached (LAN).
- **`rpc_host`** is where engine RPC workers are reached (Thunderbolt), keeping
  layer-split traffic off the LAN.
- Keep `ctx` consistent across models in the same family so the KV cache is
  homogeneous and predictable.

---

## Clusters (controller + nodes)

Run the controller on the head Mac and a node agent on each worker:

```bash
# head node
substationd --role controller --config controller.toml --data ~/substation-controller/state

# each worker
substationd --role node --config node.toml --data ~/substation-node/state
```

The controller discovers nodes from `[nodes.*]` and places engines on them.

---

## Uninstall

Use the scripts in [`scripts/`](scripts/):

```bash
# Remove the macOS app, its daemon, launch agent, and (optionally) its data
./scripts/uninstall-app.sh

# Remove a controller/node daemon from a Mac (e.g. over SSH)
./scripts/uninstall-daemon.sh --role controller
```

Both support `--dry-run` (preview), `--keep-data` (leave state/models/config), and
`--yes` (no confirmation). See the script headers for details.

---

## Development

```bash
# Build the daemon + menu-bar app + webui, then package the DMG
./packaging/make-app.sh

# Smoke test against fake engines
./scripts/smoke-test.sh
```

The DMG is written to `build/Substation-<version>.dmg`.

## Troubleshooting

- **App won't open (Gatekeeper):** right-click → Open, or clear the quarantine xattr
  (see Install above).
- **Port already in use:** another `substationd` or engine is running. Find it with
  `lsof -i :8800` and stop it, or change the port in config.
- **Model won't load:** check the **Logs** tab in the web console
  (`state/logs/controller.log` / `agent.log`). `startup_timeout_s` bounds how long
  a load may take before it is marked failed.
- **Reasoning models look empty:** some models (e.g. Qwen3.5) fill
  `reasoning_content` before final `content`; raise `max_tokens`.

## License

See the repository for license terms.
