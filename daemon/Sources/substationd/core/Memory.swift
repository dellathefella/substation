import Foundation
import Darwin

public struct MemInfo: Sendable {
    public var freeGB: Double
    public var totalGB: Double
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
        let info = MemInfo(freeGB: Self.freeGB(), totalGB: Self.totalGB)
        cached = info
        cachedAt = Date()
        return info
    }

    /// (free + speculative) pages × page size, via `vm_stat` for exact parity
    /// with Activity Monitor semantics.
    private static func freeGB() -> Double {
        let pageSize = pageSize
        var free = 0.0
        if let out = ProcessRunner.run(["/usr/bin/vm_stat"], timeout: 2) {
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 3, parts[0] == "Pages" else { continue }
                let key = String(parts[1]).replacingOccurrences(of: ":", with: "")
                let raw = String(parts[2]).replacingOccurrences(of: ".", with: "")
                guard let v = Double(raw) else { continue }
                if key == "free" || key == "speculative" || key == "purgeable" {
                    free += v * pageSize
                }
            }
        } else {
            free = Self.totalGB * 1_073_741_824 * 0.25 // conservative fallback
        }
        return max(0, free / 1_073_741_824)
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
