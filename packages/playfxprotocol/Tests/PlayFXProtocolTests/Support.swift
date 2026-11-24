import Testing
import Foundation

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

// MARK: Loopback-only guard

/// Wraps a real socket and refuses (and fails the test) any destination that is not 127.0.0.1 or ::1, so a
/// test can never put a packet on the LAN.
final class LoopbackGuardedSocket: DatagramSocket, @unchecked Sendable {
    let inner: DatagramSocket
    let destinations = Locked<[String]>([])
    init(_ inner: DatagramSocket) { self.inner = inner }

    func send(_ bytes: [UInt8], to host: String, port: UInt16) throws {
        destinations.with { $0.append(host) }
        guard isLoopback(host) else {
            Issue.record("test tried to send to non-loopback address \(host)")
            throw FailureKind.networkUnreachable
        }
        try inner.send(bytes, to: host, port: port)
    }

    func receive(timeout: Double) throws -> Datagram? { try inner.receive(timeout: timeout) }
}

extension DiscoveryEnvironment {
    /// A real UDP socket guarded to loopback, no broadcast addresses, the given ports.
    static func loopback(ps4Port: UInt16, ps5Port: UInt16, interval: Double = 0.1) -> DiscoveryEnvironment {
        var environment = DiscoveryEnvironment()
        environment.makeSocket = { ipv6 in
            LoopbackGuardedSocket(try POSIXDatagramSocket(ipv6: ipv6, broadcast: true, bindRange: Discovery.localPorts))
        }
        environment.broadcastAddresses = { _ in [] }
        environment.ps4Port = ps4Port
        environment.ps5Port = ps5Port
        environment.interval = interval
        return environment
    }
}

extension RegistrationClient {
    /// Real sockets, but only to loopback.
    func loopbackOnly() -> RegistrationClient {
        var client = self
        client.makeSocket = { host, port in
            guard isLoopback(host) else {
                Issue.record("test tried to reach non-loopback address \(host)")
                throw FailureKind.networkUnreachable
            }
            return try POSIXDatagramSocket(ipv6: SocketAddress.isIPv6(host), peer: (host, port))
        }
        client.makeConnection = { host, port in
            guard isLoopback(host) else {
                Issue.record("test tried to connect to non-loopback address \(host)")
                throw FailureKind.networkUnreachable
            }
            return try NWBlockingTCPConnection(host: host, port: port)
        }
        return client
    }
}
