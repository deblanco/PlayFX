import Foundation
import Testing

@testable import PlayFXProtocol

extension ControlEnvironment {
    /// Real sockets, but only to loopback (a test that reaches anything else fails).
    static func loopback(initPort: UInt16, ctrlPort: UInt16? = nil) -> ControlEnvironment {
        var environment = ControlEnvironment()
        environment.initPort = initPort
        environment.ctrlPort = ctrlPort ?? initPort
        environment.connectTimeout = 2
        environment.initHeaderTimeout = 1
        environment.ctrlHeaderTimeout = 1
        environment.makeInitConnection = { host, port in
            guard isLoopback(host) else {
                Issue.record("test tried to connect to non-loopback address \(host)")
                throw FailureKind.networkUnreachable
            }
            return try NWBlockingTCPConnection(host: host, port: port)
        }
        environment.makeCtrlConnection = { host, port in
            guard isLoopback(host) else {
                Issue.record("test tried to connect to non-loopback address \(host)")
                throw FailureKind.networkUnreachable
            }
            return try CtrlFramer.makeConnection(host: host, port: port)
        }
        return environment
    }
}

/// Collects the events of a session, in order.
final class EventLog: @unchecked Sendable {
    let events = Locked<[ControlEvent]>([])
    let session = Locked<ControlSession?>(nil)
    /// Runs on the session's queue for each event, after it is recorded.
    nonisolated(unsafe) var onEvent: (@Sendable (ControlEvent, ControlSession) -> Void)?

    var handler: @Sendable (ControlEvent, ControlSession) -> Void {
        { [self] event, session in
            events.with { $0.append(event) }
            onEvent?(event, session)
        }
    }

    var all: [ControlEvent] { events.with { $0 } }

    /// Polls until `condition` holds for the events, or `timeout` passes.
    @discardableResult
    func wait(timeout: Double = 5, _ condition: ([ControlEvent]) -> Bool) async -> Bool {
        let deadline = monotonicSeconds() + timeout
        while monotonicSeconds() < deadline {
            if condition(all) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition(all)
    }

    func waitForEnd(timeout: Double = 5) async -> ControlEndReason? {
        await wait(timeout: timeout) { $0.contains { if case .ended = $0 { true } else { false } } }
        for case .ended(let reason) in all { return reason }
        return nil
    }
}

func waitUntil(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = monotonicSeconds() + timeout
    while monotonicSeconds() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

let sessionIDPlain = [UInt8(0x4a)] + Array(SessionVector.sessionIDText.utf8)

@Suite struct SessionLoopbackTests {
    static func start(
        _ console: FakeSessionConsole, target: RPTarget = .ps5v1, options: ControlOptions = ControlOptions(),
        ctrlPort: UInt16? = nil, log: EventLog = EventLog(), retain: Bool = true,
        tweak: (inout ControlEnvironment) -> Void = { _ in }
    ) async throws -> ControlSession {
        var environment = ControlEnvironment.loopback(initPort: console.port, ctrlPort: ctrlPort)
        tweak(&environment)
        let session = try await ControlSession.start(
            environment: environment, address: "127.0.0.1", target: target, registKey: SessionVector.registKey,
            rpKey: SessionVector.rpKey, options: options, events: log.handler)
        // A dropped session closes silently, so tests that discard it keep it alive through the log.
        if retain { log.session.with { $0 = session } }
        return session
    }

    /// The error `start` throws.
    static func failure(
        _ console: FakeSessionConsole, target: RPTarget = .ps5v1, ctrlPort: UInt16? = nil,
        tweak: (inout ControlEnvironment) -> Void = { _ in }
    ) async -> SessionError? {
        do {
            let session = try await start(console, target: target, ctrlPort: ctrlPort, tweak: tweak)
            session.stop()
            return nil
        } catch let error as SessionError {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    /// A console that accepts ctrl, sends the session ID and then runs `after`.
    static func console(
        serverType: UInt8 = 2, initReplies: @escaping @Sendable (Int) -> FakeSessionConsole.InitReply = { _ in .nonce },
        after: @escaping @Sendable (CtrlPeer) -> Void
    ) -> FakeSessionConsole {
        FakeSessionConsole(ctrl: { peer, _ in
            peer.sendHead(serverType: serverType)
            peer.send(0x33, sessionIDPlain)
            after(peer)
        }, initReplies: initReplies)
    }

    // MARK: The whole conversation

    @Test func fullScriptOnPS5() async throws {
        let opened = { () -> [UInt8] in
            var payload = [UInt8](repeating: 0, count: 28)
            payload.appendBE32(3)
            return payload + Array("abc".utf8)
        }()
        let changed = { () -> [UInt8] in
            var payload: [UInt8] = []
            payload.appendBE32(2)
            payload.appendBE32(0)
            payload.appendBE32(2)
            payload += [UInt8](repeating: 0, count: 24)
            payload.appendBE32(2)
            return payload + Array("ab".utf8)
        }()
        let console = FakeSessionConsole { peer, _ in
            // The padded header and the first frame in one write: the bytes after the header are kept.
            peer.sendHead(then: peer.frame(0x04))
            let wrong = peer.receive()
            peer.send(0x05, [1])
            peer.send(0x04)
            let right = peer.receive()
            peer.send(0x05, [0])
            peer.send(0x33, sessionIDPlain)
            peer.send(0xfe)
            peer.send(0xfe)
            peer.send(0x01, [1])
            peer.send(0x16, [0, 0, 1])
            peer.send(0x16, [1, 0xff])
            peer.send(0x7777, [9, 8, 7])
            peer.send(0x21, opened)
            peer.send(0x24, changed)
            peer.send(0x22, [0])
            peer.send(0x01, [0])
            peer.send(0x34)
            _ = (wrong, right)
            peer.pump()
        }
        defer { console.stop() }
        let log = EventLog()
        // Both PIN requests are answered from the handler (the first arrives before `start` returns).
        log.onEvent = { [log] event, session in
            guard case .loginPINRequested = event else { return }
            let pins = log.events.with { $0.filter { $0 == .loginPINRequested }.count }
            try? session.sendLoginPIN(pins == 1 ? "0000" : "1234")
        }
        let options = { () -> ControlOptions in
            var o = ControlOptions()
            o.streamingType = .h264
            return o
        }()
        let session = try await Self.start(console, options: options, log: log)
        log.session.with { $0 = session }
        await log.wait { $0.contains(.notice(type: 0x34, payload: [])) }

        let expected: [ControlEvent] = [
            .sessionInitialized(version: .ps5v1, attempts: 1),
            .connected(model: .ps5, pictureProhibited: false),
            .loginPINRequested,
            .loginPINResult(accepted: false),
            .loginPINRequested,
            .loginPINResult(accepted: true),
            .sessionID(SessionID(value: SessionVector.sessionIDText)),
            .heartbeat(count: 1),
            .heartbeat(count: 2),
            .displayNotice(.a(set: true)),
            .displayNotice(.b(payload: [0, 0, 1], clearsState: false)),
            .displayNotice(.b(payload: [1, 0xff], clearsState: true)),
            .notice(type: 0x7777, payload: [9, 8, 7]),
            .keyboardOpened(text: "abc"),
            .keyboardTextChanged(sequence: 2, text: "ab"),
            .keyboardClosed,
            .displayNotice(.a(set: false)),
            .notice(type: 0x34, payload: []),
        ]
        #expect(log.all == expected)

        // Commands, in the order they are issued.
        try session.setMicrophone(false)
        try session.keyboardSetText("héllo")
        try session.keyboardSetText("x")
        try session.keyboardDone()
        try session.keyboardCancel()
        try session.goHome()
        try session.connectMicrophone()
        try session.goToBed()
        let peer = try #require(console.peers.with { $0.first })
        // 2 PIN replies, 5 features, 2 heartbeat replies, 8 commands.
        #expect(await waitUntil { peer.received.with { $0.count } >= 17 })
        let got = peer.received.with { $0.map { ($0.type, $0.plain) } }
        let want: [(UInt16, [UInt8])] = [
            (0x8004, Array("0000".utf8)), (0x8004, Array("1234".utf8)),
            (0x13, hex("004000")), (0x11, hex("a0ab51bdd17e0000ffffffffff000000")),
            (0x36, hex("00010159")), (0x36, hex("00010159")), (0x910, hex("00000000")),
            (0x1fe, []), (0x1fe, []),
            (0x36, hex("00010059")),
            (0x23, CtrlOutgoing.keyboardSetText(sequence: 1, text: "héllo").payload),
            (0x23, CtrlOutgoing.keyboardSetText(sequence: 2, text: "x").payload),
            (0x25, hex("00000000")), (0x25, hex("00000001")),
            (0x14, hex("00ff") + [UInt8](repeating: 0, count: 14)),
            (0x30, hex("0000")),
            (0x50, []),
        ]
        #expect(got.count == want.count)
        for (a, b) in zip(got, want) { #expect(a.0 == b.0 && a.1 == b.1) }
        // Empty payloads are not encrypted and take no counter: every frame above decrypted at the spec's
        // running counter (the peer decrypts with its own count), and the wire of an empty one is empty.
        #expect(peer.received.with { $0.filter { [0x1fe, 0x50].contains($0.type) }.allSatisfy { $0.wire.isEmpty } })

        // What the console saw in the request.
        #expect(peer.header("RP-Version") == "1.0" && peer.header("RP-ConPath") == "1")
        #expect(peer.decryptedHeader("RP-Auth", counter: 0) == SessionVector.registKey)
        let did = try #require(peer.decryptedHeader("RP-Did", counter: 1))
        #expect(did.count == 32 && did.prefix(10) == hex("00180000000700400080")[...] && did.suffix(6) == [0, 0, 0, 0, 0, 0])
        #expect(peer.decryptedHeader("RP-OSType", counter: 2) == Array("Win10.0.0".utf8) + [0])
        #expect(peer.decryptedHeader("RP-StartBitrate", counter: 3) == [0, 0, 0, 0])
        #expect(peer.decryptedHeader("RP-StreamingType", counter: 4) == [1, 0, 0, 0])
        #expect(peer.header("Host") == "127.0.0.1:\(console.port)")

        // The hand-off.
        let handoff = try #require(session.handoff)
        #expect(handoff.consoleAddress == "127.0.0.1" && handoff.negotiatedVersion == .ps5v1)
        #expect(handoff.crypt.key == hex("598fa9a031d01820db25cab6e90bb19b"))
        #expect(handoff.crypt.seed == hex("ac7d50f394ea6588f0488f76e4170c8a"))
        #expect(handoff.sessionID.value == SessionVector.sessionIDText && handoff.streamHandshakeKey.count == 16)
        #expect(handoff.consoleModel == .ps5 && handoff.streamingType == .h264 && handoff.dualSenseEnabled)
        #expect(session.consoleModel == .ps5 && session.negotiatedVersion == .ps5v1 && session.endReason == nil)

        // The console puts itself to rest and closes.
        peer.finish()
        #expect(await log.waitForEnd() == .consoleClosed)
        #expect(session.endReason == .consoleClosed)
    }

    @Test func sessionIDKnownAnswerInTheSameWriteAsTheHeader() async throws {
        let wire = hex("""
            0000004b 0033 0000 485b87a4391fd134e0fcb43f391e556b8e8601bd95d432c262d42b6e8a7562d1
            4952f1cbf256c87ae11147f7f4fd52fcc4d6140595a3caaaf2e98c4f60031cf3 e12ea890026b4bf19e21f4
            """)
        let console = FakeSessionConsole { peer, _ in
            peer.sendHead(then: wire)
            peer.pump()
        }
        defer { console.stop() }
        let log = EventLog()
        let session = try await Self.start(console, log: log)
        #expect(await log.wait { $0.contains { if case .sessionID = $0 { true } else { false } } })
        #expect(session.handoff?.sessionID.value == SessionVector.sessionIDText)
        session.stop()
        #expect(await log.waitForEnd() == .stoppedByClient)
    }

    @Test func firstPINReplyOnTheWire() async throws {
        let console = FakeSessionConsole { peer, _ in
            peer.sendHead(then: peer.frame(0x04))
            _ = peer.receive()
            peer.pump()
        }
        defer { console.stop() }
        let log = EventLog()
        let session = try await Self.start(console, log: log)
        #expect(await log.wait { $0.contains(.loginPINRequested) })
        try session.sendLoginPIN("1234")
        let peer = try #require(console.peers.with { $0.first })
        #expect(await waitUntil { peer.received.with { !$0.isEmpty } })
        #expect(peer.received.with { $0[0].wire } == hex("9bf82809"))
        session.stop()
        _ = await log.waitForEnd()
    }

    @Test func invalidPINIsRejectedWithoutSending() async throws {
        let console = FakeSessionConsole { peer, _ in peer.sendHead(); peer.pump() }
        defer { console.stop() }
        let session = try await Self.start(console)
        #expect(throws: ControlCommandError.invalidPIN) { try session.sendLoginPIN("12a") }
        #expect(throws: ControlCommandError.invalidPIN) { try session.sendLoginPIN("") }
        // No request is pending, so nothing is sent.
        #expect(throws: ControlCommandError.noPINRequested) { try session.sendLoginPIN("1234") }
        session.stop()
    }

    @Test(arguments: [(RPTarget.ps4v10, "10.0", UInt8(0)), (.ps4v9, "9.0", 1), (.ps4v8, "8.0", 0)])
    func ps4Variants(_ row: (RPTarget, String, UInt8)) async throws {
        let (target, version, type) = row
        let console = Self.console(serverType: type) { $0.pump() }
        defer { console.stop() }
        let log = EventLog()
        let session = try await Self.start(console, target: target, log: log)
        #expect(await log.wait { $0.contains { if case .sessionID = $0 { true } else { false } } })
        let peer = try #require(console.peers.with { $0.first })
        // No DualSense messages for a PS4; microphone twice and display devices.
        #expect(await waitUntil { peer.received.with { $0.count } >= 3 })
        #expect(peer.received.with { $0.map(\.type) } == [0x36, 0x36, 0x910])
        #expect(peer.header("RP-Version") == version)
        #expect(peer.header("RP-PadProcNo") == nil && peer.header("RP-StreamingType") == nil)
        #expect((peer.header("RP-StartBitrate") != nil) == (target == .ps4v10))
        #expect(peer.decryptedHeader("RP-Auth", counter: 0) == SessionVector.registKey)
        #expect(session.consoleModel == (type == 0 ? .ps4 : .ps4Pro))
        #expect(session.handoff?.streamingType == nil && session.handoff?.dualSenseEnabled == false)
        let initText = try #require(console.initRequests.with { $0.first })
        #expect(initText.contains("Rp-Version: \(version)\r\n") && initText.contains("RP-Registkey: 3031323361626364\r\n"))
        session.stop()
        _ = await log.waitForEnd()
    }

    @Test func dualSenseAndKeyboardOptions() async throws {
        let console = Self.console { $0.pump() }
        defer { console.stop() }
        var options = ControlOptions()
        options.dualSense = false
        options.enableKeyboard = true
        options.streamingType = .h265HDR
        let log = EventLog()
        let session = try await Self.start(console, options: options, log: log)
        let peer = try #require(console.peers.with { $0.first })
        #expect(await waitUntil { peer.received.with { $0.count } >= 5 })
        #expect(peer.received.with { $0.map(\.type) } == [0x0d, 0x20, 0x36, 0x36, 0x910])
        #expect(peer.decryptedHeader("RP-StreamingType", counter: 4) == [3, 0, 0, 0])
        #expect(session.handoff?.dualSenseEnabled == false)
        try session.enableKeyboard()
        #expect(await waitUntil { peer.received.with { $0.count } >= 7 })
        #expect(peer.received.with { $0.suffix(2).map(\.type) } == [0x0d, 0x20])
        session.stop()
        _ = await log.waitForEnd()
    }

    // MARK: Session init

    @Test func versionNegotiationFollowsTheConsole() async throws {
        let console = Self.console(initReplies: { $0 == 0 ? .refuse(reason: "80108b11", version: "9.0") : .nonce }) { $0.pump() }
        defer { console.stop() }
        let log = EventLog()
        let session = try await Self.start(console, target: .ps4v10, log: log)
        #expect(session.negotiatedVersion == .ps4v9)
        let texts = console.initRequests.with { $0 }
        #expect(texts.count == 2 && texts[0].contains("Rp-Version: 10.0") && texts[1].contains("Rp-Version: 9.0"))
        #expect(texts[1].hasPrefix("GET /sce/rp/session HTTP/1.1\r\n"))
        #expect(log.all.first == .sessionInitialized(version: .ps4v9, attempts: 2))
        let peer = try #require(console.peers.with { $0.first })
        #expect(peer.requestText.hasPrefix("GET /sce/rp/session/ctrl HTTP/1.1\r\n") && peer.header("RP-Version") == "9.0")
        session.stop()
        _ = await log.waitForEnd()
    }

    @Test func versionNegotiationGivesUpAfterThreeRequests() async {
        let versions = ["9.0", "10.0", "9.0", "10.0"]
        let console = FakeSessionConsole(initReplies: { .refuse(reason: "80108b11", version: versions[$0]) })
        defer { console.stop() }
        #expect(await Self.failure(console, target: .ps4v10) == .versionMismatch)
        #expect(console.initRequests.with { $0.count } == 3)
    }

    @Test(arguments: [
        ("80108b10", SessionError.consoleBusy), ("80108b15", .remotePlayCrashed), ("80108b11", .versionMismatch),
        ("80108bff", .refused(reason: 0x80108bff)), ("80108b09", .refused(reason: 0x80108b09)),
        ("deadbeef", .refused(reason: 0xdeadbeef)),
    ])
    func refusalReasons(_ row: (String, SessionError)) async {
        let console = FakeSessionConsole(initReplies: { _ in .refuse(reason: row.0) })
        defer { console.stop() }
        #expect(await Self.failure(console) == row.1)
        #expect(console.initRequests.with { $0.count } == 1)
    }

    @Test func refusalWithoutReason() async {
        let console = FakeSessionConsole(initReplies: { _ in .refuse(status: "500 Internal Server Error", reason: nil) })
        defer { console.stop() }
        #expect(await Self.failure(console) == .refused(reason: nil))
    }

    @Test func initFailures() async {
        let silent = FakeSessionConsole(initReplies: { _ in .hang })
        defer { silent.stop() }
        let started = monotonicSeconds()
        #expect(await Self.failure(silent, tweak: { $0.initHeaderTimeout = 0.2 }) == .noAnswer(.timeout))
        // The 0.2 s timeout was used (the 5 s default would take 15 s); margin for a loaded parallel run.
        #expect(monotonicSeconds() - started < 3)

        let refused = FakeSessionConsole()
        refused.stop()
        #expect(await Self.failure(refused) == .noAnswer(.connectionRefused))

        let cases: [(FakeSessionConsole.InitReply, SessionError)] = [
            (.raw(Array("garbage\r\n\r\n".utf8)), .invalidResponse),
            (.raw(Array("HTTP/1.1 200 OK\r\n\r\n".utf8)), .invalidResponse),
            (.raw(Array("HTTP/1.1 200 OK\r\nRP-Nonce: AAEC\r\n\r\n".utf8)), .invalidResponse),
            (.raw(Array("HTTP/1.1 200 OK\r\nRP-Nonce: ".utf8)), .network(.disconnected)),
            (.raw(Array(repeating: 0x41, count: 70_000)), .invalidResponse),
            (.raw(Array("HTTP/1.1 200 ".utf8) + Array(repeating: 0x41, count: 70_000)), .invalidResponse),
            (.close, .network(.disconnected)),
        ]
        for (reply, expected) in cases {
            let console = FakeSessionConsole(initReplies: { _ in reply })
            defer { console.stop() }
            #expect(await Self.failure(console) == expected)
        }
    }

    @Test func wrongKeySizesAreRejectedBeforeAnyConnection() async {
        let console = FakeSessionConsole()
        defer { console.stop() }
        await #expect(throws: SessionError.invalidInput) {
            try await ControlSession.start(
                environment: .loopback(initPort: console.port), address: "127.0.0.1", target: .ps5v1,
                registKey: [1, 2, 3], rpKey: SessionVector.rpKey, options: ControlOptions(), events: { _, _ in })
        }
        #expect(console.initRequests.with { $0.isEmpty })
    }

    // MARK: Ctrl start

    @Test func ctrlRefusals() async {
        let rejected = FakeSessionConsole { peer, _ in peer.sendHead(status: "403 Forbidden", serverType: nil); peer.waitForClose() }
        defer { rejected.stop() }
        #expect(await Self.failure(rejected) == .ctrlRejected(status: 403))

        let busy = FakeSessionConsole { peer, _ in
            peer.sendHead(status: "403 Forbidden", serverType: nil, extra: ["RP-Application-Reason: 80108b10"])
            peer.waitForClose()
        }
        defer { busy.stop() }
        #expect(await Self.failure(busy) == .consoleBusy)

        let garbage = FakeSessionConsole { peer, _ in peer.write(Array("NOT HTTP\r\n\r\n".utf8)); peer.waitForClose() }
        defer { garbage.stop() }
        #expect(await Self.failure(garbage) == .invalidResponse)

        let badType = FakeSessionConsole { peer, _ in
            peer.write(Array("HTTP/1.1 200 OK\r\nRP-Server-Type: !!!\r\n\r\n".utf8))
            peer.waitForClose()
        }
        defer { badType.stop() }
        #expect(await Self.failure(badType) == .invalidResponse)

        let endless = FakeSessionConsole { peer, _ in
            peer.write(Array("HTTP/1.1 200 OK\r\n".utf8) + Array(repeating: 0x41, count: 20_000))
            peer.waitForClose()
        }
        defer { endless.stop() }
        #expect(await Self.failure(endless) == .invalidResponse)
    }

    @Test func ctrlConnectRefused() async {
        let console = FakeSessionConsole()
        defer { console.stop() }
        #expect(await Self.failure(console, ctrlPort: FakeConsole.closedTCPPort()) == .noAnswer(.connectionRefused))
    }

    @Test func serverTypeEdgeCases() async throws {
        // A server type that isn't 16 bytes is unknown, and then counter 0 goes to the first frame.
        let odd = FakeSessionConsole { peer, _ in
            peer.sendHead(serverType: nil, extra: ["RP-Server-Type: AAECAwQFBgc="])
            peer.send(0x33, sessionIDPlain)
            peer.pump()
        }
        defer { odd.stop() }
        let log = EventLog()
        let session = try await Self.start(odd, log: log)
        #expect(await log.wait { $0.contains { if case .sessionID = $0 { true } else { false } } })
        #expect(log.all.contains(.connected(model: nil, pictureProhibited: false)))
        session.stop()

        // Prohibited picture, and a model byte nobody knows.
        let prohibited = FakeSessionConsole { peer, _ in
            peer.sendHead(serverType: 9, extra: ["RP-Prohibit: 1"])
            peer.pump()
        }
        defer { prohibited.stop() }
        let log2 = EventLog()
        let second = try await Self.start(prohibited, log: log2)
        #expect(log2.all.contains(.connected(model: nil, pictureProhibited: true)))
        #expect(second.consoleModel == nil)
        second.stop()
        _ = await log2.waitForEnd()
    }

    @Test func resetBeforeTheHeaderIsRetriedWithTheSameRequest() async throws {
        let console = FakeSessionConsole { peer, index in
            if index < 2 { return }  // closes without answering
            peer.sendHead()
            peer.pump()
        }
        defer { console.stop() }
        let log = EventLog()
        let session = try await Self.start(console, log: log)
        #expect(console.ctrlConnections.with { $0 } == 3)
        let texts = console.peers.with { $0.map(\.requestText) }
        #expect(texts.count == 3 && Set(texts).count == 1)
        session.stop()
        _ = await log.waitForEnd()
    }

    @Test func tooManyResetsFail() async {
        let console = FakeSessionConsole { _, _ in }
        defer { console.stop() }
        #expect(await Self.failure(console) == .ctrlResetRepeatedly)
        #expect(console.ctrlConnections.with { $0 } == 4)
    }

    @Test func silentHeaderIsRetriedOnce() async throws {
        let console = FakeSessionConsole { peer, index in
            if index == 0 { peer.waitForClose(limit: 3); return }
            peer.sendHead()
            peer.pump()
        }
        defer { console.stop() }
        let log = EventLog()
        let session = try await Self.start(console, log: log) { $0.ctrlHeaderTimeout = 0.2 }
        #expect(console.ctrlConnections.with { $0 } == 2)
        let texts = console.peers.with { $0.map(\.requestText) }
        #expect(Set(texts).count == 1)
        session.stop()
        _ = await log.waitForEnd()

        let mute = FakeSessionConsole { peer, _ in peer.waitForClose(limit: 3) }
        defer { mute.stop() }
        #expect(await Self.failure(mute, tweak: { $0.ctrlHeaderTimeout = 0.2 }) == .noAnswer(.timeout))
        #expect(mute.ctrlConnections.with { $0 } == 2)
    }

    @Test func ctrlConnectionFactoryFailure() async {
        let console = FakeSessionConsole()
        defer { console.stop() }
        #expect(await Self.failure(console, tweak: { $0.makeCtrlConnection = { _, _ in throw FailureKind.badAddress } })
            == .network(.badAddress))
    }

    // MARK: After the start

    @Test func startupTimeoutWithoutSessionID() async throws {
        let console = FakeSessionConsole { peer, _ in peer.sendHead(); peer.pump() }
        defer { console.stop() }
        var options = ControlOptions()
        options.startupTimeout = 0.3
        let log = EventLog()
        _ = try await Self.start(console, options: options, log: log)
        #expect(await log.waitForEnd() == .startupTimeout)
    }

    @Test func waitingForTheUserIsNotLimited() async throws {
        let console = FakeSessionConsole { peer, _ in
            peer.sendHead(then: peer.frame(0x04))
            _ = peer.receive()
            peer.pump()
        }
        defer { console.stop() }
        var options = ControlOptions()
        options.startupTimeout = 0.2
        let log = EventLog()
        let session = try await Self.start(console, options: options, log: log)
        #expect(await log.wait { $0.contains(.loginPINRequested) })
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(session.endReason == nil)
        // After the PIN is sent, the console has the time limit again.
        try session.sendLoginPIN("1234")
        #expect(await log.waitForEnd() == .startupTimeout)
    }

    @Test func pinRequestAfterSessionIDEndsTheSession() async throws {
        let console = Self.console { peer in peer.send(0x04); peer.pump() }
        defer { console.stop() }
        let log = EventLog()
        _ = try await Self.start(console, log: log)
        #expect(await log.waitForEnd() == .loginPINAfterSessionID)
        #expect(!log.all.contains(.loginPINRequested))
    }

    @Test func badAndRepeatedSessionIDs() async throws {
        let bad = FakeSessionConsole { peer, _ in peer.sendHead(); peer.send(0x33, [0x4a, 0x41]); peer.pump() }
        defer { bad.stop() }
        let log = EventLog()
        _ = try await Self.start(bad, log: log)
        #expect(await log.waitForEnd() == .invalidSessionID)

        // A second session ID is ignored but its counter is used: the heartbeat after it still decrypts.
        let twice = FakeSessionConsole { peer, _ in
            peer.sendHead()
            peer.send(0x33, sessionIDPlain)
            peer.send(0x33, sessionIDPlain)
            peer.send(0x01, [1])
            peer.pump()
        }
        defer { twice.stop() }
        let log2 = EventLog()
        let session = try await Self.start(twice, log: log2)
        #expect(await log2.wait { $0.contains(.displayNotice(.a(set: true))) })
        #expect(log2.all.filter { if case .sessionID = $0 { true } else { false } }.count == 1)
        session.stop()
        _ = await log2.waitForEnd()
    }

    @Test func heartbeatTimeout() async throws {
        let console = Self.console { peer in peer.send(0xfe); peer.pump() }
        defer { console.stop() }
        var options = ControlOptions()
        options.heartbeatTimeout = 0.3
        let log = EventLog()
        let started = monotonicSeconds()
        _ = try await Self.start(console, options: options, log: log)
        #expect(await log.waitForEnd() == .heartbeatTimeout)
        #expect(monotonicSeconds() - started < 5)
        #expect(log.all.contains(.heartbeat(count: 1)))
    }

    @Test func regularHeartbeatsKeepTheChannelUp() async throws {
        let console = Self.console { peer in
            for _ in 0..<6 { peer.send(0xfe); sleepSeconds(0.1) }
            peer.pump()
        }
        defer { console.stop() }
        var options = ControlOptions()
        options.heartbeatTimeout = 0.35
        let log = EventLog()
        let session = try await Self.start(console, options: options, log: log)
        #expect(await log.wait { $0.contains(.heartbeat(count: 6)) })
        #expect(session.endReason == nil)
        session.stop()
        #expect(await log.waitForEnd() == .stoppedByClient)
    }

    @Test func oversizeFrameEndsTheSession() async throws {
        let console = Self.console { peer in peer.write(hex("00200000 0099 0000") + [1, 2, 3]); peer.pump() }
        defer { console.stop() }
        let log = EventLog()
        _ = try await Self.start(console, log: log)
        #expect(await log.waitForEnd() == .frameTooLarge(length: 0x200000))
    }

    @Test func largeFramesAreAccepted() async throws {
        let big = (0..<3000).map { UInt8(truncatingIfNeeded: $0) }
        let console = Self.console { peer in peer.send(0x7778, big); peer.send(0x01, [1]); peer.pump() }
        defer { console.stop() }
        let log = EventLog()
        let session = try await Self.start(console, log: log)
        #expect(await log.wait { $0.contains(.notice(type: 0x7778, payload: big)) })
        #expect(await log.wait { $0.contains(.displayNotice(.a(set: true))) })
        session.stop()
        _ = await log.waitForEnd()
    }

    @Test func closeInTheMiddleOfAFrame() async throws {
        let console = Self.console { peer in
            peer.write(hex("00000010 0099 0000") + [1, 2])
            peer.finish()
            peer.waitForClose()
        }
        defer { console.stop() }
        let log = EventLog()
        _ = try await Self.start(console, log: log)
        #expect(await log.waitForEnd() == .consoleClosed)
        // The half frame produced no event.
        #expect(!log.all.contains { if case .notice = $0 { true } else { false } })
    }

    @Test func consoleResetEndsWithConnectionLost() async throws {
        let console = Self.console { peer in peer.reset() }
        defer { console.stop() }
        let log = EventLog()
        _ = try await Self.start(console, log: log)
        #expect(await log.waitForEnd() == .connectionLost(.disconnected))
    }

    @Test func commandsAfterTheEndDoNothing() async throws {
        let console = Self.console { $0.pump() }
        defer { console.stop() }
        let log = EventLog()
        let session = try await Self.start(console, log: log)
        session.stop()
        session.stop()
        #expect(await log.waitForEnd() == .stoppedByClient)
        #expect(throws: ControlCommandError.notRunning) { try session.goToBed() }
        #expect(throws: ControlCommandError.notRunning) { try session.keyboardSetText("late") }
        #expect(throws: ControlCommandError.notRunning) { try session.sendLoginPIN("1234") }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(log.all.filter { if case .ended = $0 { true } else { false } }.count == 1)
        #expect(session.endReason == .stoppedByClient)
        let peer = try #require(console.peers.with { $0.first })
        #expect(!peer.received.with { $0.contains { $0.type == 0x50 || $0.type == 0x23 || $0.type == 0x8004 } })
    }

    // MARK: Stop and cancel in each phase

    @Test func cancelDuringSessionInit() async {
        let console = FakeSessionConsole(initReplies: { _ in .hang })
        defer { console.stop() }
        let started = monotonicSeconds()
        let task = Task { try await Self.start(console, tweak: { $0.initHeaderTimeout = 5 }) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let result = await task.result
        #expect(result.failureError == .cancelled)
        // Well before the 5 s header timeout; margin for a loaded parallel run.
        #expect(monotonicSeconds() - started < 3)
    }

    @Test func cancelBeforeStarting() async {
        let console = FakeSessionConsole()
        defer { console.stop() }
        let task = Task { try await Self.start(console) }
        task.cancel()
        #expect(await task.result.failureError == .cancelled)
    }

    @Test func cancelDuringTheCtrlHeader() async throws {
        let closed = Locked(false)
        let console = FakeSessionConsole { peer, _ in
            peer.waitForClose()
            closed.with { $0 = true }
        }
        defer { console.stop() }
        let started = monotonicSeconds()
        let task = Task { try await Self.start(console, tweak: { $0.ctrlHeaderTimeout = 5 }) }
        #expect(await waitUntil { console.ctrlConnections.with { $0 } == 1 })
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        #expect(await task.result.failureError == .cancelled)
        #expect(await waitUntil { closed.with { $0 } })
        #expect(monotonicSeconds() - started < 4)
    }

    @Test func cancelWhileConnecting() async throws {
        // Cancel during the pause between session init and the ctrl connection.
        let console = FakeSessionConsole { peer, _ in peer.waitForClose() }
        defer { console.stop() }
        let task = Task { try await Self.start(console, tweak: { $0.pauseBeforeCtrl = 0.3 }) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        #expect(await task.result.failureError == .cancelled)
        #expect(console.ctrlConnections.with { $0 } == 0)
    }

    @Test func stopDuringStartupAndWhileRunning() async throws {
        for withSessionID in [false, true] {
            let closed = Locked(false)
            let console = FakeSessionConsole { peer, _ in
                peer.sendHead()
                if withSessionID { peer.send(0x33, sessionIDPlain) }
                peer.waitForClose()
                closed.with { $0 = true }
            }
            defer { console.stop() }
            let log = EventLog()
            let session = try await Self.start(console, log: log)
            if withSessionID { #expect(await log.wait { $0.contains { if case .sessionID = $0 { true } else { false } } }) }
            session.stop()
            #expect(await log.waitForEnd() == .stoppedByClient)
            #expect(await waitUntil { closed.with { $0 } })
            #expect(log.all.last == .ended(.stoppedByClient))
        }
    }

    @Test func droppingTheSessionClosesTheConnection() async throws {
        let closed = Locked(false)
        let console = FakeSessionConsole { peer, _ in
            peer.sendHead()
            peer.waitForClose()
            closed.with { $0 = true }
        }
        defer { console.stop() }
        do {
            _ = try await Self.start(console, retain: false)
        }
        #expect(await waitUntil { closed.with { $0 } })
    }
}

extension Result where Failure == any Error {
    var failureError: SessionError? {
        if case .failure(let error) = self { return error as? SessionError }
        return nil
    }
}
