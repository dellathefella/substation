import Foundation

/// Auto-tuner: picks the best set of tier→models for the current hardware,
/// aligns their context windows, and chooses placement (local vs split) with
/// cluster/RPC resource awareness. `applyPatch` rewrites the catalog accordingly.
public enum Tuner {
    public struct Pick: Sendable {
        public var tier: String
        public var model: String?
        public var placement: String
        public var ctx: Int
        public var totalGB: Double
        public var fits: Bool
        public var reason: String
        public var json: JSONValue {
            .object([
                "tier": .string(tier),
                "model": model.map { JSONValue.string($0) } ?? .null,
                "placement": .string(placement),
                "ctx": .jInt(ctx),
                "total_gb": .jDouble((totalGB * 100).rounded() / 100),
                "fits": .bool(fits),
                "reason": .string(reason),
            ])
        }
    }

    public struct Report: Sendable {
        public var picks: [Pick]
        public var alignedCtx: Int
        public var ctxWasMisaligned: Bool
        public var clusterEnabled: Bool
        public var nodes: [String]
        public var localFreeGB: Double
        public var gpuWiredLimitGB: Double
        public var warnings: [String]
        public var summary: String
        public var json: JSONValue {
            .object([
                "picks": .array(picks.map { $0.json }),
                "aligned_ctx": .jInt(alignedCtx),
                "ctx_was_misaligned": .bool(ctxWasMisaligned),
                "cluster_enabled": .bool(clusterEnabled),
                "nodes": .array(nodes.map { JSONValue.string($0) }),
                "local_free_gb": .jDouble((localFreeGB * 100).rounded() / 100),
                "gpu_wired_limit_gb": .jDouble((gpuWiredLimitGB * 100).rounded() / 100),
                "warnings": .array(warnings.map { JSONValue.string($0) }),
                "summary": .string(summary),
            ])
        }
    }

    public static func analyze(cfg: ConfigSnapshot, mem: Memory, nodes: NodesActor) async -> Report {
        let local = await mem.read()
        let limit = ResourceEstimator.gpuWiredLimitGB(totalGB: local.totalGB)
        let peers = await nodes.allNodes().map(\.id)
        var peerFree: [String: Double] = [:]
        for p in peers { if let f = await nodes.freeGB(p) { peerFree[p] = f } }
        var warnings: [String] = []

        // Estimate total footprint (weights+KV+overhead) for a model.
        func total(_ m: CatalogModel) -> Double {
            ResourceEstimator.estimate(model: m, freeGB: local.freeGB, totalGB: local.totalGB,
                                       residentGB: 0, minFreeGB: 0).totalGB
        }
        func fitsLocal(_ m: CatalogModel) -> Bool {
            ResourceEstimator.estimate(model: m, freeGB: local.freeGB, totalGB: local.totalGB,
                                       residentGB: 0, minFreeGB: cfg.minFreeRamGB).fits
        }
        func fitsSplit(_ m: CatalogModel) -> Bool {
            guard cfg.clusterEnabled, !peers.isEmpty else { return false }
            let perNode = ResourceEstimator.splitPerNodeGB(weightsGB: m.sizeGB, ctx: m.ctx,
                                                           slots: m.slots, nodeCount: 1 + peers.count)
            var minFree = local.freeGB
            for p in peers { if let f = peerFree[p] { minFree = min(minFree, f) } }
            return minFree >= perNode
        }

        let pool = cfg.models.sorted { $0.sizeGB < $1.sizeGB }
        guard !pool.isEmpty else {
            return Report(picks: [], alignedCtx: cfg.defaultCtx, ctxWasMisaligned: false,
                          clusterEnabled: cfg.clusterEnabled, nodes: peers, localFreeGB: local.freeGB,
                          gpuWiredLimitGB: limit, warnings: ["No catalog models available to tune."],
                          summary: "No models to tune.")
        }

        let fitsAny = pool.filter { fitsLocal($0) || fitsSplit($0) }
        let smart = (fitsLocal(pool[pool.count - 1]) ? [pool[pool.count - 1]] : fitsAny.filter { fitsLocal($0) }).last
            ?? fitsAny.first
        let fast = fitsAny.first ?? pool.first
        let smartGB = smart?.sizeGB ?? 0
        let fastGB = fast?.sizeGB ?? 0
        let balanced = fitsAny.first(where: { $0.name != smart?.name && $0.name != fast?.name
            && $0.sizeGB >= fastGB && $0.sizeGB <= max(smartGB, $0.sizeGB) })
            ?? pool.first(where: { $0.name != smart?.name && $0.name != fast?.name })

        func placementFor(_ m: CatalogModel) -> String {
            fitsLocal(m) ? "local" : (fitsSplit(m) ? "split:local+" + peers.joined(separator: "+") : "local")
        }
        var picks: [Pick] = []
        if let fast {
            picks.append(Pick(tier: "fast", model: fast.name, placement: "local", ctx: fast.ctx,
                              totalGB: total(fast), fits: fitsLocal(fast),
                              reason: fitsLocal(fast) ? "smallest model → lowest-latency tier" : "smallest model (does not fit in current free RAM)"))
        }
        if let balanced {
            picks.append(Pick(tier: "balanced", model: balanced.name,
                              placement: placementFor(balanced), ctx: balanced.ctx, totalGB: total(balanced),
                              fits: fitsLocal(balanced) || fitsSplit(balanced),
                              reason: "median-capacity model for general traffic"))
        }
        if let smart {
            let pl = placementFor(smart)
            let why = fitsLocal(smart)
                ? "largest model that fits locally"
                : "largest model; fits only when split across nodes"
            picks.append(Pick(tier: "smart", model: smart.name, placement: pl, ctx: smart.ctx,
                              totalGB: total(smart), fits: fitsLocal(smart) || fitsSplit(smart), reason: why))
        }
        let ordered = ["fast", "balanced", "smart"]
        picks.sort { (ordered.firstIndex(of: $0.tier) ?? 9) < (ordered.firstIndex(of: $1.tier) ?? 9) }

        // Align context to the smallest ctx among the chosen set.
        let chosen = picks.compactMap { $0.model.flatMap { cfg.model($0) } }
        let ctxs = chosen.map(\.ctx)
        let aligned = ctxs.min() ?? cfg.defaultCtx
        if Set(ctxs).count > 1 {
            warnings.append("Selected models had differing context windows (\(ctxs.map(String.init).joined(separator: ", "))); align all to \(aligned) so auto-switching is transparent.")
        }
        if let smart, !fitsLocal(smart), !fitsSplit(smart) {
            warnings.append("\(smart.name) (~\(String(format: "%.1f", total(smart))) GB) fits neither locally nor split; reduce quant/ctx or add nodes.")
        }
        if !picks.contains(where: { $0.tier == "balanced" }) {
            warnings.append("Only one distinct model fits comfortably; fast/balanced/smart may collapse to the same model.")
        }

        let summary = "\(picks.count) tiers tuned for \(String(format: "%.0f", local.totalGB)) GB local"
            + (cfg.clusterEnabled ? " + \(peers.count) node(s)" : " (cluster off)")
            + "; context aligned to \(aligned) ctx."
        return Report(picks: picks, alignedCtx: aligned, ctxWasMisaligned: Set(ctxs).count > 1,
                      clusterEnabled: cfg.clusterEnabled, nodes: peers, localFreeGB: local.freeGB,
                      gpuWiredLimitGB: limit, warnings: warnings, summary: summary)
    }

    /// Rewrite tiers + aligned ctx.
    public static func applyPatch(report: Report) -> JSONValue {
        var tiers: [String: JSONValue] = [:]
        for p in report.picks {
            if let m = p.model { tiers[p.tier] = .object(["models": .array([.string(m)])]) }
        }
        return .object(["orchestrator": .object([
            "tiers": .object(tiers),
            "default_ctx": .jInt(report.alignedCtx),
        ])])
    }
}
