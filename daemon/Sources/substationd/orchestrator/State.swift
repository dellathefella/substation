import Foundation

public actor DaemonState {
    public private(set) var paused = false
    public let startedAt = Date()

    public init() {}

    public func setPaused(_ p: Bool) { paused = p }

    public func state() -> String { paused ? "paused" : "running" }

    public func uptimeS() -> Double { Date().timeIntervalSince(startedAt) }
}
