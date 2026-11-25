import Darwin
import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

/// The pieces of internet play on their own: the typed errors, the RUDP-backed layers, the PSN adapter and the data
/// socket handling. (The whole flow is `InternetSessionTests`.)
@Suite(.serialized) struct InternetUnitTests {
    // MARK: Errors and types

    @Test func everyErrorHasAMessageAndAnEndReason() {
        let all: [InternetStartError] = [
            .cancelled, .psn(.unauthorized(step: .createSession, status: 401)), .psn(.consoleUnreachable),
            .psn(.consoleMismatch), .psn(.ps4NotPrimary), .psn(.terminated), .psn(.sessionEnded),
            .psn(.timedOut(step: .waitOffer)), .psn(.pushChannelClosed), .psn(.webSocketFailed(description: "x")),
            .psn(.transport(step: .createSession, description: "x")), .psn(.invalidCustomData),
            .psn(.httpStatus(step: .startCommand, status: 500)), .noPublicAddress, .socket(.permissionDenied),
            .holePunch(hole: .ctrl, .hostUnreachable), .holePunch(hole: .data, .consoleDidNotProbe),
            .holePunch(hole: .ctrl, .invalidOffer), .holePunch(hole: .ctrl, .noPublicAddress),
            .holePunch(hole: .ctrl, .signalingFailed("x")), .holePunch(hole: .ctrl, .cancelled),
            .registration(RegistrationError(kind: .timeout, consoleAnswered: false)),
            .registration(RegistrationError(kind: .httpNotOK(status: 403), reasonCode: 0x80108b02, consoleAnswered: true)),
            .registration(RegistrationError(kind: .invalidResponse, consoleAnswered: true)),
            .session(.consoleBusy, stage: .sessionInit), .session(.noAnswer(.timeout), stage: .ctrl),
            .switchNotAcknowledged, .stream(StreamEndReason(code: .ctrlFailed), detail: "x"),
        ]
        for error in all {
            for console in [StreamConsoleName.ps5, .ps4] {
                let message = error.userMessage(console: console)
                if error == .cancelled || error == .holePunch(hole: .ctrl, .cancelled) {
                    #expect(message.isEmpty)
                } else {
                    #expect(!message.isEmpty, "\(error)")
                    #expect(!message.contains("TOKEN"))
                }
            }
            #expect((error.endReason == nil) == (error == .cancelled))
            _ = error.retryClass
        }
        #expect(InternetStartError.session(.consoleBusy, stage: .sessionInit).retryClass == .busy)
        #expect(InternetStartError.cancelled.retryClass == .stopped)
        #expect(InternetStartError.registration(RegistrationError(kind: .timeout, consoleAnswered: true)).endReason?.code
            == .psnRegistrationFailed)
        #expect(InternetStartError.registration(RegistrationError(kind: .timeout, consoleAnswered: false)).endReason?.code
            == .psnRegistrationUnanswered)
        #expect(InternetStartError.holePunch(hole: .data, .hostUnreachable).userMessage(console: .ps5)
            .contains("video connection"))
        #expect(InternetStartError.psn(.unauthorized(step: .createSession, status: 401)).userMessage(console: .ps5)
            .contains("sign in") || InternetStartError.psn(.unauthorized(step: .createSession, status: 401))
                .userMessage(console: .ps5).contains("Sign in"))
    }

    @Test func theRemoteNeverPrintsItsToken() {
        let remote = PSNRemote(accessToken: "SECRET-TOKEN", consoleDUID: PSNVector.duid)
        #expect(!"\(remote)".contains("SECRET") && !"\(String(reflecting: remote))".contains("SECRET"))
        var dumped = ""
        dump(remote, to: &dumped)
        #expect(!dumped.contains("SECRET"))
        #expect(remote.target == .ps5v1 && PSNRemote(accessToken: "t", consoleDUID: "", platform: .ps4).target == .ps4v10)
        #expect(InternetStage.allCases.count == 10 && InternetOptions().useUPnP)
    }

    // MARK: Registration over RUDP

    static func console(
        timings: RUDPTimings = RUDPConnectionTests.timings, _ configure: (FakeRUDPConsole) -> Void = { _ in }
    ) throws -> (client: RUDPConnection, console: FakeRUDPConsole) {
        let (a, b) = try loopbackPair()
        let console = FakeRUDPConsole(socket: b)
        console.finishAfterAck = true
        configure(console)
        console.start()
        return (RUDPConnection(socket: a, timings: timings, initialSeq: 0x1234, tag: 1), console)
    }

    static func register(over rudp: RUDPConnection, account: [UInt8] = Vector.accountID, target: RPTarget = .ps5v1) throws
        -> PairingResult
    {
        try PSNRegistration.run(
            over: rudp, target: target, accountID: account, data1: Vector.d1, data2: Vector.d2,
            customData1: Vector.cd, host: "192.168.1.20", seed: Vector.seed)
    }

    @Test func registrationFailuresKeepWhatTheConsoleDid() throws {
        func failure(
            _ configure: (FakeRUDPConsole) -> Void = { _ in }, account: [UInt8] = Vector.accountID,
            target: RPTarget = .ps5v1, close: Bool = false
        ) throws -> RegistrationError? {
            let (client, console) = try Self.console(configure)
            defer { client.close(); console.stop() }
            if close { client.close() }
            do {
                _ = try Self.register(over: client, account: account, target: target)
                return nil
            } catch let error as RegistrationError {
                return error
            }
        }
        // Not HTTP at all, a refusal with its reason, a body shorter than its Content-Length, a body that isn't a record.
        #expect(try failure { $0.response = Array("not http".utf8) }
            == RegistrationError(kind: .invalidResponse, consoleAnswered: true))
        #expect(try failure { $0.response = Array("HTTP/1.1 403 Forbidden\r\nRP-Application-Reason: 80108b09\r\n\r\n".utf8) }
            == RegistrationError(kind: .httpNotOK(status: 403), reasonCode: RPReason.registrationFailed, consoleAnswered: true))
        #expect(try failure { $0.response = Array("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nshort".utf8) }
            == RegistrationError(kind: .invalidResponse, consoleAnswered: true))
        #expect(try failure { $0.response = Array("HTTP/1.1 200 OK\r\nContent-Length: 40\r\n\r\n".utf8) + [UInt8](repeating: 7, count: 40) }
            == RegistrationError(kind: .invalidData, consoleAnswered: true))
        // No INIT_ACK: the console never answered. INIT_ACK but no response: it answered, then went quiet.
        #expect(try failure { $0.skip.with { $0 = ["init": 9] } } == RegistrationError(kind: .timeout, consoleAnswered: false))
        #expect(try failure { $0.skip.with { $0 = ["request": 9] } } == RegistrationError(kind: .timeout, consoleAnswered: true))
        // A connection closed under it (a cancel), bad inputs, and a target with no PSN form.
        #expect(try failure(close: true) == RegistrationError(kind: .cancelled, consoleAnswered: false))
        #expect(try failure(account: [1, 2, 3]) == RegistrationError(kind: .invalidInput, consoleAnswered: false))
        #expect(try failure(target: .ps4v9) == RegistrationError(kind: .invalidInput, consoleAnswered: false))
    }

    @Test func aPSN4RegistrationUsesTheOtherTable() throws {
        let request = try RegistrationRequest.buildPSN(
            target: .ps4v10, accountID: Vector.accountID, seed: Vector.seed, data1: Vector.d1, data2: Vector.d2,
            customData1: Vector.cd, host: "")
        #expect(String(decoding: request.header, as: UTF8.self).contains("POST /sie/ps4/rp/sess/rgst HTTP/1.1\r\n HTTP/1.1\r\nHOST: \r\n"))
        // The PIN-form builder is unchanged: its header still says 10.0.2.15.
        let lan = try RegistrationRequest.build(target: .ps5v1, identity: .accountID(Vector.accountID), pin: 1, seed: Vector.seed)
        #expect(String(decoding: lan.header, as: UTF8.self).contains("HOST: 10.0.2.15\r\n"))
    }

    // MARK: Session init over RUDP

    @Test func sessionInitConnectionRunsTheExchangeInSend() throws {
        let (client, console) = try Self.console { $0.response = Array("HTTP/1.1 200 OK\r\nRP-Nonce: AAAA\r\n\r\n".utf8) }
        defer { client.close(); console.stop() }
        let connection = RUDPHTTPConnection(client)
        try connection.connect(timeout: 1)
        try connection.send(Array("GET /x HTTP/1.1\r\n\r\n".utf8), timeout: 1)
        #expect(try connection.receive(maximum: 4096, timeout: 1) == console.response)
        // The "stream" is closed after the one message, and closing doesn't end the RUDP connection.
        #expect(try connection.receive(maximum: 4096, timeout: 1).isEmpty)
        connection.close()
        try connection.send(Array("GET /y HTTP/1.1\r\n\r\n".utf8), timeout: 1)
    }

    @Test func sessionInitConnectionMapsTheFailures() throws {
        let (client, console) = try Self.console { $0.skip.with { $0 = ["init": 9] } }
        defer { client.close(); console.stop() }
        let connection = RUDPHTTPConnection(client)
        #expect(throws: FailureKind.timeout) { try connection.send([1], timeout: 1) }
        #expect(throws: FailureKind.invalidInput) { try connection.send([UInt8](repeating: 1, count: 5000), timeout: 1) }
        client.close()
        #expect(throws: FailureKind.cancelled) { try connection.send([1], timeout: 1) }
    }

    // MARK: Ctrl over RUDP

    final class Items: @unchecked Sendable {
        let list = Locked<[(item: [UInt8]?, failure: FailureKind?)]>([])
        func collect(_ link: RUDPCtrlLink) {
            link.receiveMessage { [self] item, failure in
                list.with { $0.append((item, failure)) }
                if item != nil { collect(link) }
            }
        }
    }

    @Test func theCtrlLinkDeliversTheHeaderThenEachFrameThenTheEnd() async throws {
        let head = Array("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8)
        let (client, console) = try Self.console { $0.response = head; $0.finishAfterAck = false }
        defer { client.close(); console.stop() }
        let link = RUDPCtrlLink(client)
        let state = Locked<[CtrlLinkState]>([])
        link.start(queue: .global()) { s in state.with { $0.append(s) } }
        #expect(await waitUntil { state.with { $0 == [.ready] } })

        let sent = Locked<[FailureKind?]>([])
        let items = Items()
        items.collect(link)
        link.send(Array("GET /ctrl HTTP/1.1\r\n\r\n".utf8)) { f in sent.with { $0.append(f) } }
        #expect(await waitUntil { sent.with { $0.count == 1 } })
        #expect(sent.with { $0 } == [nil])
        #expect(await waitUntil { items.list.with { $0.count == 1 } })
        #expect(items.list.with { $0[0].item } == CtrlStreamSplitter.encode(.head(head)))

        // A frame from the console is the next item; one from the client is a DATA message.
        let frame = hex("00000000 00fe 0000")
        console.push(FakeRUDPConsole.message(seq: console.nextSeq(), frame: frame))
        #expect(await waitUntil { items.list.with { $0.count == 2 } })
        #expect(items.list.with { $0[1].item } == CtrlStreamSplitter.encode(.frame(type: 0xfe, payload: [])))
        link.send(hex("00000000 01fe 0000")) { f in sent.with { $0.append(f) } }
        #expect(await waitUntil { console.frames.with { $0.contains(hex("00000000 01fe 0000")) } })

        // The console's FINISH is the end: no item, no failure.
        console.push(RUDPFraming.encode(type: RUDPType.finish, data: []))
        #expect(await waitUntil { items.list.with { $0.count == 3 } })
        #expect(items.list.with { $0[2].item == nil && $0[2].failure == nil })
        // Asking again after the end answers at once; a send after it fails.
        let again = Locked<[(item: [UInt8]?, failure: FailureKind?)]>([])
        link.receiveMessage { item, failure in again.with { $0.append((item, failure)) } }
        #expect(again.with { $0.count } == 1)
        link.send([1]) { f in sent.with { $0.append(f) } }
        #expect(sent.with { $0.last } == FailureKind.disconnected)
    }

    @Test func theCtrlLinkReportsAFailedStartAndStopsOnCancel() async throws {
        let (client, console) = try Self.console { $0.skip.with { $0 = ["init": 9] } }
        defer { client.close(); console.stop() }
        let link = RUDPCtrlLink(client)
        let sent = Locked<[FailureKind?]>([])
        link.send([1]) { f in sent.with { $0.append(f) } }
        #expect(await waitUntil { sent.with { !$0.isEmpty } })
        #expect(sent.with { $0 } == [FailureKind.timeout])

        // After a cancel nothing is delivered and nobody is waiting.
        let (client2, console2) = try Self.console { $0.response = Array("HTTP/1.1 200 OK\r\n\r\n".utf8) }
        defer { client2.close(); console2.stop() }
        let link2 = RUDPCtrlLink(client2)
        let delivered = Locked(0)
        link2.receiveMessage { _, _ in delivered.with { $0 += 1 } }
        link2.cancel()
        link2.receiveMessage { _, _ in delivered.with { $0 += 1 } }
        link2.send(Array("GET / HTTP/1.1\r\n\r\n".utf8)) { _ in }
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(delivered.with { $0 } == 0)
    }

    @Test func rudpErrorsBecomeFailureKinds() {
        #expect(RUDPCtrlLink.failure(RUDPError.timeout(.response)) == .timeout)
        #expect(RUDPCtrlLink.failure(RUDPError.closed) == .disconnected)
        #expect(RUDPCtrlLink.failure(RUDPError.receiveFailed) == .disconnected)
        #expect(RUDPCtrlLink.failure(RUDPError.messageTooLarge) == .invalidInput)
        #expect(RUDPCtrlLink.failure(RUDPError.wrongState) == .invalidInput)
        #expect(RUDPCtrlLink.failure(RUDPError.invalidArgument) == .invalidInput)
        #expect(RUDPCtrlLink.failure(CancellationError()) == .other(errno: 0))
    }

    // MARK: The punched socket under Takion

    @Test func theDataSocketIsDrainedAndAdoptedByATransport() throws {
        let (a, b) = try loopbackPair()
        defer { b.close() }
        for n in 0..<3 { try b.send([UInt8(n)], to: "", port: 0) }
        sleepSeconds(0.05)
        let descriptor = try #require(a.releaseDescriptor())
        // The late probes are thrown away (and an empty socket costs one short wait).
        #expect(PunchedSocket.drain(descriptor: descriptor, step: 0.05, limit: 1) == 3)
        #expect(PunchedSocket.drain(descriptor: descriptor, step: 0.02, limit: 1) == 0)
        // A released socket is closed for its old owner, and can't be released twice.
        #expect(a.releaseDescriptor() == nil)
        #expect(throws: (any Error).self) { try a.send([1], to: "", port: 0) }

        let handler = MemoryHandler()
        let transport = BSDDatagramTransport(adopting: descriptor, dontFragment: true)
        try transport.start(handler: handler)
        #expect(transport.localPort != 0)
        try b.send([9, 9], to: "", port: 0)
        #expect(eventually { handler.datagrams == [[9, 9]] })
        try transport.send([7])
        #expect(try b.receive(timeout: 1)?.bytes == [7])
        transport.stop()
        // The transport owned the descriptor: stopping closed it.
        #expect(fcntl(descriptor, F_GETFD) == -1)
    }

    @Test func aDuplicatedDescriptorKeepsTheSocketOpenForTheNextTransport() throws {
        let (a, b) = try loopbackPair()
        defer { b.close() }
        let descriptor = try #require(a.releaseDescriptor())
        defer { close(descriptor) }
        let copy = dup(descriptor)
        let probe = BSDDatagramTransport(adopting: copy, dontFragment: true)
        let handler = MemoryHandler()
        try probe.start(handler: handler)
        probe.stop()
        #expect(fcntl(copy, F_GETFD) == -1 && fcntl(descriptor, F_GETFD) != -1)
        // What arrives between the two transports waits in the socket for the second.
        try b.send([5], to: "", port: 0)
        let stream = BSDDatagramTransport(adopting: dup(descriptor), dontFragment: false)
        let later = MemoryHandler()
        try stream.start(handler: later)
        #expect(eventually { later.datagrams == [[5]] })
        stream.stop()
    }

    @Test func aSocketWithNoDescriptorOfItsOwnReleasesNothing() throws {
        let lossy = LossyPunchSocket(try loopbackSocket())
        #expect(lossy.releaseDescriptor() == nil)
        lossy.close()
    }
}

/// Counts datagrams without allocating (the handler of the allocation check below).
private final class CountingHandler: TransportHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var received: Int { lock.lock(); defer { lock.unlock() }; return count }
    func transportDidReceive(_ datagram: UnsafeMutableRawBufferPointer, at timestamp: UInt64, kernelTimestamp: Bool) {
        lock.lock(); count += 1; lock.unlock()
    }
    func transportNextWake() -> UInt64? { nil }
    func transportWake(now: UInt64) {}
    func transportFailed(errno: Int32) {}
}

// In TakionAllocationTests' suite (serialized) because the malloc hook it uses is process-wide.
extension TakionAllocationTests {
    /// The receive path on a punched, adopted socket is the LAN transport's own loop: nothing is allocated per packet
    /// (asserted in an optimised build: `scripts/test.sh -c release -Xswiftc -enable-testing --filter
    /// TakionAllocationTests`; a debug run checks the behaviour only).
    @Test func theAdoptedDataSocketReceivePathDoesNotAllocate() throws {
        let (a, b) = try loopbackPair()
        let descriptor = try #require(a.releaseDescriptor())
        let sender = try #require(b.releaseDescriptor())
        defer { close(sender) }
        let transport = BSDDatagramTransport(adopting: descriptor, dontFragment: true)
        let handler = CountingHandler()
        try transport.start(handler: handler)
        defer { transport.stop() }
        #if DEBUG
        let packets = 200
        #else
        let packets = 2000
        #endif
        let datagram = [UInt8](repeating: 0x55, count: 200)
        func burst(_ count: Int) {
            for _ in 0..<count { datagram.withUnsafeBytes { _ = Darwin.send(sender, $0.baseAddress, $0.count, 0) } }
        }
        // Warm up: the first reads settle (the ring and the thread were made by `start`).
        burst(50)
        while handler.received < 50 { usleep(500) }
        // Raw `send`s from here: the test's own sends allocate nothing, so what is counted is the receive thread's.
        let measured = countAllocations {
            burst(packets)
            let deadline = monotonicSeconds() + 5
            while handler.received < 50 + packets && monotonicSeconds() < deadline { usleep(200) }
        }
        let count = try #require(measured, "malloc_logger is not available")
        #expect(handler.received == 50 + packets)
        #if DEBUG
        // A debug build allocates inside unspecialised standard-library code, so no bound means anything here.
        _ = count
        #else
        #expect(count == 0, "\(count) allocations over \(packets) packets")
        #endif
    }
}

extension InternetUnitTests {
    // MARK: Giving back (the link on its own)

    static func link() -> InternetLink {
        InternetLink(remote: PSNRemote(accessToken: "t", consoleDUID: PSNVector.duid), options: InternetOptions(),
                     environment: InternetEnvironment())
    }

    /// After `shutdown` the punched descriptor is closed and forgotten: nothing may dup or adopt its number, which the
    /// system could have given to another socket meanwhile.
    @Test func aShutDownLinkHandsOutNoDescriptor() throws {
        let (a, b) = try loopbackPair()
        defer { b.close() }
        let descriptor = try #require(a.releaseDescriptor())
        let link = Self.link()
        #expect(link.holdDescriptor(descriptor))
        link.shutdown()
        #expect(fcntl(descriptor, F_GETFD) == -1, "shutdown closed it")
        // A new socket takes the number again.
        let reused = try loopbackSocket()
        let recycled = try #require(reused.releaseDescriptor())
        defer { close(recycled) }
        #expect(throws: InternetStartError.cancelled) { _ = try link.probeTransport() }
        #expect(throws: InternetStartError.cancelled) { _ = try link.streamTransport(dontFragment: false) }
        // The recycled descriptor was not touched (no second close by the link, no adoption).
        #expect(fcntl(recycled, F_GETFD) != -1)
        // And a descriptor offered after shutdown is refused, for the caller to close.
        #expect(!link.holdDescriptor(recycled))
    }
}

extension InternetUnitTests {
    /// A pairing's keys never reach a log through print, string interpolation or dump.
    @Test func aPairingRecordNeverPrintsItsKeys() {
        let record = PairingResult(
            registKey: hex("30313233616263640000000000000000"), rpKey: hex("a0a1a2a3a4a5a6a7a8a9aaabacadaeaf"),
            nickname: "PS5-TEST", mac: hex("0a1b2c3d4e5f"), target: .ps5v1, keyType: 2, apSSID: "ssid", apBSSID: nil,
            apKey: "wifi-password", apName: nil)
        var dumped = ""
        dump(record, to: &dumped)
        for text in ["\(record)", String(reflecting: record), dumped] {
            #expect(!text.contains("a0a1a2") && !text.contains("30313233") && !text.contains("wifi-password"))
            #expect(!text.contains("ssid"))
        }
        #expect("\(record)".contains("PS5-TEST"))
    }
}

extension InternetUnitTests {
    /// The internet ctrl environment is the injected one with the RUDP seams set, not a fresh one.
    @Test func theInternetCtrlEnvironmentKeepsWhatWasInjected() {
        var base = ControlEnvironment()
        base.connectTimeout = 7
        base.pauseBeforeCtrl = 0.5
        base.randomBytes = { _ in [1] }
        let control = Self.link().controlEnvironment(base: base)
        #expect(control.connectTimeout == 7 && control.pauseBeforeCtrl == 0.5 && control.randomBytes(16) == [1])
        #expect(control.internet)
    }
}
