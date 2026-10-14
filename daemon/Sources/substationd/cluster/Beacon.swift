import Foundation
import Darwin

public struct Beacon: Sendable, Codable {
    public var magic: String
    public var node_id: String
    public var name: String
    public var ip: String
    public var agent_port: Int
    public var version: String
    public var join_hash: String
    public var rpc_port: Int
    public var secret_hash: String

    public init(node_id: String, name: String, ip: String, agent_port: Int, version: String, join_hash: String, rpc_port: Int = 50052, secret_hash: String = "") {
        self.magic = "SUBJ"
        self.node_id = node_id
        self.name = name
        self.ip = ip
        self.agent_port = agent_port
        self.version = version
        self.join_hash = join_hash
        self.rpc_port = rpc_port
        self.secret_hash = secret_hash
    }

    enum CodingKeys: String, CodingKey {
        case magic, node_id, name, ip, agent_port, version, join_hash, rpc_port, secret_hash
    }

    /// Tolerant decode: older node agents don't send rpc_port/secret_hash, so
    /// fall back to defaults instead of dropping the whole beacon.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        magic = try c.decode(String.self, forKey: .magic)
        node_id = try c.decode(String.self, forKey: .node_id)
        name = try c.decode(String.self, forKey: .name)
        ip = try c.decode(String.self, forKey: .ip)
        agent_port = try c.decode(Int.self, forKey: .agent_port)
        version = try c.decode(String.self, forKey: .version)
        join_hash = try c.decode(String.self, forKey: .join_hash)
        rpc_port = try c.decodeIfPresent(Int.self, forKey: .rpc_port) ?? 50052
        secret_hash = try c.decodeIfPresent(String.self, forKey: .secret_hash) ?? ""
    }
}

/// UDP discovery beacons: multicast 224.0.1.87:8810 + limited broadcast.
public enum BeaconTransport {
    public static let multicastGroup = "224.0.1.87"
    public static let port: Int = 8810

    public static func joinHash(code: String, nodeId: String) -> String {
        String(sha256Hex(code + nodeId).prefix(16))
    }

    /// Persistent shared-secret hash for auto-discovery: derived from the
    /// daemon auth token, so only peers that know the token can auto-join.
    public static func secretHash(secret: String, nodeId: String) -> String {
        guard !secret.isEmpty else { return "" }
        return String(sha256Hex("substation-auto:" + secret + ":" + nodeId).prefix(32))
    }

    public static func send(_ beacon: Beacon, port: Int = port) {
        guard let payload = try? JSONEncoder().encode(beacon) else { return }
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var broadcast: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))

        for host in [multicastGroup, "255.255.255.255"] {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            addr.sin_addr.s_addr = inet_addr(host)
            payload.withUnsafeBytes { raw in
                withUnsafePointer(to: &addr) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        _ = sendto(fd, raw.baseAddress, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    /// Blocking bind + non-blocking poll loop; run on a utility thread.
    public static func listenForever(port: Int = port, handler: @escaping @Sendable (Data) -> Void) {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var bindAddr = sockaddr_in()
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = in_port_t(port).bigEndian
        bindAddr.sin_addr.s_addr = in_addr(s_addr: 0).s_addr
        let bindOK = withUnsafePointer(to: &bindAddr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0 else {
            NSLog("substationd: beacon listener bind :\(port) failed (\(errno)) — discovery disabled")
            close(fd)
            return
        }

        var mreq = ip_mreq(
            imr_multiaddr: in_addr(s_addr: inet_addr(multicastGroup)),
            imr_interface: in_addr(s_addr: 0)
        )
        setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))

        let flags = fcntl(fd, F_GETFL, 0)
        fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, MSG_DONTWAIT)
            if n > 0 {
                handler(Data(buf[0..<n]))
                Thread.sleep(forTimeInterval: 0.05)
            } else {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }
}

public enum HostInfo {
    /// First usable IPv4 on en*/bridge1xx/llw* (Thunderbolt bridges are bridge10x).
    public static func primaryIP() -> String {
        var best = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return best }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(truncatingIfNeeded: cur.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0, (flags & IFF_LOOPBACK) == 0,
                  let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  let name = cur.pointee.ifa_name
            else { continue }
            let nameStr = String(cString: name)
            var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                inet_ntop(AF_INET, &sin.pointee.sin_addr, &host, socklen_t(INET_ADDRSTRLEN))
            }
            let ip = String(cString: host)
            if nameStr == "en0" || nameStr == "en1" { return ip }
            if best == "127.0.0.1", nameStr.hasPrefix("en") || nameStr.hasPrefix("bridge1") || nameStr.hasPrefix("llw") {
                best = ip
            }
        }
        return best
    }

    public static func thunderboltActive() -> Bool {
        interfaces().contains { $0.kind == "thunderbolt-bridge" && $0.running }
    }

    public struct NetIface: Sendable {
        public var name: String
        public var ip: String
        public var netmask: String
        public var up: Bool
        public var running: Bool
        public var kind: String  // thunderbolt-bridge | thunderbolt | wifi | ethernet | loopback | vpn | other
    }

    /// IPv4 inventory for the cluster wizard: name, address, flags + kind guess.
    public static func interfaces() -> [NetIface] {
        var out: [NetIface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }
        var byName: [String: (flags: Int32, ip: String, mask: String)] = [:]
        var order: [String] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let name = cur.pointee.ifa_name, let addr = cur.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let n = String(cString: name)
            var host = [Int8](repeating: 0, count: Int(NI_MAXHOST))
            let flags = Int32(truncatingIfNeeded: cur.pointee.ifa_flags)
            guard getnameinfo(addr, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var mask = ""
            if let m = cur.pointee.ifa_netmask, m.pointee.sa_family == UInt8(AF_INET),
               (flags & IFF_LOOPBACK) == 0 {
                var mh = [Int8](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(m, socklen_t(MemoryLayout<sockaddr_in>.size), &mh, socklen_t(mh.count),
                               nil, 0, NI_NUMERICHOST) == 0 { mask = String(cString: mh) }
            }
            let ip = String(cString: host)
            if byName[n] == nil { order.append(n) }
            if ip.hasPrefix("127.") || n == "lo0" {
                byName[n] = (flags, ip.isEmpty ? "127.0.0.1" : ip, "")
                continue
            }
            byName[n] = (flags, ip, mask)
        }
        for n in order {
            guard let v = byName[n] else { continue }
            let kind: String
            if v.flags & IFF_LOOPBACK != 0 { kind = "loopback" }
            else if n.hasPrefix("bridge1") { kind = "thunderbolt-bridge" }
            else if n.hasPrefix("llw") { kind = "thunderbolt" }
            else if n.hasPrefix("utun") || n.hasPrefix("ipsec") || n.hasPrefix("ppp") { kind = "vpn" }
            else if n == "en0" { kind = "wifi" }
            else if n.hasPrefix("en") { kind = "ethernet" }
            else { kind = "other" }
            out.append(NetIface(name: n, ip: v.ip, netmask: v.mask,
                                up: (v.flags & IFF_UP) != 0, running: (v.flags & IFF_RUNNING) != 0, kind: kind))
        }
        return out
    }

    public static func hostName() -> String {
        ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "substation-node"
    }
}
