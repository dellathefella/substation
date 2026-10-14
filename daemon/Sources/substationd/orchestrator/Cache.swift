import Foundation

/// Daemon-side LRU response cache for non-streaming completions.
///
/// Bucketed PER MODEL: each model gets its own LRU, so heavy traffic on one model
/// (or a model switching in/out) never evicts another model's cached responses.
/// This is what makes the cache useful when the orchestrator swaps models on the
/// fly — a model that switches back in still has its exact-match responses cached.
public actor ResponseCache {
    private struct Bucket {
        var map: [String: String] = [:]
        var order: [String] = []
    }
    private var buckets: [String: Bucket] = [:]
    private var hits = 0
    private var misses = 0
    private var lastCanonical: String?
    private var prefixDepths: [Int] = []

    public init() {}

    public func get(model: String, key: String, enabled: Bool) -> String? {
        guard enabled else { return nil }
        if var b = buckets[model], let v = b.map[key] {
            hits += 1
            b.order.removeAll { $0 == key }
            b.order.append(key)
            buckets[model] = b
            return v
        }
        misses += 1
        return nil
    }

    public func set(model: String, key: String, _ value: String, maxEntries: Int) {
        var b = buckets[model] ?? Bucket()
        guard b.map[key] == nil else { return }
        b.map[key] = value
        b.order.append(key)
        while b.order.count > max(1, maxEntries) {
            b.map.removeValue(forKey: b.order.removeFirst())
        }
        buckets[model] = b
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
        let entries = buckets.values.reduce(0) { $0 + $1.order.count }
        return .object([
            "enabled": .bool(enabled),
            "entries": .jInt(entries),
            "max_entries": .jInt(maxEntries),
            "models_cached": .jInt(buckets.count),
            "hit_ratio": .jDouble((ratio * 1000).rounded() / 1000),
            "prefix_reuse_estimate": .jDouble((depth / 1000).rounded() / 1000),
            "slot_util": .object(slotUtil),
        ])
    }
}
