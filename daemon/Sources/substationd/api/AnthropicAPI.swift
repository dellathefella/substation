import Foundation
import Vapor

/// Anthropic Messages API (/v1/messages) translated onto the same routing
/// pipeline, so Claude Code (ANTHROPIC_BASE_URL) can use Substation directly.
extension Routes {
    static func flattenContent(_ v: JSONValue?) -> String {
        guard let v else { return "" }
        if let s = v.stringValue { return s }
        if let arr = v.arrayValue {
            return arr.compactMap { block in
                block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
            }.joined(separator: "\n")
        }
        return ""
    }

    public static func anthropicToOpenAI(_ body: JSONValue) -> JSONValue? {
        guard var msgs = body["messages"]?.arrayValue else { return nil }
        var out: [JSONValue] = []
        let sys = flattenContent(body["system"])
        if !sys.isEmpty { out.append(.object(["role": .string("system"), "content": .string(sys)])) }
        msgs = msgs.filter { m in m["role"]?.stringValue == "user" || m["role"]?.stringValue == "assistant" }
        for m in msgs {
            guard let role = m["role"]?.stringValue else { continue }
            out.append(.object(["role": .string(role), "content": .string(flattenContent(m["content"]))]))
        }
        guard !out.isEmpty else { return nil }
        var obj: [String: JSONValue] = [
            "model": body["model"] ?? .string("auto"),
            "messages": .array(out),
        ]
        if body["stream"]?.boolValue == true { obj["stream"] = .bool(true) }
        if let mt = body["max_tokens"] { obj["max_tokens"] = mt }
        if let t = body["temperature"] { obj["temperature"] = t }
        if let p = body["top_p"] { obj["top_p"] = p }
        if let s = body["stop_sequences"] { obj["stop"] = s }
        return .object(obj)
    }

    static func registerAnthropic(_ app: Application, _ kit: Kit) {
        app.on(.POST, "v1", "messages", body: .collect(maxSize: "32mb")) { req async throws -> Response in
            do {
                try await auth(req, kit)
                let body = try await Routes.jsonBody(req)
                guard let open = Routes.anthropicToOpenAI(body) else {
                    throw APIError.badRequest("messages required")
                }
                let virtual = body["model"]?.stringValue ?? "auto"
                let session = req.headers.first(name: "X-Substation-Session")
                    ?? req.headers.first(name: "x-session-id")
                if body["stream"]?.boolValue == true {
                    let msgID = "msg_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24)).lowercased()
                    return try await kit.pipeline.stream(body: open, sessionKey: session, anthropic: msgID)
                }
                let resp = try await kit.pipeline.complete(body: open, sessionKey: session)
                guard let data = resp.body.data,
                      var o = JSONCoding.decode(data)?.objectValue,
                      let choice = o["choices"]?[0]
                else { return resp }
                let text = choice["message"]?["content"]?.stringValue ?? ""
                let finish = choice["finish_reason"]?.stringValue ?? "stop"
                var obj: [String: JSONValue] = [
                    "id": .string("msg_" + String((o["id"]?.stringValue ?? String(UUID().uuidString.prefix(24))).prefix(24))),
                    "type": .string("message"),
                    "role": .string("assistant"),
                    "model": .string(virtual),
                    "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                    "stop_reason": .string(finish == "length" ? "max_tokens" : "end_turn"),
                    "stop_sequence": .null,
                ]
                if let u = o["usage"] {
                    obj["usage"] = .object([
                        "input_tokens": u["prompt_tokens"] ?? .jInt(0),
                        "output_tokens": u["completion_tokens"] ?? .jInt(0),
                    ])
                }
                return jsonResponse(.object(obj), extra: [("cache-control", "no-cache")])
            } catch let e as APIError {
                return e.abortResponse
            }
        }

        app.on(.POST, "v1", "messages", "count_tokens", body: .collect(maxSize: "32mb")) { req async throws -> Response in
            try await auth(req, kit)
            let body = try await Routes.jsonBody(req)
            let data = JSONCoding.encode(body)
            let tokens = max(1, data.count / 4)
            return jsonResponse(.object(["input_tokens": .jInt(tokens)]))
        }
    }

    /// Ready-made client configs for common harnesses, built from the daemon's
    /// real listen address (bind + port) and current auth state.
    static func registerConnectors(_ app: Application, _ kit: Kit) {
        app.get("api", "connectors") { req async throws -> Response in
            try await auth(req, kit)
            let cfg = await kit.cfg.snapshot
            let lan = HostInfo.primaryIP()
            let listenHost: String
            switch cfg.bind {
            case "0.0.0.0", "", "::", "*": listenHost = lan.isEmpty ? "127.0.0.1" : lan
            default: listenHost = cfg.bind
            }
            var bases: [JSONValue] = [.object([
                "label": .string(cfg.bind == listenHost ? "listen address" : "bind (\(cfg.bind))"),
                "base": .string("http://\(cfg.bind):\(cfg.port)"),
            ])]
            if listenHost != "127.0.0.1" && listenHost != cfg.bind {
                bases.append(.object(["label": .string("this machine"), "base": .string("http://127.0.0.1:\(cfg.port)")]))
            }
            let key = cfg.authToken
            let keyLine = key.isEmpty ? "not-required" : key
            let note = key.isEmpty ? "Auth is disabled on this daemon; any non-empty API key works."
                                   : "Replace <KEY> only if your client can't read the token below."
            let base = "http://\(listenHost):\(cfg.port)"
            func f(_ name: String, _ lang: String, _ code: String) -> JSONValue {
                .object(["name": .string(name), "lang": .string(lang), "code": .string(code)])
            }

            let opencode = """
            {
              "$schema": "https://opencode.ai/config.json",
              "provider": {
                "substation": {
                  "npm": "@ai-sdk/openai-compatible",
                  "name": "Substation",
                  "options": { "baseURL": "\(base)/v1", "apiKey": "\(keyLine)" },
                  "models": {
                    "auto": { "name": "Substation auto" },
                    "auto-fast": { "name": "Substation fast" },
                    "auto-smart": { "name": "Substation smart" }
                  }
                }
              }
            }
            """
            let claude = """
            # Claude Code → Substation (Anthropic Messages API)
            export ANTHROPIC_BASE_URL="\(base)"
            export ANTHROPIC_API_KEY="\(keyLine)"
            export ANTHROPIC_MODEL="auto"
            export ANTHROPIC_SMALL_FAST_MODEL="auto-fast"
            claude
            """
            let codex = """
            # ~/.codex/config.toml
            model = "auto"
            model_provider = "substation"

            [model_providers.substation]
            name = "Substation"
            base_url = "\(base)/v1"
            env_key = "SUBSTATION_TOKEN"
            wire_api = "chat"

            # then: export SUBSTATION_TOKEN="\(keyLine)"
            """
            let generic = """
            # Any OpenAI-compatible client (curl, SDKs, aider, Continue…)
            export OPENAI_BASE_URL="\(base)/v1"
            export OPENAI_API_KEY="\(keyLine)"

            curl -s \(base)/v1/chat/completions \\
              -H "content-type: application/json" \(key.isEmpty ? "" : "-H \u{22}Authorization: Bearer \(key)\u{22}") \\
              -d '{"model":"auto","messages":[{"role":"user","content":"hello"}]}'
            """
            func harness(_ id: String, _ name: String, _ noteExtra: String, _ files: [JSONValue]) -> JSONValue {
                .object([
                    "id": .string(id), "name": .string(name),
                    "note": .string(noteExtra.isEmpty ? note : noteExtra),
                    "files": .array(files),
                ])
            }
            let harnesses: [JSONValue] = [
                harness("opencode", "opencode", "Put in project or ~/.config/opencode/opencode.json; models appear as Substation auto/fast/smart.",
                        [f("opencode.json", "json", opencode)]),
                harness("claude-code", "Claude Code", "Claude Code speaks the Anthropic Messages API; Substation serves /v1/messages (weights stream through the same router).",
                        [f("claude-code.sh", "sh", claude)]),
                harness("codex", "Codex CLI", "Merge into ~/.codex/config.toml, export the token, run codex.",
                        [f("config.toml", "toml", codex)]),
                harness("generic", "Generic OpenAI client", "Works with anything that can point at an OpenAI-compatible base URL.",
                        [f("openai.sh", "sh", generic)]),
            ]
            var obj: [String: JSONValue] = [
                "base": .string(base),
                "bases": .array(bases),
                "key_required": .bool(!key.isEmpty),
                "models": .array(["auto", "auto-fast", "auto-smart"].map { JSONValue.string($0) }),
                "harnesses": .array(harnesses),
            ]
            if !key.isEmpty { obj["api_key"] = .string(key) }
            return jsonResponse(.object(obj))
        }

        /// Cluster-join wizard snapshot: interfaces + Thunderbolt state +
        /// discovered peers + joined nodes with link quality, in one poll.
        app.get("api", "cluster", "wizard") { req async throws -> Response in
            try await auth(req, kit)
            let cfg = await kit.cfg.snapshot
            let ifaces = HostInfo.interfaces()
            let tb = ifaces.contains { ($0.kind == "thunderbolt-bridge" || $0.kind == "thunderbolt") && $0.running && !$0.ip.isEmpty }
            let tbDown = ifaces.contains { $0.kind == "thunderbolt-bridge" && !$0.ip.isEmpty && !$0.running }
            let lan = HostInfo.primaryIP()
            let suggestIdx = max(1, (await kit.nodes.allNodes()).count + 1)
            return jsonResponse(.object([
                "hostname": .string(ProcessInfo.processInfo.hostName),
                "cluster_enabled": .bool(cfg.clusterEnabled),
                "controller_id": .string(cfg.controllerId),
                "base": .string("http://\(lan.isEmpty ? "127.0.0.1" : lan):\(cfg.port)"),
                "agent_port": .jInt(cfg.agentPort),
                "rpc_port": .jInt(cfg.rpcPort),
                "interfaces": .array(ifaces.map { i in
                    .object([
                        "name": .string(i.name), "ip": .string(i.ip), "netmask": .string(i.netmask),
                        "up": .bool(i.up), "running": .bool(i.running), "kind": .string(i.kind),
                    ])
                }),
                "thunderbolt_active": .bool(tb),
                "thunderbolt_down": .bool(tbDown),
                "plumb": .object([
                    "head": .string("networksetup -setmanual \"Thunderbolt Bridge\" 10.99.\(suggestIdx).1 255.255.255.0"),
                    "peer": .string("networksetup -setmanual \"Thunderbolt Bridge\" 10.99.\(suggestIdx).2 255.255.255.0"),
                ]),
                "discovered": .array((await kit.nodes.peersJSON()).arrayValue ?? []),
                "nodes": await kit.nodes.nodesJSON(),
            ]))
        }
    }
}
