import Foundation

/// Token ledger: prompt vs completion, per tier/model, hourly buckets for UI.
public actor TokenUsage {
    /// Reference cloud pricing (USD per 1M tokens, indicative list prices as of
    /// 2026). Used ONLY to compute "what this would have cost in the cloud" —
    /// Substation itself never sends data anywhere. Edit freely; not financial advice.
    public struct Provider: Sendable {
        public let id: String
        public let label: String
        public let model: String
        public let inputPerM: Double
        public let outputPerM: Double
    }
    public static let providers: [Provider] = [
        .init(id: "openai", label: "OpenAI", model: "gpt-4.1", inputPerM: 2.0, outputPerM: 8.0),
        .init(id: "openai", label: "OpenAI", model: "gpt-4o", inputPerM: 2.5, outputPerM: 10.0),
        .init(id: "anthropic", label: "Anthropic", model: "claude-sonnet-4.5", inputPerM: 3.0, outputPerM: 15.0),
        .init(id: "anthropic", label: "Anthropic", model: "claude-opus-4.1", inputPerM: 15.0, outputPerM: 75.0),
        .init(id: "google", label: "Google", model: "gemini-2.5-pro", inputPerM: 1.25, outputPerM: 10.0),
        .init(id: "deepseek", label: "DeepSeek", model: "deepseek-chat", inputPerM: 0.27, outputPerM: 1.10),
    ]

    public struct Cost {
        public let id: String
        public let label: String
        public let model: String
        public let usd: Double
    }
    public func estimatedCloudCosts() -> [Cost] {
        Self.providers.map { p in
            Cost(id: p.id, label: p.label, model: p.model,
                 usd: Double(promptTotal) / 1_000_000 * p.inputPerM + Double(completionTotal) / 1_000_000 * p.outputPerM)
        }
    }

    private var promptTotal = 0
    private var completionTotal = 0
    private var cacheHits = 0
    private var byTier: [String: (p: Int, c: Int)] = [:]
    private var byModel: [String: (p: Int, c: Int)] = [:]
    private var hourly: [(hour: Int64, p: Int, c: Int)] = []
    private let maxHours = 72

    public init() {}

    public func record(prompt: Int, completion: Int, tier: String, model: String, cached: Bool = false) {
        promptTotal += prompt
        completionTotal += completion
        if cached { cacheHits += 1 }
        var t = byTier[tier] ?? (0, 0); t.p += prompt; t.c += completion; byTier[tier] = t
        var m = byModel[model] ?? (0, 0); m.p += prompt; m.c += completion; byModel[model] = m
        let h = Int64(Date().timeIntervalSince1970 / 3600)
        if var last = hourly.last, last.hour == h {
            last.p += prompt; last.c += completion
            hourly[hourly.count - 1] = last
        } else {
            hourly.append((h, prompt, completion))
            if hourly.count > maxHours { hourly.removeFirst(hourly.count - maxHours) }
        }
    }

    public func snapshotJSON() -> JSONValue {
        .object([
            "prompt_total": .jInt(promptTotal),
            "completion_total": .jInt(completionTotal),
            "total": .jInt(promptTotal + completionTotal),
            "cache_hits": .jInt(cacheHits),
            "by_tier": .object(byTier.mapValues { JSONValue.object(["prompt": .jInt($0.p), "completion": .jInt($0.c)]) }),
            "by_model": .object(byModel.mapValues { JSONValue.object(["prompt": .jInt($0.p), "completion": .jInt($0.c)]) }),
            "hourly": .array(hourly.map { h in
                JSONValue.object([
                    "hour": .jDouble(Double(h.hour) * 3600),
                    "prompt": .jInt(h.p),
                    "completion": .jInt(h.c),
                ])
            }),
            "cloud_cost_estimate": .array(Self.providers.map { p in
                let usd = Double(promptTotal) / 1_000_000 * p.inputPerM + Double(completionTotal) / 1_000_000 * p.outputPerM
                return JSONValue.object([
                    "provider": .string(p.label),
                    "model": .string(p.model),
                    "usd": .jDouble((usd * 10_000).rounded() / 10_000),
                ])
            }),
            "pricing_note": .string("Indicative cloud list prices (USD/1M tokens), informational only; Substation runs locally and sends nothing out"),
        ])
    }
}
