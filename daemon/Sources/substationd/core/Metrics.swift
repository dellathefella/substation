import Foundation

/// Counters + bounded sample rings; percentiles computed on read (sorted copy).
public actor MetricsActor {
    private let maxSamples = 1000
    private var counters: [String: Double] = [:]
    private var samples: [String: [Double]] = [:]
    private var requestTimes: [Double] = []
    private var tokensWindow: [(ms: Double, tokens: Double)] = []
    private var engineTokS: [String: Double] = [:]

    public init() {}

    public func increment(_ key: String, _ by: Double = 1) {
        counters[key, default: 0] += by
    }

    public func record(_ key: String, _ value: Double) {
        guard value.isFinite else { return }
        var ring = samples[key] ?? []
        ring.append(value)
        if ring.count > maxSamples { ring.removeFirst(ring.count - maxSamples) }
        samples[key] = ring
    }

    public func recordRequest() {
        let now = Date().timeIntervalSince1970 * 1000
        requestTimes.append(now)
        let cutoff = now - 60_000
        requestTimes.removeAll { $0 < cutoff }
    }

    public func recordTokens(_ count: Double, ms: Double) {
        let now = Date().timeIntervalSince1970 * 1000
        tokensWindow.append((now, count))
        tokensWindow.removeAll { now - $0.ms > 10_000 }
        _ = ms
    }

    public func setEngineTokS(_ modelNode: String, _ v: Double) {
        engineTokS[modelNode] = v
    }

    public func requestsPerMin() -> Double {
        let now = Date().timeIntervalSince1970 * 1000
        requestTimes.removeAll { now - $0 > 60_000 }
        return Double(requestTimes.count)
    }

    public func tokensPerSec() -> Double {
        let now = Date().timeIntervalSince1970 * 1000
        tokensWindow.removeAll { now - $0.ms > 10_000 }
        let total = tokensWindow.reduce(0) { $0 + $1.tokens }
        return total / 10.0
    }

    /// p50/p95/p99 over the current ring for `key`.
    public func percentiles(_ key: String) -> JSONValue {
        guard let ring = samples[key], !ring.isEmpty else { return .null }
        let sorted = ring.sorted()
        func p(_ q: Double) -> Double {
            let idx = min(sorted.count - 1, max(0, Int((q * Double(sorted.count)).rounded()) ))
            return sorted[idx]
        }
        return .object([
            "p50": .jDouble((p(0.50) * 100).rounded() / 100),
            "p95": .jDouble((p(0.95) * 100).rounded() / 100),
            "p99": .jDouble((p(0.99) * 100).rounded() / 100),
        ])
    }

    public func snapshot() -> JSONValue {
        var percentilesObj: [String: JSONValue] = [:]
        for key in ["ttft_ms", "total_ms", "tok_s"] {
            percentilesObj[key] = percentiles(key)
        }
        var byTier: [String: JSONValue] = [:]
        for key in samples.keys.sorted() where key.hasPrefix("ttft_ms.") || key.hasPrefix("tok_s.") {
            byTier[key] = percentiles(key)
        }
        var countersObj: [String: JSONValue] = [:]
        for (k, v) in counters.sorted(by: { $0.key < $1.key }) {
            countersObj[k] = v == v.rounded() ? .jInt(Int(v)) : .jDouble(v)
        }
        var engineObj: [String: JSONValue] = [:]
        for (k, v) in engineTokS.sorted(by: { $0.key < $1.key }) {
            engineObj[k] = .jDouble((v * 100).rounded() / 100)
        }
        return .object([
            "counters": .object(countersObj),
            "percentiles": .object(percentilesObj),
            "by_key": .object(byTier),
            "engine_tok_s": .object(engineObj),
            "requests_per_min": .jDouble(requestsPerMin()),
            "tokens_per_sec": .jDouble(tokensPerSec()),
            "samples": .jInt(samples.values.map(\.count).max() ?? 0),
        ])
    }
}
