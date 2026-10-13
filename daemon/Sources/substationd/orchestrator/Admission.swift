import Foundation

/// FIFO admission gate. Never rejects: callers wait their turn, so clients
/// never see 503 for "engine busy/loading" — only latency (transparency §6.2).
public actor Admission {
    private var maxConcurrent = 8
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func configure(_ newMax: Int) {
        maxConcurrent = max(1, newMax)
        drain()
    }

    public func acquire() async -> Double {
        if active < maxConcurrent {
            active += 1
            return 0
        }
        let t0 = Date()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
        return Date().timeIntervalSince(t0) * 1000
    }

    public func release() {
        active = max(0, active - 1)
        drain()
    }

    private func drain() {
        while active < maxConcurrent, !waiters.isEmpty {
            active += 1
            waiters.removeFirst().resume()
        }
    }

    public var activeCount: Int { active }
    public var waiterCount: Int { waiters.count }
}
