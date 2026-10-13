import Foundation
import Vapor

/// Hugging Face model discovery + download + auto-registration.
///
/// Invariants:
/// - The HF token is NEVER stored on the actor, NEVER persisted, NEVER
///   logged and NEVER included in any event payload. It lives only inside
///   the transient request/task that uses it.
/// - A download may only begin after a preflight range request proves the
///   file is reachable with the supplied token (or publicly). A gated or
///   private repo without a valid token fails with `needs_token` BEFORE
///   any bytes move — the UI treats this as "we asked for the token".
public actor DeployActor {
    public struct Job: Sendable {
        public var id: String
        public var repo: String
        public var file: String
        public var mmproj: String?
        public var name: String
        public var tier: String
        public var path: String
        public var mmprojPath: String?
        public var bytes: Int64 = 0
        public var total: Int64 = 0
        public var state: String = "queued"
        public var error: String?
        public var started: Double = 0
    }

    private var jobs: [String: Job] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private let events: EventActor
    private let cfg: ConfigStore
    private let engines: EngineActor

    public init(events: EventActor, cfg: ConfigStore, engines: EngineActor) {
        self.events = events
        self.cfg = cfg
        self.engines = engines
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 7200
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private static func enc(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: - HF discovery

    public func search(_ query: String, token: String) async -> JSONValue {
        var comps = URLComponents(string: "https://huggingface.co/api/models")!
        var items = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "filter", value: "gguf"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "25"),
        ]
        for e in ["downloads", "gated", "private"] {
            items.append(URLQueryItem(name: "expand[]", value: e))
        }
        comps.queryItems = items
        guard let url = comps.url else { return .array([]) }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, resp) = try await Self.session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 {
                return .object(["error": .string("needs_token")])
            }
            guard status == 200, let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return .object(["error": .string("hf_search_\(status)")])
            }
            var out: [JSONValue] = []
            for m in arr {
                guard let id = (m["id"] as? String) ?? (m["_id"] as? String) else { continue }
                var obj: [String: JSONValue] = [:]
                obj["repo"] = .string(id)
                obj["downloads"] = .jInt((m["downloads"] as? Int) ?? 0)
                obj["gated"] = .bool(Self.isGated(m["gated"]))
                obj["private"] = .bool((m["private"] as? Bool) ?? false)
                out.append(.object(obj))
            }
            return .array(out)
        } catch {
            return .object(["error": .string("hf_unreachable")])
        }
    }

    private static func isGated(_ v: Any?) -> Bool {
        if let s = v as? String { return s != "false" && !s.isEmpty }
        return (v as? Bool) ?? false
    }

    public func files(_ repo: String, token: String) async -> JSONValue {
        let url = "https://huggingface.co/api/models/\(Self.enc(repo))/tree/main?recursive=true"
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "GET"
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, resp) = try await Self.session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 {
                return .object(["error": .string("needs_token")])
            }
            guard status == 200, let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return .object(["error": .string("hf_tree_\(status)")])
            }
            var out: [JSONValue] = []
            for e in arr {
                guard (e["type"] as? String) == "file",
                      let path = e["path"] as? String, path.hasSuffix(".gguf") else { continue }
                let size = (e["size"] as? Double) ?? Double((e["size"] as? Int) ?? 0)
                var obj: [String: JSONValue] = [:]
                obj["file"] = .string(path)
                obj["size"] = .jInt(Int(size))
                let base = (path as NSString).lastPathComponent.lowercased()
                obj["mmproj"] = .bool(base.contains("mmproj") || base.contains("projector"))
                out.append(.object(obj))
            }
            return .array(out)
        } catch {
            return .object(["error": .string("hf_unreachable")])
        }
    }

    // MARK: - Deploy

    public func start(repo: String, file: String, mmproj: String?, name: String, tier: String, token: String) async -> (Int, JSONValue) {
        let okName = !name.isEmpty && name.range(of: "^[a-z0-9][a-z0-9._-]{0,63}$", options: .regularExpression) != nil
        guard okName else {
            return (400, .object(["error": .string("bad_name"), "detail": .string("use lowercase letters, digits, dot, dash, underscore (≤64 chars)")]))
        }
        guard file.hasSuffix(".gguf") else { return (400, .object(["error": .string("bad_file"), "detail": .string("only .gguf files are supported")])) }
        if let mm = mmproj, !mm.isEmpty, !mm.hasSuffix(".gguf") {
            return (400, .object(["error": .string("bad_mmproj")]))
        }
        let cfgNow = await cfg.snapshot
        guard !cfgNow.models.contains(where: { $0.name == name }) else {
            return (409, .object(["error": .string("name_exists")]))
        }
        let dir = cfgNow.modelsDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("\(name).gguf")
        if FileManager.default.fileExists(atPath: path) {
            return (409, .object(["error": .string("file_exists"), "detail": .string(path)]))
        }

        let id = UUID().uuidString
        var job = Job(id: id, repo: repo, file: file, mmproj: mmproj, name: name,
                      tier: tier.isEmpty ? "balanced" : tier, path: path)
        job.state = "checking"
        job.started = Date().timeIntervalSince1970

        // Preflight: prove reachability with a 1-byte range BEFORE any
        // progress bar exists. Gated/private without a valid token fails
        // here — the client must ask the user for a token.
        let total = await preflightTotal(repo: repo, file: file, token: token)
        switch total {
        case .needsToken:
            return (423, .object(["error": .string("needs_token"), "detail": .string("repo \(repo) is gated or private — add a valid HF token")]))
        case .notFound:
            return (404, .object(["error": .string("not_found")]))
        case .failed(let code):
            return (502, .object(["error": .string("hf_\(code)")]))
        case .ok(let t):
            guard t > 0 else { return (502, .object(["error": .string("unknown_size")])) }
            job.total = t
        }
        if let mm = mmproj, !mm.isEmpty {
            switch await preflightTotal(repo: repo, file: mm, token: token) {
            case .needsToken:
                return (423, .object(["error": .string("needs_token"), "detail": .string("mmproj fetch requires a valid HF token")]))
            case .notFound:
                return (404, .object(["error": .string("mmproj_not_found")]))
            case .failed(let code):
                return (502, .object(["error": .string("hf_\(code)")]))
            case .ok(let t):
                job.total += t
                job.mmprojPath = (dir as NSString).appendingPathComponent("\(name)-mmproj.gguf")
            }
        }

        job.state = "downloading"
        jobs[id] = job
        publish(job)

        let ev = events
        tasks[id] = Task.detached(priority: .utility) { [weak self] in
            await self?.run(id: id, token: token, events: ev)
        }
        var out: [String: JSONValue] = [:]
        out["id"] = .string(id)
        out["name"] = .string(name)
        out["repo"] = .string(repo)
        out["file"] = .string(file)
        out["tier"] = .string(job.tier)
        out["total"] = .jInt(Int(job.total))
        return (202, .object(out))
    }

    private enum Preflight { case ok(Int64), needsToken, notFound, failed(Int) }

    private func preflightTotal(repo: String, file: String, token: String) async -> Preflight {
        let encFile = file.split(separator: "/").map { Self.enc(String($0)) }.joined(separator: "/")
        let resolve = "https://huggingface.co/\(Self.enc(repo))/resolve/main/\(encFile)"
        var head = URLRequest(url: URL(string: resolve)!)
        head.httpMethod = "GET"
        head.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        head.timeoutInterval = 20
        if !token.isEmpty { head.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (_, resp) = try await Self.session.data(for: head)
            guard let http = resp as? HTTPURLResponse else { return .failed(0) }
            switch http.statusCode {
            case 200, 206:
                if let cr = http.value(forHTTPHeaderField: "Content-Range"),
                   let totalStr = cr.split(separator: "/").last, let t = Int64(totalStr) {
                    return .ok(t)
                }
                return .ok(Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "0") ?? 0)
            case 401, 403:
                return .needsToken
            case 404:
                return .notFound
            default:
                return .failed(http.statusCode)
            }
        } catch {
            return .failed(0)
        }
    }

    private func run(id: String, token: String, events ev: EventActor) async {
        guard let job = jobs[id] else { return }

        // 1) main GGUF
        if let err = await download(resolve: resolveURL(job.repo, job.file), to: job.path, token: token, id: id, ev: ev) {
            finish(id, state: "error", error: err)
            return
        }
        // 2) optional mmproj
        if let mm = job.mmprojPath, let mmFile = job.mmproj, !mmFile.isEmpty {
            if let err = await download(resolve: resolveURL(job.repo, mmFile), to: mm, token: token, id: id, ev: ev) {
                try? FileManager.default.removeItem(atPath: job.path)
                finish(id, state: "error", error: err)
                return
            }
        }
        finish(id, state: "ready")
    }

    private func resolveURL(_ repo: String, _ file: String) -> String {
        let encFile = file.split(separator: "/").map { Self.enc(String($0)) }.joined(separator: "/")
        return "https://huggingface.co/\(Self.enc(repo))/resolve/main/\(encFile)"
    }

    /// Downloads one file; nil on success, error string on failure.
    private func download(resolve: String, to path: String, token: String, id: String, ev: EventActor) async -> String? {
        let part = path + ".part"
        FileManager.default.createFile(atPath: part, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: part) else { return "write_failed" }
        defer { try? fh.close() }
        var req = URLRequest(url: URL(string: resolve)!)
        req.httpMethod = "GET"
        req.timeoutInterval = 7200
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        var bytes: Int64 = 0
        var lastPublish = Date()
        var lastBytes: Int64 = 0
        var declared: Int64 = 0
        do {
            let (stream, resp) = try await Self.session.bytes(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 || status == 206 else { return "http_\(status)" }
            declared = Int64((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length") ?? "0") ?? 0
            for try await byte in stream {
                if Task.isCancelled {
                    try? FileManager.default.removeItem(atPath: part)
                    return "canceled"
                }
                fh.write(Data([byte]))
                bytes += 1
                if Date().timeIntervalSince(lastPublish) >= 1.0 {
                    let mbps = Double(bytes - lastBytes) / 1_048_576.0
                    lastPublish = Date()
                    lastBytes = bytes
                    self.jobs[id]?.bytes = bytes
                    if let j = jobs[id] {
                        var obj: [String: JSONValue] = [:]
                        obj["id"] = .string(id)
                        obj["name"] = .string(j.name)
                        obj["repo"] = .string(j.repo)
                        obj["file"] = .string(j.file)
                        obj["bytes"] = .jInt(Int(j.bytes))
                        obj["total"] = .jInt(Int(j.total))
                        obj["pct"] = .jDouble(j.total > 0 ? Double(j.bytes) / Double(j.total) * 100 : 0)
                        obj["mbps"] = .jDouble((mbps * 10).rounded() / 10)
                        obj["state"] = .string("downloading")
                        await ev.publish("model.download", .object(obj))
                    }
                }
            }
        } catch {
            if Task.isCancelled { return "canceled" }
            return "io_error"
        }
        guard bytes > 4 else { return "empty_file" }
        if declared > 0, bytes != declared { return "size_mismatch" }
        try? FileManager.default.moveItem(atPath: part, toPath: path)
        // GGUF magic check (read-only handle: the write handle cannot read).
        guard let head = FileManager.default.contents(atPath: path)?.prefix(4),
              Array(head) == Array("GGUF".utf8) else {
            try? FileManager.default.removeItem(atPath: path)
            return "not_gguf"
        }
        return nil
    }

    private func finish(_ id: String, state: String, error: String? = nil) {
        guard var job = jobs[id] else { return }
        job.state = state
        job.error = error
        if state == "canceled" || state == "error" {
            try? FileManager.default.removeItem(atPath: job.path + ".part")
            publish(job)
            return
        }
        publish(job)
        Task {
            await self.install(job)
        }
    }

    private func install(_ job: Job) async {
        var entry: [String: JSONValue] = [:]
        entry["name"] = .string(job.name)
        entry["gguf"] = .string(job.path)
        entry["tier"] = .string(job.tier)
        let attrs = try? FileManager.default.attributesOfItem(atPath: job.path)
        let sizeGB = ((attrs?[.size] as? Int64).map { Double($0) / 1_000_000_000 }) ?? 0
        entry["size_gb"] = .jDouble((sizeGB * 10).rounded() / 10)
        entry["ctx"] = .jInt(8192)
        entry["placement"] = .string("local")
        entry["kind"] = .string("local")
        if let mm = job.mmprojPath, FileManager.default.fileExists(atPath: mm) {
            entry["mmproj"] = .string(mm)
            entry["vision"] = .bool(true)
        }

        var rawObj = (await cfg.snapshot).raw.objectValue ?? [:]
        var models = rawObj["models"]?.arrayValue ?? []
        models.append(.object(entry))
        rawObj["models"] = .array(models)
        var orch = rawObj["orchestrator"]?.objectValue ?? [:]
        var tiers = orch["tiers"]?.objectValue ?? [:]
        var tierObj = tiers[job.tier]?.objectValue ?? [:]
        var list = tierObj["models"]?.arrayValue ?? []
        if !list.contains(where: { $0.stringValue == job.name }) { list.append(.string(job.name)) }
        tierObj["models"] = .array(list)
        tiers[job.tier] = .object(tierObj)
        orch["tiers"] = .object(tiers)
        rawObj["orchestrator"] = .object(orch)
        try? await cfg.applyPatch(.object(rawObj))

        let fresh = await cfg.snapshot
        if let cat = fresh.models.first(where: { $0.name == job.name }) {
            _ = try? await engines.ensureLoaded(cat, placement: .local, cfg: fresh)
        }
        var j = job
        j.state = "installed"
        jobs[job.id] = j
        publish(j)
        await events.publish("model.deployed", .object([
            "name": .string(job.name), "tier": .string(job.tier), "repo": .string(job.repo),
            "file": .string(job.file), "size_gb": .jDouble((sizeGB * 10).rounded() / 10),
            "vision": .bool(job.mmprojPath != nil),
        ]))
    }

    private func publish(_ j: Job) {
        Task {
            var obj: [String: JSONValue] = [:]
            obj["id"] = .string(j.id)
            obj["name"] = .string(j.name)
            obj["repo"] = .string(j.repo)
            obj["file"] = .string(j.file)
            obj["bytes"] = .jInt(Int(j.bytes))
            obj["total"] = .jInt(Int(j.total))
            obj["pct"] = .jDouble(j.total > 0 ? Double(j.bytes) / Double(j.total) * 100 : 0)
            obj["state"] = .string(j.state)
            obj["error"] = j.error.map { JSONValue.string($0) } ?? .null
            await events.publish("model.download", .object(obj))
        }
    }

    public func list() -> JSONValue {
        var out: [JSONValue] = []
        for j in jobs.values.sorted(by: { $0.started > $1.started }) {
            var obj: [String: JSONValue] = [:]
            obj["id"] = .string(j.id)
            obj["name"] = .string(j.name)
            obj["repo"] = .string(j.repo)
            obj["file"] = .string(j.file)
            obj["tier"] = .string(j.tier)
            obj["bytes"] = .jInt(Int(j.bytes))
            obj["total"] = .jInt(Int(j.total))
            obj["state"] = .string(j.state)
            obj["error"] = j.error.map { JSONValue.string($0) } ?? .null
            obj["vision"] = .bool(j.mmprojPath != nil)
            out.append(.object(obj))
        }
        return .array(out)
    }

    public func cancel(_ id: String) -> Bool {
        guard jobs[id] != nil else { return false }
        tasks[id]?.cancel()
        if var j = jobs[id], j.state == "queued" || j.state == "checking" {
            j.state = "canceled"
            j.error = "canceled"
            jobs[id] = j
            publish(j)
        }
        return true
    }
}

public enum DeployRoutes {
    public static func register(_ app: Application, _ kit: Kit, _ deploy: DeployActor) {
        app.get("api", "hf", "search") { req async throws -> Response in
            try await Routes.auth(req, kit)
            let q = (try? req.query.get(String.self, at: "q")) ?? ""
            let token = (try? req.query.get(String.self, at: "token")) ?? ""
            let out = await deploy.search(q, token: token)
            return jsonResponse(out, status: out["error"]?.stringValue == "needs_token" ? .locked : .ok)
        }
        app.get("api", "hf", "files") { req async throws -> Response in
            try await Routes.auth(req, kit)
            let repo = (try? req.query.get(String.self, at: "repo")) ?? ""
            let token = (try? req.query.get(String.self, at: "token")) ?? ""
            guard !repo.isEmpty else { return jsonResponse(.object(["error": .string("repo required")]), status: .badRequest) }
            let out = await deploy.files(repo, token: token)
            return jsonResponse(out, status: out["error"]?.stringValue == "needs_token" ? .locked : .ok)
        }
        app.on(.POST, "api", "deployments", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await Routes.auth(req, kit)
            let body = (try? await Routes.jsonBody(req))?.objectValue ?? [:]
            let (status, out) = await deploy.start(
                repo: body["repo"]?.stringValue ?? "",
                file: body["file"]?.stringValue ?? "",
                mmproj: body["mmproj"]?.stringValue,
                name: body["name"]?.stringValue ?? "",
                tier: body["tier"]?.stringValue ?? "balanced",
                token: body["token"]?.stringValue ?? ""
            )
            return jsonResponse(out, status: HTTPResponseStatus(statusCode: status, reasonPhrase: status == 202 ? "Accepted" : "Deploy"))
        }
        app.get("api", "deployments") { req async throws -> Response in
            try await Routes.auth(req, kit)
            return jsonResponse(await deploy.list())
        }
        app.on(.POST, "api", "deployments", ":id", "cancel") { req async throws -> Response in
            try await Routes.auth(req, kit)
            let id = req.parameters.get("id") ?? ""
            return jsonResponse(.object(["canceled": .bool(await deploy.cancel(id))]))
        }
    }
}
