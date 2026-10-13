import Foundation
import Darwin

/// Preflight resource estimates + live pressure, so we can WARN before an
/// engine load that would OOM/swap (rough, local-only heuristics).
public enum ResourceEstimator {
    public struct Estimate: Sendable {
        public var model: String
        public var weightsGB: Double
        public var kvGB: Double
        public var overheadGB: Double
        public var totalGB: Double
        public var freeGB: Double
        public var gpuWiredLimitGB: Double
        public var residentGB: Double
        public var projectedFreeGB: Double
        public var fitsFree: Bool
        public var fitsGPU: Bool
        public var warnings: [String]
        public var fits: Bool { fitsFree && fitsGPU }

        public var json: JSONValue {
            .object([
                "model": .string(model),
                "weights_gb": .jDouble(r(weightsGB)),
                "kv_gb": .jDouble(r(kvGB)),
                "overhead_gb": .jDouble(r(overheadGB)),
                "total_gb": .jDouble(r(totalGB)),
                "free_gb": .jDouble(r(freeGB)),
                "gpu_wired_limit_gb": .jDouble(r(gpuWiredLimitGB)),
                "resident_gb": .jDouble(r(residentGB)),
                "projected_free_gb": .jDouble(r(projectedFreeGB)),
                "fits_free": .bool(fitsFree),
                "fits_gpu": .bool(fitsGPU),
                "fits": .bool(fitsFree && fitsGPU),
                "warnings": .array(warnings.map { JSONValue.string($0) }),
            ])
        }
        private func r(_ x: Double) -> Double { (x * 100).rounded() / 100 }
    }

    /// sysctl iogpu.wired_limit_mb (MB); 0/unset → 75% of RAM (Apple Silicon default).
    public static func gpuWiredLimitGB(totalGB: Double) -> Double {
        var mb: Int32 = 0
        var len = MemoryLayout<Int32>.size
        let kr = sysctlbyname("iogpu.wired_limit_mb", &mb, &len, nil, 0)
        if kr == 0, mb > 0 { return Double(mb) / 1024.0 }
        return totalGB * 0.75
    }

    public static func estimate(model m: CatalogModel, freeGB: Double, totalGB: Double,
                                residentGB: Double, minFreeGB: Double) -> Estimate {
        let kvPer1k = (m.kvMBPer1k > 0 ? m.kvMBPer1k : 100.0) / 1024.0   // GB per 1k ctx per slot
        let kv = (Double(m.ctx) / 1024.0) * kvPer1k * Double(max(1, m.slots))
        let overhead = max(0.5, m.sizeGB * 0.06)
        let total = m.sizeGB + kv + overhead
        let limit = gpuWiredLimitGB(totalGB: totalGB)
        let projected = freeGB - total
        var warnings: [String] = []
        if total > limit {
            warnings.append("\(m.name) ≈ \(String(format: "%.1f", total)) GB exceeds the Metal GPU wired limit (\(String(format: "%.0f", limit)) GB); the engine may fail to load. Reduce ctx/slots, use a smaller quant, or enable clustering and split across nodes.")
        }
        if total > freeGB {
            warnings.append("\(m.name) ≈ \(String(format: "%.1f", total)) GB exceeds currently free memory (\(String(format: "%.1f", freeGB)) GB); load will likely swap or fail.")
        }
        if projected < minFreeGB {
            warnings.append("After loading \(m.name), free memory ≈ \(String(format: "%.1f", projected)) GB falls below the \(String(format: "%.0f", minFreeGB)) GB safety margin; expect eviction or slowdowns.")
        }
        return Estimate(model: m.name, weightsGB: m.sizeGB, kvGB: kv, overheadGB: overhead,
                        totalGB: total, freeGB: freeGB, gpuWiredLimitGB: limit, residentGB: residentGB,
                        projectedFreeGB: projected, fitsFree: projected >= minFreeGB, fitsGPU: total <= limit,
                        warnings: warnings)
    }
}
