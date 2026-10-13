import Foundation

/// Thin REST client for `substationd admin …` / `substationd join …` (§7).
public enum CLI {
    static var base: String {
        ProcessInfo.processInfo.environment["SUBSTATION_URL"] ?? "http://127.0.0.1:8800"
    }

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 600
        return URLSession(configuration: cfg)
    }()

    public static func run(_ args: [String]) async -> Int32 {
        guard let first = args.first else {
            print(usage)
            return 2
        }
        switch first {
        case "admin": return await admin(Array(args.dropFirst()))
        case "join": return await join(Array(args.dropFirst()))
        default:
            print(usage)
            return 2
        }
    }

    static var usage: String {
        """
        substationd admin status | metrics | events [n]
        substationd admin models list | model load <name> | model unload <name>
        substationd admin cluster enable | disable
        substationd admin config get | config set <dotted.key> <json-value>
        substationd admin pause | resume | reload
        substationd admin chat "prompt" [--model auto] [--stream]
        substationd join --controller <ip> --code <6-digit>
        (SUBSTATION_URL overrides \(base))
        """
    }

    static func request(_ method: String, _ pathOrURL: String, _ body: Data? = nil) async -> Int32 {
        let full = pathOrURL.hasPrefix("http") ? pathOrURL : base + pathOrURL
        guard let url = URL(string: full) else { return 2 }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let token = ProcessInfo.processInfo.environment["SUBSTATION_TOKEN"], !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        req.httpBody = body
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let v = JSONCoding.decode(data) {
                print(JSONCoding.encodeString(v, pretty: true))
            } else {
                print(String(data: data, encoding: .utf8) ?? "")
            }
            return status < 400 ? 0 : 1
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
    }

    static func json(_ obj: [String: JSONValue]) -> Data {
        JSONCoding.encode(.object(obj))
    }

    static func admin(_ args: [String]) async -> Int32 {
        guard let verb = args.first else { print(usage); return 2 }
        let rest = Array(args.dropFirst())
        switch verb {
        case "status": return await request("GET", "/api/status")
        case "metrics": return await request("GET", "/api/metrics")
        case "events":
            let n = rest.first ?? "200"
            return await request("GET", "/api/events?limit=\(n)")
        case "models":
            return await request("GET", "/api/models")
        case "model":
            guard rest.count >= 2 else { print("model load|unload <name>"); return 2 }
            let name = rest[1]
            switch rest[0] {
            case "load": return await request("POST", "/api/models/\(name)/load", json([:]))
            case "unload": return await request("POST", "/api/models/\(name)/unload", json([:]))
            default: print("model load|unload <name>"); return 2
            }
        case "cluster":
            if rest.first == "unjoin" {
                let node = rest.count >= 2 ? "?node=\(rest[1])" : ""
                return await request("POST", "/api/cluster/unjoin\(node)", json([:]))
            }
            guard rest.first == "enable" || rest.first == "disable" else { print("cluster enable|disable|unjoin [node]"); return 2 }
            return await request("PUT", "/api/config", json(["cluster": .object(["enabled": .bool(rest[0] == "enable")])]))
        case "config":
            if rest.first == "reset" { return await request("POST", "/api/admin/reset-config", json([:])) }
            guard rest.first == "get" || rest.first == "set" else { print("config get | config set <key> <json> | config reset"); return 2 }
            if rest[0] == "get" { return await request("GET", "/api/config") }
            guard rest.count >= 3, let v = JSONCoding.decode(Data(rest[2].utf8)) else {
                print("usage: config set <dotted.key> <json-value>"); return 2
            }
            let parts = rest[1].split(separator: ".").map(String.init)
            var patch = v
            for part in parts.reversed() { patch = .object([part: patch]) }
            return await request("PUT", "/api/config", JSONCoding.encode(patch))
        case "pause": return await request("POST", "/api/admin/pause", json([:]))
        case "resume": return await request("POST", "/api/admin/resume", json([:]))
        case "reload": return await request("POST", "/api/admin/reload", json([:]))
        case "rotate-key": return await request("POST", "/api/admin/rotate-key", json([:]))
        case "reset": return await request("POST", "/api/admin/reset-config", json([:]))
        case "chat":
            guard let prompt = rest.first else { print("chat \"prompt\" [--model auto] [--stream]"); return 2 }
            let flags = Array(rest.dropFirst())
            var model = "auto"
            if let idx = flags.firstIndex(of: "--model"), idx + 1 < flags.count {
                model = flags[idx + 1]
            }
            let stream = flags.contains("--stream")
            return await chat(prompt: prompt, model: model, stream: stream)
        default:
            print(usage)
            return 2
        }
    }

    static func chat(prompt: String, model: String, stream: Bool) async -> Int32 {
        let body = json([
            "model": .string(model),
            "messages": .array([.object(["role": .string("user"), "content": .string(prompt)])]),
            "stream": .bool(stream),
        ])
        guard let url = URL(string: base + "/v1/chat/completions") else { return 2 }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = ProcessInfo.processInfo.environment["SUBSTATION_TOKEN"], !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = body
        do {
            if stream {
                let (bytes, resp) = try await session.bytes(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                    print("HTTP \(http.statusCode)")
                }
                for try await line in bytes.lines {
                    guard line.hasPrefix("data:") else { continue }
                    let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { print(""); return 0 }
                    if let v = JSONCoding.decode(Data(payload.utf8)),
                       let delta = v["choices"]?[0]?["delta"]?["content"]?.stringValue
                    {
                        FileHandle.standardOutput.write(Data(delta.utf8))
                    }
                }
                print("")
                return 0
            } else {
                let (data, resp) = try await session.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if let v = JSONCoding.decode(data), let content = v["choices"]?[0]?["message"]?["content"]?.stringValue {
                    print(content)
                } else {
                    print(String(data: data, encoding: .utf8) ?? "")
                }
                return status < 400 ? 0 : 1
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
    }

    static func join(_ args: [String]) async -> Int32 {
        var controller = ""
        var code = ""
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--controller":
                if i + 1 < args.count { controller = args[i + 1]; i += 1 }
            case "--code":
                if i + 1 < args.count { code = args[i + 1]; i += 1 }
            default: break
            }
            i += 1
        }
        guard !controller.isEmpty, code.count == 6, code.allSatisfy(\.isNumber) else {
            print("usage: substationd join --controller <ip> --code <6-digit>")
            return 2
        }
        let agentPort = Int(ProcessInfo.processInfo.environment["SUBSTATION_AGENT_PORT"] ?? "8801") ?? 8801
        let body = json([
            "node_id": .string(UUID().uuidString.lowercased()),
            "name": .string(ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "peer"),
            "ip": .string(HostInfo.primaryIP()),
            "agent_port": .jInt(agentPort),
            "rpc_port": .jInt(50052),
            "code": .string(code),
        ])
        let port = ProcessInfo.processInfo.environment["SUBSTATION_CONTROLLER_PORT"] ?? "8800"
        return await request("POST", "http://\(controller):\(port)/api/cluster/join-relay", body)
    }
}
