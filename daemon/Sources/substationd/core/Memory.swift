import Foundation
import Darwin

public struct MemInfo: Sendable {
    public var freeGB: Double
    public var totalGB: Double
    /// "Real" pressure — app + wired + compressed. Excludes file-backed
    /// (cached file) pages, which macOS hands back instantly under pressure.
    public var usedGB: Double
}

/// vm_stat + sysctl hw.memsize, cached 1.5s.
public actor Memory {
    private static let pageSize: Double = {
        var ps = vm_size_t(0)
        let kr = host_page_size(mach_host_self(), &ps)
        return (kr == KERN_SUCCESS && ps > 0) ? Double(ps) : 16384
    }()

    private static let totalGB: Double = {
        var size: Int64 = 0
        var len = MemoryLayout<Int64>.size
        sysctlbyname("hw.memsize", &size, &len, nil, 0)
        return Double(size) / 1_073_741_824
    }()

    private var cached: MemInfo?
    private var cachedAt: Date?

    public init() {}

    public func read() -> MemInfo {
        if let c = cached, let at = cachedAt, Date().timeIntervalSince(at) < 1.5 {
            return c
        }
        let info = Self.sample()
        cached = info
        cachedAt = Date()
        return info
    }

    /// Activity-Monitor semantics: used = app(internal − purgeable) + wired +
    /// compressed. File-backed pages (disk cache) are NOT "used" — macOS frees
    /// them on demand — so `freeGB` here means AVAILABLE, not truly idle pages.
    private static func sample() -> MemInfo {
        let total = totalGB
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS, pageSize > 0 else {
            return MemInfo(freeGB: total * 0.25, totalGB: total, usedGB: total * 0.75)
        }
        let gb = pageSize / 1_073_741_824
        let internalPages = Double(stats.internal_page_count) * gb
        let purgeable = Double(stats.purgeable_count) * gb
        let wired = Double(stats.wire_count) * gb
        let compressed = Double(stats.compressor_page_count) * gb
        let used = max(0, min(total, internalPages - purgeable + wired + compressed))
        return MemInfo(freeGB: max(0, total - used), totalGB: total, usedGB: used)
    }
}

public enum ProcessRunner {
    @discardableResult
    public static func run(_ args: [String], timeout: Double = 5) -> String? {
        guard !args.isEmpty, let first = args.first else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: first)
        p.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if p.isRunning {
            p.terminationHandler = nil
            kill(p.processIdentifier, SIGTERM)
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
