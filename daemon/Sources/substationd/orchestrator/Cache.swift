import Foundation

/// Daemon-side LRU response cache for non-streaming completions.
public actor ResponseCache {
    private var map: [String: String] = [:]
    private var order: [String] = []
    private var hits = 0
    private var misses = 0
    private var lastCanonical: String?
    private var prefixDepths: [Int] = []

    public init() {}

    public func get(_ key: String, enabled: Bool) -> String? {
        guard enabled else { return nil }
        if let v = map[key] {
            hits += 1
            order.removeAll { $0 == key }
            order.append(key)
            return v
        }
        misses += 1
        return nil
    }

    public func set(_ key: String, _ value: String, maxEntries: Int) {
        guard map[key] == nil else { return }
        map[key] = value
        order.append(key)
        while order.count > max(1, maxEntries) {
            map.removeValue(forKey: order.removeFirst())
        }
    }

    /// Track prefix reuse between consecutive canonical prompts (heuristic
    /// estimate of llama.cpp prefix-cache benefit at the daemon layer).
    public func noteCanonical(_ canonical: String) {
        if let last = lastCanonical {
            var n = 0
            for (a, b) in zip(last.utf16, canonical.utf16) {
                if a != b { break }
                n += 1
            }
            prefixDepths.append(n)
            if prefixDepths.count > 64 { prefixDepths.removeFirst(prefixDepths.count - 64) }
        }
        lastCanonical = canonical
    }

    public func stats(enabled: Bool, maxEntries: Int, slotUtil: [String: JSONValue]) -> JSONValue {
        let total = hits + misses
        let ratio = total == 0 ? 0.0 : Double(hits) / Double(total)
        let depth = prefixDepths.isEmpty ? 0.0 : Double(prefixDepths.reduce(0, +)) / Double(prefixDepths.count)
        return .object([
            "enabled": .bool(enabled),
            "entries": .jInt(order.count),
            "max_entries": .jInt(maxEntries),
            "hit_ratio": .jDouble((ratio * 1000).rounded() / 1000),
            "prefix_reuse_estimate": .jDouble((depth / 1000).rounded() / 1000),
            "slot_util": .object(slotUtil),
        ])
    }
}
