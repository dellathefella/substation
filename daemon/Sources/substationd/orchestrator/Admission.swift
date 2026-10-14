import Foundation

/// Typed rejection from the admission gate when the system is saturated.
/// Carries a retry-after hint so the client can back off instead of hanging.
public struct AdmissionError: Error {
    public let retryAfterMs: Int
    public let reason: String
    public init(retryAfterMs: Int, reason: String) {
        self.retryAfterMs = retryAfterMs
        self.reason = reason
    }
}

/// FIFO admission gate with backpressure + per-session fairness.
///
/// Normally never rejects: callers wait their turn, so clients see latency,
/// not 503 (transparency §6.2). But an unbounded queue is a footgun — a
/// flood of long requests (or one client hammering) makes every caller hang
/// until their own timeout. So two guards fail fast instead of queueing:
///   • `maxQueued`  — once this many waiters are already queued, new requests
///                    get `.overloaded` (429 + Retry-After) rather than
///                    joining a queue that won't drain in reasonable time.
///   • `maxPerSession` — a single session can't hold more than this many
///                    requests in flight (active + queued), so one hog can't
///                    starve everyone else.
public actor Admission {
    private var maxConcurrent = 8
    private var maxQueued = 64
    private var maxPerSession = 4
    private var retryAfterMs = 2000
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// In-flight (active + queued) count per session key.
    private var perSession: [String: Int] = [:]

    public init() {}

    public func configure(_ newMax: Int, maxQueued: Int? = nil,
                         maxPerSession: Int? = nil, retryAfterMs: Int? = nil) {
        maxConcurrent = max(1, newMax)
        if let q = maxQueued { self.maxQueued = max(0, q) }
        if let p = maxPerSession { self.maxPerSession = max(1, p) }
        if let r = retryAfterMs { self.retryAfterMs = max(250, r) }
        drain()
    }

    /// Acquire a slot for `session` (nil = anonymous, exempt from the
    /// per-session cap). Returns the queue wait in ms. Throws `.overloaded`
    /// when the queue is full or this session is already at its cap.
    public func acquire(session: String?) async throws -> Double {
        let key = (session?.isEmpty == false) ? session! : nil
        if let k = key, (perSession[k] ?? 0) >= maxPerSession {
            throw AdmissionError(retryAfterMs: retryAfterMs, reason: "session_limit")
        }
        if active < maxConcurrent {
            active += 1
            if let k = key { perSession[k, default: 0] += 1 }
            return 0
        }
        if waiters.count >= maxQueued {
            throw AdmissionError(retryAfterMs: retryAfterMs, reason: "queue_full")
        }
        let t0 = Date()
        if let k = key { perSession[k, default: 0] += 1 }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
        return Date().timeIntervalSince(t0) * 1000
    }

    public func release(session: String?) {
        active = max(0, active - 1)
        if let k = (session?.isEmpty == false) ? session! : nil,
           let c = perSession[k] {
            perSession[k] = max(0, c - 1)
        }
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
    public func inFlight(_ session: String?) -> Int {
        guard let k = (session?.isEmpty == false) ? session! : nil else { return 0 }
        return perSession[k] ?? 0
    }
}
