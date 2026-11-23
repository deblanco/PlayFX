import Darwin

/// One received datagram and the IP address (text) it came from.
struct Datagram: Sendable, Equatable {
    var bytes: [UInt8]
    var source: String
}

/// A UDP socket, small enough for tests to replace with a fake that injects failures and timeouts.
protocol DatagramSocket: AnyObject {
    /// Sends one datagram. On a socket connected to a peer, `host` and `port` are ignored.
    func send(_ bytes: [UInt8], to host: String, port: UInt16) throws
    /// Waits up to `timeout` seconds for a datagram; nil when none came. Throws `FailureKind` on errors
    /// (for a connected socket this includes "connection refused" from an ICMP port unreachable).
    func receive(timeout: Double) throws -> Datagram?
}

/// Seconds on a monotonic clock.
func monotonicSeconds() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
}

/// Blocks the thread for `seconds`.
func sleepSeconds(_ seconds: Double) {
    guard seconds > 0 else { return }
    var request = timespec(tv_sec: Int(seconds), tv_nsec: Int((seconds - Double(Int(seconds))) * 1e9))
    var left = timespec()
    while nanosleep(&request, &left) == -1 && errno == EINTR { request = left }
}

/// A BSD UDP socket.
final class POSIXDatagramSocket: DatagramSocket, @unchecked Sendable {
    private let fd: Int32
    private let isConnected: Bool

    /// - Parameters:
    ///   - ipv6: the address family of the peer (IPv4 otherwise).
    ///   - broadcast: sets `SO_BROADCAST` (Network.framework cannot send broadcasts, hence a BSD socket).
    ///   - bindRange: local ports to try in order; an ephemeral port is used when none is free.
    ///   - peer: connects the socket to this address, which makes ICMP port unreachable surface as
    ///     `ECONNREFUSED` on receive (registration search).
    init(ipv6: Bool = false, broadcast: Bool = false, bindRange: ClosedRange<UInt16>? = nil,
         peer: (host: String, port: UInt16)? = nil) throws {
        let family = ipv6 ? AF_INET6 : AF_INET
        let s = socket(family, SOCK_DGRAM, 0)
        guard s >= 0 else { throw FailureKind(errno: errno) }
        do {
            try Self.setOption(s, SOL_SOCKET, SO_NOSIGPIPE, 1)
            if broadcast { try Self.setOption(s, SOL_SOCKET, SO_BROADCAST, 1) }
            // NET_SERVICE_TYPE_RD (Responsive Data): discovery, wake and registration are small
            // request/answer exchanges that a user is waiting on, so they should not queue behind bulk
            // traffic on Wi-Fi. (RV is Responsive Multimedia A/V and VI is Interactive Video; those are for the
            // stream.) Best effort.
            try? Self.setOption(s, SOL_SOCKET, SO_NET_SERVICE_TYPE, NET_SERVICE_TYPE_RD)
            var bound = false
            for port in bindRange ?? 0...0 where !bound {
                bound = Self.bind(s, ipv6: ipv6, port: port)
            }
            if !bound { _ = Self.bind(s, ipv6: ipv6, port: 0) }
            if let peer {
                guard let address = SocketAddress(host: peer.host, port: peer.port) else {
                    throw FailureKind.badAddress
                }
                guard address.withSockaddr({ connect(s, $0, $1) }) == 0 else { throw FailureKind(errno: errno) }
            }
        } catch {
            close(s)
            throw error
        }
        fd = s
        isConnected = peer != nil
    }

    deinit { close(fd) }

    private static func setOption(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32) throws {
        var v = value
        guard setsockopt(fd, level, name, &v, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw FailureKind(errno: errno)
        }
    }

    private static func bind(_ fd: Int32, ipv6: Bool, port: UInt16) -> Bool {
        let any = SocketAddress(host: ipv6 ? "::" : "0.0.0.0", port: port)!
        return any.withSockaddr { Darwin.bind(fd, $0, $1) } == 0
    }

    func send(_ bytes: [UInt8], to host: String, port: UInt16) throws {
        let sent: Int
        if isConnected {
            sent = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        } else {
            guard let address = SocketAddress(host: host, port: port) else { throw FailureKind.badAddress }
            sent = bytes.withUnsafeBytes { buffer in
                address.withSockaddr { Darwin.sendto(fd, buffer.baseAddress, buffer.count, 0, $0, $1) }
            }
        }
        guard sent == bytes.count else { throw FailureKind(errno: errno) }
    }

    func receive(timeout: Double) throws -> Datagram? {
        let deadline = monotonicSeconds() + max(0, timeout)
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = max(0, deadline - monotonicSeconds())
            let rc = poll(&pfd, 1, Int32((remaining * 1000).rounded(.up)))
            if rc < 0 {
                if errno == EINTR { continue }
                throw FailureKind(errno: errno)
            }
            if rc == 0 { return nil }
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            var buffer = [UInt8](repeating: 0, count: 2048)
            let count = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    buffer.withUnsafeMutableBytes { recvfrom(fd, $0.baseAddress, $0.count, 0, sa, &length) }
                }
            }
            guard count >= 0 else {
                if errno == EINTR || errno == EAGAIN { continue }
                throw FailureKind(errno: errno)
            }
            return Datagram(bytes: Array(buffer[0..<count]), source: SocketAddress.text(of: storage))
        }
    }
}

/// A numeric IPv4 or IPv6 socket address.
struct SocketAddress {
    private var storage = sockaddr_storage()
    private var length: socklen_t = 0

    /// Parses a numeric address; nil if it is neither IPv4 nor IPv6 text.
    init?(host fullHost: String, port: UInt16) {
        // A scoped literal such as fe80::1%en0 carries the interface after the percent sign.
        let parts = fullHost.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        let host = String(parts[0])
        var scope: UInt32 = 0
        if parts.count == 2 {
            let name = String(parts[1])
            scope = UInt32(name) ?? if_nametoindex(name)
            guard scope != 0 else { return nil }
        }
        let parsed = withUnsafeMutablePointer(to: &storage) { raw -> socklen_t? in
            let v4 = UnsafeMutableRawPointer(raw).assumingMemoryBound(to: sockaddr_in.self)
            if inet_pton(AF_INET, host, &v4.pointee.sin_addr) == 1 {
                v4.pointee.sin_family = sa_family_t(AF_INET)
                v4.pointee.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                v4.pointee.sin_port = port.bigEndian
                return socklen_t(MemoryLayout<sockaddr_in>.size)
            }
            let v6 = UnsafeMutableRawPointer(raw).assumingMemoryBound(to: sockaddr_in6.self)
            if inet_pton(AF_INET6, host, &v6.pointee.sin6_addr) == 1 {
                v6.pointee.sin6_family = sa_family_t(AF_INET6)
                v6.pointee.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                v6.pointee.sin6_port = port.bigEndian
                v6.pointee.sin6_scope_id = scope
                return socklen_t(MemoryLayout<sockaddr_in6>.size)
            }
            return nil
        }
        guard let parsed, scope == 0 || Self.isIPv6(host) else { return nil }
        length = parsed
    }

    /// True when `host` is IPv6 text.
    static func isIPv6(_ host: String) -> Bool {
        var v6 = in6_addr()
        return inet_pton(AF_INET6, String(host.prefix { $0 != "%" }), &v6) == 1
    }

    func withSockaddr<R>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
        withUnsafePointer(to: storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }

    /// Numeric text of a received address.
    static func text(of storage: sockaddr_storage) -> String {
        var storage = storage
        var out = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN) + 1)
        return withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { v4 in
                if Int32(v4.pointee.sin_family) == AF_INET {
                    var addr = v4.pointee.sin_addr
                    inet_ntop(AF_INET, &addr, &out, socklen_t(out.count))
                } else {
                    pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { v6 in
                        var addr = v6.pointee.sin6_addr
                        inet_ntop(AF_INET6, &addr, &out, socklen_t(out.count))
                    }
                }
                return String(decoding: out.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
    }
}

/// One IPv4 interface address as reported by `getifaddrs`.
struct InterfaceAddress: Equatable {
    var flags: Int32
    var address: UInt32
    var netmask: UInt32
}

/// The directed broadcast addresses (`address | ~netmask`, text) of interfaces that are up, can broadcast and
/// are not loopback or /32 (discovery.md section 4.2), without duplicates.
func directedBroadcastAddresses(of interfaces: [InterfaceAddress]) -> [String] {
    var seen = Set<UInt32>()
    var result: [String] = []
    for interface in interfaces {
        guard interface.flags & IFF_UP != 0, interface.flags & IFF_BROADCAST != 0,
              interface.flags & IFF_LOOPBACK == 0, interface.netmask != 0xffff_ffff else { continue }
        let broadcast = interface.address | ~interface.netmask
        guard seen.insert(broadcast).inserted else { continue }
        result.append((0..<4).map { String((broadcast >> UInt32(24 - 8 * $0)) & 0xff) }.joined(separator: "."))
    }
    return result
}

/// The directed broadcast address of every IPv4 interface of this Mac that qualifies.
func directedBroadcastAddresses() -> [String] {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return [] }
    defer { freeifaddrs(first) }
    var interfaces: [InterfaceAddress] = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = cursor {
        defer { cursor = entry.pointee.ifa_next }
        guard let address = entry.pointee.ifa_addr, let mask = entry.pointee.ifa_netmask,
              Int32(address.pointee.sa_family) == AF_INET else { continue }
        let a = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
        let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
        interfaces.append(InterfaceAddress(flags: Int32(entry.pointee.ifa_flags), address: a, netmask: m))
    }
    return directedBroadcastAddresses(of: interfaces)
}
