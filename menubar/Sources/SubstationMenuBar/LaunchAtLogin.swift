import Foundation

/// Manages a per-user LaunchAgent so the menu bar app (and thus the daemon it
/// supervises) can start at login. Uses a plist in ~/Library/LaunchAgents and
/// launchctl, which works for a plain SPM executable (no .app bundle required).
enum LaunchAtLogin {
    static let label = "com.substation.menubar"

    private static var plistURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return dir.appendingPathComponent("\(label).plist")
    }

    static func isSupported() -> Bool {
        FileManager.default.isExecutableFile(atPath: bundlePath)
    }

    private static var bundlePath: String {
        // The running executable (SPM build or bundled Resources copy).
        CommandLine.arguments.first ?? Bundle.main.executablePath ?? ""
    }

    static func isEnabled() -> Bool {
        // Synchronous launchctl print: exit 0 == service loaded.
        if run(["print", "gui/\(getuid())/\(label)"]) == nil { return true }
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Enable or disable. Returns nil on success, an error string otherwise.
    static func setEnabled(_ on: Bool) -> String? {
        let fm = FileManager.default
        if on {
            let dir = plistURL.deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [bundlePath],
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],
                "StandardOutPath": (fm.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent("Library/Logs/Substation-menubar.out.log"),
                "StandardErrorPath": (fm.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent("Library/Logs/Substation-menubar.err.log"),
            ]
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: plistURL, options: .atomic)
            } catch {
                return "could not write LaunchAgent: \(error.localizedDescription)"
            }
            return run(["bootstrap", "gui/\(getuid())", plistURL.path])
        } else {
            _ = run(["bootout", "gui/\(getuid())/\(label)"])
            do { try fm.removeItem(at: plistURL) } catch { return "could not remove LaunchAgent: \(error.localizedDescription)" }
            return nil
        }
    }

    @discardableResult
    private static func run(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return nil } catch { return "launchctl failed: \(error.localizedDescription)" }
    }
}
