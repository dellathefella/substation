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
    public var remote: RemoteTarget?
}

/// A non-local upstream (cloud provider or an already-running server).
public struct RemoteTarget: Sendable {
    public var url: String       // base URL, no trailing slash
    public var key: String?      // bearer / x-api-key
    public var proto: String     // "openai" | "anthropic"
    public var model: String     // upstream model id

    public init(url: String, key: String?, proto: String, model: String) {
        self.url = url
        self.key = key
        self.proto = proto
        self.model = model
    }

    public static func host(of url: String) -> String {
        var s = url
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let i = s.firstIndex(of: "/") { s = String(s[s.startIndex..<i]) }
        return s
    }
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
    public let usage: TokenUsage
    public let mem: Memory
    public let nodes: NodesActor

    public init(
        cfg: ConfigStore, events: EventActor, metrics: MetricsActor, engines: EngineActor,
        admission: Admission, sessions: SessionActor, cache: ResponseCache, state: DaemonState,
        usage: TokenUsage, mem: Memory, nodes: NodesActor
    ) {
        self.cfg = cfg
        self.events = events
        self.metrics = metrics
        self.engines = engines
        self.admission = admission
        self.sessions = sessions
        self.cache = cache
        self.state = state
        self.usage = usage
        self.mem = mem
        self.nodes = nodes
    }

    // MARK: - Triage

    /// Fallback model when auto routing without an orchestrator: config
    /// `orchestrator.default_model` if loadable, else the smallest catalog model.
    public static func defaultModelName(_ cfg: ConfigSnapshot) -> String? {
        let fm = FileManager.default
        func live(_ m: CatalogModel) -> Bool { m.kind != "local" || fm.fileExists(atPath: m.gguf) }
        if !cfg.defaultModel.isEmpty, let m = cfg.model(cfg.defaultModel), live(m) {
            return cfg.defaultModel
        }
        return cfg.models.filter(live).min(by: { $0.sizeGB < $1.sizeGB })?.name
    }

    /// Largest LOCAL-placement catalog model that fits free memory now,
    /// preferring the requested tier. nil → nothing fits.
    private func bestLocalFit(cfg: ConfigSnapshot, preferTier: String) async -> CatalogModel? {
        let free = await mem.read().freeGB
        let local = cfg.models.filter { Placement.parse($0.placement) == .local && $0.sizeGB + 2.0 <= free }
        if let same = local.filter({ $0.tier == preferTier }).max(by: { $0.sizeGB < $1.sizeGB }) { return same }
        return local.max(by: { $0.sizeGB < $1.sizeGB })
    }

    public static func heuristicTier(_ prompt: String, names: [String]) -> (String, [String]) {
        let hasCode = prompt.contains("```") || prompt.lowercased().contains("code")
        let lightest = names.first ?? "fast"
        let heaviest = names.last ?? "smart"
        let middle = names.count > 2 ? names[names.count / 2] : heaviest
        if prompt.count > 600 || hasCode { return (heaviest, ["len:\(prompt.count)", "code:\(hasCode)"]) }
        if prompt.count < 80 { return (lightest, ["len:\(prompt.count)"]) }
        return (middle, ["len:\(prompt.count)"])
    }

    public func triage(_ userText: String, cfg: ConfigSnapshot) async -> TierDecision {
        let t0 = Date()
        let compact = String(userText.prefix(1200))
        let names = cfg.tierNames.isEmpty ? ["fast", "balanced", "smart"] : cfg.tierNames
        let descs: [String] = names.map { n in
            let d = cfg.tierDesc(n)
            if !d.isEmpty { return "\(n)=\(d)" }
            switch n {
            case "fast": return "fast=trivial/short"
            case "balanced": return "balanced=normal Q&A/writing"
            case "smart": return "smart=code/complex/reasoning/long"
            default: return "\(n)=\(n) tier"
            }
        }
        let prompt = """
        Classify the USER REQUEST into one tier. Reply ONLY JSON:
        {"tier":"<one of: \(names.joined(separator: ", "))>","confidence":0..1,"signals":[".."]}
        \(descs.joined(separator: ", "))
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
               let tier = parsed["tier"]?.stringValue, cfg.tierNames.contains(tier)
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
        let (tier, signals) = Self.heuristicTier(userText, names: cfg.tierNames.isEmpty ? ["fast", "balanced", "smart"] : cfg.tierNames)
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

        // Auto-router disabled → single fixed model mode: every auto* request
        // goes straight to the default model (no triage, no tiers, no sticky).
        if !cfg.orchestratorEnabled {
            guard let d = Self.defaultModelName(cfg) ?? cfg.models.first?.name else {
                throw APIError.noModelLoaded("Auto-router is disabled and the catalog is empty; define a model or set orchestrator.default_model.")
            }
            let catalog = cfg.model(d)
            // Remote/external profile as the fixed model: proxy straight upstream.
            if let catalog, catalog.kind != "local", let base = catalog.baseUrl, !base.isEmpty {
                try? await events.publish("router.disabled", [
                    ("id", .string(requestId)), ("model", .string(d)), ("node", .string("remote")),
                ])
                return RouteInfo(
                    requestId: requestId, virtualModel: virtual, tier: "single", confidence: 1,
                    method: "router_disabled", model: d, node: "remote", split: false, rpcPeers: [],
                    reason: "router_disabled remote:\(catalog.kind)", engine: Self.remoteEngine(catalog, base: base),
                    sticky: false, waitedQueueMs: 0, waitedLoadingMs: 0,
                    remote: RemoteTarget(url: base, key: catalog.apiKey, proto: catalog.proto,
                                         model: catalog.remoteModel ?? catalog.name)
                )
            }
            var placement = Placement.parse(catalog?.placement ?? "local")
            if !cfg.clusterEnabled { placement = .local }
            let queueWait = await admission.acquire()
            let engine: RunningEngine
            do {
                engine = try await engines.ensureLoaded(catalog ?? cfg.models[0], placement: placement, cfg: cfg)
            } catch {
                await admission.release()
                throw error
            }
            try? await events.publish("router.disabled", [
                ("id", .string(requestId)), ("model", .string(d)), ("node", .string(engine.node)),
            ])
            var splitPeers: [String] = []
            if case .split(let ids) = placement, ids.count > 1 { splitPeers = Array(ids.dropFirst()) }
            return RouteInfo(
                requestId: requestId, virtualModel: virtual, tier: "single", confidence: 1,
                method: "router_disabled", model: d, node: engine.node, split: engine.split,
                rpcPeers: splitPeers, reason: "router_disabled single_model:\(d)",
                engine: engine, sticky: false, waitedQueueMs: queueWait, waitedLoadingMs: 0
            )
        }

        // Orchestrator availability + fallback cascade:
        //   auto + triage present   → model triage (real intelligence/speed routing)
        //   auto + triage missing   → default model (config default_model → smallest catalog model)
        //   nothing available       → explicit "no model loaded + orchestrator unavailable" error
        let triagePresent = FileManager.default.fileExists(atPath: cfg.triageGguf)
        let orchestratorUp: Bool
        if triagePresent {
            orchestratorUp = await engines.triageHealthy(cfg: cfg)
        } else {
            orchestratorUp = false
        }
        if !orchestratorUp {
            if Self.defaultModelName(cfg) == nil {
                throw APIError.noModelLoaded(
                    "No model is loaded and the orchestrator is unavailable (triage model '\(cfg.triageGguf)' not found). Download the small model or set orchestrator.default_model to a catalog model."
                )
            }
        }

        // 1) Triage (virtual models only; a concrete model name is a pin).
        var decision: TierDecision
        var forcedTier: String?
        var presetModel: String?
        switch virtual {
        case "auto":
            if orchestratorUp {
                decision = await triage(userText, cfg: cfg)
            } else {
                let d = Self.defaultModelName(cfg)!
                decision = TierDecision(tier: cfg.model(d)?.tier ?? "balanced", confidence: 1,
                                        method: "fallback", ms: 0,
                                        signals: ["orchestrator_unavailable", "default_model:\(d)"])
                presetModel = d
                await events.publish("orchestrator.fallback", [
                    ("id", .string(requestId)),
                    ("reason", .string(triagePresent ? "triage_engine_unreachable" : "triage_model_missing")),
                    ("default_model", .string(d)),
                ])
            }
        default:
            if virtual.hasPrefix("auto-"), cfg.tierNames.contains(String(virtual.dropFirst(5))) {
                let t = String(virtual.dropFirst(5))
                forcedTier = t
                decision = TierDecision(tier: t, confidence: 1, method: "model", ms: 0, signals: ["pinned-tier"])
            } else {
                forcedTier = cfg.model(virtual)?.tier ?? "balanced"
                decision = TierDecision(tier: forcedTier!, confidence: 1, method: "model", ms: 0, signals: ["pinned-model"])
            }
        }
        await events.publish("triage.decision", [
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
        var modelName = presetModel ?? (forcedTier != nil ? virtual : "")
        var tier = decision.tier
        var sticky = false
        if forcedTier == nil, presetModel == nil {
            let candidate = (cfg.tiers[tier] ?? []).first(where: { cfg.model($0) != nil })
            var pinned: Sticky?
            if let key = sessionKey, !key.isEmpty {
                pinned = await sessions.pinned(key, ttlSeconds: cfg.sessionStickSeconds)
            }
            if let key = sessionKey, !key.isEmpty, let pinned {
                let upgrading = cfg.tierRank(tier) > pinned.rank
                    && decision.confidence >= cfg.triageUpgradeConfidence
                if upgrading, let candidate {
                    modelName = candidate
                    await sessions.pin(key, model: candidate, tier: tier, rank: cfg.tierRank(tier))
                } else {
                    tier = pinned.tier
                    modelName = pinned.model
                    sticky = true
                    await sessions.touch(key)
                }
            } else if let candidate {
                modelName = candidate
                if let key = sessionKey, !key.isEmpty {
                    await sessions.pin(key, model: candidate, tier: tier, rank: cfg.tierRank(tier))
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
        guard let requested = cfg.model(modelName) else {
            throw EngineError.notFound("model \(modelName)")
        }

        // 4) Placement + RPC resource awareness. A remote/split placement the
        //    target node(s) cannot serve right now is downgraded to the best
        //    LOCAL model that fits, so auto-switching never strands a request on
        //    an over-budget node.
        var finalCatalog = requested
        var placement = Placement.parse(requested.placement)
        if !cfg.clusterEnabled { placement = .local }
        switch placement {
        case .node(let id):
            if let free = await nodes.freeGB(id) {
                let need = requested.sizeGB + 2.0
                if free < need {
                    if let alt = await bestLocalFit(cfg: cfg, preferTier: tier) {
                        finalCatalog = alt
                        placement = .local
                        try? await events.publish("resource.warning", [
                            ("model", .string(requested.name)), ("node", .string(id)),
                            ("reason", .string("rpc_resources_insufficient")),
                            ("need_gb", .jDouble((need * 100).rounded() / 100)),
                            ("free_gb", .jDouble((free * 100).rounded() / 100)),
                            ("fallback", .string(alt.name)),
                        ])
                    }
                }
            }
        case .split(let explicitIds):
            var ids = explicitIds
            if ids.isEmpty { ids = ["local"] + (await nodes.allNodes()).filter { $0.healthy }.map(\.id) }
            if ids.count > 1 {
                let perNode = ResourceEstimator.splitPerNodeGB(weightsGB: requested.sizeGB, ctx: requested.ctx,
                                                               slots: requested.slots, nodeCount: ids.count)
                var shortfall = false
                if ids.first == "local" || ids.first == "self" {
                    if (await mem.read()).freeGB < perNode { shortfall = true }
                } else if let f = await nodes.freeGB(ids[0]), f < perNode { shortfall = true }
                for peer in ids.dropFirst() {
                    if let f = await nodes.freeGB(peer), f < perNode { shortfall = true }
                }
                if shortfall, let alt = await bestLocalFit(cfg: cfg, preferTier: tier) {
                    finalCatalog = alt
                    placement = .local
                    try? await events.publish("resource.warning", [
                        ("model", .string(requested.name)), ("node", .string(ids.first ?? "?")),
                        ("reason", .string("rpc_resources_insufficient")),
                        ("need_per_node_gb", .jDouble((perNode * 100).rounded() / 100)),
                        ("fallback", .string(alt.name)),
                    ])
                }
            }
        default:
            break
        }

        // 5) Remote/external profile → proxy straight upstream; no local engine.
        if finalCatalog.kind != "local", let base = finalCatalog.baseUrl, !base.isEmpty {
            try? await events.publish("route.selected", [
                ("id", .string(requestId)), ("model", .string(modelName)), ("node", .string("remote")),
                ("split", .bool(false)), ("rpc_peers", .array([])),
                ("reason", .string("tier=\(tier) conf=\(String(format: "%.2f", decision.confidence)) method=\(decision.method) remote=\(finalCatalog.kind) target:\(base)")),
            ])
            await metrics.increment("routed_total")
            if let key = sessionKey, !key.isEmpty {
                await sessions.pin(key, model: modelName, tier: tier, rank: cfg.tierRank(tier))
            }
            return RouteInfo(
                requestId: requestId, virtualModel: virtual, tier: tier,
                confidence: decision.confidence, method: decision.method,
                model: modelName, node: "remote", split: false, rpcPeers: [],
                reason: "remote:\(finalCatalog.kind)", engine: Self.remoteEngine(finalCatalog, base: base),
                sticky: sticky, waitedQueueMs: 0, waitedLoadingMs: 0,
                remote: RemoteTarget(url: base, key: finalCatalog.apiKey, proto: finalCatalog.proto,
                                     model: finalCatalog.remoteModel ?? finalCatalog.name)
            )
        }

        // 6) Admission gate (queued), then load (loading) — never 503.
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
            engine = try await engines.ensureLoaded(finalCatalog, placement: placement, cfg: cfg)
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
            ("reason", .string("tier=\(tier) conf=\(String(format: "%.2f", decision.confidence)) method=\(decision.method) placement=\(finalCatalog.placement) sticky=\(sticky)")),
        ])
        await metrics.increment("routed_total")

        // 6) Prefetch: low-confidence triage may be wrong → warm the next tier.
        if decision.confidence < cfg.triageUpgradeConfidence, virtual == "auto" {
            let names = cfg.tierNames
            let idx = names.firstIndex(of: tier) ?? -1
            let nextTier = idx + 1 < names.count ? names[idx + 1] : names.last
            if let nextTier, nextTier != tier, let nextName = cfg.tiers[nextTier]?.first, let nextModel = cfg.model(nextName) {
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
            waitedQueueMs: queueWait, waitedLoadingMs: loadedWait, remote: nil
        )
    }

    static func remoteEngine(_ m: CatalogModel, base: String) -> RunningEngine {
        let now = Date()
        return RunningEngine(
            model: m.name, node: "remote", host: RemoteTarget.host(of: base), port: 0,
            pid: 0, split: false, rpcPeers: [], placement: m.kind,
            loadedAt: now, lastUsed: now, sizeGB: 0, ctx: m.ctx
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
