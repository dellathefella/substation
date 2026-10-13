import Foundation
import Vapor
import WebSocketKit

public struct Event: Codable, Sendable {
    public var type: String
    public var ts: Double
    public var data: JSONValue

    public init(_ type: String, _ data: JSONValue) {
        self.type = type
        self.ts = Date().timeIntervalSince1970 * 1000
        self.data = data
    }
}

/// Ring buffer of recent events + fan-out to WebSocket subscribers.
public actor EventActor {
    private var ring: [Event] = []
    private var ringSize = 2000
    private var subs: [UUID: WebSocket] = [:]

    public func configure(ringSize: Int) {
        self.ringSize = max(16, ringSize)
    }

    public func publish(_ event: Event) {
        ring.append(event)
        if ring.count > ringSize { ring.removeFirst(ring.count - ringSize) }
        guard let data = try? JSONEncoder().encode(event), let value = JSONCoding.decode(data) else { return }
        let frame = JSONCoding.encodeString(value)
        for (_, ws) in subs {
            ws.send(frame)
        }
    }

    public func publish(_ type: String, _ data: JSONValue) {
        publish(Event(type, data))
    }

    private struct DedupState { var ms: Double; var hash: Int; var count: Int }
    private var dedup: [String: DedupState] = [:]

    /// Emits at most one event per `key` per cooldown window while the payload
    /// is unchanged; suppressed duplicates are counted and reported on the
    /// next emission as `repeated: N`. A changed payload emits immediately.
    public func publishDeduped(_ type: String, key: String, _ data: JSONValue, cooldown: Double = 20) {
        let now = Date().timeIntervalSince1970 * 1000
        let h = data.hashValue
        if let last = dedup[key], last.hash == h {
            if now - last.ms < cooldown * 1000 {
                dedup[key] = DedupState(ms: last.ms, hash: h, count: last.count + 1)
                return
            }
            var obj = data.objectValue ?? [:]
            obj["repeated"] = .jInt(last.count)
            dedup[key] = DedupState(ms: now, hash: h, count: 0)
            publish(Event(type, .object(obj)))
            return
        }
        dedup[key] = DedupState(ms: now, hash: h, count: 0)
        publish(Event(type, data))
    }

    public func publishDeduped(_ type: String, key: String, _ fields: [(String, JSONValue)], cooldown: Double = 20) {
        var dict: [String: JSONValue] = [:]
        for (k, v) in fields { dict[k] = v }
        publishDeduped(type, key: key, .object(dict), cooldown: cooldown)
    }

    public func publish(_ type: String, _ fields: [(String, JSONValue)]) {
        var obj: [String: JSONValue] = [:]
        for (k, v) in fields { obj[k] = v }
        publish(Event(type, .object(obj)))
    }

    public func subscribe(_ ws: WebSocket) -> UUID {
        let id = UUID()
        subs[id] = ws
        pongs[id] = Date().timeIntervalSince1970
        return id
    }

    public func unsubscribe(_ id: UUID) {
        pongs[id] = nil
        subs.removeValue(forKey: id)
    }

    public func subscriberCount() -> Int { subs.count }

    /// App-level liveness: clients answer {"type":"ping"} with
    /// {"type":"pong"}; the sweep loop closes sockets whose last pong is
    /// older than the threshold (black-holed wifi TCP would never error).
    public func pong(from id: UUID) { pongs[id] = Date().timeIntervalSince1970 }

    public func lastPong(_ id: UUID) -> Double? { pongs[id] }

    private var pongs: [UUID: Double] = [:]

    /// Newest first.
    public func recent(limit: Int) -> [Event] {
        Array(ring.suffix(max(0, limit)).reversed())
    }
}
