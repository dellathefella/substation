import Foundation
import Vapor

/// Minimal MCP server (Model Context Protocol, JSON-RPC 2.0).
/// HTTP: POST /mcp (stateless request/response).
/// stdio: `substationd mcp` — newline JSON-RPC on stdin/stdout, proxying to the
/// local controller so agents can spawn it as a subprocess without deps.
enum MCP {
    static let protocolVersion = "2025-03-26"

    static let tools: [JSONValue] = [
        tool("substation_status", "Daemon status: state, models loaded, tokens/sec, cluster state, auto mode availability.", [:]),
        tool("substation_metrics", "Live metrics: latency percentiles, throughput, cache hit ratio, triage distribution.", [:]),
        tool("substation_events", "Recent routing decisions (transparent view of real model/node per request).", ["limit": "number"]),
        tool("substation_models", "Model catalog with load state and placement. Returns REAL model ids (admin surface).", [:]),
        tool("substation_chat", "Orchestrated chat via the auto router. model defaults to 'auto' (real model chosen per request).", ["prompt": "string", "model": "string", "session": "string"]),
        tool("substation_model_load", "Load a catalog model into memory now.", ["name": "string"]),
        tool("substation_model_unload", "Unload a catalog model to free memory.", ["name": "string"]),
        tool("substation_cluster", "Cluster state: joined nodes, link probes, RDMA warnings. action=unjoin [node].", ["action": "string", "node": "string"]),
        tool("substation_config", "Runtime config. action=get | set {key,value} | reset (factory template, clears cluster).", ["action": "string", "key": "string", "value": "string"]),
        tool("substation_pause", "Pause or resume routing. action=pause|resume.", ["action": "string"]),
    ]

    static func tool(_ name: String, _ desc: String, _ props: [String: String]) -> JSONValue {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(props.mapValues { JSONValue.object(["type": .string($0)]) }),
        ])
        return .object([
            "name": .string(name),
            "description": .string(desc),
            "inputSchema": schema,
        ])
    }

    /// Full JSON-RPC response for one request message.
    static func respond(_ body: JSONValue, base: String, bearer: String) async -> JSONValue {
        let id = body["id"] ?? .null
        let method = body["method"]?.stringValue ?? ""
        switch method {
        case "initialize":
            return result(id, .object([
                "protocolVersion": .string(protocolVersion),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string("substation"), "version": .string("0.1.0")]),
            ]))
        case "tools/list":
            return result(id, .object(["tools": .array(tools)]))
        case "tools/call":
            let name = body["params"]?["name"]?.stringValue ?? ""
            let args = body["params"]?["arguments"] ?? .object([:])
            let (text, isError) = await call(name: name, args: args, base: base, bearer: bearer)
            return result(id, .object([
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string(text),
                ])]),
                "isError": .bool(isError),
            ]))
        default:
            return .object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "error": .object(["code": .jInt(-32601), "message": .string("method not found: \(method)")]),
            ])
        }
    }

    private static func result(_ id: JSONValue, _ value: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": value])
    }

    private static func call(name: String, args: JSONValue, base: String, bearer: String) async -> (String, Bool) {
        let session = URLSession(configuration: .ephemeral)
        func get(_ path: String) async -> (String, Bool) { await raw(base + path, "GET", nil, bearer, session) }
        func post(_ path: String, _ obj: JSONValue) async -> (String, Bool) {
            await raw(base + path, "POST", JSONCoding.encode(obj), bearer, session)
        }
        switch name {
        case "substation_status": return await get("/api/status")
        case "substation_metrics": return await get("/api/metrics")
        case "substation_events":
            let n = args["limit"]?.intValue ?? 20
            return await get("/api/events?limit=\(n)")
        case "substation_models": return await get("/api/models")
        case "substation_chat":
            guard let prompt = args["prompt"]?.stringValue, !prompt.isEmpty else {
                return ("missing prompt", true)
            }
            let model = args["model"]?.stringValue ?? "auto"
            var body: [String: JSONValue] = [
                "model": .string(model),
                "messages": .array([.object([
                    "role": .string("user"),
                    "content": .string(prompt),
                ])]),
                "stream": .bool(false),
            ]
            if let s = args["session"]?.stringValue { body["user"] = .string(s) }
            let (text, err) = await raw(base + "/v1/chat/completions", "POST", JSONCoding.encode(.object(body)), bearer, session)
            if err { return (text, true) }
            if let v = JSONCoding.decode(Data(text.utf8)), let c = v["choices"]?[0]?["message"]?["content"]?.stringValue {
                return (c, false)
            }
            return (text, false)
        case "substation_model_load":
            guard let n = args["name"]?.stringValue else { return ("missing name", true) }
            return await post("/api/models/\(n)/load", .object([:]))
        case "substation_model_unload":
            guard let n = args["name"]?.stringValue else { return ("missing name", true) }
            return await post("/api/models/\(n)/unload", .object([:]))
        case "substation_cluster":
            switch args["action"]?.stringValue ?? "status" {
            case "unjoin":
                let q = args["node"]?.stringValue.map { "?node=\($0)" } ?? ""
                return await post("/api/cluster/unjoin\(q)", .object([:]))
            default:
                return await get("/api/nodes")
            }
        case "substation_config":
            switch args["action"]?.stringValue ?? "get" {
            case "reset": return await post("/api/admin/reset-config", .object([:]))
            case "set":
                guard let key = args["key"]?.stringValue,
                      let raw = args["value"]?.stringValue,
                      let v = JSONCoding.decode(Data(raw.utf8))
                else { return ("set needs key + JSON value", true) }
                var patch = v
                for part in key.split(separator: ".").reversed() { patch = .object([String(part): patch]) }
                return await putJSON(base + "/api/config", patch, bearer, session)
            default: return await get("/api/config")
            }
        case "substation_pause":
            let a = args["action"]?.stringValue == "resume" ? "resume" : "pause"
            return await post("/api/admin/\(a)", .object([:]))
        default:
            return ("unknown tool: \(name)", true)
        }
    }

    private static func raw(_ url: String, _ method: String, _ body: Data?, _ bearer: String, _ session: URLSession) async -> (String, Bool) {
        guard let u = URL(string: url) else { return ("bad url", true) }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.timeoutInterval = 120
        if !bearer.isEmpty { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? ""
            return (text, status >= 400)
        } catch {
            return ("request failed: \(error.localizedDescription)", true)
        }
    }

    private static func putJSON(_ url: String, _ obj: JSONValue, _ bearer: String, _ session: URLSession) async -> (String, Bool) {
        guard let u = URL(string: url) else { return ("bad url", true) }
        var req = URLRequest(url: u)
        req.httpMethod = "PUT"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !bearer.isEmpty { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        req.httpBody = JSONCoding.encode(obj)
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (String(data: data, encoding: .utf8) ?? "", status >= 400)
        } catch {
            return ("request failed: \(error.localizedDescription)", true)
        }
    }

    /// stdio gateway loop (newline-delimited JSON-RPC).
    static func stdio(base: String, bearer: String) async {
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let msg = JSONCoding.decode(Data(trimmed.utf8)) else { continue }
            let out = await respond(msg, base: base, bearer: bearer)
            FileHandle.standardOutput.write(Data((JSONCoding.encodeString(out) + "\n").utf8))
        }
    }
}
