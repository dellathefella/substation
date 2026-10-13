import Foundation

public struct RunningEngine: Sendable {
    public var model: String
    public var node: String       // "local" or node id
    public var host: String       // reachable host
    public var port: Int
    public var pid: Int32         // 0 when remote
    public var split: Bool
    public var rpcPeers: [String]
    public var placement: String
    public var loadedAt: Date
    public var lastUsed: Date
    public var sizeGB: Double
    public var ctx: Int

    public var key: String { "\(model)@\(node)" }
    public var baseURL: String { "http://\(host):\(port)" }
}

public enum Placement: Sendable, Hashable {
    case local
    case node(String)
    case split([String])

    public static func parse(_ s: String) -> Placement {
        if s.hasPrefix("node:") { return .node(String(s.dropFirst(5))) }
        if s.hasPrefix("split:") { return .split(s.dropFirst(6).split(separator: "+").map(String.init)) }
        return .local
    }
}

/// Supervises llama-server engines + the triage engine + optional rpc-server.
public actor EngineActor {
    private var engines: [String: RunningEngine] = [:]
    private var usedPorts: Set<Int> = []
    private var lastMetrics: [String: (tokens: Double, seconds: Double)] = [:]
    private var slotUtil: [String: (used: Int, slots: Int)] = [:]
    private var triagePid: Int32 = 0
    private var rpcPid: Int32 = 0
    private var lastDecodeRates: [String: Double] = [:]

    private let events: EventActor
    private let metrics: MetricsActor
    private let mem: Memory
    private let nodes: NodesActor
    private let client = EngineClient()
    private let sleepGuard = SleepGuard()

    public var sleepPrevented: Bool { sleepGuard.isActive }

    private func refreshSleepFromLive(_ live: [RunningEngine]) {
        sleepGuard.setActive(live.contains { $0.pid > 0 })
    }

    public init(events: EventActor, metrics: MetricsActor, mem: Memory, nodes: NodesActor) {
        self.events = events
        self.metrics = metrics
        self.mem = mem
        self.nodes = nodes
    }

    // MARK: - Spawning

    private func spawnProcess(_ exec: String, args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: (exec as NSString).isAbsolutePath ? exec : FileManager.default.currentDirectoryPath + "/" + exec)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        let binDir = (p.executableURL?.deletingLastPathComponent().path ?? "")
        env["DYLD_LIBRARY_PATH"] = (env["DYLD_LIBRARY_PATH"].map { binDir + ":" + $0 }) ?? binDir
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return 0
        }
        return p.processIdentifier
    }

    public func startTriageIfNeeded(_ cfg: ConfigSnapshot) async {
        guard triagePid == 0, !cfg.triageGguf.isEmpty,
              FileManager.default.fileExists(atPath: cfg.llamaServer)
        else { return }
        if await isHealthOK(url: "http://127.0.0.1:\(cfg.triagePort)/health") { return }
        let pid = spawnProcess(cfg.llamaServer, args: [
            "-m", cfg.triageGguf,
            "--alias", "substation-triage",
            "--host", "127.0.0.1",
            "--port", String(cfg.triagePort),
            "-c", "2048",
            "--metrics",
        ])
        triagePid = pid
        usedPorts.insert(cfg.triagePort)
    }

    public func stopTriage() {
        if triagePid > 0 { kill(triagePid, SIGTERM); triagePid = 0 }
    }

    private var triageHealthCache: (at: Date, ok: Bool)?
    /// Cached (2s) health probe of the resident triage engine.
    public func triageHealthy(cfg: ConfigSnapshot) async -> Bool {
        if let c = triageHealthCache, Date().timeIntervalSince(c.at) < 2 { return c.ok }
        let ok = await isHealthOK(url: "http://127.0.0.1:\(cfg.triagePort)/health")
        triageHealthCache = (Date(), ok)
        return ok
    }

    /// Orchestrator is "ready" only when the triage GGUF exists AND its engine answers.
    public func orchestratorReady(cfg: ConfigSnapshot) async -> Bool {
        guard FileManager.default.fileExists(atPath: cfg.triageGguf) else { return false }
        return await triageHealthy(cfg: cfg)
    }

    public func startRPCSelf(_ cfg: ConfigSnapshot) -> Bool {
        if rpcPid > 0 { return true }
        guard FileManager.default.isExecutableFile(atPath: cfg.rpcServer) else { return false }
        rpcPid = spawnProcess(cfg.rpcServer, args: ["--host", "0.0.0.0", "--port", String(cfg.rpcPort)])
        return rpcPid > 0
    }

    public func stopRPCSelf() {
        if rpcPid > 0 { kill(rpcPid, SIGTERM); rpcPid = 0 }
    }

    public var rpcSelfUp: Bool { rpcPid > 0 && kill(rpcPid, 0) == 0 }

    // MARK: - Ensure loaded

    /// Ensures `model` is served at the placement target; loads synchronously
    /// (clients never see a "loading" error, only latency).
    public func ensureLoaded(_ model: CatalogModel, placement: Placement, cfg: ConfigSnapshot) async throws -> RunningEngine {
        let (node, splitPeers, isSplit): (String, [String], Bool)
        switch placement {
        case .local:
            (node, splitPeers, isSplit) = ("local", [], false)
        case .node(let n):
            (node, splitPeers, isSplit) = (cfg.clusterEnabled ? n : "local", [], false)
        case .split(var ids):
            // RPC profile: head + peers. "split" with no explicit ids →
            // local head + every eligible joined node. Weights are streamed
            // over RPC head→workers; worker rpc-servers run WITHOUT cache.
            if cfg.clusterEnabled {
                let joined = await nodes.allNodes()
                if ids.isEmpty { ids = ["local"] + joined.filter { $0.healthy }.map(\.id) }
                var eligible: [String] = []
                for id in ids {
                    if id == "local" || id == "self" { eligible.append(id); continue }
                    if let n = await nodes.node(id), n.healthy { eligible.append(id) }
                }
                ids = eligible
            }
            if cfg.clusterEnabled, ids.count > 1 {
                (node, splitPeers, isSplit) = (ids[0], Array(ids.dropFirst()), true)
            } else {
                (node, splitPeers, isSplit) = ("local", [], false)
            }
        }
        let key = "\(model.name)@\(node)"

        if var existing = engines[key] {
            existing.lastUsed = Date()
            engines[key] = existing
            return existing
        }

        try await evictIfNeeded(forGB: model.sizeGB, cfg: cfg)

        // Preflight resource estimate: warn (never block) if this may OOM/swap.
        let memNow = await mem.read()
        let resident = engines.values.reduce(0) { $0 + $1.sizeGB }
        let est = ResourceEstimator.estimate(model: model, freeGB: memNow.freeGB,
                                             totalGB: memNow.totalGB, residentGB: resident,
                                             minFreeGB: cfg.minFreeRamGB)
        if !est.warnings.isEmpty {
            await events.publish("resource.warning", [
                ("model", .string(model.name)),
                ("node", .string(node)),
                ("total_gb", .jDouble((est.totalGB * 100).rounded() / 100)),
                ("free_gb", .jDouble((est.freeGB * 100).rounded() / 100)),
                ("gpu_wired_limit_gb", .jDouble((est.gpuWiredLimitGB * 100).rounded() / 100)),
                ("fits", .bool(est.fits)),
                ("warnings", .array(est.warnings.map { JSONValue.string($0) })),
            ])
        }

        let t0 = Date()
        await events.publish("model.loading", [
            ("model", .string(model.name)),
            ("node", .string(node)),
            ("gb", .jDouble(model.sizeGB)),
            ("ms", .jInt(0)),
        ])

        var engine: RunningEngine
        if node == "local" {
            let port = nextPort(cfg)
            var args = [
                "-m", model.gguf,
                "--alias", model.name,
                "--host", "127.0.0.1",
                "--port", String(port),
                "-c", String(model.ctx),
                "--cache-reuse", "256",
                "--parallel", "4",
                "--metrics",
            ]
            if isSplit {
                let rpc = splitPeers.compactMap { peer in
                    cfg.node(peer).map { "\($0.host):\($0.rpcPort)" }
                }
                let weights = (["1"] + splitPeers.map { _ in "1" }).joined(separator: ",")
                args += ["--rpc", rpc.joined(separator: ","), "--tensor-split", weights]
            }
            args += model.flags
            let pid = spawnProcess(cfg.llamaServer, args: args)
            if pid == 0 { throw EngineError.notFound("cannot spawn \(cfg.llamaServer)") }
            engine = RunningEngine(
                model: model.name, node: "local", host: "127.0.0.1", port: port,
                pid: pid, split: isSplit, rpcPeers: splitPeers, placement: model.placement,
                loadedAt: Date(), lastUsed: Date(), sizeGB: model.sizeGB, ctx: model.ctx
            )
            usedPorts.insert(port)
        } else {
            guard let n = cfg.node(node) else { throw EngineError.notFound("node \(node)") }
            let port = nextPort(cfg, remote: true)
            let spawnBody: JSONValue = .object([
                "model": .string(model.name),
                "port": .jInt(port),
                "rpc": .array(splitPeers.compactMap { cfg.node($0) }.map { .string("\($0.host):\($0.rpcPort)") }),
                "tensor_split": .array([JSONValue.string("1")] + splitPeers.map { _ in .string("1") }),
            ])
            let status: Int
            do {
                (status, _) = try await client.json(
                    method: "POST",
                    url: "http://\(n.host):\(n.agentPort)/api/node/runner/spawn",
                    body: spawnBody,
                    bearer: cfg.authToken,
                    timeout: 30
                )
            }
            if status >= 400 { throw EngineError.status(status) }
            engine = RunningEngine(
                model: model.name, node: node, host: n.host, port: port,
                pid: 0, split: isSplit, rpcPeers: splitPeers, placement: model.placement,
                loadedAt: Date(), lastUsed: Date(), sizeGB: model.sizeGB, ctx: model.ctx
            )
        }

        try await waitReady(engine, cfg: cfg)
        engine.loadedAt = Date()
        engine.lastUsed = Date()
        engines[engine.key] = engine
        await metrics.increment("models_loaded_total")
        await events.publish("model.loaded", [
            ("model", .string(model.name)),
            ("node", .string(node)),
            ("gb", .jDouble(model.sizeGB)),
            ("ms", .jInt(Int(Date().timeIntervalSince(t0) * 1000))),
        ])
        return engine
    }

    /// Node-agent path: spawn a runner on the given port, bound 0.0.0.0 so the
    /// controller can reach it; optional rpc peers make it a split worker head.
    public func ensureSpawnedLocally(
        _ model: CatalogModel, port: Int, rpc: [String], tensorSplit: [String],
        cfg: ConfigSnapshot, placement: Placement
    ) async throws -> RunningEngine {
        let key = "\(model.name)@local"
        if var existing = engines[key] {
            existing.lastUsed = Date()
            engines[key] = existing
            return existing
        }
        try await evictIfNeeded(forGB: model.sizeGB, cfg: cfg)
        var args = [
            "-m", model.gguf,
            "--alias", model.name,
            "--host", "0.0.0.0",
            "--port", String(port),
            "-c", String(model.ctx),
            "--cache-reuse", "256",
            "--parallel", "4",
            "--metrics",
        ]
        if !rpc.isEmpty {
            args += ["--rpc", rpc.joined(separator: ","), "--tensor-split", tensorSplit.joined(separator: ",")]
        }
        args += model.flags
        let pid = spawnProcess(cfg.llamaServer, args: args)
        if pid == 0 { throw EngineError.notFound("cannot spawn \(cfg.llamaServer)") }
        var engine = RunningEngine(
            model: model.name, node: "local", host: HostInfo.primaryIP(), port: port,
            pid: pid, split: !rpc.isEmpty, rpcPeers: rpc, placement: model.placement,
            loadedAt: Date(), lastUsed: Date(), sizeGB: model.sizeGB, ctx: model.ctx
        )
        usedPorts.insert(port)
        try await waitReady(engine, cfg: cfg)
        engine.loadedAt = Date()
        engines[key] = engine
        await events.publish("model.loaded", [
            ("model", .string(model.name)), ("node", .string("local")),
            ("gb", .jDouble(model.sizeGB)), ("ms", .jInt(0)),
        ])
        return engine
    }

    private func waitReady(_ engine: RunningEngine, cfg: ConfigSnapshot) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(cfg.startupTimeoutS))
        while Date() < deadline {
            if await isHealthOK(url: engine.baseURL + "/health") { return }
            if engine.pid > 0, kill(engine.pid, 0) != 0 {
                throw EngineError.notFound("engine exited during load")
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw EngineError.timeout
    }

    private func isHealthOK(url: String) async -> Bool {
        guard let (status, text) = try? await client.getText(url, timeout: 2) else { return false }
        return status == 200 && text.contains("ok")
    }

    private func nextPort(_ cfg: ConfigSnapshot, remote: Bool = false) -> Int {
        var p = cfg.basePort
        while usedPorts.contains(p) || engines.values.contains(where: { $0.port == p }) { p += 1 }
        return p
    }

    // MARK: - Unload / evict

    public func unload(model: String) async {
        for (key, e) in engines where e.model == model {
            engines.removeValue(forKey: key)
            if e.pid > 0 { kill(e.pid, SIGTERM) }
            slotUtil.removeValue(forKey: key)
            lastMetrics.removeValue(forKey: key)
            await events.publish("model.unloaded", [
                ("model", .string(e.model)),
                ("node", .string(e.node)),
                ("gb", .jDouble(e.sizeGB)),
                ("ms", .jInt(0)),
            ])
        }
    }

    private func evictIfNeeded(forGB: Double, cfg: ConfigSnapshot) async throws {
        var guardCount = engines.count
        while guardCount > 0 {
            guardCount -= 1
            let info = await mem.read()
            if info.freeGB >= cfg.minFreeRamGB + max(1, forGB / 2) { return }
            let victims = engines.values
                .filter { !$0.split }
                .sorted { $0.lastUsed < $1.lastUsed }
            guard let victim = victims.first ?? engines.values.sorted(by: { $0.lastUsed < $1.lastUsed }).first else { return }
            engines.removeValue(forKey: victim.key)
            if victim.pid > 0 { kill(victim.pid, SIGTERM) }
            slotUtil.removeValue(forKey: victim.key)
            await events.publish("model.unloaded", [
                ("model", .string(victim.model)),
                ("node", .string(victim.node)),
                ("gb", .jDouble(victim.sizeGB)),
                ("ms", .jInt(0)),
                ("reason", .string("lru_evict")),
            ])
        }
    }

    // MARK: - Polling

    public func startLoops(cfg: ConfigSnapshot, cfgStore: ConfigStore) {
        let events = self.events
        let metrics = self.metrics
        let client = self.client
        Task.detached(priority: .utility) {
            while true {
                let cfgNow = await cfgStore.snapshot
                let ms = max(250, cfgNow.metricsSampleMs)
                try? await Task.sleep(for: .milliseconds(ms))
                let engines = await self.listLive()
                await self.refreshSleepFromLive(engines)
                for e in engines {
                    await self.sampleEngine(e, cfg: cfgNow)
                }
                _ = events
                _ = metrics
                _ = client
            }
        }
    }

    private func sampleEngine(_ engine: RunningEngine, cfg: ConfigSnapshot) async {
        // Engine metrics (Prometheus text)
        if let (status, text) = try? await client.getText(engine.baseURL + "/metrics", timeout: 3), status == 200 {
            let vals = Self.parseProm(text)
            if let tok = vals["llama:decode_tokens"], let sec = vals["llama:decode_seconds"] {
                if let prev = lastMetrics[engine.key] {
                    let dTok = tok - prev.tokens
                    let dSec = sec - prev.seconds
                    if dSec > 0.2, dTok >= 0 {
                        let tokS = dTok / dSec
                        lastMetrics[engine.key] = (tok, sec)
                        lastDecodeRates[engine.key] = tokS
                        await metrics.setEngineTokS(engine.key, (tokS * 100).rounded() / 100)
                        if engine.split {
                            await events.publish("rpc.sample", [
                                ("node", .string(engine.node)),
                                ("rpc_ms_last", .jInt(0)),
                                ("tok_s", .jDouble((tokS * 100).rounded() / 100)),
                            ])
                        }
                    } else {
                        lastMetrics[engine.key] = (tok, sec)
                    }
                } else {
                    lastMetrics[engine.key] = (tok, sec)
                }
            }
            if let q = vals["llama:queue_count"] { await metrics.record("queue_depth", q) }
        }
        // Slots
        if let (status, val) = try? await client.json(method: "GET", url: engine.baseURL + "/slots", timeout: 3),
           status == 200, let slots = val?.arrayValue
        {
            let used = slots.filter { ($0["state"]?.stringValue ?? "") == "busy" }.count
            slotUtil[engine.key] = (used, slots.count)
        }
    }

    public static func parseProm(_ text: String) -> [String: Double] {
        var out: [String: Double] = [:]
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("llama:"), let sp = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let name = String(line[line.startIndex..<sp])
            let rest = line[line.index(after: sp)...].trimmingCharacters(in: .whitespaces)
            if let v = Double(rest) { out[name] = v }
        }
        return out
    }

    public func listLive() -> [RunningEngine] {
        engines.values.filter { $0.pid == 0 || kill($0.pid, 0) == 0 }
    }

    public func list() -> [RunningEngine] { Array(engines.values) }

    public func slotUtilization() -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (k, v) in slotUtil {
            out[k] = .object(["used": .jInt(v.used), "slots": .jInt(v.slots)])
        }
        return out
    }

    public func decodeRate(_ key: String) -> Double? { lastDecodeRates[key] }

    public func touch(_ key: String) {
        if var e = engines[key] {
            e.lastUsed = Date()
            engines[key] = e
        }
    }
}
