import Foundation

public struct CatalogModel: Sendable, Hashable {
    public var name: String
    public var gguf: String
    /// Optional directory override (drive, network share, external SSD).
    /// `dir` + `file` compose `gguf` when no explicit gguf path is given.
    /// Supports ~ expansion and $VAR/${VAR} env expansion (e.g. $VOLUME_NAME).
    public var dir: String?
    public var file: String?
    public var tier: String
    public var sizeGB: Double
    public var ctx: Int
    public var placement: String
    /// Node this model resides on (joins placement when placement is unset).
    public var node: String?
    /// Replica target nodes — one copy per node. When more than one, requests
    /// for this model load-balance across the loaded copies (least-loaded,
    /// with session affinity). Derived from the `nodes` array, else the
    /// single `node`, else empty (→ local placement).
    public var nodes: [String]
    /// True when the model is replicated across >1 node for load balancing.
    public var isReplicated: Bool { nodes.count > 1 }
    /// "local" (llama.cpp on this cluster) | "external" (already-running
    /// server on the LAN) | "remote" (cloud provider; api_key applies).
    public var kind: String
    public var baseUrl: String?
    public var apiKey: String?
    /// Model id to send upstream (defaults to the catalog name).
    public var remoteModel: String?
    /// Upstream wire protocol for external/remote: "openai" | "anthropic".
    public var proto: String
    public var flags: [String]
    /// KV-cache estimate: MB per 1k context tokens per parallel slot.
    /// 0 → estimator default (100 MB/1k/slot).
    public var kvMBPer1k: Double
    /// llama-server --parallel slots (KV replicated per slot).
    public var slots: Int
    /// Number of full-context units the `-c` pool is sized against. NOTE: with
    /// `--kv-unified`, llama.cpp treats `-c` as the PER-SEQUENCE context and
    /// sizes the shared pool to `n_parallel × per_seq` — so there is NO memory
    /// saving while keeping the full per-sequence window. Unified KV only helps
    /// when per-sequence context is deliberately reduced below the trained max.
    /// Disabled by default (`kv_unified = false`); the safe non-unified path
    /// sizes `-c = per_slot × slots` and is what ships for the 262k models.
    public var poolSlots: Int
    /// Use a single unified KV buffer shared across all slots (`--kv-unified`).
    /// OFF by default — see `poolSlots` note: it does not save memory at full
    /// context and mis-sizing it can over-allocate (pool = per_seq × parallel).
    public var kvUnified: Bool
    /// The divisor used to size the `-c` pool: under unified KV it's the pool
    /// unit count (`poolSlots`), otherwise the slot count (`slots`).
    public var kvPoolSlots: Int { kvUnified ? max(1, poolSlots) : max(1, slots) }
    /// Vision (multimodal) projector file for llama.cpp --mmproj.
    public var mmproj: String?
    /// True when the profile can accept image inputs (mmproj present).
    public var vision: Bool
    /// False = profile defined but dormant: routing skips it (RAM-lean tracks
    /// ported from the Ansible playbooks; flip `enabled = true` to activate).
    public var enabled: Bool
    /// --tensor-split weights for split placement (e.g. "1,2"); empty = even.
    public var tensorSplit: String
    /// llama.cpp `--cache-reuse`: minimum prefix tokens reused from the KV cache.
    public var cacheReuse: Int
    /// llama.cpp `--cache-ram` (MiB): the unified KV cache pool that retains
    /// prompt KV across requests/slots for reuse. -1 = no limit, 0 = disabled.
    public var cacheRamMiB: Int
    /// llama.cpp `--cache-idle-slots`: retain KV of idle slots in the unified
    /// pool so returning sessions reuse their prefix instead of re-prefilling.
    /// Only emitted when `cacheRamMiB` != 0 (requires the unified KV cache).
    public var cacheIdleSlots: Bool
    /// Reasoning model: emits `reasoning_content` before the final answer.
    /// When set and a request's `max_tokens` is below the configured
    /// `reasoning_reserve_tokens`, the pipeline raises it so the visible
    /// answer isn't starved by the thinking tokens.
    public var reasoning: Bool
}

public struct NodeStatic: Sendable, Hashable {
    public var id: String
    public var host: String
    public var agentPort: Int
    public var rpcPort: Int
    /// Host used for the RPC data plane (e.g. a Thunderbolt point-to-point IP);
    /// falls back to `host` when unset.
    public var rpcHost: String
    public var totalRamGB: Double
}

/// Immutable runtime snapshot of the effective config (read per request).
public struct ConfigSnapshot: Sendable {
    public var raw: JSONValue
    public var tree: [String: JSONValue] { raw.objectValue ?? [:] }

    public var bind: String { tree["daemon"]?["bind"]?.stringValue ?? "0.0.0.0" }
    public var port: Int { tree["daemon"]?["port"]?.intValue ?? 8800 }
    public var webuiDist: String { tree["daemon"]?["webui_dist"]?.stringValue ?? "./webui/dist" }
    public var authToken: String { tree["daemon"]?["auth_token"]?.stringValue ?? "" }
    public var sessionStickSeconds: Int { tree["daemon"]?["session_stick_seconds"]?.intValue ?? 300 }
    public var maxConcurrentRequests: Int { tree["daemon"]?["max_concurrent_requests"]?.intValue ?? 8 }
    /// Backpressure: max waiters before new requests get 429 instead of
    /// joining a queue that won't drain in reasonable time. 0 = reject all
    /// when at maxConcurrent (no queueing).
    public var maxQueued: Int { tree["daemon"]?["max_queued"]?.intValue ?? 64 }
    /// Per-session fairness: max requests one session may hold in flight
    /// (active + queued) before it gets 429'd. Anonymous requests exempt.
    public var maxPerSession: Int { tree["daemon"]?["max_per_session"]?.intValue ?? 4 }
    /// Retry-After (ms) advertised on 429 responses.
    public var admissionRetryAfterMs: Int { tree["daemon"]?["admission_retry_after_ms"]?.intValue ?? 2000 }

    public var clusterEnabled: Bool { tree["cluster"]?["enabled"]?.boolValue ?? false }
    /// False = this machine is control-plane only: no local engines, no local
    /// rpc-server, `local` placements are refused (compute lives on nodes).
    public var localEnabled: Bool { tree["cluster"]?["local_enabled"]?.boolValue ?? true }
    public var controllerId: String { tree["cluster"]?["controller_id"]?.stringValue ?? "studio0" }
    public var heartbeatMs: Int { tree["cluster"]?["heartbeat_ms"]?.intValue ?? 2000 }
    public var autoHeal: Bool { tree["cluster"]?["auto_heal"]?.boolValue ?? true }
    /// Auto-register discovered peers as nodes when they present a valid
    /// shared-secret hash (derived from daemon.auth_token). Requires a non-empty token.
    public var autoDiscover: Bool { tree["cluster"]?["auto_discover"]?.boolValue ?? false }
    public var probeBytesMB: Int { tree["cluster"]?["probe_bytes_mb"]?.intValue ?? 16 }

    public var orchestratorEnabled: Bool { tree["orchestrator"]?["enabled"]?.boolValue ?? true }
    public var triageGguf: String { ConfigSnapshot.expandPath(tree["orchestrator"]?["triage_gguf"]?.stringValue ?? "") }
    public var triagePort: Int { tree["orchestrator"]?["triage_port"]?.intValue ?? 8931 }
    public var triageTimeoutMs: Int { tree["orchestrator"]?["triage_timeout_ms"]?.intValue ?? 250 }
    public var triageUpgradeConfidence: Double { tree["orchestrator"]?["triage_upgrade_confidence"]?.doubleValue ?? 0.8 }
    public var cacheEnabled: Bool { tree["orchestrator"]?["cache_enabled"]?.boolValue ?? true }
    public var cacheMaxEntries: Int { tree["orchestrator"]?["cache_max_entries"]?.intValue ?? 256 }
    /// When a reasoning model's request `max_tokens` is below this, raise it so
    /// the visible answer isn't starved by `reasoning_content`. 0 = disabled.
    public var reasoningReserveTokens: Int { tree["orchestrator"]?["reasoning_reserve_tokens"]?.intValue ?? 0 }
    /// Size-based tier routing: a small request that triage didn't confidently
    /// mark as hard work goes to the cheap tier, reserving the flagship's
    /// slots for requests that actually need it. Only affects auto-routed
    /// (non-pinned) requests.
    public var sizeRouteEnabled: Bool { tree["orchestrator"]?["size_route_enabled"]?.boolValue ?? true }
    /// A request whose estimated context need is <= this many tokens counts as
    /// "small" for size-based tier routing.
    public var smallRequestTokens: Int { tree["orchestrator"]?["small_request_tokens"]?.intValue ?? 256 }
    /// The tier small requests are routed to.
    public var smallRequestTier: String { tree["orchestrator"]?["small_request_tier"]?.stringValue ?? "fast" }
    /// Model to use when auto routing but the orchestrator/triage model is unavailable.
    /// Empty → smallest catalog model.
    public var defaultModel: String { tree["orchestrator"]?["default_model"]?.stringValue ?? "" }
    /// Load only the orchestrator (triage) model at startup; big tiers load on demand.
    public var idleLoadOnly: Bool { tree["orchestrator"]?["idle_load_only"]?.boolValue ?? true }
    public var startOnLogin: Bool { tree["daemon"]?["start_on_login"]?.boolValue ?? false }

    public var llamaServer: String { Self.expandPath(tree["engines"]?["llama_server"]?.stringValue ?? "llama-server") }
    public var rpcServer: String { Self.expandPath(tree["engines"]?["rpc_server"]?.stringValue ?? "rpc-server") }
    public var basePort: Int { tree["engines"]?["base_port"]?.intValue ?? 8940 }
    public var startupTimeoutS: Int { tree["engines"]?["startup_timeout_s"]?.intValue ?? 180 }
    public var idleEvictSeconds: Int { tree["engines"]?["idle_evict_seconds"]?.intValue ?? 900 }
    public var minFreeRamGB: Double { tree["engines"]?["min_free_ram_gb"]?.doubleValue ?? 8 }
    /// Reserve this much RAM for macOS and let the GPU have the rest. When > 0
    /// it overrides the kernel's `iogpu.wired_limit_mb` for the guard's
    /// budget — but never above what the kernel will actually wire (the guard
    /// clamps to the real sysctl so an un-raised limit can't cause an OOM).
    /// To unlock the full value the operator must also raise the sysctl:
    ///   sudo sysctl -w iogpu.wired_limit_mb=<GB*1024>
    public var macosReserveGB: Double { tree["engines"]?["macos_reserve_gb"]?.doubleValue ?? 0 }
    public var defaultCtx: Int { tree["engines"]?["default_ctx"]?.intValue ?? 8192 }

    public var metricsSampleMs: Int { tree["metrics"]?["sample_interval_ms"]?.intValue ?? 1000 }
    public var eventRingSize: Int { tree["metrics"]?["event_ring_size"]?.intValue ?? 2000 }
    public var wsTickBatchMs: Int { tree["metrics"]?["ws_tick_batch_ms"]?.intValue ?? 250 }

    public var agentPort: Int { tree["node"]?["agent_port"]?.intValue ?? 8801 }
    public var rpcPort: Int { tree["node"]?["rpc_port"]?.intValue ?? 50052 }

    public var tiers: [String: [String]] {
        var out: [String: [String]] = [:]
        if let tiers = tree["orchestrator"]?["tiers"]?.objectValue {
            for (tier, v) in tiers {
                out[tier] = v["models"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            }
        }
        return out
    }

    /// Tier priority: lower = lighter/cheaper. Built-in trio keeps its
    /// historic order when `priority` is unset.
    public func tierPriority(_ name: String) -> Int {
        if let p = tree["orchestrator"]?["tiers"]?[name]?["priority"]?.intValue { return p }
        switch name {
        case "fast": return 0
        case "balanced": return 1
        case "smart": return 2
        default: return 1
        }
    }

    /// Tier names ordered lightest → heaviest (priority, then name).
    public var tierNames: [String] {
        tiers.keys.sorted { a, b in
            let pa = tierPriority(a), pb = tierPriority(b)
            return pa == pb ? a < b : pa < pb
        }
    }

    public func tierRank(_ name: String) -> Int { tierNames.firstIndex(of: name) ?? 1 }

    public func tierDesc(_ name: String) -> String {
        tree["orchestrator"]?["tiers"]?[name]?["desc"]?.stringValue ?? ""
    }

    public var modelsDir: String { Self.expandPath(tree["engines"]?["models_dir"]?.stringValue ?? "./models") }

    public var models: [CatalogModel] {
        tree["models"]?.arrayValue?.compactMap { m in
            guard let name = m["name"]?.stringValue else { return nil }
            let kind = m["kind"]?.stringValue ?? "local"
            let dirRaw = m["dir"]?.stringValue
            let dir = dirRaw.map { Self.expandPath($0) }
            let file = m["file"]?.stringValue
            let rawGguf = m["gguf"]?.stringValue
            var gguf = ""
            if kind == "local" {
                if let dir, let file {
                    gguf = dir + "/" + file
                } else if let rawGguf {
                    let expanded = Self.expandPath(rawGguf)
                    if expanded.hasPrefix("/") {
                        gguf = expanded
                    } else if FileManager.default.fileExists(atPath: expanded) {
                        gguf = expanded  // already resolvable relative to cwd
                    } else {
                        gguf = modelsDir + "/" + expanded
                    }
                } else if let dir {
                    gguf = dir + "/" + name + ".gguf"
                } else {
                    gguf = modelsDir + "/" + name + ".gguf"
                }
                gguf = Self.normalize(gguf)
            } else if let rawGguf {
                gguf = Self.normalize(Self.expandPath(rawGguf))
            }
            return CatalogModel(
                name: name,
                gguf: gguf,
                dir: dir,
                file: file,
                tier: m["tier"]?.stringValue ?? "balanced",
                sizeGB: m["size_gb"]?.doubleValue ?? 4,
                ctx: m["ctx"]?.intValue ?? defaultCtx,
                placement: m["placement"]?.stringValue
                    ?? (m["node"]?.stringValue.map { $0.isEmpty || $0 == "local" ? "local" : "node:\($0)" } ?? "local"),
                node: m["node"]?.stringValue,
                nodes: m["nodes"]?.arrayValue?.compactMap { $0.stringValue }
                    ?? (m["node"]?.stringValue.map { [$0] } ?? []),
                kind: kind,
                baseUrl: m["base_url"]?.stringValue.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 },
                apiKey: m["api_key"]?.stringValue,
                remoteModel: m["model"]?.stringValue ?? m["remote_model"]?.stringValue,
                proto: m["protocol"]?.stringValue ?? "openai",
                flags: m["flags"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
                kvMBPer1k: m["kv_mb_per_1k_ctx"]?.doubleValue ?? 0,
                slots: m["parallel_slots"]?.intValue ?? 4,
                poolSlots: m["pool_slots"]?.intValue ?? 4,
                kvUnified: m["kv_unified"]?.boolValue ?? false,
                mmproj: m["mmproj"]?.stringValue.map { Self.normalize(Self.expandPath($0)) },
                vision: m["vision"]?.boolValue ?? ((m["mmproj"]?.stringValue) != nil),
                enabled: m["enabled"]?.boolValue ?? true,
                tensorSplit: (m["tensor_split"]?.stringValue ?? "")
                    .replacingOccurrences(of: " ", with: ""),
                cacheReuse: m["cache_reuse"]?.intValue ?? 256,
                cacheRamMiB: m["cache_ram_mib"]?.intValue ?? 8192,
                cacheIdleSlots: m["cache_idle_slots"]?.boolValue ?? true,
                reasoning: m["reasoning"]?.boolValue ?? false
            )
        } ?? []
    }

    public func model(_ name: String) -> CatalogModel? {
        models.first { $0.name == name }
    }

    /// ~ and $VAR/${VAR} expansion for model paths (drives, network shares).
    public static func expandPath(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var s = raw
        if s == "~" {
            s = NSHomeDirectory()
        } else if s.hasPrefix("~/") {
            s = NSHomeDirectory() + String(s.dropFirst(1))
        }
        let env = ProcessInfo.processInfo.environment
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "$" {
                var j = s.index(after: i)
                var name = ""
                var braced = false
                if j < s.endIndex, s[j] == "{" { braced = true; j = s.index(after: j) }
                while j < s.endIndex {
                    let c = s[j]
                    if c == "}" && braced { j = s.index(after: j); break }
                    if c == "}" || !(c.isLetter || c.isNumber || c == "_") { break }
                    name.append(c)
                    j = s.index(after: j)
                }
                if !name.isEmpty, let v = env[name] { out += v; i = j; continue }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    static func normalize(_ p: String) -> String {
        var r = p
        while r.contains("//") { r = r.replacingOccurrences(of: "//", with: "/") }
        return r.hasSuffix("/") ? String(r.dropLast()) : r
    }

    public var nodes: [NodeStatic] {
        (tree["nodes"]?.objectValue ?? [:]).map { id, v in
            NodeStatic(
                id: id,
                host: v["host"]?.stringValue ?? "",
                agentPort: v["agent_port"]?.intValue ?? 8801,
                rpcPort: v["rpc_port"]?.intValue ?? 50052,
                rpcHost: v["rpc_host"]?.stringValue ?? (v["host"]?.stringValue ?? ""),
                totalRamGB: v["total_ram_gb"]?.doubleValue ?? 0
            )
        }
        .sorted { $0.id < $1.id }
    }

    public func node(_ id: String) -> NodeStatic? {
        if id == "local" || id == "self" { return nil }
        if let n = nodes.first(where: { $0.id == id || $0.host == id }) { return n }
        return NodeStatic(id: id, host: id, agentPort: agentPort, rpcPort: rpcPort, rpcHost: id, totalRamGB: 0)
    }
}

/// Mutable config store. Loads the TOML, exposes snapshots, applies partial
/// JSON patches (deep-merge), persists, and re-derives the snapshot.
public actor ConfigStore {
    public private(set) var snapshot: ConfigSnapshot
    private let path: String
    private var watchers: [@Sendable (ConfigSnapshot) -> Void] = []

    public init(path: String) throws {
        self.path = path
        var tree = JSONValue.object([:])
        if let data = FileManager.default.contents(atPath: path),
             let text = String(data: data, encoding: .utf8)
        {
            tree = TOML.parse(text)
        }
        self.snapshot = ConfigSnapshot(raw: tree)
    }

    public func reload() throws {
        if let data = FileManager.default.contents(atPath: path),
             let text = String(data: data, encoding: .utf8)
        {
            snapshot = ConfigSnapshot(raw: TOML.parse(text))
        }
    }

    /// Apply a partial patch. Returns the changed top-level-ish key paths.
    public func applyPatch(_ patch: JSONValue) throws -> [String] {
        snapshot = ConfigSnapshot(raw: deepMerge(snapshot.raw, patch))
        try? TOML.write(snapshot.raw).write(toFile: path, atomically: true, encoding: .utf8)
        let keys = patch.objectValue?.keys.sorted().map { $0 } ?? []
        for w in watchers { w(snapshot) }
        return keys
    }

    /// Set a dotted key path (used by `admin config set`).
    public func setDotted(_ path: String, _ value: JSONValue) throws -> [String] {
        let parts = path.split(separator: ".").map(String.init)
        snapshot = ConfigSnapshot(raw: Self.setPath(snapshot.raw, parts, value))
        try? TOML.write(snapshot.raw).write(toFile: self.path, atomically: true, encoding: .utf8)
        let keys = [path]
        for w in watchers { w(snapshot) }
        return keys
    }

    public func addWatcher(_ w: @escaping @Sendable (ConfigSnapshot) -> Void) {
        watchers.append(w)
    }

    /// Remove a dotted key path (e.g. nodes.studio0). Returns whether it existed.
    @discardableResult
    public func removePath(_ path: String) -> Bool {
        let parts = path.split(separator: ".").map(String.init)
        let (next, removed) = Self.removePathInner(snapshot.raw, parts)
        snapshot = ConfigSnapshot(raw: next)
        try? TOML.write(snapshot.raw).write(toFile: self.path, atomically: true, encoding: .utf8)
        if removed { for w in watchers { w(snapshot) } }
        return removed
    }

    /// Reset the entire tree to `tree` (defaults) and persist.
    public func reset(to tree: JSONValue) throws {
        snapshot = ConfigSnapshot(raw: tree)
        try TOML.write(snapshot.raw).write(toFile: path, atomically: true, encoding: .utf8)
        for w in watchers { w(snapshot) }
    }

    private static func setPath(_ v: JSONValue, _ parts: [String], _ value: JSONValue) -> JSONValue {
        guard let first = parts.first else { return value }
        var obj = v.objectValue ?? [:]
        if parts.count == 1 {
            obj[first] = value
        } else {
            obj[first] = setPath(obj[first] ?? .object([:]), Array(parts.dropFirst()), value)
        }
        return .object(obj)
    }

    private static func removePathInner(_ v: JSONValue, _ parts: [String]) -> (JSONValue, Bool) {
        guard let first = parts.first else { return (v, false) }
        var obj = v.objectValue ?? [:]
        if parts.count == 1 {
            let had = obj[first] != nil
            obj[first] = nil
            return (.object(obj), had)
        }
        if obj[first] != nil {
            let (child, removed) = removePathInner(obj[first]!, Array(parts.dropFirst()))
            obj[first] = child
            return (.object(obj), removed)
        }
        return (.object(obj), false)
    }
}
