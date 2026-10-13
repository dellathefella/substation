import Foundation
import Vapor

/// Graceful self-restart: spawns a detached `sleep + exec` re-exec of this
/// exact binary with its original argv, then exits the current process.
/// Works for both controller and node-agent roles.
public enum DaemonRestart {
    public static func scheduleSelfRestart(delaySec: TimeInterval = 0.7, preExit: @escaping @Sendable () async -> Void = {}) {
        let argv = CommandLine.arguments
        guard let first = argv.first else { return }
        let exe = URL(fileURLWithPath: first).resolvingSymlinksInPath().path
        let quoted = argv.dropFirst().map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: " ")
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "sleep 3; exec '\(exe)' \(quoted)"]
        let logPath = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent("state/restart.log")
        if !FileManager.default.fileExists(atPath: logPath) {
            try? FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            sh.standardOutput = handle
            sh.standardError = handle
        } else {
            sh.standardOutput = FileHandle.nullDevice
            sh.standardError = FileHandle.nullDevice
        }
        do {
            try sh.run()
        } catch {
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delaySec) {
            Task {
                await preExit()
                exit(0)
            }
        }
    }

    /// Fire-and-forget restart of every joined node's agent, then self.
    public static func restartFleet(nodes: [NodeEntry], client: EngineClient, token: String, kitEvents: EventActor, preExit: @escaping @Sendable () async -> Void = {}) async {
        for n in nodes {
            _ = try? await client.json(
                method: "POST", url: "http://\(n.ip):\(n.agentPort)/api/admin/restart",
                body: .object([:]), bearer: token, timeout: 5
            )
        }
        try? await kitEvents.publish("daemon.restarting", .object(["scope": .string("fleet")]))
        scheduleSelfRestart(delaySec: 1.5, preExit: preExit)
    }
}
