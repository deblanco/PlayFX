import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

/// A scripted `BlockingTCPConnection`.
final class FakeConnection: BlockingTCPConnection, @unchecked Sendable {
    var connectResult: FailureKind?
    var sendResult: FailureKind?
    let sent = Locked<[UInt8]>([])
    let closed = Locked(false)
    private let script: Locked<[Result<[UInt8], FailureKind>]>

    init(_ script: [Result<[UInt8], FailureKind>]) { self.script = Locked(script) }

    func connect(timeout: Double) throws { if let connectResult { throw connectResult } }

    func send(_ bytes: [UInt8], timeout: Double) throws {
        if let sendResult { throw sendResult }
        sent.with { $0 += bytes }
    }

    func receive(maximum: Int, timeout: Double) throws -> [UInt8] {
        try script.with { $0.isEmpty ? .success([]) : $0.removeFirst() }.get()
    }

    func close() { closed.with { $0 = true } }
}

@Suite struct RegistrationFlowTests {
    static let okHead = "HTTP/1.1 200 OK\r\nContent-Length: 137\r\n\r\n"

    /// A client over fakes; the connection answers `script`, the search socket answers like a console.
    static func client(
        _ connection: FakeConnection, searchReplies: Bool = true, socketError: FailureKind? = nil
    ) -> (RegistrationClient, FakeDatagramSocket, Locked<[Double]>) {
        let socket = FakeDatagramSocket()
        socket.onSend = { sent in
            searchReplies
                ? [Datagram(bytes: Array("RES3".utf8), source: "other"), Datagram(bytes: Array("RES3".utf8) + [0], source: "192.168.1.9")]
                : []
        }
        let pauses = Locked<[Double]>([])
        var client = RegistrationClient()
        client.searchTimeout = 0.1
        client.makeSocket = { _, _ in
            if let socketError { throw socketError }
            return socket
        }
        client.makeConnection = { _, _ in connection }
        client.randomBytes = { _ in Vector.seed }
        client.pause = { seconds in pauses.with { $0.append(seconds) } }
        return (client, socket, pauses)
    }

    static func recorded() throws -> [UInt8] { try fixture("response-ps5-1") }

    func run(_ client: RegistrationClient) throws -> PairingResult {
        try client.register(address: "192.168.1.9", target: .ps5v1, identity: .accountID(Vector.accountID), pin: Vector.pin)
    }

    func failure(_ client: RegistrationClient) -> RegistrationError? {
        do {
            _ = try run(client)
            return nil
        } catch let error as RegistrationError {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    @Test func succeedsAndSendsHeaderThenBodyInOrder() throws {
        // Header and body arrive split across reads, the body part in the same read as the header end.
        let recorded = try Self.recorded()
        let connection = FakeConnection([
            .success(Array(Self.okHead.utf8.prefix(10))),
            .success(Array(Self.okHead.utf8.dropFirst(10)) + recorded[..<20]),
            .success(Array(recorded[20...])),
        ])
        let (client, socket, pauses) = Self.client(connection)
        let result = try run(client)
        #expect(result.nickname == "PS5-TEST" && result.target == .ps5v1)
        #expect(socket.sent.with { $0 } == [SentDatagram(bytes: Array("SRC3".utf8) + [0], host: "192.168.1.9", port: 9295)])
        #expect(pauses.with { $0 } == [0.1])
        let request = try Self.build()
        #expect(connection.sent.with { $0 } == request.header + request.body)
        #expect(connection.closed.with { $0 })
    }

    static func build() throws -> RegistrationRequest { try RegistrationTests.build(.ps5v1) }

    @Test func ps4SearchUsesSRC2() throws {
        let socket = FakeDatagramSocket()
        socket.onSend = { _ in [Datagram(bytes: Array("RES2".utf8), source: "x")] }
        var client = RegistrationClient()
        client.makeSocket = { _, _ in socket }
        client.makeConnection = { _, _ in FakeConnection([.success(Array("HTTP/1.1 403 X\r\n\r\n".utf8))]) }
        client.randomBytes = { _ in Vector.seed }
        client.pause = { _ in }
        _ = try? client.register(address: "h", target: .ps4v10, identity: .accountID(Vector.accountID), pin: 1)
        #expect(socket.sent.with { $0[0].bytes } == Array("SRC2".utf8) + [0])
    }

    @Test func searchSilenceTimesOut() {
        let (client, _, pauses) = Self.client(FakeConnection([]), searchReplies: false)
        let error = failure(client)
        #expect(error == RegistrationError(kind: .timeout, consoleAnswered: false))
        #expect(pauses.with { $0.isEmpty })
    }

    @Test func searchSocketErrors() {
        let (client, _, _) = Self.client(FakeConnection([]), socketError: .badAddress)
        #expect(failure(client) == RegistrationError(kind: .badAddress, consoleAnswered: false))

        let socket = FakeDatagramSocket()
        socket.queue(.failure(.connectionRefused))
        var refused = RegistrationClient()
        refused.makeSocket = { _, _ in socket }
        #expect(failure(refused) == RegistrationError(kind: .connectionRefused, consoleAnswered: false))

        let broken = FakeDatagramSocket()
        broken.onSend = { _ in throw FailureKind.networkUnreachable }
        var unreachable = RegistrationClient()
        unreachable.makeSocket = { _, _ in broken }
        #expect(failure(unreachable) == RegistrationError(kind: .networkUnreachable, consoleAnswered: false))
    }

    @Test func connectionStepsFailAfterTheConsoleAnswered() {
        let refused = FakeConnection([])
        refused.connectResult = .connectionRefused
        #expect(failure(Self.client(refused).0) == RegistrationError(kind: .connectionRefused, consoleAnswered: true))

        let cannotSend = FakeConnection([])
        cannotSend.sendResult = .disconnected
        #expect(failure(Self.client(cannotSend).0) == RegistrationError(kind: .disconnected, consoleAnswered: true))

        var noConnection = Self.client(FakeConnection([])).0
        noConnection.makeConnection = { _, _ in throw FailureKind.badAddress }
        #expect(failure(noConnection) == RegistrationError(kind: .badAddress, consoleAnswered: true))

        let closed = FakeConnection([.success([])])
        #expect(failure(Self.client(closed).0) == RegistrationError(kind: .disconnected, consoleAnswered: true))

        let connectTimeout = FakeConnection([])
        connectTimeout.connectResult = .timeout
        #expect(failure(Self.client(connectTimeout).0) == RegistrationError(kind: .timeout, consoleAnswered: true))
        #expect(failure(Self.client(connectTimeout).0)?.userMessage(ps5: true).hasPrefix("The PS5 stopped answering") == true)

        let timedOut = FakeConnection([.failure(.timeout)])
        #expect(failure(Self.client(timedOut).0) == RegistrationError(kind: .timeout, consoleAnswered: true))
    }

    @Test func rejectionCarriesStatusAndReason() {
        let withReason = FakeConnection([.success(Array("HTTP/1.1 403 Forbidden\r\nRP-Application-Reason: 0x80108b09\r\n\r\n".utf8))])
        #expect(failure(Self.client(withReason).0)
            == RegistrationError(kind: .httpNotOK(status: 403), reasonCode: 0x80108b09, consoleAnswered: true))
        let without = FakeConnection([.success(Array("HTTP/1.1 500 X\r\n\r\n".utf8))])
        #expect(failure(Self.client(without).0)
            == RegistrationError(kind: .httpNotOK(status: 500), reasonCode: nil, consoleAnswered: true))
    }

    @Test func unusableReplies() throws {
        let invalid = RegistrationError(kind: .invalidResponse, consoleAnswered: true)
        #expect(failure(Self.client(FakeConnection([.success(Array("garbage garbage".utf8))])).0) == invalid)
        #expect(failure(Self.client(FakeConnection([.success(Array("HTTP/1.1 200 OK\r\n\r\n".utf8))])).0) == invalid)
        #expect(failure(Self.client(FakeConnection([.success(Array("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8))])).0) == invalid)
        #expect(failure(Self.client(FakeConnection([.success(Array("HTTP/1.1 200 OK\r\nContent-Length: 99999999\r\n\r\n".utf8))])).0) == invalid)
        // A header that never ends.
        let endless = FakeConnection([.success(Array("HTTP/1.1 200 OK\r\n".utf8))] + (0..<10).map { _ in .success([UInt8](repeating: 0x41, count: 2000)) })
        var capped = Self.client(endless).0
        capped.maximumResponse = 4096
        #expect(failure(capped) == invalid)

        // A body that decrypts to nothing usable.
        let junk = [UInt8](repeating: 7, count: 137)
        let result = failure(Self.client(FakeConnection([.success(Array(Self.okHead.utf8) + junk)])).0)
        #expect(result == RegistrationError(kind: .invalidData, consoleAnswered: true))
    }

    @Test func bodyCutShort() throws {
        let recorded = try Self.recorded()
        let connection = FakeConnection([.success(Array(Self.okHead.utf8) + recorded[..<30]), .success([])])
        #expect(failure(Self.client(connection).0) == RegistrationError(kind: .disconnected, consoleAnswered: true))
    }

    @Test func emptyRequiredFieldsAreUnusable() throws {
        let request = try RegistrationTests.build(.ps5v1)
        for text in [
            "PS5-RegistKey: \r\nRP-Key: 00112233445566778899aabbccddeeff\r\nPS5-Mac: 0a1b2c3d4e5f\r\n",
            "PS5-RegistKey:\r\nRP-Key: 00112233445566778899aabbccddeeff\r\nPS5-Mac: 0a1b2c3d4e5f\r\n",
            "PS5-RegistKey: 61\r\nRP-Key: \r\nPS5-Mac: 0a1b2c3d4e5f\r\n",
            "PS5-RegistKey: 61\r\nRP-Key: 00112233445566778899aabbccddeeff\r\nPS5-Mac: \r\n",
        ] {
            let encrypted = try request.context.encrypted(Array(text.utf8), counter: 0)
            #expect(throws: FailureKind.invalidData) { try request.parsePairing(encrypted, target: .ps5v1) }
        }
    }

    @Test func onlineIDMustBeASingleLine() {
        for name in ["a\r\nInjected: 1", "a\nb", "a\rb", "a\0b"] {
            #expect(throws: FailureKind.invalidInput) {
                try RegistrationRequest.build(target: .ps4v9, identity: .onlineID(name), pin: 1, seed: Vector.seed)
            }
        }
    }

    @Test func headerNamesAreCaseInsensitive() {
        let head = "HTTP/1.1 403 X\r\nrp-application-reason: 80108b09\r\ncontent-length: 5\r\n\r\n"
        guard case .head(let parsed) = MiniHTTP.parseHead(Array(head.utf8)) else {
            Issue.record("expected a head")
            return
        }
        #expect(parsed.applicationReason == 0x80108b09 && parsed.contentLength == 5)
    }

    @Test func cancelledBeforeTheConnection() {
        let (client, _, _) = Self.client(FakeConnection([]))
        client.token.cancel()
        #expect(failure(client) == RegistrationError(kind: .cancelled, consoleAnswered: false))
    }

    @Test func cancelledDuringTheSearch() {
        let (client, _, _) = Self.client(FakeConnection([]), searchReplies: false)
        var slow = client
        slow.searchTimeout = 5
        let token = slow.token
        let started = monotonicSeconds()
        // A thread of its own: a dispatch queue's worker can be kept waiting for seconds while the whole suite runs.
        Thread {
            sleepSeconds(0.1)
            token.cancel()
        }.start()
        #expect(failure(slow) == RegistrationError(kind: .cancelled, consoleAnswered: false))
        // Well under the 5 s search timeout; the margin is for a loaded machine running the suite in parallel.
        #expect(monotonicSeconds() - started < 2.5)
    }

    @Test func inputErrorsBeforeAnyNetwork() {
        let (client, socket, _) = Self.client(FakeConnection([]))
        let error = try? client.register(address: "a", target: .ps5v1, identity: .accountID([1]), pin: 1)
        #expect(error == nil)
        #expect(socket.sent.with { $0.isEmpty })
    }

    /// The public entry points against a loopback address nobody listens on: refused, no LAN traffic.
    @Test func publicRegisterAgainstClosedLoopbackPort() {
        for ps5 in [true, false] {
            do {
                _ = try Registration.register(address: "127.0.0.1", ps5: ps5, accountId: Vector.accountID, pin: 1)
                Issue.record("registration cannot succeed")
            } catch let error as RegistrationError {
                #expect(error.kind == .connectionRefused || error.kind == .timeout)
                #expect(!error.consoleAnswered)
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
    }
}
