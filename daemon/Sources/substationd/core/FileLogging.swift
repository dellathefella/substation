import Foundation
import Logging

/// Multiplexing log sink: writes every line to stderr (so nohup/launchd still
/// capture it) AND to a file under `<dataDir>/logs/` so the webui log page —
/// which lists that directory — can show the daemon's own operational logs.
///
/// To keep drive usage bounded and cheap:
/// - File writes are BUFFERED and flushed in batches (fewer syscalls, not one per line).
/// - The file is ROTATED by size: when it would exceed `maxBytes`, it is renamed to
///   `<name>.1` (shifting older backups up to `keep`) and a fresh file is opened.
enum DaemonLogFile {
    static let lock = NSLock()
    nonisolated(unsafe) static var handle: FileHandle?
    nonisolated(unsafe) static var path: String = ""
    nonisolated(unsafe) static var maxBytes: Int = 5_000_000      // rotate the daemon log at ~5 MB
    nonisolated(unsafe) static var keep: Int = 3                  // keep <name>.1 … <name>.keep
    nonisolated(unsafe) static var buffer = Data()
    static let flushBytes = 32_000           // flush the buffer once it reaches ~32 KB
    nonisolated(unsafe) static var timer: DispatchSourceTimer?
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return f
    }()

    /// Open (append) the daemon log file and start the periodic flush timer.
    static func configure(path: String, maxBytes: Int = 5_000_000, keep: Int = 3) {
        lock.lock()
        defer { lock.unlock() }
        if handle != nil { return }
        self.path = path
        self.maxBytes = maxBytes
        self.keep = max(1, keep)
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let h = FileHandle(forWritingAtPath: path)
        h?.seekToEndOfFile()
        handle = h
        startFlushTimerLocked()
    }

    /// Buffer a rendered line; flush when the buffer is large enough.
    static func write(_ data: Data) {
        lock.lock()
        buffer.append(data)
        let shouldFlush = buffer.count >= flushBytes
        lock.unlock()
        if shouldFlush { flush() }
    }

    /// Flush buffered bytes to disk, rotating first if that would exceed the cap.
    static func flush() {
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty else { return }
        // Rotate may replace `handle`; write to the CURRENT handle, not a stale one.
        rotateIfNeededLocked(adding: buffer.count)
        handle?.write(buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    /// Rotate `<path>` → `<path>.1` (shifting older backups), reopen a fresh file.
    /// Caller must hold `lock`.
    private static func rotateIfNeededLocked(adding: Int) {
        guard !path.isEmpty, let h = handle else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        guard size + adding > maxBytes else { return }
        h.synchronizeFile()
        h.closeFile()
        let fm = FileManager.default
        // Drop the oldest backup, then shift .n → .(n+1) from newest to oldest.
        try? fm.removeItem(atPath: "\(path).\(keep)")
        var i = keep - 1
        while i >= 1 {
            let from = "\(path).\(i)"
            let to = "\(path).\(i + 1)"
            if fm.fileExists(atPath: from) { try? fm.moveItem(atPath: from, toPath: to) }
            i -= 1
        }
        if fm.fileExists(atPath: path) { try? fm.moveItem(atPath: path, toPath: "\(path).1") }
        fm.createFile(atPath: path, contents: nil)
        let nh = FileHandle(forWritingAtPath: path)
        handle = nh
    }

    private static func startFlushTimerLocked() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "substation.log.flush"))
        t.schedule(deadline: .now() + 2.0, repeating: 2.0)
        t.setEventHandler { flush() }
        t.resume()
        timer = t
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
        DaemonLogFile.write(data)
    }
}
