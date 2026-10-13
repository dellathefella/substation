import Foundation

public struct Sticky: Sendable {
    public var model: String
    public var tier: String
    public var rank: Int
    public var lastUsed: Date
}

/// Session stickiness: session → pinned model/tier, TTL-based.
public actor SessionActor {
    private var map: [String: Sticky] = [:]

    public init() {}

    public func pinned(_ id: String, ttlSeconds: Int) -> Sticky? {
        guard let s = map[id] else { return nil }
        if Date().timeIntervalSince(s.lastUsed) > Double(ttlSeconds) {
            map.removeValue(forKey: id)
            return nil
        }
        return s
    }

    public func pin(_ id: String, model: String, tier: String, rank: Int) {
        map[id] = Sticky(model: model, tier: tier, rank: rank, lastUsed: Date())
    }

    public func touch(_ id: String) {
        if var s = map[id] {
            s.lastUsed = Date()
            map[id] = s
        }
    }

    public static func rank(of tier: String) -> Int {
        switch tier {
        case "fast": return 0
        case "balanced": return 1
        case "smart": return 2
        default: return 1
        }
    }
}
