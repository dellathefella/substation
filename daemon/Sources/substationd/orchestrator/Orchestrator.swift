import Foundation

public struct TierDecision: Sendable {
    public var tier: String
    public var confidence: Double
    public var method: String   // "model" | "heuristic"
    public var ms: Int
    public var signals: [String]
}

public struct RouteInfo: Sendable {
    public var requestId: String
    public var virtualModel: String
    public var tier: String
    public var confidence: Double
    public var method: String
    public var model: String
    public var node: String
    public var split: Bool
    public var rpcPeers: [String]
    public var reason: String
    public var engine: RunningEngine
    public var sticky: Bool
    public var waitedQueueMs: Double
    public var waitedLoadingMs: Double
}

/// Triage → tier → catalog → placement, with session stickiness and prefetch.
public struct Orchestrator: Sendable {
    public let cfg: ConfigStore
    public let events: EventActor
    public let metrics: MetricsActor
    public let engines: EngineActor
    public let admission: Admission
    public let sessions: SessionActor
    public let cache: ResponseCache
    public let state: DaemonState
    public let client = EngineClient()

    public init(
        cfg: ConfigStore, events: EventActor, metrics: MetricsActor, engines: EngineActor,
        admission: Admission, sessions: SessionActor, cache: ResponseCache, state: DaemonState
    ) {
        self.cfg = cfg
        self.events = events
        self.metrics = metrics
        self.engines = engines
        self.admission = admission
        self.sessions = sessions
        self.cache = cache
        self.state = state
    }

    // MARK: - Triage

    public static func heuristicTier(_ prompt: String) -> (String, [String]) {
        let hasCode = prompt.contains("```") || prompt.lowercased().contains("code")
        if prompt.count > 600 || hasCode { return ("smart", ["len:\(prompt.count)", "code:\(hasCode)"]) }
        if prompt.count < 80 { return ("fast", ["len:\(prompt.count)"]) }
        return ("balanced", ["len:\(prompt.count)"])
    }

    public func triage(_ userText: String, cfg: ConfigSnapshot) async -> TierDecision {
        let t0 = Date()
        let compact = String(userText.prefix(1200))
        let prompt = """
        Classify the USER REQUEST into one tier. Reply ONLY JSON:
        {"tier":"fast"|"balanced"|"smart","confidence":0..1,"signals":[".."]}
        fast=trivial/short, balanced=normal Q&A/writing, smart=code/complex/reasoning/long.
        USER REQUEST: \(compact)
        """
        let body: JSONValue = .object([
            "model": .string("substation-triage"),
            "messages": .array([.object([
                "role": .string("user"),
                "content": .string(prompt),
            ])]),
            "temperature": .jDouble(0),
            "max_tokens": .jInt(40),
            "stream": .bool(false),
            "response_format": .object(["type": .string("json_object")]),
        ])
        do {
            let (status, val) = try await client.json(
                method: "POST",
                url: "http://127.0.0.1:\(cfg.triagePort)/v1/chat/completions",
                body: body,
                timeout: Double(cfg.triageTimeoutMs) / 1000 + 0.05
            )
            if status == 200,
               let content = val?["choices"]?[0]?["message"]?["content"]?.stringValue,
               let parsed = Self.parseTriageJSON(content),
               let tier = parsed["tier"]?.stringValue, ["fast", "balanced", "smart"].contains(tier)
            {
                return TierDecision(
                    tier: tier,
                    confidence: parsed["confidence"]?.doubleValue ?? 0.5,
                    method: "model",
                    ms: Int(Date().timeIntervalSince(t0) * 1000),
                    signals: parsed["signals"]?.arrayValue?.compactMap { $0.stringValue } ?? []
                )
            }
        } catch {}
        let (tier, signals) = Self.heuristicTier(userText)
        return TierDecision(tier: tier, confidence: 0.5, method: "heuristic",
                            ms: Int(Date().timeIntervalSince(t0) * 1000), signals: signals)
    }

    private static func parseTriageJSON(_ raw: String) -> JSONValue? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return JSONCoding.decode(Data(text[start...].utf8))
    }

    // MARK: - Routing

    /// Full orchestration for one chat completion.
    public func route(
        requestedModel: String?,
        messages: JSONValue?,
        sessionKey: String?
    ) async throws -> RouteInfo {
        let cfg = await cfg.snapshot
        let requestId = "req-" + String(UUID().uuidString.prefix(8)).lowercased()
        let virtual = requestedModel?.isEmpty == false ? requestedModel! : "auto"

        let userText = Self.lastUserText(messages)

        // 1) Triage (virtual models only; a concrete model name is a pin).
        var decision: TierDecision
        var forcedTier: String?
        switch virtual {
        case "auto": decision = await triage(userText, cfg: cfg)
        case "auto-fast": decision = TierDecision(tier: "fast", confidence: 1, method: "model", ms: 0, signals: ["pinned"])
        case "auto-smart": decision = TierDecision(tier: "smart", confidence: 1, method: "model", ms: 0, signals: ["pinned"])
        default: forcedTier = cfg.model(virtual)?.tier ?? "balanced"; decision = TierDecision(tier: forcedTier!, confidence: 1, method: "model", ms: 0, signals: ["pinned-model"])
        }
        try? await events.publish("triage.decision", [
            ("id", .string(requestId)),
            ("tier", .string(decision.tier)),
            ("confidence", .jDouble(decision.confidence)),
            ("method", .string(decision.method)),
            ("ms", .jInt(decision.ms)),
        ])
        await metrics.increment("triage_\(decision.method)")
        await metrics.increment("tier_\(decision.tier)")

        // 2) Session stickiness: stay on the pinned model; one-way upgrade only
        //    at confidence >= threshold (transparency invariant #3).
        var modelName = forcedTier != nil ? virtual : ""
        var tier = decision.tier
        var sticky = false
        if forcedTier == nil {
            let candidate = (cfg.tiers[tier] ?? []).first(where: { cfg.model($0) != nil })
            var pinned: Sticky?
            if let key = sessionKey, !key.isEmpty {
                pinned = await sessions.pinned(key, ttlSeconds: cfg.sessionStickSeconds)
            }
            if let key = sessionKey, !key.isEmpty, let pinned {
                let upgrading = SessionActor.rank(of: tier) > pinned.rank
                    && decision.confidence >= cfg.triageUpgradeConfidence
                if upgrading, let candidate {
                    modelName = candidate
                    await sessions.pin(key, model: candidate, tier: tier, rank: SessionActor.rank(of: tier))
                } else {
                    tier = pinned.tier
                    modelName = pinned.model
                    sticky = true
                    await sessions.touch(key)
                }
            } else if let candidate {
                modelName = candidate
                if let key = sessionKey, !key.isEmpty {
                    await sessions.pin(key, model: candidate, tier: tier, rank: SessionActor.rank(of: tier))
                }
            }
        }
        if modelName.isEmpty || cfg.model(modelName) == nil {
            let candidates = cfg.tiers[tier] ?? []
            guard let first = candidates.first(where: { cfg.model($0) != nil }) else {
                throw EngineError.notFound("no catalog model for tier \(tier)")
            }
            modelName = first
        }
        guard let catalog = cfg.model(modelName) else {
            throw EngineError.notFound("model \(modelName)")
        }

        // 4) Placement (node/split honoured only when cluster enabled).
        var placement = Placement.parse(catalog.placement)
        if !cfg.clusterEnabled { placement = .local }

        // 5) Admission gate (queued), then load (loading) — never 503.
        let queueWait = await admission.acquire()
        var loadedWait = 0.0
        if queueWait > 1 {
            try? await events.publish("engine.wait", [
                ("id", .string(requestId)), ("ms", .jInt(Int(queueWait))), ("reason", .string("queued")),
            ])
        }
        let t0 = Date()
        let engine: RunningEngine
        do {
            engine = try await engines.ensureLoaded(catalog, placement: placement, cfg: cfg)
        } catch {
            await admission.release()
            throw error
        }
        loadedWait = Date().timeIntervalSince(t0) * 1000
        if loadedWait > 1500 {
            try? await events.publish("engine.wait", [
                ("id", .string(requestId)), ("ms", .jInt(Int(loadedWait))), ("reason", .string("loading")),
            ])
        }

        let splitPeers: [String]
        if case .split(let ids) = placement { splitPeers = Array(ids.dropFirst()) } else { splitPeers = [] }
        try? await events.publish("route.selected", [
            ("id", .string(requestId)),
            ("model", .string(modelName)),
            ("node", .string(engine.node)),
            ("split", .bool(engine.split)),
            ("rpc_peers", .array(splitPeers.map { .string($0) })),
            ("reason", .string("tier=\(tier) conf=\(String(format: "%.2f", decision.confidence)) method=\(decision.method) placement=\(catalog.placement) sticky=\(sticky)")),
        ])
        await metrics.increment("routed_total")

        // 6) Prefetch: low-confidence triage may be wrong → warm the next tier.
        if decision.confidence < cfg.triageUpgradeConfidence, virtual == "auto" {
            let nextTier = tier == "fast" ? "balanced" : "smart"
            if let nextName = cfg.tiers[nextTier]?.first, let nextModel = cfg.model(nextName) {
                let engines = self.engines
                let cfgNow = cfg
                let ev = self.events
                Task.detached(priority: .background) {
                    if await engines.needsLoad(model: nextName, node: "local") {
                        try? await ev.publish("engine.wait", [
                            ("id", .string("prefetch")), ("ms", .jInt(0)), ("reason", .string("loading")),
                        ])
                        _ = try? await engines.ensureLoaded(nextModel, placement: .local, cfg: cfgNow)
                    }
                }
            }
        }

        return RouteInfo(
            requestId: requestId, virtualModel: virtual, tier: tier,
            confidence: decision.confidence, method: decision.method,
            model: modelName, node: engine.node, split: engine.split, rpcPeers: splitPeers,
            reason: "tier=\(tier)", engine: engine, sticky: sticky,
            waitedQueueMs: queueWait, waitedLoadingMs: loadedWait
        )
    }

    public static func lastUserText(_ messages: JSONValue?) -> String {
        guard let arr = messages?.arrayValue else { return "" }
        for m in arr.reversed() {
            if m["role"]?.stringValue == "user", let c = m["content"]?.stringValue { return c }
        }
        return ""
    }
}

extension EngineActor {
    public func needsLoad(model: String, node: String) -> Bool {
        listLive().contains { $0.model == model && $0.node == node }
    }
}
