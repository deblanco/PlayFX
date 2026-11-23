import CryptoKit
import Testing
import Foundation

@testable import PlayFXProtocol

/// Hex text to bytes (test inputs are well formed).
func hex(_ text: String) -> [UInt8] {
    decodeHex(text.utf8.filter { $0 != 0x20 && $0 != 0x0a })!
}

func sha256Hex(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

/// A recorded vector from `Fixtures` (whitespace-separated hex lines).
func fixture(_ name: String) throws -> [UInt8] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "hex", subdirectory: "Fixtures"))
    return hex(try String(contentsOf: url, encoding: .utf8))
}

/// The common inputs of docs/protocol/test-vectors.md.
enum Vector {
    static let nonce = hex("9f3c5a17e2b4086dc1f05e7a3b92d4c8")
    static let rpKey = hex("4a6f1e2d8c7b5a3948e7f6d5c4b3a291")
    static let seed = hex("0f1e2d3c4b5a69788796a5b4c3d2e1f0")
    static let pin: UInt32 = 12345678
    static let accountID = hex("1581e97df4102211")
    static let plaintext = Array("The quick brown fox jumps over 13 dogs".utf8)
    static let d1 = hex("101112131415161718191a1b1c1d1e1f")
    static let d2 = hex("202122232425262728292a2b2c2d2e2f")
    static let cd = hex("303132333435363738393a3b3c3d3e3f")
    static let registKey = hex("61316232633364340000000000000000")
}

/// A lock-protected value shared with threads and callbacks.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func with<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

struct SentDatagram: Equatable {
    var bytes: [UInt8]
    var host: String
    var port: UInt16
}

/// A scripted `DatagramSocket`: records sends, lets a closure answer them, and can fail.
final class FakeDatagramSocket: DatagramSocket, @unchecked Sendable {
    let sent = Locked<[SentDatagram]>([])
    private let inbox = Locked<[Result<Datagram?, FailureKind>]>([])
    var onSend: @Sendable (SentDatagram) throws -> [Datagram] = { _ in [] }

    func queue(_ result: Result<Datagram?, FailureKind>) { inbox.with { $0.append(result) } }

    func send(_ bytes: [UInt8], to host: String, port: UInt16) throws {
        let datagram = SentDatagram(bytes: bytes, host: host, port: port)
        sent.with { $0.append(datagram) }
        for reply in try onSend(datagram) { queue(.success(reply)) }
    }

    func receive(timeout: Double) throws -> Datagram? {
        if let next = inbox.with({ $0.isEmpty ? nil : $0.removeFirst() }) { return try next.get() }
        sleepSeconds(min(timeout, 0.02))
        return nil
    }
}

// MARK: Loopback-only guard

func isLoopback(_ host: String) -> Bool { host == "127.0.0.1" || host == "::1" }

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
        environment.broadcastAddresses = { [] }
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
