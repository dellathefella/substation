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
}

public struct NodeStatic: Sendable, Hashable {
    public var id: String
    public var host: String
    public var agentPort: Int
    public var rpcPort: Int
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

    public var clusterEnabled: Bool { tree["cluster"]?["enabled"]?.boolValue ?? false }
    public var controllerId: String { tree["cluster"]?["controller_id"]?.stringValue ?? "studio0" }
    public var heartbeatMs: Int { tree["cluster"]?["heartbeat_ms"]?.intValue ?? 2000 }
    public var probeBytesMB: Int { tree["cluster"]?["probe_bytes_mb"]?.intValue ?? 16 }

    public var orchestratorEnabled: Bool { tree["orchestrator"]?["enabled"]?.boolValue ?? true }
    public var triageGguf: String { ConfigSnapshot.expandPath(tree["orchestrator"]?["triage_gguf"]?.stringValue ?? "") }
    public var triagePort: Int { tree["orchestrator"]?["triage_port"]?.intValue ?? 8931 }
    public var triageTimeoutMs: Int { tree["orchestrator"]?["triage_timeout_ms"]?.intValue ?? 250 }
    public var triageUpgradeConfidence: Double { tree["orchestrator"]?["triage_upgrade_confidence"]?.doubleValue ?? 0.8 }
    public var cacheEnabled: Bool { tree["orchestrator"]?["cache_enabled"]?.boolValue ?? true }
    public var cacheMaxEntries: Int { tree["orchestrator"]?["cache_max_entries"]?.intValue ?? 256 }
    /// Model to use when auto routing but the orchestrator/triage model is unavailable.
    /// Empty → smallest catalog model.
    public var defaultModel: String { tree["orchestrator"]?["default_model"]?.stringValue ?? "" }
    /// Load only the orchestrator (triage) model at startup; big tiers load on demand.
    public var idleLoadOnly: Bool { tree["orchestrator"]?["idle_load_only"]?.boolValue ?? true }
    public var startOnLogin: Bool { tree["daemon"]?["start_on_login"]?.boolValue ?? false }

    public var llamaServer: String { tree["engines"]?["llama_server"]?.stringValue ?? "llama-server" }
    public var rpcServer: String { tree["engines"]?["rpc_server"]?.stringValue ?? "rpc-server" }
    public var basePort: Int { tree["engines"]?["base_port"]?.intValue ?? 8940 }
    public var startupTimeoutS: Int { tree["engines"]?["startup_timeout_s"]?.intValue ?? 180 }
    public var idleEvictSeconds: Int { tree["engines"]?["idle_evict_seconds"]?.intValue ?? 900 }
    public var minFreeRamGB: Double { tree["engines"]?["min_free_ram_gb"]?.doubleValue ?? 8 }
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
                kind: kind,
                baseUrl: m["base_url"]?.stringValue.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 },
                apiKey: m["api_key"]?.stringValue,
                remoteModel: m["model"]?.stringValue ?? m["remote_model"]?.stringValue,
                proto: m["protocol"]?.stringValue ?? "openai",
                flags: m["flags"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
                kvMBPer1k: m["kv_mb_per_1k_ctx"]?.doubleValue ?? 0,
                slots: m["parallel_slots"]?.intValue ?? 4
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
                totalRamGB: v["total_ram_gb"]?.doubleValue ?? 0
            )
        }
        .sorted { $0.id < $1.id }
    }

    public func node(_ id: String) -> NodeStatic? {
        if id == "local" || id == "self" { return nil }
        if let n = nodes.first(where: { $0.id == id || $0.host == id }) { return n }
        return NodeStatic(id: id, host: id, agentPort: agentPort, rpcPort: rpcPort, totalRamGB: 0)
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
