import Foundation

// All response models are tolerant: every field is optional so a partial or
// differently-shaped daemon payload never crashes the menu bar app.

struct StatusResponse: Codable, Sendable {
    let state: String?
    let uptimeSec: Double?
    let requestsActive: Int?
    let requestsPerMin: Double?
    let tokensPerSec: Double?
    let modelsLoaded: Int?
    let modelsTotal: Int?
    let models: [StatusModel]?
    let nodes: [StatusNode]?
    let autoAvailable: Bool?
    let orchestratorUp: Bool?
    let defaultModel: String?

    enum CodingKeys: String, CodingKey {
        case state, models, nodes
        case uptimeSec = "uptime_s"
        case requestsActive = "requests_active"
        case requestsPerMin = "requests_per_min"
        case tokensPerSec = "tokens_per_sec"
        case modelsLoaded = "models_loaded"
        case modelsTotal = "models_total"
        case autoAvailable = "auto_available"
        case orchestratorUp = "orchestrator_up"
        case defaultModel = "default_model"
    }

    var isPaused: Bool {
        guard let s = state?.lowercased() else { return false }
        return s.contains("paus")
    }

    /// Auto routing is degraded to a default model (orchestrator not running
    /// but a fallback model exists). True = degraded; false = healthy or unknown.
    var isDegradedAuto: Bool {
        (orchestratorUp == false) && (autoAvailable == true)
    }
}

struct StatusModel: Codable, Sendable {
    let name: String?
    let model: String?
    let tier: String?
    let node: String?
    let sizeGB: Double?
    let loaded: Bool?

    enum CodingKeys: String, CodingKey {
        case name, model, tier, node, loaded
        case sizeGB = "size_gb"
    }

    var displayName: String { name ?? model ?? "?" }
}

struct StatusNode: Codable, Sendable {
    let id: String?
    let name: String?
    let online: Bool?
    let healthy: Bool?
    let ramUsedGB: Double?
    let ramTotalGB: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, online, healthy
        case ramUsedGB = "ram_used_gb"
        case ramTotalGB = "ram_total_gb"
    }

    var displayId: String { id ?? name ?? "?" }
    var isOnline: Bool { online ?? healthy ?? false }
}

struct MetricsResponse: Codable, Sendable {
    let cacheHitRatio: Double?
    let tokensPerSec: Double?
    let requestsPerMin: Double?
    let requestsActive: Int?

    enum CodingKeys: String, CodingKey {
        case cacheHitRatio = "cache_hit_ratio"
        case tokensPerSec = "tokens_per_sec"
        case requestsPerMin = "requests_per_min"
        case requestsActive = "requests_active"
    }
}

struct EventEntry: Codable, Sendable, Identifiable {
    struct Data: Codable, Sendable {
        let id: String?
        let tier: String?
        let confidence: Double?
        let method: String?
        let model: String?
        let node: String?
        let reason: String?
        let virtualModel: String?
        let cached: Bool?
    }

    let type: String?
    let ts: Double?
    let data: Data?

    var id: String {
        let inner = data?.id ?? ""
        return "\(type ?? "?")/\(ts ?? 0)/\(inner)"
    }

    var tier: String? { data?.tier }
    var detail: String {
        var parts: [String] = []
        if let m = data?.model { parts.append(m) }
        if let n = data?.node { parts.append("@\(n)") }
        if let c = data?.confidence { parts.append(String(format: "%.2f", c)) }
        if let r = data?.reason { parts.append(r) }
        return parts.isEmpty ? (type ?? "") : parts.joined(separator: " ")
    }
}

struct NodeEntry: Codable, Sendable, Identifiable {
    let idRaw: String?
    let name: String?
    let online: Bool?
    let healthy: Bool?
    let state: String?
    let ramUsedGB: Double?
    let ramTotalGB: Double?

    enum CodingKeys: String, CodingKey {
        case idRaw = "id", name, online, healthy, state
        case ramUsedGB = "ram_used_gb"
        case ramTotalGB = "ram_total_gb"
    }

    var id: String { idRaw ?? name ?? "?" }
    var displayId: String { idRaw ?? name ?? "?" }
    var isOnline: Bool {
        if let o = online { return o }
        if let h = healthy { return h }
        if let s = state?.lowercased() { return s == "online" || s == "ok" || s == "healthy" || s == "up" }
        return false
    }
    var ramFraction: Double? {
        guard let used = ramUsedGB, let total = ramTotalGB, total > 0 else { return nil }
        return min(max(used / total, 0), 1)
    }
}

struct ModelEntry: Codable, Sendable, Identifiable {
    let name: String?
    let model: String?
    let tier: String?
    let node: String?
    let sizeGB: Double?
    let loaded: Bool?
    let state: String?
    let ownedBy: String?

    enum CodingKeys: String, CodingKey {
        case name, model, tier, node, loaded, state
        case sizeGB = "size_gb"
        case ownedBy = "owned_by"
    }

    var id: String { name ?? model ?? UUID().uuidString }
    var displayName: String { name ?? model ?? "?" }
    var isLoaded: Bool {
        if let l = loaded { return l }
        if let s = state?.lowercased() { return s == "loaded" || s == "ready" || s == "running" }
        return true
    }

    var displayNode: String { node ?? "local" }
    var displayTier: String { tier ?? "—" }
    var displaySize: String {
        guard let g = sizeGB else { return "—" }
        return String(format: "%.1f GB", g)
    }
}

struct ConfigResponse: Codable, Sendable {
    let cluster: Cluster?
    let data: ConfigPayload?

    struct Cluster: Codable, Sendable {
        let enabled: Bool?
    }
    struct ConfigPayload: Codable, Sendable {
        let cluster: Cluster?
    }

    var clusterEnabled: Bool {
        cluster?.enabled ?? data?.cluster?.enabled ?? false
    }
}
