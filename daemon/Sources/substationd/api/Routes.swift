import Foundation
import Vapor
import NIOCore
import NIOHTTP1

/// Everything the controller needs, actor-backed and Sendable-safe.
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
    public let client = EngineClient()

    public init(
        cfg: ConfigStore, events: EventActor, metrics: MetricsActor, engines: EngineActor,
        admission: Admission, sessions: SessionActor, cache: ResponseCache, state: DaemonState,
        chat: ChatActor, nodes: NodesActor, mem: Memory
    ) {
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
            admission: admission, sessions: sessions, cache: cache, state: state
        ))
    }
}

public enum Routes {
    public static let version = "0.1.0"

    public static func registerController(_ app: Application, _ kit: Kit) throws {
        // Transparency: virtual catalog + real catalog, distinct owned_by.
        app.get("v1", "models") { req async throws -> Response in
            try await auth(req, kit)
            let cfg = await kit.cfg.snapshot
            var data: [JSONValue] = ["auto", "auto-fast", "auto-smart"].map { name in
                .object([
                    "id": .string(name),
                    "object": .string("model"),
                    "owned_by": .string("substation-virtual"),
                ])
            }
            for m in cfg.models {
                data.append(.object([
                    "id": .string(m.name),
                    "object": .string("model"),
                    "owned_by": .string("substation"),
                ]))
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
            return jsonResponse(.object([
                "state": .string(state),
                "uptime_s": .jDouble((uptime * 10).rounded() / 10),
                "requests_active": .jInt(activeReq),
                "requests_queued": .jInt(queuedReq),
                "requests_per_min": .jDouble(rpm),
                "tokens_per_sec": .jDouble((tps * 10).rounded() / 10),
                "models_loaded": .jInt(engines.count),
                "models_total": .jInt(cfg.models.count),
                "memory": .object([
                    "free_gb": .jDouble((mem.freeGB * 100).rounded() / 100),
                    "total_gb": .jDouble((mem.totalGB * 100).rounded() / 100),
                    "min_free_gb": .jDouble(cfg.minFreeRamGB),
                ]),
                "cluster_enabled": .bool(cfg.clusterEnabled),
                "engines": .array(engines.map { e in
                    .object([
                        "model": .string(e.model), "node": .string(e.node), "port": .jInt(e.port),
                        "split": .bool(e.split), "rpc_peers": .array(e.rpcPeers.map { JSONValue.string($0) }),
                    ])
                }),
                "nodes": await kit.nodes.nodesJSON(),
                "version": .string(version),
            ]))
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
                return .object([
                    "name": .string(m.name),
                    "tier": .string(m.tier),
                    "gguf": .string(m.gguf),
                    "size_gb": .jDouble(m.sizeGB),
                    "ctx": .jInt(m.ctx),
                    "placement": .string(m.placement),
                    "loaded": .bool(engine != nil),
                    "node": engine.map { JSONValue.string($0.node) } ?? .null,
                    "port": engine.map { JSONValue.jInt($0.port) } ?? .null,
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
            let id = "admin-" + String(UUID().uuidString.prefix(6))
            try? await kit.events.publish("engine.wait", [("id", .string(id)), ("ms", .jInt(0)), ("reason", .string("loading"))])
            do {
                let e = try await kit.engines.ensureLoaded(model, placement: Placement.parse(model.placement), cfg: cfg)
                return jsonResponse(.object(["loaded": .bool(true), "model": .string(e.model), "node": .string(e.node), "port": .jInt(e.port)]))
            } catch {
                throw APIError.upstream("\(error)")
            }
        }

        app.on(.POST, "api", "models", ":name", "unload", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await auth(req, kit)
            let name = req.parameters.get("name") ?? ""
            await kit.engines.unload(model: name)
            return jsonResponse(.object(["unloaded": .bool(true), "model": .string(name)]))
        }

        // MARK: Admin

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
            if cfg.clusterEnabled { _ = await kit.engines.startRPCSelf(cfg) } else { await kit.engines.stopRPCSelf() }
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

            // Joining implies clustering; persist + enable rpc-server locally.
            let keys = try await kit.cfg.applyPatch(.object(["cluster": .object(["enabled": .bool(true)])]))
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
                let link = await LinkProbe.probe(host: ip, agentPort: agentPort, cfg: cfg, events: events, client: client)
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

        // MARK: Chat

        registerChat(app, kit)

        // MARK: WebSocket

        app.webSocket("ws") { req, ws in
            Task {
                let id = await kit.events.subscribe(ws)
                await kit.events.publish("ws.hello", .object([
                    "version": .string(version),
                    "subscribers": .jInt(await kit.events.subscriberCount()),
                ]))
                ws.onClose.whenComplete { _ in
                    Task { await kit.events.unsubscribe(id) }
                }
            }
        }

        // Root fallback when webui/dist has no index.html.
        app.get { req async throws -> Response in
            let dist = (await kit.cfg.snapshot).webuiDist + "/index.html"
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
        guard constantTimeEqual(provided, token) else { throw APIError.unauthorized }
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
}
