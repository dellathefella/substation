import Foundation
import Vapor

/// Info tab backend: what llama.cpp is running where, and how to update
/// the llama.cpp tree (git pull + incremental build + engine respawn).
public actor LlamaUpdate {
    public static let shared = LlamaUpdate()

    private var running = false

    private init() {}

    private func sh(_ launchPath: String, _ args: [String], cwd: String, timeout: TimeInterval) async -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() > deadline {
                p.terminate()
                return (-9, "timeout")
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// `llama-server --version` prints "version: NNNN (hash)" to stderr.
    public func version(binary: String) async -> JSONValue {
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            return .object(["error": .string("binary_missing")])
        }
        let cwd = FileManager.default.currentDirectoryPath
        let (code, out) = await sh("/bin/sh", ["-c", "'\(binary)' --version 2>&1 | head -8"], cwd: cwd, timeout: 8)
        guard code == 0 else { return .object(["error": .string("version_failed_\(code)")]) }
        var ver = "", commit = ""
        for line in out.split(separator: "\n") {
            if let a = line.range(of: "version: ") {
                let rest = line[a.upperBound...]
                commit = rest.split(separator: " ").first.map(String.init) ?? ""
                if let b = line.range(of: " (", range: a.upperBound..<line.endIndex) {
                    ver = String(line[a.upperBound..<b.lowerBound])
                }
            }
        }
        var obj: [String: JSONValue] = [:]
        obj["version"] = .string(ver)
        obj["commit"] = .string(commit)
        obj["raw"] = .string(String(out.prefix(600)))
        return .object(obj)
    }

    public func head(src: String) async -> String {
        let (code, out) = await sh("/usr/bin/git", ["rev-parse", "--short", "HEAD"], cwd: src, timeout: 10)
        return code == 0 ? out.trimmingCharacters(in: .whitespacesAndNewlines) : "?"
    }

    /// Kick off pull → build → restart-local-engines. Returns false when a
    /// run is already active or the tree is not a git checkout.
    public func start(src: String, cfgStore: ConfigStore, engines: EngineActor, events: EventActor) -> Bool {
        guard !running else { return false }
        guard FileManager.default.fileExists(atPath: src + "/.git") else { return false }
        running = true
        let ncpu = ProcessInfo.processInfo.activeProcessorCount
        Task.detached(priority: .utility) { [self] in
            await publish(events, "checking", src: src)
            _ = await sh("/usr/bin/git", ["fetch", "--all", "--tags", "--prune"], cwd: src, timeout: 300)
            let (pullCode, pullOut) = await sh("/usr/bin/git", ["pull", "--ff-only"], cwd: src, timeout: 300)
            let head = await head(src: src)
            if pullCode != 0 {
                await publish(events, "error", src: src, detail: String(pullOut.suffix(400)))
                await self.finish()
                return
            }
            if pullOut.contains("Already up to date") {
                await publish(events, "current", src: src, detail: head)
                await self.finish()
                return
            }
            await publish(events, "building", src: src)
            let (buildCode, buildOut) = await sh(
                "/usr/bin/cmake", ["--build", "build", "-j", String(max(2, min(10, ncpu)))],
                cwd: src, timeout: 3600
            )
            if buildCode != 0 {
                await publish(events, "error", src: src, detail: String(buildOut.suffix(400)))
                await self.finish()
                return
            }
            await publish(events, "restarting", src: src)
            let cfg = await cfgStore.snapshot
            for e in await engines.listLive() where e.node == "local" {
                _ = await engines.respawn(e, cfg: cfg)
            }
            await publish(events, "done", src: src, detail: head)
            await self.finish()
        }
        return true
    }

    private func finish() { running = false }

    private func publish(_ events: EventActor, _ state: String, src: String, detail: String = "") {
        Task {
            await events.publishDeduped("llama.update", key: "llama.update", .object([
                "state": .string(state), "src": .string(src), "detail": .string(detail),
            ]), cooldown: 15, throttle: true)
        }
    }
}

public enum LlamaInfoRoutes {
    /// binary lives at <src>/build/bin/llama-server → src is three levels up.
    static func srcDir(for binary: String) -> String {
        let abs = (binary as NSString).standardizingPath
        return ((( abs as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
    }

    public static func register(_ app: Application, _ kit: Kit) {
        app.get("api", "llama") { req async throws -> Response in
            try await Routes.auth(req, kit)
            return jsonResponse(await Self.info(kit))
        }
        app.on(.POST, "api", "llama", "update", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            try await Routes.auth(req, kit)
            let cfg = await kit.cfg.snapshot
            let src = Self.srcDir(for: cfg.llamaServer)
            let started = await LlamaUpdate.shared.start(src: src, cfgStore: kit.cfg, engines: kit.engines, events: kit.events)
            return jsonResponse(
                .object(["started": .bool(started), "src": .string(src)]),
                status: started ? .accepted : .conflict
            )
        }
    }

    private static func info(_ kit: Kit) async -> JSONValue {
        let cfg = await kit.cfg.snapshot
        let llamaAbs = cfg.llamaServer
        let src = Self.srcDir(for: llamaAbs)
        let metrics = await kit.metrics.snapshot()
        var engines: [JSONValue] = []
        for e in await kit.engines.listLive() {
            var obj: [String: JSONValue] = [:]
            obj["model"] = .string(e.model)
            obj["node"] = .string(e.node)
            obj["port"] = .jInt(e.port)
            obj["pid"] = .jInt(Int(e.pid))
            obj["split"] = .bool(e.split)
            obj["rpc_peers"] = .array(e.rpcPeers.map { JSONValue.string($0) })
            obj["size_gb"] = .jDouble(e.sizeGB)
            obj["cache_tokens"] = .jInt(e.ctx)
            obj["uptime_s"] = .jInt(Int(Date().timeIntervalSince(e.loadedAt)))
            if let t = metrics["engine_tok_s"]?.objectValue?[e.key]?.doubleValue {
                obj["tok_s"] = .jDouble(t)
            } else {
                obj["tok_s"] = .null
            }
            engines.append(.object(obj))
        }
        let headStr = await LlamaUpdate.shared.head(src: src)
        let verJSON = await LlamaUpdate.shared.version(binary: llamaAbs)
        let rpcUp = await kit.engines.rpcSelfUp
        var out: [String: JSONValue] = [:]
        out["binary"] = .string(llamaAbs)
        out["rpc_binary"] = .string(cfg.rpcServer)
        out["src"] = .string(src)
        out["git"] = .bool(FileManager.default.fileExists(atPath: src + "/.git"))
        out["head"] = .string(headStr)
        out["version"] = verJSON
        out["rpc_up"] = .bool(rpcUp)
        out["engines"] = .array(engines)
        return .object(out)
    }
}
