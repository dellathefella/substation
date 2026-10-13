import Foundation
import Logging

/// Multiplexing log handler: writes every line to stderr (so nohup/launchd still
/// capture it) AND to a file under `<dataDir>/logs/` so the webui log page —
/// which lists that directory — can show the daemon's own operational logs
/// instead of only the engine logs.
enum DaemonLogFile {
    static let lock = NSLock()
    nonisolated(unsafe) static var handle: FileHandle?
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return f
    }()

    /// Open (append) the daemon log file. Safe to call once at startup.
    static func configure(path: String) {
        lock.lock()
        defer { lock.unlock() }
        if handle != nil { return }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let h = FileHandle(forWritingAtPath: path)
        h?.seekToEndOfFile()
        handle = h
    }
}

struct DaemonLogHandler: LogHandler {
    var logLevel: Logger.Level = .info
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.MetadataValue? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(level: Logger.Level, message: Logger.Message, metadata extra: Logger.Metadata?,
            source: String, file: String, function: String, line: UInt) {
        guard level >= logLevel else { return }
        let ts = DaemonLogFile.formatter.string(from: Date())
        let lvl = level.rawValue.prefix(4)
        var rendered = "\(ts) \(lvl) [\(source)] \(message)"
        let merged = self.metadata.merging(extra ?? [:]) { _, new in new }
        if !merged.isEmpty {
            let md = merged.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            rendered += " {\(md)}"
        }
        rendered += "\n"
        let data = Data(rendered.utf8)
        FileHandle.standardError.write(data)
        DaemonLogFile.lock.lock()
        DaemonLogFile.handle?.write(data)
        DaemonLogFile.lock.unlock()
    }
}
