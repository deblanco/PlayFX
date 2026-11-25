import Darwin
import Foundation

// The sockets under internet play (holepunch.md sections 2 and 5, rudp.md). Hole punching needs what
// Network.framework can't give: many sockets with a low `IP_TTL`, one socket per hole that is bound to a port we
// choose to read back, and `SO_REUSEPORT`. They are BSD sockets behind one small protocol so tests can inject
// loopback sockets, lossy sockets and fakes (DESIGN.md "Testable without a console").

/// One received datagram and where it came from.
public struct UDPPacket: Sendable, Equatable {
    /// The datagram's bytes.
    public var bytes: [UInt8]
    /// The sender's IP address (numeric text).
    public var host: String
    /// The sender's UDP port.
    public var port: UInt16

    public init(bytes: [UInt8], host: String, port: UInt16) {
        self.bytes = bytes
        self.host = host
        self.port = port
    }
}

/// A UDP socket as the hole punch, STUN, SSDP and RUDP use it.
///
/// Implementations are thread safe: RUDP sends from the caller's thread while its receive thread reads.
public protocol UDPPunchSocket: AnyObject, Sendable {
    /// The local port the socket is bound to.
    var localPort: UInt16 { get }
    /// Sends one datagram. On a connected socket `host` and `port` are ignored.
    func send(_ bytes: [UInt8], to host: String, port: UInt16) throws
    /// Waits up to `timeout` seconds for a datagram; nil when none came. Throws `FailureKind` on a socket error.
    func receive(timeout: Double) throws -> UDPPacket?
    /// Connects the socket to one peer: later sends go there and only that peer's datagrams are received.
    func connect(host: String, port: UInt16) throws
    /// Sets the IP time to live of what the socket sends (holepunch.md section 5.3 step 2).
    func setTimeToLive(_ ttl: Int) throws
    /// Closes the socket; calls in flight finish first. Safe to call twice.
    func close()
    /// Hands the open descriptor to the caller (the Takion transport that adopts the punched data socket) and leaves the
    /// object closed; nil when it can't (closed already, a call in flight, or a socket with no descriptor of its own).
    func releaseDescriptor() -> Int32?
}

extension UDPPunchSocket {
    public func releaseDescriptor() -> Int32? { nil }
}

/// A BSD UDP/IPv4 socket (`UDPPunchSocket`).
public final class POSIXPunchSocket: UDPPunchSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    private var connected = false
    private var users = 0
    private var closing = false
    /// The local port the system chose (or the one asked for).
    public let localPort: UInt16

    /// Creates a socket with `SO_REUSEPORT`, bound to `bindHost:port` (holepunch.md section 2: `0.0.0.0`, port 0).
    /// - Parameters:
    ///   - timeToLive: `IP_TTL` to set at once (the extra sockets of section 5.3 use 2).
    ///   - multicastTimeToLive: `IP_MULTICAST_TTL`, for SSDP (holepunch.md section 3.1 uses 2).
    public init(bindHost: String = "0.0.0.0", port: UInt16 = 0, timeToLive: Int? = nil,
                multicastTimeToLive: Int? = nil) throws {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { throw FailureKind(errno: errno) }
        do {
            try Self.setOption(s, SOL_SOCKET, SO_NOSIGPIPE, 1)
            try Self.setOption(s, SOL_SOCKET, SO_REUSEPORT, 1)
            if let timeToLive { try Self.setOption(s, IPPROTO_IP, IP_TTL, Int32(timeToLive)) }
            if let multicastTimeToLive {
                var ttl = UInt8(clamping: multicastTimeToLive)
                guard setsockopt(s, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, 1) == 0 else {
                    throw FailureKind(errno: errno)
                }
            }
            guard let address = SocketAddress(host: bindHost, port: port) else { throw FailureKind.badAddress }
            guard address.withSockaddr({ Darwin.bind(s, $0, $1) }) == 0 else { throw FailureKind(errno: errno) }
            var bound = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &length) }
            }
            guard named == 0 else { throw FailureKind(errno: errno) }
            localPort = UInt16(bigEndian: bound.sin_port)
        } catch {
            Darwin.close(s)
            throw error
        }
        fd = s
    }

    deinit {
        if fd >= 0 { Darwin.close(fd) }
    }

    private static func setOption(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32) throws {
        var v = value
        guard setsockopt(fd, level, name, &v, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw FailureKind(errno: errno)
        }
    }

    /// Runs `body` with the descriptor, which stays open until `body` returns even if `close()` is called meanwhile.
    private func withDescriptor<R>(_ body: (Int32) throws -> R) throws -> R {
        lock.lock()
        guard !closing else {
            lock.unlock()
            throw FailureKind.disconnected
        }
        users += 1
        let descriptor = fd
        lock.unlock()
        defer {
            lock.lock()
            users -= 1
            if closing && users == 0 && fd >= 0 {
                Darwin.close(fd)
                fd = -1
            }
            lock.unlock()
        }
        return try body(descriptor)
    }

    public func connect(host: String, port: UInt16) throws {
        guard let address = SocketAddress(host: host, port: port) else { throw FailureKind.badAddress }
        try withDescriptor { descriptor in
            guard address.withSockaddr({ Darwin.connect(descriptor, $0, $1) }) == 0 else {
                throw FailureKind(errno: errno)
            }
        }
        lock.lock()
        connected = true
        lock.unlock()
    }

    public func setTimeToLive(_ ttl: Int) throws {
        try withDescriptor { try Self.setOption($0, IPPROTO_IP, IP_TTL, Int32(ttl)) }
    }

    public func send(_ bytes: [UInt8], to host: String, port: UInt16) throws {
        lock.lock()
        let isConnected = connected
        lock.unlock()
        let address = isConnected ? nil : SocketAddress(host: host, port: port)
        if !isConnected && address == nil { throw FailureKind.badAddress }
        // errno is read inside the closure: leaving `withDescriptor` takes a lock, which may overwrite it.
        let (sent, code) = try withDescriptor { descriptor -> (Int, Int32) in
            let count: Int
            if let address {
                count = bytes.withUnsafeBytes { buffer in
                    address.withSockaddr { Darwin.sendto(descriptor, buffer.baseAddress, buffer.count, 0, $0, $1) }
                }
            } else {
                count = bytes.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
            }
            return (count, errno)
        }
        guard sent == bytes.count else { throw FailureKind(errno: code) }
    }

    public func receive(timeout: Double) throws -> UDPPacket? {
        let deadline = monotonicSeconds() + max(0, timeout)
        return try withDescriptor { descriptor in
            while true {
                var pfd = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let remaining = max(0, deadline - monotonicSeconds())
                let rc = poll(&pfd, 1, Int32((remaining * 1000).rounded(.up)))
                if rc < 0 {
                    if errno == EINTR { continue }
                    throw FailureKind(errno: errno)
                }
                if rc == 0 { return nil }
                var storage = sockaddr_storage()
                var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
                // An RUDP message may be 4095 bytes and a datagram holds several: a short buffer would truncate them.
                var buffer = [UInt8](repeating: 0, count: 8192)
                let count = withUnsafeMutablePointer(to: &storage) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        buffer.withUnsafeMutableBytes { recvfrom(descriptor, $0.baseAddress, $0.count, 0, sa, &length) }
                    }
                }
                guard count >= 0 else {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw FailureKind(errno: errno)
                }
                let port = withUnsafePointer(to: &storage) {
                    $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
                }
                return UDPPacket(bytes: Array(buffer[0..<count]), host: SocketAddress.text(of: storage), port: port)
            }
        }
    }

    public func close() {
        lock.lock()
        closing = true
        if users == 0 && fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        lock.unlock()
    }

    /// Hands the open descriptor to the caller (a Takion transport that adopts the punched data socket) and
    /// leaves this object closed. Nil if it is closed already or a call is still in flight.
    public func releaseDescriptor() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard !closing, users == 0, fd >= 0 else { return nil }
        closing = true
        let descriptor = fd
        fd = -1
        return descriptor
    }
}

/// An IPv4 interface as `getifaddrs` reports it.
public struct LocalInterface: Sendable, Equatable {
    /// The interface name, for example `en0`.
    public var name: String
    /// The `IFF_*` flags.
    public var flags: Int32
    /// The IPv4 address, dotted text.
    public var address: String

    public init(name: String, flags: Int32, address: String) {
        self.name = name
        self.flags = flags
        self.address = address
    }
}

/// This machine's own addresses (no packet is sent to find them).
public enum LocalInterfaces {
    /// Every IPv4 interface address.
    public static func all() -> [LocalInterface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(first) }
        var result: [LocalInterface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, Int32(address.pointee.sa_family) == AF_INET else { continue }
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var copy = value
            var out = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN) + 1)
            inet_ntop(AF_INET, &copy, &out, socklen_t(out.count))
            result.append(LocalInterface(
                name: String(cString: entry.pointee.ifa_name), flags: Int32(entry.pointee.ifa_flags),
                address: String(decoding: out.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)))
        }
        return result
    }

    /// The first IPv4 address of an interface that is up, running and not loopback (holepunch.md section 4.1, the
    /// LOCAL candidate when UPnP gave none).
    public static func firstUsableIPv4(_ interfaces: [LocalInterface]) -> String? {
        let wanted = IFF_UP | IFF_RUNNING
        return interfaces.first { $0.flags & wanted == wanted && $0.flags & IFF_LOOPBACK == 0 }?.address
    }

    /// The local address the system would use to reach `host` (the UPnP gateway), found by connecting a UDP
    /// socket, which sends nothing. Nil when there is no route.
    public static func address(toward host: String) -> String? {
        guard let target = SocketAddress(host: host, port: 9) else { return nil }
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return nil }
        defer { Darwin.close(s) }
        guard target.withSockaddr({ Darwin.connect(s, $0, $1) }) == 0 else { return nil }
        var local = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &length) }
        }
        return named == 0 ? SocketAddress.text(of: local) : nil
    }
}

/// The process's descriptor limit.
public enum FileLimit {
    /// Raises the soft `RLIMIT_NOFILE` to `wanted` (or the hard limit, if lower); returns the soft limit afterwards.
    /// The 250 extra hole-punch sockets need more than the 256 a GUI app may start with.
    @discardableResult
    public static func raiseSoftLimit(toAtLeast wanted: UInt64) -> UInt64 {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 0 }
        if UInt64(limit.rlim_cur) < wanted {
            // macOS refuses a soft limit above OPEN_MAX even when the hard limit is "unlimited".
            let target = min(UInt64(limit.rlim_max), wanted, UInt64(OPEN_MAX))
            if target > UInt64(limit.rlim_cur) {
                var raised = limit
                raised.rlim_cur = rlim_t(target)
                if setrlimit(RLIMIT_NOFILE, &raised) == 0 { limit = raised }
            }
        }
        return UInt64(limit.rlim_cur)
    }
}
