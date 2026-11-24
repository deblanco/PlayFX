import Darwin
import Foundation

@testable import PlayFXProtocol

// Test doubles for internet play, shared with StreamCore's tests: a router, a STUN server, the console's PSN
// messages and `InternetRig`, which wires them to `FakePSN` and `InternetConsole`. Nothing here may reach beyond
// the loopback interface.

/// Where a loopback guard reports a destination that isn't loopback. The guard also refuses it (the socket throws
/// `networkUnreachable`), so a test fails either way; this is what a test checks to say so in words.
enum LoopbackViolations {
    static let recorded = Locked<[String]>([])
    static func record(_ text: String) { recorded.with { $0.append(text) } }
}

/// Wraps a socket and refuses (and fails the test) any destination that is not loopback, so a test can never put a
/// packet on the LAN, a router or the internet. Every attempt is recorded.
final class LoopbackGuardedPunchSocket: UDPPunchSocket, @unchecked Sendable {
    let inner: any UDPPunchSocket
    let destinations = Locked<[String]>([])
    /// Every time to live set, in order.
    let ttls = Locked<[Int]>([])
    init(_ inner: any UDPPunchSocket) { self.inner = inner }

    var localPort: UInt16 { inner.localPort }

    func send(_ bytes: [UInt8], to host: String, port: UInt16) throws {
        destinations.with { $0.append(host) }
        // A connected socket ignores `host`; the empty one RUDP passes is fine there.
        guard host.isEmpty || isLoopback(host) else {
            LoopbackViolations.record("test tried to send to non-loopback address \(host)")
            throw FailureKind.networkUnreachable
        }
        try inner.send(bytes, to: host, port: port)
    }

    func receive(timeout: Double) throws -> UDPPacket? { try inner.receive(timeout: timeout) }
    func connect(host: String, port: UInt16) throws {
        guard isLoopback(host) else {
            LoopbackViolations.record("test tried to connect to non-loopback address \(host)")
            throw FailureKind.networkUnreachable
        }
        try inner.connect(host: host, port: port)
    }
    func setTimeToLive(_ ttl: Int) throws {
        ttls.with { $0.append(ttl) }
        try inner.setTimeToLive(ttl)
    }
    func close() { inner.close() }
    func releaseDescriptor() -> Int32? { inner.releaseDescriptor() }
}

/// A guarded UDP socket bound to 127.0.0.1.
func loopbackSocket() throws -> LoopbackGuardedPunchSocket {
    LoopbackGuardedPunchSocket(try POSIXPunchSocket(bindHost: "127.0.0.1"))
}

