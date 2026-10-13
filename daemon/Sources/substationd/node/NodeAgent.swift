import Foundation
import Vapor
import NIOCore

/// Node agent (`--role node`, :8801). Bearer-authed; controller heartbeats this.
public struct NodeKit: Sendable {
    public let cfg: ConfigStore
    public let events: EventActor
    public let engines: EngineActor
    public let mem: Memory
    public let client = EngineClient()
    public let nodeId: String
    public let nodeName: String
    public let joinCodeFile: String

    public init(cfg: ConfigStore, events: EventActor, engines: EngineActor, mem: Memory, dataDir: String) {
        self.cfg = cfg
        self.events = events
        self.engines = engines
        self.mem = mem
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        let idFile = dataDir + "/node_id"
        if let existing = try? String(contentsOfFile: idFile, encoding: .utf8), !existing.isEmpty {
            nodeId = existing
        } else {
            nodeId = UUID().uuidString.lowercased()
            try? nodeId.write(toFile: idFile, atomically: true, encoding: .utf8)
        }
        nodeName = HostInfo.hostName()
        joinCodeFile = dataDir + "/join_code"
    }

    /// Node's own join code: config value if set, else generate + persist.
    public func currentJoinCode() -> String {
        if let data = FileManager.default.contents(atPath: joinCodeFile),
           let code = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           code.count == 6
        {
            return code
        }
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        try? code.write(toFile: joinCodeFile, atomically: true, encoding: .utf8)
        return code
    }
}

extension NodeKit {
    static func auth(_ req: Request, _ kit: NodeKit) async throws {
        let token = await kit.cfg.snapshot.authToken
        guard !token.isEmpty else { return }
        let header = req.headers.first(name: .authorization) ?? ""
        let provided = header.hasPrefix("Bearer ") ? String(header.dropFirst(7)) : header
        guard constantTimeEqual(provided, token) else { throw APIError.unauthorized }
    }

    /// Node health: RAM via vm_stat/sysctl, gpu% skipped (0), runners, rpc_up.
    public func healthJSON() async -> JSONValue {
        let mem = await mem.read()
        let live = await engines.listLive()
        let rpcUp = await engines.rpcSelfUp
        var runners: [JSONValue] = []
        for e in live {
            let rate = await engines.decodeRate(e.key) ?? 0
            runners.append(.object([
                "model": .string(e.model),
                "port": .jInt(e.port),
                "state": .string("ok"),
                "tok_s": .jDouble((rate * 100).rounded() / 100),
            ]))
        }
        return .object([
            "ram_used_gb": .jDouble(((mem.totalGB - mem.freeGB) * 100).rounded() / 100),
            "ram_total_gb": .jDouble((mem.totalGB * 100).rounded() / 100),
            "gpu_pct": .jDouble(0),
            "runners": .array(runners),
            "rpc_up": .bool(rpcUp),
        ])
    }
}

public enum NodeRoutes {
    public static func register(_ app: Application, _ kit: NodeKit) throws {
        app.get("api", "node", "health") { req async throws -> Response in
            try await NodeKit.auth(req, kit)
            return jsonResponse(await kit.healthJSON())
        }

        // Bandwidth probe blob: streams `mbps` MB of zeros in a chunked body.
        app.get("api", "node", "blob") { req async throws -> Response in
            try await NodeKit.auth(req, kit)
            let mb = min(64, max(1, Int(req.query[String.self, at: "mbps"] ?? "16") ?? 16))
            let total = mb * 1_048_576
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .contentType, value: "application/octet-stream")
            return Response(status: .ok, headers: headers, body: .init(asyncStream: { writer in
                let chunk = ByteBuffer(bytes: [UInt8](repeating: 0, count: 131_072))
                var sent = 0
                while sent < total {
                    try await writer.write(.buffer(chunk))
                    sent += 131_072
                }
                try await writer.write(.end)
            }))
        }

        app.on(.POST, "api", "node", "runner", "spawn", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await NodeKit.auth(req, kit)
            let body = try await Routes.jsonBody(req)
            guard let model = body["model"]?.stringValue, let port = body["port"]?.intValue else {
                throw APIError.badRequest("model + port required")
            }
            let cfg = await kit.cfg.snapshot
            guard let catalog = cfg.model(model) else {
                throw APIError.notFound("model \(model) not in node catalog")
            }
            let rpc = body["rpc"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            let ts = body["tensor_split"]?.arrayValue?.compactMap { $0.stringValue } ?? ["1"]
            let placement: Placement = rpc.isEmpty ? .local : .split(["local"] + rpc)
            do {
                let e = try await kit.engines.ensureSpawnedLocally(
                    catalog, port: port, rpc: rpc, tensorSplit: ts, cfg: cfg, placement: placement
                )
                return jsonResponse(.object(["spawned": .bool(true), "model": .string(model), "port": .jInt(e.port)]))
            } catch {
                throw APIError.upstream("\(error)")
            }
        }

        app.on(.POST, "api", "node", "runner", "kill", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await NodeKit.auth(req, kit)
            let body = try await Routes.jsonBody(req)
            let model = body["model"]?.stringValue ?? ""
            await kit.engines.unload(model: model)
            return jsonResponse(.object(["killed": .bool(true), "model": .string(model)]))
        }

        app.on(.POST, "api", "node", "rpc", "start", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await NodeKit.auth(req, kit)
            let ok = await kit.engines.startRPCSelf(await kit.cfg.snapshot)
            return jsonResponse(.object(["rpc_up": .bool(ok)]), status: ok ? .ok : .serviceUnavailable)
        }

        app.on(.POST, "api", "node", "rpc", "stop", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await NodeKit.auth(req, kit)
            await kit.engines.stopRPCSelf()
            return jsonResponse(.object(["rpc_up": .bool(false)]))
        }

        // Node's own join-code endpoint (spec §6). Generates a code when none set.
        app.on(.POST, "api", "admin", "join-code", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await NodeKit.auth(req, kit)
            let code = kit.currentJoinCode()
            return jsonResponse(.object(["code": .string(code), "expires_in": .jInt(600)]))
        }

        // Controller pushes a rotated key here (authed with the CURRENT key) so
        // the whole cluster moves to the new key together.
        app.on(.POST, "api", "admin", "set-key", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await NodeKit.auth(req, kit)
            let body = (try? await Routes.jsonBody(req)) ?? .object([:])
            guard let key = body["key"]?.stringValue, !key.isEmpty else {
                return jsonResponse(.object(["error": .object(["message": .string("missing key"), "code": .string("bad_request")])]), status: .badRequest)
            }
            _ = try? await kit.cfg.setDotted("daemon.auth_token", .string(key))
            return jsonResponse(.object(["ok": .bool(true)]))
        }

        // Peer join receiver (spec §6): forwards code to controller /join-relay.
        app.on(.POST, "api", "cluster", "join", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await NodeKit.auth(req, kit)
            let body = try await Routes.jsonBody(req)
            let controller = body["controller_ip"]?.stringValue ?? ""
            let cfg = await kit.cfg.snapshot
            let code = body["code"]?.stringValue ?? kit.currentJoinCode()
            guard !controller.isEmpty else { throw APIError.badRequest("controller_ip required") }
            let selfBody: JSONValue = .object([
                "node_id": .string(kit.nodeId),
                "name": .string(kit.nodeName),
                "ip": .string(HostInfo.primaryIP()),
                "agent_port": .jInt(cfg.agentPort),
                "rpc_port": .jInt(cfg.rpcPort),
                "code": .string(code),
            ])
            do {
                let (status, resp) = try await kit.client.json(
                    method: "POST",
                    url: "http://\(controller):\(cfg.port)/api/cluster/join-relay",
                    body: selfBody,
                    bearer: cfg.authToken,
                    timeout: 15
                )
                if status >= 400 {
                    throw APIError.upstream("controller rejected join (HTTP \(status))")
                }
                return jsonResponse(resp ?? .object(["joined": .bool(true)]))
            } catch let e as APIError {
                throw e
            } catch {
                throw APIError.upstream("\(error)")
            }
        }
    }
}
