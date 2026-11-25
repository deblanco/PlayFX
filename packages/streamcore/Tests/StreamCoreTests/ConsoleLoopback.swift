import Darwin
import Foundation
import Testing
@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport
@testable import StreamCore

/// A discovery responder on a loopback UDP port: answers every search with `answer` and records what it received
/// (searches and wake packets).
final class DiscoveryResponder: @unchecked Sendable {
    static func answer(status: String = "200 Ok", ps5: Bool = true, hostID: String = "0A1B2C3D4E5F",
                       name: String = "PS5-TEST", app: String? = "Astro Bot") -> String {
        var text = "HTTP/1.1 \(status)\nhost-id:\(hostID)\nhost-type:\(ps5 ? "PS5" : "PS4")\nhost-name:\(name)\n"
            + "host-request-port:997\nsystem-version:09060008\n"
            + "device-discovery-protocol-version:\(ps5 ? "00030010" : "00020020")\n"
        if let app { text += "running-app-name:\(app)\nrunning-app-titleid:PPSA00001\n" }
        return text
    }

    let port: UInt16
    private let fd: Int32
    private let answer: [UInt8]?
    private let running = LockedFlag()
    private let packets = LockedLines()
    var received: [String] { packets.lines }

    init(answer: String?) {
        self.answer = answer.map { Array($0.utf8) + [0] }
        (fd, port) = FakeConsole.bindSocket(SOCK_DGRAM)
        Thread.detachNewThread { [self] in serve() }
    }

    func stop() {
        running.stop()
        close(fd)
    }

    private func serve() {
        while running.isRunning {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 50) > 0 else { continue }
            var from = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            var buffer = [UInt8](repeating: 0, count: 512)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    buffer.withUnsafeMutableBytes { recvfrom(fd, $0.baseAddress, 512, 0, sa, &length) }
                }
            }
            guard count > 0 else { continue }
            let text = String(decoding: buffer[0..<count].prefix { $0 != 0 }, as: UTF8.self)
            packets.append(text)
            guard let answer, text.hasPrefix("SRCH") else { continue }
            withUnsafePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = answer.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, sa, length) }
                }
            }
        }
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = true
    var isRunning: Bool { lock.withLock { on } }
    func stop() { lock.withLock { on = false } }
}

private func isLoopback(_ host: String) -> Bool { host == "127.0.0.1" || host == "::1" || host == "localhost" }

extension Console.Backend {
    /// Discovery and wake over the real PlayFXProtocol code on loopback, with `port` as both console ports and no
    /// broadcasts. A search with no host (a LAN broadcast in the app) asks 127.0.0.1 instead; any other
    /// non-loopback address is a test bug.
    static func loopback(discoveryPort port: UInt16) -> Console.Backend {
        var environment = DiscoveryEnvironment()
        environment.broadcastAddresses = { _ in [] }
        environment.ps4Port = port
        environment.ps5Port = port
        environment.interval = 0.05
        var backend = Console.Backend.live
        backend.discover = { host, timeout in
            let target = host ?? "127.0.0.1"
            guard isLoopback(target) else {
                Issue.record("test tried to search \(target)")
                return []
            }
            return try Discovery.discover(host: target, timeout: timeout, environment: environment, token: CancelToken())
        }
        backend.wake = { address, key, ps5 in
            guard isLoopback(address) else {
                Issue.record("test tried to wake \(address)")
                return false
            }
            return Discovery.wake(address: address, registKey: key, ps5: ps5, environment: environment)
        }
        return backend
    }

    /// Pairing over the real PlayFXProtocol code against a fake console on loopback.
    static func loopback(searchPort: UInt16, requestPort: UInt16, base: Console.Backend = .live) -> Console.Backend {
        var backend = base
        backend.register = { address, ps5, account, pin in
            guard isLoopback(address) else {
                Issue.record("test tried to pair with \(address)")
                throw FailureKind.networkUnreachable
            }
            var client = RegistrationClient()
            client.searchPort = searchPort
            client.requestPort = requestPort
            client.searchTimeout = 1
            client.pauseAfterSearch = 0.01
            client.connectTimeout = 2
            client.headerTimeout = 0.5
            client.bodyTimeout = 0.5
            return try client.register(
                address: address, target: ps5 ? .ps5v1 : .ps4v10, identity: .accountID(account), pin: pin)
        }
        return backend
    }
}

/// Runs `body` with `Console` talking to `backend`.
func withConsoleBackend<T>(_ backend: Console.Backend, _ body: () throws -> T) rethrows -> T {
    let saved = Console.backend
    Console.backend = backend
    defer { Console.backend = saved }
    return try body()
}
