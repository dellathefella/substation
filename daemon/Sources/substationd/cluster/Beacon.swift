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

    public init(node_id: String, name: String, ip: String, agent_port: Int, version: String, join_hash: String) {
        self.magic = "SUBJ"
        self.node_id = node_id
        self.name = name
        self.ip = ip
        self.agent_port = agent_port
        self.version = version
        self.join_hash = join_hash
    }
}

/// UDP discovery beacons: multicast 224.0.1.87:8810 + limited broadcast.
public enum BeaconTransport {
    public static let multicastGroup = "224.0.1.87"
    public static let port: Int = 8810

    public static func joinHash(code: String, nodeId: String) -> String {
        String(sha256Hex(code + nodeId).prefix(16))
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
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return false }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(truncatingIfNeeded: cur.pointee.ifa_flags)
            guard let name = cur.pointee.ifa_name,
                  String(cString: name).hasPrefix("bridge1"),
                  (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0
            else { continue }
            return true
        }
        return false
    }

    public static func hostName() -> String {
        ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "substation-node"
    }
}
