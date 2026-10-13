import Foundation
import Darwin
import IOKit

/// CPU % (host CPU ticks delta), GPU % (IOAccelerator PerformanceStatistics,
/// best-effort — nil where unavailable) and network throughput (getifaddrs
/// byte counters delta). All deltas are since the previous read; first call
/// primes the baseline and reports nil for CPU/NET.
public actor System {
    public struct Stats: Sendable {
        public var cpuPct: Double?
        public var gpuPct: Double?
        public var rxBps: Double?
        public var txBps: Double?
        public var rxTotal: Double
        public var txTotal: Double
    }

    private var lastCPU: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32, at: Date)?
    private var lastNet: (rx: UInt64, tx: UInt64, at: Date)?

    public init() {}

    public func read() -> Stats {
        var s = Stats(cpuPct: nil, gpuPct: Self.gpuPct(), rxBps: nil, txBps: nil,
                      rxTotal: 0, txTotal: 0)
        if let (rx, tx) = Self.netBytes() {
            let now = Date()
            if let last = lastNet {
                let dt = now.timeIntervalSince(last.at)
                if dt > 0.2 {
                    s.rxBps = max(0, Double(rx &- last.rx) / dt)
                    s.txBps = max(0, Double(tx &- last.tx) / dt)
                }
            }
            lastNet = (rx, tx, now)
            s.rxTotal = Double(rx)
            s.txTotal = Double(tx)
        }
        if let cpu = Self.cpuDelta(&lastCPU) { s.cpuPct = cpu }
        return s
    }

    public func json() -> JSONValue {
        let s = read()
        var o: [String: JSONValue] = [:]
        if let c = s.cpuPct { o["cpu_pct"] = .jDouble((c * 10).rounded() / 10) }
        if let g = s.gpuPct { o["gpu_pct"] = .jDouble((g * 10).rounded() / 10) }
        if let r = s.rxBps { o["rx_bps"] = .jDouble((r / 1024).rounded()) }
        if let t = s.txBps { o["tx_bps"] = .jDouble((t / 1024).rounded()) }
        o["rx_total"] = .jDouble(s.rxTotal)
        o["tx_total"] = .jDouble(s.txTotal)
        return .object(o)
    }

    // MARK: - CPU

    private static func cpuDelta(_ last: inout (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32, at: Date)?) -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let now = Date()
        defer {
            last = (info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3, now)
        }
        guard let l = last else { return nil }
        let du = Double(info.cpu_ticks.0 &- l.user)
        let ds = Double(info.cpu_ticks.1 &- l.system)
        let dn = Double(info.cpu_ticks.3 &- l.nice)
        let di = Double(info.cpu_ticks.2 &- l.idle)
        let busy = du + ds + dn
        let tot = busy + di
        guard tot > 0 else { return nil }
        return max(0, min(100, busy / tot * 100))
    }

    // MARK: - GPU (IOAccelerator performance statistics)

    private static func gpuPct() -> Double? {
        var service: io_service_t = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        if service == 0 {
            // older kernels expose it as AGXAccelerator
            service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        }
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any],
              let perf = dict["PerformanceStatistics"] as? [String: Any]
        else { return nil }
        for key in ["GPU Activity(%)", "Device Utilization %", "GPU Activity %", "Device Utilization(%)"] {
            if let v = perf[key] as? Double, v >= 0, v <= 100 { return v }
            if let n = perf[key] as? NSNumber {
                let d = n.doubleValue
                if d >= 0, d <= 100 { return d }
            }
        }
        return nil
    }

    // MARK: - Network

    private static func netBytes() -> (UInt64, UInt64)? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return nil }
        defer { freeifaddrs(ifap) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var cur = ifap
        while let p = cur {
            let ifa = p.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               let name = ifa.ifa_name.map({ String(cString: $0) }),
               isPhysical(name), let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) {
                rx &+= UInt64(data.pointee.ifi_ibytes)
                tx &+= UInt64(data.pointee.ifi_obytes)
            }
            cur = ifa.ifa_next
        }
        return (rx, tx)
    }

    private static func isPhysical(_ name: String) -> Bool {
        let prefixes = ["en", "bridge", "llw", "eth", "stf", "an"]
        return prefixes.contains { name.hasPrefix($0) }
    }
}
