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

    public let system: System

    public init(cfg: ConfigStore, events: EventActor, engines: EngineActor, mem: Memory, dataDir: String, system: System) {
        self.system = system
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
        // Report this node's local catalog (name + whether the GGUF is present)
        // so the controller can reconcile profiles against what we can actually
        // serve, and surface "controller has a profile this node can't run".
        let snap = await cfg.snapshot
        let fm = FileManager.default
        var catalog: [JSONValue] = []
        for m in snap.models where m.kind == "local" {
            catalog.append(.object([
                "name": .string(m.name),
                "gguf": .string(m.gguf),
                "exists": .bool(fm.fileExists(atPath: m.gguf)),
            ]))
        }
        return .object([
            "ram_used_gb": .jDouble(((mem.totalGB - mem.freeGB) * 100).rounded() / 100),
            "ram_total_gb": .jDouble((mem.totalGB * 100).rounded() / 100),
            "gpu_pct": .jDouble(0),
            "runners": .array(runners),
            "rpc_up": .bool(rpcUp),
            "catalog": .array(catalog),
            "system": await system.json(),
        ])
    }
}

public enum NodeRoutes {
    public static func register(_ app: Application, _ kit: NodeKit) throws {
        // Landing page: this is a headless node agent, not the console.
        app.get("") { req async throws -> Response in
            let nodeId = String(kit.nodeId.prefix(8))
            let html = """
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="refresh" content="300">
            <title>Substation node \(nodeId)</title>
            <style>
            body{background:#0d1017;color:#d7dce5;font:14px/1.5 -apple-system,system-ui,sans-serif;display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0}
            .card{background:#151a24;border:1px solid #232b3a;border-radius:12px;padding:28px 34px;min-width:340px;max-width:480px}
            h1{font-size:16px;margin:0 0 4px;color:#fff} .dim{color:#8a94a6;font-size:12px}
            .pill{display:inline-block;padding:2px 10px;border-radius:99px;font-size:11px;margin:10px 6px 14px 0}
            .ok{background:#12331f;color:#5fd98a} .off{background:#2a2333;color:#9a8fb0}
            .bar{height:8px;background:#232b3a;border-radius:4px;overflow:hidden;margin:6px 0 2px}
            .bar>i{display:block;height:100%;background:#3f8cff}
            table{width:100%;border-collapse:collapse;margin-top:12px;font-size:12px}
            td{padding:4px 6px;border-top:1px solid #232b3a} .mono{font-family:ui-monospace,monospace}
            a{color:#5aa2ff}
            </style></head><body><div class="card">
            <h1>⬢ Substation node <span class="mono">\(nodeId)</span></h1>
            <div class="dim">headless worker agent — no console here</div>
            <div id="pills"><span class="pill off">connecting…</span></div>
            <div class="dim" id="ram">RAM</div><div class="bar"><i id="rambar" style="width:0%"></i></div>
            <div class="dim" style="margin-top:10px">runners</div>
            <table id="runners"><tr><td class="dim">none loaded</td></tr></table>
            <div class="dim" style="margin-top:16px">Console lives on the controller — <span class="mono">http://&lt;controller&gt;:8800</span></div>
            </div><script>
            async function tick(){
              try{
                const r = await fetch('/api/node/health'); const d = await r.json();
                const pills = document.getElementById('pills');
                pills.innerHTML = '<span class="pill '+(d.rpc_up?'ok':'off')+'">rpc '+(d.rpc_up?'up':'down')+'</span>'
                  + '<span class="pill ok">healthy</span>';
                const used = d.ram_used_gb||0, tot = d.ram_total_gb||1;
                document.getElementById('ram').textContent = 'RAM '+used.toFixed(1)+' / '+tot.toFixed(0)+' GB';
                document.getElementById('rambar').style.width = Math.min(100, used/tot*100)+'%';
                const t = document.getElementById('runners');
                if (d.runners && d.runners.length){
                  t.innerHTML = d.runners.map(x=>'<tr><td class="mono">'+x.model+'</td><td class="dim">:'+x.port+'</td></tr>').join('');
                } else { t.innerHTML = '<tr><td class="dim">none loaded</td></tr>'; }
              }catch(e){
                document.getElementById('pills').innerHTML = '<span class="pill off">agent unreachable</span>';
              }
            }
            tick(); setInterval(tick, 3000);
            </script></body></html>
            """
            return Response(status: .ok, headers: [
                "Content-Type": "text/html; charset=utf-8",
                "Cache-Control": "no-store",
            ], body: .init(string: html))
        }

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

        app.on(.POST, "api", "admin", "restart", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await NodeKit.auth(req, kit)
            try? await kit.events.publish("daemon.restarting", .object(["scope": .string("node-self")]))
            DaemonRestart.scheduleSelfRestart(preExit: { await kit.engines.shutdownAll() })
            return jsonResponse(.object(["restarting": .bool(true)]))
        }

        app.on(.POST, "api", "node", "rpc", "start", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await NodeKit.auth(req, kit)
            let ok = await kit.engines.startRPCSelf(await kit.cfg.snapshot)
            return jsonResponse(.object(["rpc_up": .bool(ok)]), status: ok ? .ok : .serviceUnavailable)
        }

        app.on(.POST, "api", "node", "rpc", "stop", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await NodeKit.auth(req, kit)
            await kit.engines.stopRPCSelf(port: (await kit.cfg.snapshot).rpcPort)
            return jsonResponse(.object(["rpc_up": .bool(false)]))
        }

        app.get("api", "node", "logs") { req async throws -> Response in
            try await NodeKit.auth(req, kit)
            // With ?name=… → tail that file; without → list the node's log files.
            if let name = req.query[String.self, at: "name"], !name.isEmpty {
                return try LogFiles.sendLog(req, logsDir: kit.engines.logsDir, name: name,
                                          tail: req.query[Int.self, at: "tail"])
            }
            return jsonResponse(.object(["logs": .array(LogFiles.listLogs(kit.engines.logsDir))]))
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
