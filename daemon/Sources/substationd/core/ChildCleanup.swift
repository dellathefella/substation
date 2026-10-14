import Foundation
import Darwin

/// Thread-safe registry of child PIDs spawned by this daemon.
///
/// A signal handler cannot safely touch actor-isolated state (e.g. `EngineActor.managed`),
/// so every spawned child PID is mirrored here. The SIGTERM/SIGINT handler reads this
/// list to clean up GPU-holding `llama-server` / `ggml-rpc-server` children before the
/// process exits — closing the gap where a daemon killed by a signal left orphans behind.
public final class ChildPids: @unchecked Sendable {
    public static let shared = ChildPids()
    private var pids: [pid_t] = []
    private var fired = false
    private var sources: [DispatchSourceSignal] = []
    private let lock = NSLock()

    /// Keep a strong reference to signal sources — a resumed-but-unreferenced
    /// DispatchSource can be deallocated by ARC, silently disabling the handler.
    func retainSource(_ src: DispatchSourceSignal) {
        lock.lock(); sources.append(src); lock.unlock()
    }

    public func add(_ pid: pid_t) {
        guard pid > 0 else { return }
        lock.lock(); pids.append(pid); lock.unlock()
    }

    public func remove(_ pid: pid_t) {
        lock.lock(); pids.removeAll { $0 == pid }; lock.unlock()
    }

    public func all() -> [pid_t] {
        lock.lock(); defer { lock.unlock() }; return pids
    }

    public func clear() {
        lock.lock(); pids.removeAll(); lock.unlock()
    }

    /// Returns true exactly once — guards the signal handler against re-entry.
    public func fireOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }

    /// SIGTERM every tracked child, give it a grace period to flush, then SIGKILL
    /// survivors (a Metal/OOM-stuck llama-server ignores SIGTERM).
    public func killAll(graceMicroseconds: useconds_t = 500_000) {
        let snapshot = all()
        for pid in snapshot { kill(pid, SIGTERM) }
        usleep(graceMicroseconds)
        for pid in snapshot where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}

/// Install SIGTERM/SIGINT handlers that terminate tracked children before exiting.
///
/// Vapor does not catch SIGTERM by default, so without this the daemon dies on the
/// signal and never runs `EngineActor.shutdownAll()` (which only runs after
/// `app.execute()` returns). Call once at startup, before `app.execute()`.
public func installChildCleanupSignalHandlers() {
    let queue = DispatchQueue(label: "substation.child-cleanup")
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: queue)
        src.setEventHandler {
            guard ChildPids.shared.fireOnce() else { return }
            let pids = ChildPids.shared.all()
            NSLog("substationd: caught signal \(sig) — terminating \(pids.count) child process(es)")
            ChildPids.shared.killAll()
            exit(0)
        }
        src.resume()
        ChildPids.shared.retainSource(src)
    }
}
