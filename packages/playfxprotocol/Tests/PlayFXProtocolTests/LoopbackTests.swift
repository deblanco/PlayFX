import Darwin
import Foundation
import Testing

@testable import PlayFXProtocol

/// End to end on 127.0.0.1 with ephemeral ports: the real BSD UDP socket and the real `NWConnection` talk
/// to a fake console written from the spec.
@Suite struct LoopbackTests {
    static func client(_ console: FakeConsole) -> RegistrationClient {
        var client = RegistrationClient()
        client.searchPort = console.searchPort
        client.requestPort = console.requestPort
        client.searchTimeout = 1
        client.pauseAfterSearch = 0.01
        client.connectTimeout = 2
        client.headerTimeout = 0.5
        client.bodyTimeout = 0.5
        return client.loopbackOnly()
    }

    static func run(_ console: FakeConsole, client: RegistrationClient? = nil) -> Result<PairingResult, RegistrationError> {
        do {
            return .success(try (client ?? Self.client(console)).register(
                address: "127.0.0.1", target: console.target, identity: .accountID(Vector.accountID), pin: Vector.pin))
        } catch let error as RegistrationError {
            return .failure(error)
        } catch {
            Issue.record("unexpected \(error)")
            return .failure(RegistrationError(kind: .other(errno: -1), consoleAnswered: false))
        }
    }

    @Test(arguments: RPTarget.allCases) func pairsWithEveryTarget(_ target: RPTarget) throws {
        let console = FakeConsole(target: target, pin: Vector.pin) { _ in
            .encrypted(status: "200 OK", plaintext: FakeConsole.pairingPlaintext(ps5: target.isPS5))
        }
        defer { console.stop() }
        let result = try Self.run(console).get()
        #expect(result.registKey == Vector.registKey)
        #expect(result.rpKey == hex("00112233445566778899aabbccddeeff"))
        #expect(result.mac == hex("0a1b2c3d4e5f"))
        #expect(result.nickname == "\(target.isPS5 ? "PS5" : "PS4")-TEST")
        #expect(result.keyType == 2 && result.target == target)

        // The console saw the exact header and the inner text of registration.md section 3.
        let request = try #require(console.requests.with { $0.first })
        let isLegacy = target == .ps4v8 || target == .ps4v9
        let text = isLegacy
            ? "Client-Type: Windows\r\nNp-AccountId: FYHpffQQIhE=\r\n"
            : "Client-Type: \(RegistrationRequest.clientType)\r\nNp-AccountId: FYHpffQQIhE=\r\n"
        #expect(request.inner == text)
        let path = isLegacy ? "/sce/rp/regist" : target.isPS5 ? "/sie/ps5/rp/sess/rgst" : "/sie/ps4/rp/sess/rgst"
        let version = ["ps4v8": "", "ps4v9": "RP-Version: 9.0\r\n", "ps4v10": "RP-Version: 10.0\r\n", "ps5v1": "RP-Version: 1.0\r\n"]["\(target)"]!
        #expect(String(decoding: request.header, as: UTF8.self)
            == "POST \(path) HTTP/1.1\r\n HTTP/1.1\r\nHOST: 10.0.2.15\r\nUser-Agent: remoteplay Windows\r\nConnection: close\r\nContent-Length: \(request.body.count)\r\n\(version)\r\n")
    }

    @Test func legacyOnlineID() throws {
        let console = FakeConsole(target: .ps4v9, pin: Vector.pin) { _ in
            .encrypted(status: "200 OK", plaintext: FakeConsole.pairingPlaintext(ps5: false))
        }
        defer { console.stop() }
        _ = try Self.client(console).register(
            address: "127.0.0.1", target: .ps4v9, identity: .onlineID("playfx-tester"), pin: Vector.pin)
        #expect(console.requests.with { $0[0].inner } == "Client-Type: Windows\r\nNp-Online-Id: playfx-tester\r\n")
    }

    @Test func wrongPIN() {
        let console = FakeConsole(target: .ps5v1, pin: Vector.pin) { _ in
            .header("HTTP/1.1 403 Forbidden\r\nRP-Application-Reason: 80108b09\r\nContent-Length: 0\r\n\r\n")
        }
        defer { console.stop() }
        guard case .failure(let error) = Self.run(console) else { Issue.record("expected a failure"); return }
        #expect(error == RegistrationError(kind: .httpNotOK(status: 403), reasonCode: 0x80108b09, consoleAnswered: true))
        #expect(error.userMessage(ps5: true).hasPrefix("The code is wrong or has expired."))
    }

    @Test func otherReasons() {
        for (reason, prefix) in [("80108b02", "The PlayStation account ID"), ("80108b11", "The PS5's Remote Play version"),
                                 ("80108b10", "The PS5 is already in a Remote Play session."), ("80108bff", "The PS5 refused pairing (reason 0x80108bff)")] {
            let console = FakeConsole(target: .ps5v1, pin: Vector.pin) { _ in
                .header("HTTP/1.1 400 Bad Request\r\nRP-Application-Reason: \(reason)\r\n\r\n")
            }
            defer { console.stop() }
            guard case .failure(let error) = Self.run(console) else { Issue.record("expected a failure"); return }
            #expect(error.reasonCode == UInt32(reason, radix: 16))
            #expect(error.userMessage(ps5: true).hasPrefix(prefix), "\(reason)")
        }
    }

    @Test func searchNeverAnswered() {
        let console = FakeConsole(target: .ps5v1, pin: Vector.pin, answersSearch: false) { _ in .close }
        defer { console.stop() }
        var client = Self.client(console)
        client.searchTimeout = 0.2
        guard case .failure(let error) = Self.run(console, client: client) else { Issue.record("expected a failure"); return }
        #expect(error == RegistrationError(kind: .timeout, consoleAnswered: false))
        #expect(error.userMessage(ps5: true).hasPrefix("The PS5 didn't answer."))
    }

    @Test func pairingScreenClosedUDPRefused() {
        var client = RegistrationClient().loopbackOnly()
        client.searchPort = FakeConsole.closedUDPPort()
        client.searchTimeout = 1
        let result = try? client.register(
            address: "127.0.0.1", target: .ps5v1, identity: .accountID(Vector.accountID), pin: 1)
        #expect(result == nil)
        do {
            _ = try client.register(address: "127.0.0.1", target: .ps5v1, identity: .accountID(Vector.accountID), pin: 1)
        } catch {
            #expect(error as? RegistrationError == RegistrationError(kind: .connectionRefused, consoleAnswered: false))
        }
    }

    @Test func tcpRefusedAfterTheSearchAnswer() {
        let console = FakeConsole(target: .ps5v1, pin: Vector.pin, listensTCP: false) { _ in .close }
        defer { console.stop() }
        var client = Self.client(console)
        client.requestPort = FakeConsole.closedTCPPort()
        guard case .failure(let error) = Self.run(console, client: client) else { Issue.record("expected a failure"); return }
        #expect(error == RegistrationError(kind: .connectionRefused, consoleAnswered: true))
        #expect(error.userMessage(ps5: true).hasPrefix("The PS5 stopped answering"))
    }

    @Test func garbageResponse() {
        let console = FakeConsole(target: .ps5v1, pin: Vector.pin) { _ in .raw(Array("this is not http at all\r\n\r\n".utf8)) }
        defer { console.stop() }
        guard case .failure(let error) = Self.run(console) else { Issue.record("expected a failure"); return }
        #expect(error == RegistrationError(kind: .invalidResponse, consoleAnswered: true))
        #expect(error.userMessage(ps5: true).hasPrefix("Registration failed:"))
    }

    @Test func okWithoutUsableFields() {
        let console = FakeConsole(target: .ps5v1, pin: Vector.pin) { _ in
            .encrypted(status: "200 OK", plaintext: "PS5-Nickname: only a name\r\n")
        }
        defer { console.stop() }
        guard case .failure(let error) = Self.run(console) else { Issue.record("expected a failure"); return }
        #expect(error == RegistrationError(kind: .invalidData, consoleAnswered: true))
    }

    @Test func consoleClosesWithoutAnswering() {
        let console = FakeConsole(target: .ps5v1, pin: Vector.pin) { _ in .close }
        defer { console.stop() }
        guard case .failure(let error) = Self.run(console) else { Issue.record("expected a failure"); return }
        #expect(error.consoleAnswered)
        #expect(error.kind == .disconnected)
        #expect(error.userMessage(ps5: true).hasPrefix("The PS5 stopped answering partway through pairing."))
    }

    @Test func consoleClosesInTheMiddleOfTheBody() {
        let console = FakeConsole(target: .ps4v10, pin: Vector.pin) { _ in
            .raw(Array("HTTP/1.1 200 OK\r\nContent-Length: 137\r\n\r\nshort".utf8))
        }
        defer { console.stop() }
        guard case .failure(let error) = Self.run(console) else { Issue.record("expected a failure"); return }
        #expect(error == RegistrationError(kind: .disconnected, consoleAnswered: true))
    }

    @Test func consoleGoesSilent() {
        let console = FakeConsole(target: .ps5v1, pin: Vector.pin) { _ in .hang }
        defer { console.stop() }
        var client = Self.client(console)
        client.headerTimeout = 0.2
        guard case .failure(let error) = Self.run(console, client: client) else { Issue.record("expected a failure"); return }
        #expect(error == RegistrationError(kind: .timeout, consoleAnswered: true))
    }

    @Test func wrongPINIsNotAcceptedByAConsoleWithAnotherPIN() {
        // The console derives its key from another PIN, so the client cannot decrypt: unusable data.
        let console = FakeConsole(target: .ps5v1, pin: 11111111) { _ in
            .encrypted(status: "200 OK", plaintext: FakeConsole.pairingPlaintext(ps5: true))
        }
        defer { console.stop() }
        guard case .failure(let error) = Self.run(console) else { Issue.record("expected a failure"); return }
        #expect(error.kind == .invalidData)
    }

    // MARK: Discovery and wake over the real UDP socket

    @Test func discoversAndWakesOverLoopback() throws {
        let (fd, port) = FakeConsole.bindSocket(SOCK_DGRAM)
        defer { close(fd) }
        let received = Locked<[[UInt8]]>([])
        let running = Locked(true)
        Thread.detachNewThread {
            while running.with({ $0 }) {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&pfd, 1, 20) > 0 else { continue }
                var from = sockaddr_storage()
                var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
                var buffer = [UInt8](repeating: 0, count: 512)
                let n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        buffer.withUnsafeMutableBytes { recvfrom(fd, $0.baseAddress, 512, 0, sa, &length) }
                    }
                }
                guard n > 0 else { continue }
                let packet = Array(buffer[0..<n])
                received.with { $0.append(packet) }
                // Only the PS5 search is answered; wake gets no answer.
                guard packet == Discovery.searchPacket(ps5: true) else { continue }
                let answer = Array(DiscoveryTests.ps5Answer.utf8)
                withUnsafePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        _ = answer.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, sa, length) }
                    }
                }
            }
        }
        defer { running.with { $0 = false } }

        let environment = DiscoveryEnvironment.loopback(ps4Port: port, ps5Port: port)
        let found = try Discovery.discover(host: "127.0.0.1", timeout: 0.5, environment: environment, token: CancelToken())
        #expect(found.count == 1)
        #expect(found.first?.hostID == "0A1B2C3D4E5F" && found.first?.address == "127.0.0.1")
        #expect(found.first?.kind == .ps5 && found.first?.name == "PS5-TEST")

        #expect(Discovery.wake(address: "127.0.0.1", registKey: Vector.registKey, ps5: true, environment: environment))
        sleepSeconds(0.1)
        #expect(received.with { $0.contains(Discovery.wakePacket(credential: "2712847316", ps5: true)) })

        // Public unicast calls to loopback only (nothing listens on the console ports): no consoles, and no
        // error because the sends themselves succeed. The broadcast forms are never called from tests.
        #expect(Discovery.discover(host: "127.0.0.1", timeout: 0.05).isEmpty)
        #expect(Discovery.discover(host: "::1", timeout: 0.05).isEmpty)
        #expect(try Discovery.discoverThrowing(host: "127.0.0.1", timeout: 0.05).isEmpty)
        #expect(Discovery.discover(host: "not an address", timeout: 0.05).isEmpty)
        #expect(throws: FailureKind.badAddress) { try Discovery.discoverThrowing(host: "not an address", timeout: 0.05) }
    }

    @Test func cancellingARegistrationAgainstASilentConsoleReturnsQuickly() async throws {
        let console = FakeConsole(target: .ps5v1, pin: Vector.pin) { _ in .hang }
        defer { console.stop() }
        var client = Self.client(console)
        client.headerTimeout = 10
        let ready = client
        let task = Task {
            try await Registration.registerAsync(
                client: ready, address: "127.0.0.1", target: .ps5v1, identity: .accountID(Vector.accountID), pin: Vector.pin)
        }
        // Wait until the console has the request, so the client is blocked reading the answer.
        let waitStart = monotonicSeconds()
        while console.requests.with({ $0.isEmpty }) && monotonicSeconds() - waitStart < 3 { sleepSeconds(0.01) }
        let cancelledAt = monotonicSeconds()
        task.cancel()
        let result = await task.result
        #expect(monotonicSeconds() - cancelledAt < 0.5)
        guard case .failure(let error) = result, let registration = error as? RegistrationError else {
            Issue.record("expected a RegistrationError")
            return
        }
        #expect(registration.kind == .cancelled && registration.consoleAnswered)
        #expect(registration.userMessage(ps5: true).isEmpty)
    }

    @Test func asyncRegistrationSucceeds() async throws {
        let console = FakeConsole(target: .ps4v10, pin: Vector.pin) { _ in
            .encrypted(status: "200 OK", plaintext: FakeConsole.pairingPlaintext(ps5: false))
        }
        defer { console.stop() }
        let result = try await Registration.registerAsync(
            client: Self.client(console), address: "127.0.0.1", target: .ps4v10,
            identity: .accountID(Vector.accountID), pin: Vector.pin)
        #expect(result.nickname == "PS4-TEST")
    }

    @Test func socketErrorsAreThrown() {
        #expect(throws: FailureKind.badAddress) { try POSIXDatagramSocket(peer: ("not an address", 1)) }
        let socket = try? POSIXDatagramSocket()
        #expect(throws: FailureKind.badAddress) { try socket?.send([1], to: "nope", port: 1) }
        #expect((try? socket?.receive(timeout: 0.01)) == .some(nil))
        #expect(throws: FailureKind.badAddress) { try NWBlockingTCPConnection(host: "", port: 1) }
    }

    @Test func receiveTimesOutOnASilentPeer() throws {
        // A listener that accepts (the kernel completes the handshake) and never sends.
        let (fd, port) = FakeConsole.bindSocket(SOCK_STREAM)
        listen(fd, 4)
        defer { close(fd) }
        let connection = try NWBlockingTCPConnection(host: "127.0.0.1", port: port)
        defer { connection.close() }
        try connection.connect(timeout: 2)
        #expect(throws: FailureKind.timeout) { try connection.receive(maximum: 10, timeout: 0.1) }
    }
}
