import Foundation

/// Factory config template restored by POST /api/admin/reset-config.
public enum ConfigDefaults {
    public static let toml = """
    [daemon]
    bind = "127.0.0.1"
    port = 8800
    webui_dist = "./webui/dist"
    auth_token = ""
    session_stick_seconds = 300
    max_concurrent_requests = 8

    [cluster]
    enabled = false
    controller_id = "local"
    heartbeat_ms = 2000
    auto_heal = true

    [orchestrator]
    # Auto-router: triage model classifies each request into fast/balanced/smart.
    # Set false to disable routing: every auto/auto-fast/auto-smart request then
    # goes to default_model (or the only catalog model) — single-model mode.
    enabled = true
    triage_gguf = "models/qwen2.5-0.5b-instruct-q4_k_m.gguf"
    triage_port = 8931
    triage_timeout_ms = 400
    triage_upgrade_confidence = 0.8
    cache_enabled = true
    cache_max_entries = 256

    [orchestrator.tiers.fast]
    models = ["qwen2.5-1.5b"]
    priority = 0
    [orchestrator.tiers.balanced]
    models = ["qwen2.5-7b"]
    priority = 1
    [orchestrator.tiers.smart]
    models = ["qwen2.5-7b"]
    priority = 2

    [engines]
    llama_server = "./third_party/llama.cpp/build/bin/llama-server"
    rpc_server = "./third_party/llama.cpp/build/bin/ggml-rpc-server"
    base_port = 8940
    startup_timeout_s = 300
    idle_evict_seconds = 900
    min_free_ram_gb = 8
    default_ctx = 8192

    [metrics]
    sample_interval_ms = 1000
    event_ring_size = 2000
    ws_tick_batch_ms = 250

    # Model profile: node = home for non-RPC models (exactly one node, e.g.
    # node = "studio0"). placement = "local" | "node:<id>" | "split[:id+id…]".
    # A bare "split" RPC profile spans the head plus every eligible joined
    # node; weights stream head→workers over RPC without worker-side caching.
    # flags = extra llama-server arguments appended verbatim.
    [[models]]
    name = "qwen2.5-1.5b"
    gguf = "models/qwen2.5-1.5b-instruct-q4_k_m.gguf"
    tier = "fast"
    size_gb = 1.1
    ctx = 4096
    placement = "local"
    # node = "local"
    # flags = ["--no-mmap", "--flash-attn"]

    [[models]]
    name = "qwen2.5-7b"
    gguf = "models/qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf"
    tier = "balanced"
    size_gb = 4.7
    ctx = 4096
    placement = "local"
    """
}
