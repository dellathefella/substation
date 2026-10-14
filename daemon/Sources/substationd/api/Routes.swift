import NIOHTTP1
import Security
import Foundation
import Vapor
import NIOCore
import NIOHTTP1

/// Everything the controller needs, actor-backed and Sendable-safe.
enum LogFiles {
    static func safeLogName(_ name: String) -> String? {
        let n = name.replacingOccurrences(of: "/", with: "")
        guard n.hasSuffix(".log"), !n.contains(".."), !n.isEmpty else { return nil }
        return n
    }

    static func listLogs(_ dir: String) -> [JSONValue] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: dir))?.filter { $0.hasSuffix(".log") }.sorted() ?? []
        return files.map { f in
            let attrs = try? fm.attributesOfItem(atPath: dir + "/" + f)
            return .object([
                "name": .string(f),
                "bytes": .jDouble(Double(attrs?[.size] as? Int ?? 0)),
                "mtime_ms": .jDouble(Double((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000),
            ])
        }
    }

    static func sendLog(_ req: Request, logsDir: String, name raw: String?, tail rawTail: Int?) throws -> Response {
        guard let raw = raw, let name = safeLogName(raw) else {
            throw APIError.badRequest("invalid log name")
        }
        let tail = rawTail ?? 300
        let path = logsDir + "/" + name
        guard let data = FileManager.default.contents(atPath: path) else {
            throw APIError.notFound("no log \(name)")
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.suffix(max(1, min(tail, 5000)))
        return jsonResponse(.object([
            "name": .string(name),
            "lines": .jInt(lines.count),
            "tail": .jInt(kept.count),
            "text": .array(kept.map { .string(String($0)) }),
        ]))
    }
}

public struct Kit: Sendable {
    public let cfg: ConfigStore
    public let events: EventActor
    public let metrics: MetricsActor
    public let engines: EngineActor
    public let admission: Admission
    public let sessions: SessionActor
    public let cache: ResponseCache
    public let state: DaemonState
    public let chat: ChatActor
    public let nodes: NodesActor
    public let mem: Memory
    public let pipeline: ChatPipeline
    public let system: System
    public let dataDir: String
    public let deploy: DeployActor
    public let webuiDir: String
    public let client = EngineClient()
    public let usage = TokenUsage()

    public init(
        cfg: ConfigStore, events: EventActor, metrics: MetricsActor, engines: EngineActor,
        admission: Admission, sessions: SessionActor, cache: ResponseCache, state: DaemonState,
        chat: ChatActor, nodes: NodesActor, mem: Memory, system: System, dataDir: String,
        deploy: DeployActor,
        webuiDir: String = "webui/dist"
    ) {
        self.system = system
        self.dataDir = dataDir
        self.deploy = deploy
        self.webuiDir = webuiDir
        self.cfg = cfg
        self.events = events
        self.metrics = metrics
        self.engines = engines
        self.admission = admission
        self.sessions = sessions
        self.cache = cache
        self.state = state
        self.chat = chat
        self.nodes = nodes
        self.mem = mem
        self.pipeline = ChatPipeline(orch: Orchestrator(
            cfg: cfg, events: events, metrics: metrics, engines: engines,
            admission: admission, sessions: sessions, cache: cache, state: state,
            usage: usage, mem: mem, nodes: nodes
        ))
    }
}

/// HTML must never be cached: assets are content-hashed, but a stale
/// index.html pins the browser to an old bundle (old hashed JS 404s after
/// each rebuild). Hashed assets may cache; HTML always revalidates.
public struct NoCacheHTML: Middleware {
    public init() {}
    public func respond(to request: Request, chainingTo next: any Responder) -> EventLoopFuture<Response> {
        next.respond(to: request).map { res in
            let path = request.url.path
            if path == "/" || path.hasSuffix(".html") || !path.contains(".") {
                res.headers.replaceOrAdd(name: .cacheControl, value: "no-cache, must-revalidate")
            } else if path.hasPrefix("/assets/") {
                res.headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=31536000, immutable")
            }
            return res
        }
    }
}

public enum Routes {
    public static let version = "0.1.0"

    /// CSPRNG API key: "sub_" + 40 hex chars.
    public static func newAPIKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 20)
        let ok = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if ok != errSecSuccess { for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) } }
        return "sub_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func registerController(_ app: Application, _ kit: Kit) throws {
        // Transparency: virtual catalog + real catalog, distinct owned_by.
        app.get("v1", "models") { req async throws -> Response in
            try await auth(req, kit)
            let cfg = await kit.cfg.snapshot
            let autoOK = Orchestrator.defaultModelName(cfg) != nil
            let orchUp = await kit.engines.orchestratorReady(cfg: cfg)
            var data: [JSONValue] = []
            if cfg.orchestratorEnabled {
                data += (["auto"] + cfg.tierNames.map { "auto-\($0)" }).map { name in
                    .object([
                        "id": .string(name),
                        "object": .string("model"),
                        "owned_by": .string("substation-virtual"),
                        "substation": .object([
                            "auto_available": .bool(name != "auto" || autoOK),
                            "auto_router": .string("enabled"),
                            "orchestrator_up": .bool(orchUp),
                            "triage_model_present": .bool(FileManager.default.fileExists(atPath: cfg.triageGguf)),
                        ]),
                    ])
                }
            }
            for m in cfg.models {
                var obj: [String: JSONValue] = [
                    "id": .string(m.name),
                    "object": .string("model"),
                    "owned_by": .string(m.kind == "local" ? "substation" : "substation-\(m.kind)"),
                    "substation": .object([
                        "kind": .string(m.kind),
                        "tier": .string(m.tier),
                        "placement": .string(m.placement),
                        "auto_router": .string(cfg.orchestratorEnabled ? "enabled" : "disabled"),
                    ]),
                ]
                if let b = m.baseUrl { obj["base_url"] = .string(b) }
                data.append(.object(obj))
            }
            return jsonResponse(.object(["object": .string("list"), "data": .array(data)]))
        }

        app.on(.POST, "v1", "chat", "completions", body: .collect(maxSize: "64mb")) { req async throws -> Response in
            do {
                try await auth(req, kit)
                let body = try await Routes.jsonBody(req)
                let session = req.headers.first(name: "X-Substation-Session")
                    ?? body["user"]?.stringValue
                let streaming = body["stream"]?.boolValue ?? false
                if streaming {
                    return try await kit.pipeline.stream(body: body, sessionKey: session)
                } else {
                    return try await kit.pipeline.complete(body: body, sessionKey: session)
                }
            } catch let e as APIError {
                return e.abortResponse
            }
        }

        // MARK: Status / metrics / events

        app.get("api", "status") { req async throws -> Response in
            try await auth(req, kit)
            let cfg = await kit.cfg.snapshot
            let engines = await kit.engines.listLive()
            let activeReq = await kit.admission.activeCount
            let queuedReq = await kit.admission.waiterCount
            let mem = await kit.mem.read()
            let rpm = await kit.metrics.requestsPerMin()
            let tps = await kit.metrics.tokensPerSec()
            let state = await kit.state.state()
            let uptime = await kit.state.uptimeS()
            let resident = engines.reduce(0.0) { $0 + $1.sizeGB }
            let gpuLimit = ResourceEstimator.gpuWiredLimitGB(totalGB: mem.totalGB, macosReserveGB: cfg.macosReserveGB)
            let ramUsed = mem.totalGB - mem.freeGB
            let pressure: String
            if mem.freeGB < cfg.minFreeRamGB || ramUsed > gpuLimit { pressure = "critical" }
            else if mem.freeGB < cfg.minFreeRamGB * 2 { pressure = "warn" }
            else { pressure = "ok" }
            var obj: [String: JSONValue] = [
                "state": .string(state),
                "uptime_s": .jDouble((uptime * 10).rounded() / 10),
                "requests_active": .jInt(activeReq),
                "requests_queued": .jInt(queuedReq),
                "requests_per_min": .jDouble(rpm),
                "tokens_per_sec": .jDouble((tps * 10).rounded() / 10),
                "models_loaded": .jInt(engines.count),
                "models_total": .jInt(cfg.models.count),
            ]
            obj["memory"] = .object([
                "free_gb": .jDouble((mem.freeGB * 100).rounded() / 100),
                "used_gb": .jDouble((ramUsed * 100).rounded() / 100),
                "total_gb": .jDouble((mem.totalGB * 100).rounded() / 100),
                "min_free_gb": .jDouble(cfg.minFreeRamGB),
                "resident_gb": .jDouble((resident * 100).rounded() / 100),
                "gpu_wired_limit_gb": .jDouble((gpuLimit * 100).rounded() / 100),
                "pressure": .string(pressure),
                "local_enabled": .bool(cfg.localEnabled),
            ])
            obj["system"] = await kit.system.json()
            obj["cluster_enabled"] = .bool(cfg.clusterEnabled)
            obj["auto_router"] = .string(cfg.orchestratorEnabled ? "enabled" : "disabled")
            obj["auto_available"] = .bool(!cfg.orchestratorEnabled || Orchestrator.defaultModelName(cfg) != nil)
            obj["orchestrator_up"] = .bool(await kit.engines.orchestratorReady(cfg: cfg))
            obj["default_model"] = Orchestrator.defaultModelName(cfg).map { JSONValue.string($0) } ?? .null
            obj["engines"] = .array(engines.map { e in
                .object([
                    "model": .string(e.model), "node": .string(e.node), "port": .jInt(e.port),
                    "split": .bool(e.split), "rpc_peers": .array(e.rpcPeers.map { JSONValue.string($0) }),
                    "ctx": .jInt(e.ctx),
                    "weights_gb": .jDouble((e.sizeGB * 10).rounded() / 10),
                    "gpu_footprint_gb": .jDouble((e.gpuFootprintGB * 10).rounded() / 10),
                ])
            })
            // GPU wired-memory budget: per-node + global across the cluster.
            // Each node reports its own wired limit in health; we sum resident
            // engine footprints per node. The controller's own machine is
            // folded into the co-located node agent (same IP) so it's never
            // double-counted.
            let localIP = HostInfo.primaryIP()
            let healthyNodes = (await kit.nodes.allNodes()).filter { $0.healthy }
            let localCovered = healthyNodes.contains { $0.ip == localIP }
            let localResident = engines.filter { $0.node == "local" }.reduce(0.0) { $0 + $1.gpuFootprintGB }
            var perNode: [JSONValue] = []
            var clusterLimit = 0.0
            var clusterResident = 0.0
            // The controller's own machine as a GPU line only when no node
            // agent already represents it.
            if !localCovered {
                clusterLimit += gpuLimit
                clusterResident += localResident
                perNode.append(.object([
                    "node": .string("local"),
                    "wired_limit_gb": .jDouble((gpuLimit * 10).rounded() / 10),
                    "resident_gb": .jDouble((localResident * 10).rounded() / 10),
                    "headroom_gb": .jDouble(((gpuLimit - localResident) * 10).rounded() / 10),
                ]))
            }
            for n in healthyNodes {
                let nodeLimit = n.lastHealth?["gpu_wired_limit_gb"]?.doubleValue
                    ?? (n.lastHealth?["ram_total_gb"]?.doubleValue ?? 0) * 0.75
                var nodeResident = engines.filter { $0.node == n.id }.reduce(0.0) { $0 + $1.gpuFootprintGB }
                if n.ip == localIP { nodeResident += localResident }   // fold controller-local engines in
                clusterLimit += nodeLimit
                clusterResident += nodeResident
                perNode.append(.object([
                    "node": .string(n.id),
                    "wired_limit_gb": .jDouble((nodeLimit * 10).rounded() / 10),
                    "resident_gb": .jDouble((nodeResident * 10).rounded() / 10),
                    "headroom_gb": .jDouble(((nodeLimit - nodeResident) * 10).rounded() / 10),
                ]))
            }
            obj["gpu_budget"] = .object([
                "wired_limit_gb": .jDouble((clusterLimit * 10).rounded() / 10),
                "resident_gb": .jDouble((clusterResident * 10).rounded() / 10),
                "headroom_gb": .jDouble(((clusterLimit - clusterResident) * 10).rounded() / 10),
                "per_node": .array(perNode),
            ])
            // Same-model load-balancing view (replicas per model).
            obj["replicas"] = await kit.engines.replicaStatus(cfg: cfg)
            obj["nodes"] = await kit.nodes.nodesJSON()
            // Catalog reconciliation: which local profiles can actually be
            // served by at least one healthy node (or this host if local is on)?
            obj["catalog_reconciliation"] = Self.reconcileCatalog(cfg: cfg, nodes: await kit.nodes.allNodes())
            obj["version"] = .string(version)
            return jsonResponse(.object(obj))
        }

        app.get("api", "metrics") { req async throws -> Response in
            try await auth(req, kit)
            let snap = await kit.metrics.snapshot()
            let queue = JSONValue.jInt(await kit.admission.activeCount + kit.admission.waiterCount)
            let mem = await kit.mem.read()
            let cacheStats = await kit.cache.stats(
                enabled: (await kit.cfg.snapshot).cacheEnabled,
                maxEntries: (await kit.cfg.snapshot).cacheMaxEntries,
                slotUtil: await kit.engines.slotUtilization()
            )
            var obj = snap.objectValue ?? [:]
            obj["queue_depth"] = queue
            obj["cache"] = cacheStats
            obj["token_usage"] = await kit.usage.snapshotJSON()
            obj["memory"] = .object([
                "free_gb": .jDouble((mem.freeGB * 100).rounded() / 100),
                "total_gb": .jDouble((mem.totalGB * 100).rounded() / 100),
            ])
            return jsonResponse(.object(obj))
        }

        app.get("api", "events") { req async throws -> Response in
            try await auth(req, kit)
            let limit = Int(req.query[String.self, at: "limit"] ?? "200") ?? 200
            let events = await kit.events.recent(limit: limit)
            let arr = events.map { e -> JSONValue in
                (try? JSONEncoder().encode(e)).flatMap { JSONCoding.decode($0) } ?? .null
            }
            return jsonResponse(.array(arr))
        }

        app.get("api", "cache") { req async throws -> Response in
            try await auth(req, kit)
            let cfg = await kit.cfg.snapshot
            return jsonResponse(await kit.cache.stats(
                enabled: cfg.cacheEnabled, maxEntries: cfg.cacheMaxEntries,
                slotUtil: await kit.engines.slotUtilization()
            ))
        }

        // MARK: Models

        app.get("api", "models") { req async throws -> Response in
            try await auth(req, kit)
            let cfg = await kit.cfg.snapshot
            let live = await kit.engines.list()
            return jsonResponse(.array(cfg.models.map { m in
                let engine = live.first { $0.model == m.name }
                var masked: String?
                if let k = m.apiKey, !k.isEmpty {
                    masked = k.count > 8 ? String(k.prefix(4)) + "…" + String(k.suffix(4)) : "****"
                }
                return .object([
                    "name": .string(m.name),
                    "kind": .string(m.kind),
                    "tier": .string(m.tier),
                    "gguf": .string(m.gguf),
                    "size_gb": .jDouble(m.sizeGB),
                    "ctx": .jInt(m.ctx),
                    "placement": .string(m.placement),
                    "loaded": .bool(engine != nil),
                    "enabled": .bool(m.enabled),
                    "vision": .bool(m.vision),
                    "node": engine.map { JSONValue.string($0.node) } ?? (m.node.map { JSONValue.string($0) } ?? .null),
                    "flags": .array(m.flags.map { JSONValue.string($0) }),
                    "port": engine.map { JSONValue.jInt($0.port) } ?? .null,
                    "base_url": m.baseUrl.map { JSONValue.string($0) } ?? .null,
                    "remote_model": m.remoteModel.map { JSONValue.string($0) } ?? .null,
                    "protocol": .string(m.proto),
                    "api_key_masked": masked.map { JSONValue.string($0) } ?? .null,
                ])
            }))
        }

        app.on(.POST, "api", "models", ":name", "load", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await auth(req, kit)
            let name = req.parameters.get("name") ?? ""
            let cfg = await kit.cfg.snapshot
            guard let model = cfg.model(name) else {
                throw APIError.notFound("model \(name)")
            }
            guard model.enabled else {
                throw APIError.badRequest("profile \(name) is dormant (enabled = false in config)")
            }
            guard model.kind == "local" else {
                throw APIError.badRequest("\(model.kind) profiles are served by their upstream — nothing to load locally")
            }
            let id = "admin-" + String(UUID().uuidString.prefix(6))
            try? await kit.events.publish("engine.wait", [("id", .string(id)), ("ms", .jInt(0)), ("reason", .string("loading"))])
            do {
                let e = try await kit.engines.ensureLoaded(model, placement: Placement.parse(model.placement), cfg: cfg)
                return jsonResponse(.object(["loaded": .bool(true), "model": .string(e.model), "node": .string(e.node), "port": .jInt(e.port)]))
            } catch let err as EngineError {
                if case .tooLarge(let m) = err { throw APIError.noCapacity(m) }
                throw APIError.upstream("\(err)")
            } catch {
                throw APIError.upstream("\(error)")
            }
        }

        app.on(.POST, "api", "models", ":name", "unload", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await auth(req, kit)
            let name = req.parameters.get("name") ?? ""
            let cfg = await kit.cfg.snapshot
            let body = (try? await Routes.jsonBody(req)) ?? .object([:])
            let force = body["force"]?.boolValue ?? false
            await kit.engines.unload(model: name, cfg: cfg, force: force)
            return jsonResponse(.object(["unloaded": .bool(true), "model": .string(name), "force": .bool(force)]))
        }

        // Force-kill a llama-server by port on a node — for an orphan the
        // daemon no longer tracks (crashed / half-killed load still holding
        // GPU). Proxies to the node agent's kill_port.
        app.on(.POST, "api", "nodes", ":id", "force-kill-port", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await auth(req, kit)
            let id = req.parameters.get("id") ?? ""
            let cfg = await kit.cfg.snapshot
            guard let n = cfg.node(id) else { throw APIError.notFound("node \(id)") }
            let body = try await Routes.jsonBody(req)
            let port = body["port"]?.intValue ?? 0
            guard port > 0 else { throw APIError.badRequest("port required") }
            do {
                let (status, val) = try await kit.client.json(
                    method: "POST",
                    url: "http://\(n.host):\(n.agentPort)/api/node/runner/kill_port",
                    body: .object(["port": .jInt(port)]),
                    bearer: cfg.authToken, timeout: 15
                )
                if status >= 400 { throw APIError.upstream("node \(id) kill_port HTTP \(status)") }
                return jsonResponse(val ?? .object(["killed_pid": .null]))
            } catch let e as APIError { throw e }
            catch { throw APIError.upstream("\(error)") }
        }

        // Restart a loaded engine in place (kill + respawn same placement).
        app.on(.POST, "api", "models", ":name", "restart", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await auth(req, kit)
            let name = req.parameters.get("name") ?? ""
            let cfg = await kit.cfg.snapshot
            let mine = await kit.engines.listLive().filter { $0.model == name }
            guard !mine.isEmpty else {
                return jsonResponse(.object(["error": .object(["message": .string("\(name) is not loaded"), "code": .string("not_loaded")])]), status: .notFound)
            }
            var done: [String] = []
            for e in mine {
                if await kit.engines.respawn(e, cfg: cfg) { done.append(e.node) }
            }
            let nodesJSON: [JSONValue] = done.map { JSONValue.string($0) }
            try? await kit.events.publish("engine.restarted", .object([
                "model": JSONValue.string(name), "nodes": JSONValue.array(nodesJSON),
            ]))
            return jsonResponse(.object([
                "restarted": .bool(!done.isEmpty), "model": .string(name), "nodes": JSONValue.array(nodesJSON),
            ]))
        }

        app.on(.POST, "api", "engines", "restart-all", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await auth(req, kit)
            let cfg = await kit.cfg.snapshot
            let live = await kit.engines.listLive()
            var done: [String] = []
            for e in live {
                if await kit.engines.respawn(e, cfg: cfg) { done.append("\(e.model)@\(e.node)") }
            }
            let enginesJSON: [JSONValue] = done.map { JSONValue.string($0) }
            try? await kit.events.publish("engine.restarted", .object([
                "all": JSONValue.bool(true), "engines": JSONValue.array(enginesJSON),
            ]))
            return jsonResponse(.object(["restarted": .jInt(done.count), "engines": JSONValue.array(enginesJSON)]))
        }

        // Preflight memory estimate for a catalog model (warn before load).
        app.get("api", "models", ":name", "estimate") { req async throws -> Response in
            try await auth(req, kit)
            let name = req.parameters.get("name") ?? ""
            let cfg = await kit.cfg.snapshot
            guard let model = cfg.model(name) else { throw APIError.notFound("model \(name)") }
            let mem = await kit.mem.read()
            let resident = await kit.engines.list().reduce(0.0) { $0 + $1.sizeGB }
            let est = ResourceEstimator.estimate(model: model, freeGB: mem.freeGB,
                                                 totalGB: mem.totalGB, residentGB: resident,
                                                 minFreeGB: cfg.minFreeRamGB)
            return jsonResponse(est.json)
        }

        // Resource monitor: live memory pressure + per-model preflight estimates.
        app.get("api", "resources") { req async throws -> Response in
            try await auth(req, kit)
            let cfg = await kit.cfg.snapshot
            let mem = await kit.mem.read()
            let live = await kit.engines.list()
            let resident = live.reduce(0.0) { $0 + $1.sizeGB }
            let limit = ResourceEstimator.gpuWiredLimitGB(totalGB: mem.totalGB, macosReserveGB: cfg.macosReserveGB)
            let used = mem.totalGB - mem.freeGB
            let pressure: String
            if mem.freeGB < cfg.minFreeRamGB || used > limit { pressure = "critical" }
            else if mem.freeGB < cfg.minFreeRamGB * 2 { pressure = "warn" }
            else { pressure = "ok" }
            let estimates = cfg.models.map { m -> JSONValue in
                ResourceEstimator.estimate(model: m, freeGB: mem.freeGB, totalGB: mem.totalGB,
                                           residentGB: resident, minFreeGB: cfg.minFreeRamGB).json
            }
            return jsonResponse(.object([
                "ram_total_gb": .jDouble((mem.totalGB * 100).rounded() / 100),
                "ram_used_gb": .jDouble((used * 100).rounded() / 100),
                "ram_free_gb": .jDouble((mem.freeGB * 100).rounded() / 100),
                "resident_gb": .jDouble((resident * 100).rounded() / 100),
                "gpu_wired_limit_gb": .jDouble((limit * 100).rounded() / 100),
                "pressure": .string(pressure),
                "local_enabled": .bool(cfg.localEnabled),
                "min_free_gb": .jDouble(cfg.minFreeRamGB),
                "engines": .array(live.map { .object([
                    "model": .string($0.model), "node": .string($0.node), "size_gb": .jDouble($0.sizeGB),
                ]) }),
                "estimates": .array(estimates),
            ]))
        }

        // MARK: Admin

        // Auto-tuner: analyze + apply.
        app.get("api", "tune", "analyze") { req async throws -> Response in
            try await auth(req, kit)
            let cfg = await kit.cfg.snapshot
            let report = await Tuner.analyze(cfg: cfg, mem: kit.mem, nodes: kit.nodes)
            return jsonResponse(report.json)
        }
        app.on(.POST, "api", "tune", "apply") { req async throws -> Response in
            try await auth(req, kit)
            let cfg = await kit.cfg.snapshot
            let report = await Tuner.analyze(cfg: cfg, mem: kit.mem, nodes: kit.nodes)
            try await kit.cfg.applyPatch(Tuner.applyPatch(report: report))
            try? await kit.events.publish("config.changed", [("keys", .array([.string("orchestrator.tiers"), .string("orchestrator.default_ctx")])), ("tuned", .bool(true))])
            return jsonResponse(.object(["ok": .bool(true), "applied": report.json]))
        }

        app.on(.POST, "api", "admin", "pause", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await auth(req, kit)
            await kit.state.setPaused(true)
            try? await kit.events.publish("admin.pause", .object(["by": .string("api")]))
            return jsonResponse(.object(["ok": .bool(true), "state": .string("paused")]))
        }

        app.on(.POST, "api", "admin", "resume", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await auth(req, kit)
            await kit.state.setPaused(false)
            try? await kit.events.publish("admin.resume", .object(["by": .string("api")]))
            return jsonResponse(.object(["ok": .bool(true), "state": .string("running")]))
        }

        app.on(.POST, "api", "admin", "reload", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await auth(req, kit)
            try await kit.cfg.reload()
            let cfg = await kit.cfg.snapshot
            await kit.events.configure(ringSize: cfg.eventRingSize)
            await kit.admission.configure(cfg.maxConcurrentRequests)
            try? await kit.events.publish("config.changed", .object(["keys": .array([.string("reload")])]))
            return jsonResponse(.object(["ok": .bool(true)]))
        }

        app.on(.POST, "api", "admin", "join-code", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await auth(req, kit)
            let code = await kit.nodes.issueJoinCode(ttlSeconds: 600)
            try? await kit.events.publish("admin.join_code", .object(["expires_in": .jInt(600)]))
            return jsonResponse(.object(["code": .string(code), "expires_in": .jInt(600)]))
        }

        // MARK: Config

        app.get("api", "config") { req async throws -> Response in
            try await auth(req, kit)
            let cfg = await kit.cfg.snapshot
            return jsonResponse(redactSecrets(cfg.raw))
        }

        app.on(.PUT, "api", "config", body: .collect(maxSize: "4mb")) { req async throws -> Response in
            try await auth(req, kit)
            let patch = try await Routes.jsonBody(req)
            let keys = try await kit.cfg.applyPatch(patch)
            let cfg = await kit.cfg.snapshot
            await kit.events.configure(ringSize: cfg.eventRingSize)
            await kit.admission.configure(cfg.maxConcurrentRequests)
            if cfg.clusterEnabled && cfg.localEnabled { _ = await kit.engines.startRPCSelf(cfg) } else { await kit.engines.stopRPCSelf(port: (await kit.cfg.snapshot).rpcPort) }
            try? await kit.events.publish("config.changed", .object([
                "keys": .array(keys.map { JSONValue.string($0) }),
            ]))
            return jsonResponse(redactSecrets(cfg.raw))
        }

        // MARK: Cluster / discovery / nodes

        app.get("api", "nodes") { req async throws -> Response in
            try await auth(req, kit)
            return jsonResponse(await kit.nodes.nodesJSON())
        }

        app.get("api", "discovery") { req async throws -> Response in
            try await auth(req, kit)
            return jsonResponse(await kit.nodes.peersJSON())
        }

        // CLI `substationd join` posts here; controller registers the node.
        app.on(.POST, "api", "cluster", "join-relay", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await auth(req, kit)
            let body = try await Routes.jsonBody(req)
            let code = body["code"]?.stringValue ?? ""
            guard await kit.nodes.consumeJoinCode(code) else {
                throw APIError.unauthorized
            }
            let nodeId = body["node_id"]?.stringValue ?? "peer-\(String(UUID().uuidString.prefix(6)))"
            let name = body["name"]?.stringValue ?? nodeId
            let ip = body["ip"]?.stringValue ?? "127.0.0.1"
            let agentPort = body["agent_port"]?.intValue ?? 8801
            let rpcPort = body["rpc_port"]?.intValue ?? 50052
            await kit.nodes.register(id: nodeId, name: name, ip: ip, agentPort: agentPort, rpcPort: rpcPort)

            // Joining implies clustering; persist node + enable rpc-server locally.
            let keys = try await kit.cfg.applyPatch(.object([
                "cluster": .object(["enabled": .bool(true)]),
                "nodes": .object([nodeId: .object([
                    "host": .string(ip),
                    "agent_port": .jInt(agentPort),
                    "rpc_port": .jInt(rpcPort),
                ])]),
            ]))
            let cfg = await kit.cfg.snapshot
            _ = await kit.engines.startRPCSelf(cfg)
            try? await kit.events.publish("config.changed", .object(["keys": .array(keys.map { JSONValue.string($0) })]))
            try? await kit.events.publish("node.health", .object([
                "node": .string(nodeId), "ram_used_gb": .jDouble(0), "ram_total_gb": .jDouble(0),
                "gpu_pct": .jDouble(0), "runners": .array([]), "joined": .bool(true),
            ]))

            // Link probe (non-blocking for the caller).
            let nodesActor = kit.nodes
            let events = kit.events
            let client = kit.client
            Task.detached(priority: .utility) {
                // Ask the peer to bring up its rpc worker, then probe the link.
                _ = try? await client.json(
                    method: "POST",
                    url: "http://\(ip):\(agentPort)/api/node/rpc/start",
                    body: .object([:]),
                    timeout: 15
                )
                let link = await LinkProbe.probe(host: ip, agentPort: agentPort, tbHost: cfg.node(nodeId)?.rpcHost, cfg: cfg, events: events, client: client)
                await nodesActor.setLink(id: nodeId, link: link)
            }
            return jsonResponse(.object(["joined": .bool(true), "node_id": .string(nodeId)]))
        }

        app.on(.POST, "api", "cluster", ":node", "plumb-thunderbolt", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await auth(req, kit)
            let node = req.parameters.get("node") ?? ""
            let idx = max(1, await kit.nodes.allNodes().count)
            let cmd = "networksetup -setmanual \"Thunderbolt Bridge\" 10.99.\(idx).1 255.255.255.0"
            try? await kit.events.publish("admin.plumb", .object(["node": .string(node)]))
            return jsonResponse(.object([
                "node": .string(node),
                "command": .string(cmd),
                "applied": .bool(false),
                "peer_command": .string("networksetup -setmanual \"Thunderbolt Bridge\" 10.99.\(idx).2 255.255.255.0"),
                "note": .string("needs admin; run on both ends; controller re-probes within 60s"),
            ]))
        }

        // Controller-side RPC worker control: self, or proxied to one joined node.
        app.on(.POST, "api", "admin", "restart", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await auth(req, kit)
            try? await kit.events.publish("daemon.restarting", .object(["scope": .string("self")]))
            DaemonRestart.scheduleSelfRestart(preExit: { await kit.engines.shutdownAll() })
            return jsonResponse(.object(["restarting": .bool(true)]))
        }

        app.on(.POST, "api", "cluster", "restart-daemons", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await auth(req, kit)
            let cfg = await kit.cfg.snapshot
            let nodes = await kit.nodes.allNodes()
            Task { await DaemonRestart.restartFleet(nodes: nodes, client: kit.client, token: cfg.authToken, kitEvents: kit.events, preExit: { await kit.engines.shutdownAll() }) }
            return jsonResponse(.object(["restarting": .bool(true), "peers": .jInt(nodes.count)]))
        }

        app.on(.POST, "api", "cluster", "rpc-self", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await auth(req, kit)
            let body = (try? await Routes.jsonBody(req)) ?? .object([:])
            let start = body["start"]?.boolValue ?? true
            let up: Bool
            if start { up = await kit.engines.startRPCSelf(await kit.cfg.snapshot) }
            else { await kit.engines.stopRPCSelf(port: (await kit.cfg.snapshot).rpcPort); up = false }
            return jsonResponse(.object(["rpc_up": .bool(up)]), status: (!start || up) ? .ok : .serviceUnavailable)
        }

        app.on(.POST, "api", "cluster", "rpc-peer", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await auth(req, kit)
            let body = try await Routes.jsonBody(req)
            let nodeId = body["node_id"]?.stringValue ?? ""
            let start = body["start"]?.boolValue ?? true
            guard let n = await kit.nodes.node(nodeId) else {
                return jsonResponse(.object(["error": .object(["message": .string("node \(nodeId) not joined"), "code": .string("not_found")])]), status: .notFound)
            }
            let cfg = await kit.cfg.snapshot
            let url = "http://\(n.ip):\(n.agentPort)/api/node/rpc/\(start ? "start" : "stop")"
            guard let (status, val) = try? await kit.client.json(method: "POST", url: url, body: .object([:]), bearer: cfg.authToken, timeout: 15), status < 400 else {
                return jsonResponse(.object(["error": .object(["message": .string("peer \(nodeId) refused rpc/\(start ? "start" : "stop")"), "code": .string("peer_failed")])]), status: .badGateway)
            }
            try? await kit.events.publishDeduped("cluster.rpc", key: "cluster.rpc:\(body["node_id"]?.stringValue ?? "")", .object([
                "node": .string(nodeId), "start": .bool(start),
            ]), cooldown: 120, throttle: true)
            return jsonResponse(val ?? .object(["rpc_up": .bool(start)]))
        }

        // Erase a config subtree the merge-based PUT cannot express
        // (currently: custom tiers). Locked to orchestrator.tiers.<one-segment>.
        app.on(.POST, "api", "admin", "erase", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await auth(req, kit)
            let body = try await Routes.jsonBody(req)
            let path = body["path"]?.stringValue ?? ""
            let parts = path.split(separator: ".")
            guard path.hasPrefix("orchestrator.tiers."), parts.count == 3 else {
                return jsonResponse(.object(["error": .object([
                    "message": .string("only orchestrator.tiers.<name> paths may be erased"), "code": .string("bad_request"),
                ])]), status: .badRequest)
            }
            let existed = await kit.cfg.removePath(path)
            try? await kit.events.publish("config.changed", .object([
                "keys": .array([.string("orchestrator")]), "erased": .string(path),
            ]))
            return jsonResponse(.object(["ok": .bool(true), "existed": .bool(existed)]))
        }

        // Unjoin a single node (?node=id) or the whole cluster (no param).
        app.on(.POST, "api", "cluster", "unjoin") { req async throws -> Response in
            try await auth(req, kit)
            if let node = req.query[String.self, at: "node"] {
                await kit.nodes.unregister(id: node)
                await kit.cfg.removePath("nodes.\(node)")
                try? await kit.events.publish("node.unjoined", [("node", .string(node))])
            } else {
                await kit.nodes.clearCluster()
                await kit.cfg.removePath("nodes")
                _ = try? await kit.cfg.applyPatch(.object(["cluster": .object(["enabled": .bool(false)])]))
                await kit.engines.stopRPCSelf(port: (await kit.cfg.snapshot).rpcPort)
                try? await kit.events.publish("cluster.disabled", [("reason", .string("unjoined"))])
            }
            let remaining = await kit.nodes.allNodes().count
            return jsonResponse(.object([
                "ok": .bool(true), "nodes_remaining": .jInt(remaining),
                "rpc_server_stopped": .bool(remaining == 0),
            ]))
        }

        // Rotate the global API key. Cuts over immediately; returns the new key
        // exactly once. Reset-config (factory template) clears it (disables auth).
        app.on(.POST, "api", "admin", "rotate-key") { req async throws -> Response in
            try await auth(req, kit)
            let oldKey = await kit.cfg.snapshot.authToken
            let key = Routes.newAPIKey()
            // Push to peers while the old key is still valid; all-or-nothing.
            var pushed: [String] = []
            for n in await kit.nodes.allNodes() {
                let r = try? await kit.client.json(
                    method: "POST",
                    url: "http://\(n.ip):\(n.agentPort)/api/admin/set-key",
                    body: .object(["key": .string(key)]),
                    bearer: oldKey,
                    timeout: 10
                )
                if let r, r.0 >= 400 {
                    return jsonResponse(.object(["error": .object([
                        "message": .string("peer \(n.id) refused rotation (\(r.0)); nothing rotated"),
                        "code": .string("rotation_failed"),
                    ])]), status: .badGateway)
                }
                pushed.append(n.id)
            }
            _ = try await kit.cfg.setDotted("daemon.auth_token", .string(key))
            try? await kit.events.publish("admin.key.rotated", [("at", .jDouble(Date().timeIntervalSince1970 * 1000))])
            return jsonResponse(.object([
                "ok": .bool(true),
                "key": .string(key),
                "nodes_updated": .array(pushed.map { JSONValue.string($0) }),
                "note": .string("new key effective now; update webui/menubar clients and MCP env. Reset-config disables auth"),
            ]))
        }

        // Reset config to factory defaults (keeps models on disk; clears cluster).
        app.on(.POST, "api", "admin", "reset-config") { req async throws -> Response in
            try await auth(req, kit)
            try await kit.cfg.reset(to: TOML.parse(ConfigDefaults.toml))
            await kit.nodes.clearCluster()
            await kit.engines.stopRPCSelf(port: (await kit.cfg.snapshot).rpcPort)
            let keys: [String] = ["*"]
            try? await kit.events.publish("config.changed", [("keys", .array(keys.map { JSONValue.string($0) })), ("reset", .bool(true))])
            return jsonResponse(.object(["ok": .bool(true), "reset": .bool(true)]))
        }

        // MARK: MCP server (HTTP transport, JSON-RPC 2.0)

        app.on(.POST, "mcp", body: .collect(maxSize: "2mb")) { req async throws -> Response in
            try await auth(req, kit)
            let body = try await Routes.jsonBody(req)
            let cfg = await kit.cfg.snapshot
            let out = await MCP.respond(body, base: "http://127.0.0.1:\(cfg.port)", bearer: cfg.authToken)
            return jsonResponse(out)
        }

        // MARK: Chat

        registerChat(app, kit)
        registerAnthropic(app, kit)
        registerConnectors(app, kit)

        // MARK: WebSocket


        // MARK: Engine logs (llama.cpp / ggml-rpc diagnostics)

        app.get("api", "logs") { req async throws -> Response in
            try await auth(req, kit)
            return jsonResponse(.object(["logs": .array(LogFiles.listLogs(kit.engines.logsDir))]))
        }

        app.get("api", "logs", ":name") { req async throws -> Response in
            try await auth(req, kit)
            return try LogFiles.sendLog(req, logsDir: kit.engines.logsDir,
                                 name: req.parameters.get("name") ?? "", tail: req.query[Int.self, at: "tail"])
        }

        app.get("api", "cluster", "logs") { req async throws -> Response in
            try await auth(req, kit)
            guard let nodeId = req.query[String.self, at: "node"],
                  let n = await kit.nodes.node(nodeId) else {
                return jsonResponse(.object(["error": .object(["message": .string("node required"), "code": .string("bad_request")])]), status: .badRequest)
            }
            let cfg = await kit.cfg.snapshot
            // With ?name=… → tail that file; without → list the node's log files.
            let url: String
            if let name = req.query[String.self, at: "name"], !name.isEmpty {
                let tail = req.query[Int.self, at: "tail"] ?? 300
                url = "http://\(n.ip):\(n.agentPort)/api/node/logs?name=\(name)&tail=\(tail)"
            } else {
                url = "http://\(n.ip):\(n.agentPort)/api/node/logs"
            }
            guard let (status, val) = try? await kit.client.json(method: "GET", url: url, bearer: cfg.authToken, timeout: 10), status < 400 else {
                return jsonResponse(.object(["error": .object(["message": .string("node \(nodeId) unreachable"), "code": .string("peer_failed")])]), status: .badGateway)
            }
            var obj = val?.objectValue ?? [:]
            obj["node"] = .string(nodeId)
            return jsonResponse(.object(obj))
        }

        app.webSocket("ws") { req, ws in
            let loop = ws.eventLoop
            let id = await kit.events.subscribe(ws)
            // Hello goes to THIS socket only — not the global event feed.
            let hello = Event("ws.hello", .object([
                "version": .string(version),
                "subscribers": .jInt(await kit.events.subscriberCount()),
            ]))
            if let data = try? JSONEncoder().encode(hello), let val = JSONCoding.decode(data) {
                let str = JSONCoding.encodeString(val)
                try? await loop.submit { try ws.send(str) }.get()
            }
            // Liveness: protocol ping every 20 s (browsers auto-pong via
            // onPong); no pong for 45 s (wifi black-hole) → force close.
            try? await loop.submit {
                try ws.onPong { _, _ in
                    Task { await kit.events.pong(from: id) }
                }
                ws.onClose.whenComplete { _ in
                    Task { await kit.events.unsubscribe(id) }
                }
            }.get()
            Task.detached(priority: .background) {
                while true {
                    let closed = try? await loop.submit { ws.isClosed }.get()
                    if closed == true { break }
                    do {
                        try await loop.submit { try ws.sendPing() }.get()
                    } catch {
                        break
                    }
                    let last = await kit.events.lastPong(id) ?? Date().timeIntervalSince1970
                    if Date().timeIntervalSince1970 - last > 45 {
                        try? await loop.flatSubmit { ws.close() }.get()
                        break
                    }
                    try? await Task.sleep(for: .seconds(20))
                }
            }
        }

        // Root fallback when webui/dist has no index.html.
        app.get { req async throws -> Response in
            let dist = kit.webuiDir + "/index.html"
            if FileManager.default.fileExists(atPath: dist),
               let data = FileManager.default.contents(atPath: dist)
            {
                var headers = HTTPHeaders()
                headers.replaceOrAdd(name: .contentType, value: "text/html; charset=utf-8")
                return Response(status: .ok, headers: headers, body: .init(buffer: ByteBuffer(data: data)))
            }
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .contentType, value: "text/html; charset=utf-8")
            return Response(status: .ok, headers: headers, body: .init(string:
                "<html><body><h1>Substation</h1><p>Controller running. Build webui/dist to enable the dashboard. API: <code>/api/status</code>, <code>/ws</code>.</p></body></html>"))
        }
    }

    // MARK: Helpers

    static func auth(_ req: Request, _ kit: Kit) async throws {
        let token = await kit.cfg.snapshot.authToken
        guard !token.isEmpty else { return }
        let header = req.headers.first(name: .authorization) ?? ""
        let provided = header.hasPrefix("Bearer ") ? String(header.dropFirst(7)) : header
        guard constantTimeEqual(provided, token) else {
            throw Abort(.unauthorized, reason: "missing or invalid bearer token")
        }
    }

    static func jsonBody(_ req: Request) async throws -> JSONValue {
        guard let buffer = try await req.body.collect(max: 64 * 1024 * 1024).get(),
              buffer.readableBytes > 0,
              let v = JSONCoding.decode(Data(buffer: buffer))
        else {
            throw APIError.badRequest("expected a JSON body")
        }
        return v
    }

    static func redactSecrets(_ v: JSONValue) -> JSONValue {
        var obj = v.objectValue ?? [:]
        if var d = obj["daemon"]?.objectValue {
            if d["auth_token"]?.stringValue?.isEmpty == false { d["auth_token"] = .string("<redacted>") }
            obj["daemon"] = .object(d)
        }
        return .object(obj)
    }

    /// Reconcile the controller's local model profiles against what each
    /// healthy node actually reports it can serve (catalog entry present on
    /// disk). Profiles with no capable node are surfaced as "unservable" so a
    /// controller↔node catalog mismatch is visible before a request fails.
    static func reconcileCatalog(cfg: ConfigSnapshot, nodes: [NodeEntry]) -> JSONValue {
        let localProfiles = cfg.models.filter { $0.kind == "local" }
        let fm = FileManager.default
        var nodeServes: [(id: String, names: Set<String>)] = []
        for n in nodes where n.healthy {
            var names = Set<String>()
            if let cat = n.lastHealth?["catalog"]?.arrayValue {
                for c in cat where c["exists"]?.boolValue == true {
                    if let nm = c["name"]?.stringValue { names.insert(nm) }
                }
            }
            nodeServes.append((n.id, names))
        }
        var perProfile: [JSONValue] = []
        var unservable: [String] = []
        for p in localProfiles {
            var capable: [String] = []
            if cfg.localEnabled && fm.fileExists(atPath: p.gguf) { capable.append("local") }
            for ns in nodeServes where ns.names.contains(p.name) { capable.append(ns.id) }
            if capable.isEmpty { unservable.append(p.name) }
            perProfile.append(.object([
                "profile": .string(p.name),
                "capable_nodes": .array(capable.map { JSONValue.string($0) }),
            ]))
        }
        return .object([
            "profiles": .array(perProfile),
            "unservable": .array(unservable.map { JSONValue.string($0) }),
        ])
    }
}
