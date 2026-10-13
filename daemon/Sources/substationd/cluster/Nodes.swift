import Foundation

public struct NodeEntry: Sendable {
    public var id: String
    public var name: String
    public var ip: String
    public var agentPort: Int
    public var rpcPort: Int
    public var healthy: Bool
    public var joinedMs: Double
    public var lastHealth: JSONValue?
    public var link: JSONValue?
}

public struct DiscoveredPeer: Sendable {
    public var nodeId: String
    public var name: String
    public var ip: String
    public var agentPort: Int
    public var version: String
    public var joinHash: String
    public var seenMs: Double
    public var link: JSONValue?
}

public func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    guard a.utf8.count == b.utf8.count else { return false }
    var diff: UInt8 = 0
    for (x, y) in zip(a.utf8, b.utf8) { diff |= x ^ y }
    return diff == 0
}

/// Controller-side cluster state: node registry, join codes, discovered peers.
public actor NodesActor {
    public struct JoinCode: Sendable {
        public var code: String
        public var expires: Date
    }

    private var nodes: [String: NodeEntry] = [:]
    private var codes: [String: JoinCode] = [:]
    private var peers: [String: DiscoveredPeer] = [:]
    public let nodeId: String
    public let nodeName: String

    public init(dataDir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        let idFile = dataDir + "/node_id"
        if let existing = try? String(contentsOfFile: idFile, encoding: .utf8), !existing.isEmpty {
            nodeId = existing
        } else {
            nodeId = UUID().uuidString.lowercased()
            try? nodeId.write(toFile: idFile, atomically: true, encoding: .utf8)
        }
        nodeName = HostInfo.hostName()
    }

    // MARK: Join codes

    public func issueJoinCode(ttlSeconds: Int = 600) -> String {
        codes = codes.filter { $0.value.expires > Date() }
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        codes[code] = JoinCode(code: code, expires: Date().addingTimeInterval(TimeInterval(ttlSeconds)))
        return code
    }

    public func consumeJoinCode(_ code: String) -> Bool {
        codes = codes.filter { $0.value.expires > Date() }
        for (candidate, entry) in codes where constantTimeEqual(candidate, code) {
            _ = entry
            codes.removeValue(forKey: candidate)
            return true
        }
        return false
    }

    // MARK: Registry

    public func register(id: String, name: String, ip: String, agentPort: Int, rpcPort: Int) {
        nodes[id] = NodeEntry(
            id: id, name: name, ip: ip, agentPort: agentPort, rpcPort: rpcPort,
            healthy: false, joinedMs: Date().timeIntervalSince1970 * 1000, lastHealth: nil, link: nil
        )
    }

    public func setHealth(id: String, healthy: Bool, health: JSONValue?) {
        guard var n = nodes[id] else { return }
        n.healthy = healthy
        n.lastHealth = health
        nodes[id] = n
    }

    public func setLink(id: String, link: JSONValue?) {
        guard var n = nodes[id] else { return }
        n.link = link
        nodes[id] = n
    }

    public func allNodes() -> [NodeEntry] { Array(nodes.values) }

    public func node(_ id: String) -> NodeEntry? { nodes[id] }

    public func nodesJSON() -> JSONValue {
        .array(nodes.values.sorted { $0.id < $1.id }.map { n in
            .object([
                "id": .string(n.id),
                "name": .string(n.name),
                "ip": .string(n.ip),
                "agent_port": .jInt(n.agentPort),
                "rpc_port": .jInt(n.rpcPort),
                "healthy": .bool(n.healthy),
                "joined_ms": .jDouble(n.joinedMs),
                "health": n.lastHealth ?? .null,
                "link": n.link ?? .null,
            ])
        })
    }

    // MARK: Discovery (beacon peers)

    public func ingestBeacon(_ beacon: Beacon) {
        peers[beacon.node_id] = DiscoveredPeer(
            nodeId: beacon.node_id, name: beacon.name, ip: beacon.ip,
            agentPort: beacon.agent_port, version: beacon.version,
            joinHash: beacon.join_hash, seenMs: Date().timeIntervalSince1970 * 1000,
            link: peers[beacon.node_id]?.link
        )
    }

    public func setPeerLink(nodeId: String, link: JSONValue) {
        guard var p = peers[nodeId] else { return }
        p.link = link
        peers[nodeId] = p
    }

    public func peersJSON() -> JSONValue {
        .array(peers.values.sorted { $0.nodeId < $1.nodeId }.map { p in
            .object([
                "node_id": .string(p.nodeId),
                "name": .string(p.name),
                "ip": .string(p.ip),
                "agent_port": .jInt(p.agentPort),
                "version": .string(p.version),
                "join_hash": .string(p.joinHash),
                "seen_ms_ago": .jDouble((Date().timeIntervalSince1970 * 1000) - p.seenMs),
                "link": p.link ?? .null,
            ])
        })
    }

    public func allPeers() -> [DiscoveredPeer] { Array(peers.values) }
}

/// TCP-latency + bulk-transfer link probe with RDMA/TB warnings (§6).
public enum LinkProbe {
    public static func probe(
        host: String, agentPort: Int, probeMB: Int = 16,
        cfg: ConfigSnapshot, events: EventActor, client: EngineClient
    ) async -> JSONValue {
        var rttMs = -1.0
        var mbps = -1.0
        var kind = "wifi"

        // TCP connect RTT proxy: 3 tiny GETs, keep best.
        for _ in 0..<3 {
            let t0 = Date()
            if let (status, _) = try? await client.getText("http://\(host):\(agentPort)/api/node/health", timeout: 2),
               status < 500
            {
                let ms = Date().timeIntervalSince(t0) * 1000
                if rttMs < 0 || ms < rttMs { rttMs = ms }
            }
        }

        let bytes = probeMB * 1_048_576
        let t1 = Date()
        if let got = try? await client.downloadBytes(url: "http://\(host):\(agentPort)/api/node/blob?mbps=\(probeMB)", maxBytes: bytes, timeout: 30) {
            let sec = Date().timeIntervalSince(t1)
            if sec > 0.005 { mbps = (Double(got) * 8 / 1e6) / sec }
        }

        let tb = rttMs >= 0 && rttMs < 1.2 && mbps > 2500
        if tb { kind = "thunderbolt" } else if mbps > 300 { kind = "ethernet" }

        // llama.cpp GGML RPC is TCP; RDMA is not exercised. Warn per §6.
        if kind != "thunderbolt" {
            try? await events.publish("cluster.warning", .object([
                "node": .string(host),
                "level": .string("warn"),
                "code": .string("rdma_unavailable"),
                "msg": .string("RPC split will be TCP-bound; connect a Thunderbolt cable for RDMA."),
            ]))
        } else if rttMs > 1.5 || mbps < 3000 {
            try? await events.publish("cluster.warning", .object([
                "node": .string(host),
                "level": .string("warn"),
                "code": .string("rdma_not_enabled"),
                "msg": .string("RDMA not enabled — llama.cpp RPC over TCP. Expect degraded split-model throughput."),
            ]))
        }
        if rttMs > 8 {
            try? await events.publish("cluster.warning", .object([
                "node": .string(host),
                "level": .string("warn"),
                "code": .string("high_latency"),
                "msg": .string(String(format: "Link RTT %.1f ms > 8 ms; split placements may stall.", rttMs)),
            ]))
        }

        return .object([
            "kind": .string(kind),
            "rtt_ms": .jDouble((rttMs * 100).rounded() / 100),
            "mbps": .jDouble((mbps * 100).rounded() / 100),
            "rdma": .bool(false),
        ])
    }
}
