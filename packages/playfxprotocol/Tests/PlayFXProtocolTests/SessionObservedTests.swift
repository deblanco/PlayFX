import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

/// The start-up races, cancellation, redaction and the sequences seen on a real PS5 (ctrl.md, "Observed on a
/// real console"), against the spec-built fake console.
@Suite struct SessionObservedTests {
    static func isSessionID(_ event: ControlEvent) -> Bool {
        if case .sessionID = event { true } else { false }
    }

    @Test func pinRequestInTheSameWriteAsTheHeaderIsAnsweredFromTheHandler() async throws {
        let console = FakeSessionConsole { peer, _ in
            peer.sendHead(then: peer.frame(0x04))
            let reply = peer.receive()
            #expect(reply?.plain == Array("1234".utf8))
            peer.send(0x05, [0])
            peer.send(0x33, sessionIDPlain)
            peer.pump()
        }
        defer { console.stop() }
        let log = EventLog()
        log.onEvent = { event, session in
            if event == .loginPINRequested { try? session.sendLoginPIN("1234") }
        }
        let session = try await SessionLoopbackTests.start(console, log: log)
        #expect(await log.wait { $0.contains(where: Self.isSessionID) })
        #expect(log.all.contains(.loginPINResult(accepted: true)))
        // The request was answered, so a second PIN has nothing to answer.
        #expect(throws: ControlCommandError.noPINRequested) { try session.sendLoginPIN("1234") }
        session.stop()
        _ = await log.waitForEnd()
    }

    @Test func wrongPINRequestsAnotherAndTheHandlerAnswersAgain() async throws {
        let console = FakeSessionConsole { peer, _ in
            peer.sendHead(then: peer.frame(0x04))
            _ = peer.receive()
            peer.send(0x05, [1])
            peer.send(0x04)
            let second = peer.receive()
            peer.send(0x05, [0])
            peer.send(0x33, sessionIDPlain)
            #expect(second?.plain == Array("2222".utf8))
            peer.pump()
        }
        defer { console.stop() }
        let log = EventLog()
        log.onEvent = { event, session in
            if event == .loginPINRequested {
                let count = log.events.with { $0.filter { $0 == .loginPINRequested }.count }
                try? session.sendLoginPIN(count == 1 ? "1111" : "2222")
            }
        }
        let session = try await SessionLoopbackTests.start(console, log: log)
        #expect(await log.wait { $0.contains(where: Self.isSessionID) })
        session.stop()
        _ = await log.waitForEnd()
    }

    @Test func cancellingTheTaskOnceCtrlIsUpKeepsTheSession() async throws {
        let console = FakeSessionConsole { peer, _ in
            peer.sendHead()
            sleepSeconds(0.2)
            peer.send(0xfe)
            peer.pump()
        }
        defer { console.stop() }
        let box = Locked<Task<ControlSession, Error>?>(nil)
        let log = EventLog()
        // Cancel from inside the handler: the start continuation is resumed right after this event.
        log.onEvent = { event, _ in
            if case .connected = event { box.with { $0 }?.cancel() }
        }
        let task = Task { try await SessionLoopbackTests.start(console, log: log) }
        box.with { $0 = task }
        let session = try await task.value
        #expect(await log.wait { $0.contains(.heartbeat(count: 1)) })
        #expect(session.endReason == nil)
        session.stop()
        #expect(await log.waitForEnd() == .stoppedByClient)
    }

    @Test func nothingPrintsKeysOrSessionIDs() throws {
        let context = try SessionVector.context(.ps5v1)
        let id = SessionID(value: SessionVector.sessionIDText)
        let handoff = StreamHandoff(
            consoleAddress: "192.0.2.10", negotiatedVersion: .ps5v1, crypt: context, sessionID: id,
            streamHandshakeKey: hex("404142434445464748494a4b4c4d4e4f"), consoleModel: .ps5, streamingType: .h264,
            dualSenseEnabled: true)
        let secrets = [
            "598fa9a031d01820db25cab6e90bb19b", "ac7d50f394ea6588f0488f76e4170c8a", "404142434445464748494a4b4c4d4e4f",
            "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf", "000102030405060708090a0b0c0d0e0f", SessionVector.sessionIDText,
            "AAECAwQFBgcICQoLDA0ODw==",
        ]
        func texts<T>(_ value: T) -> [String] {
            var dumped = ""
            dump(value, to: &dumped)
            return [String(describing: value), String(reflecting: value), dumped, "\(value)"]
        }
        for text in texts(context) + texts(handoff) + texts(id) {
            for secret in secrets {
                #expect(!text.contains(secret))
                #expect(!text.lowercased().contains(secret.lowercased()))
            }
            // Byte arrays would show as decimal lists in a dump.
            #expect(!text.contains("89, 143") && !text.contains("[89"))
        }
        #expect(String(describing: context) == "RPCryptContext(keys hidden)")
    }

    @Test func handlerIsReleasedWhenTheChannelEnds() async throws {
        final class Probe: @unchecked Sendable {}
        let console = FakeSessionConsole { peer, _ in peer.sendHead(); peer.pump() }
        defer { console.stop() }
        weak var weakProbe: Probe?
        let session: ControlSession
        do {
            let probe = Probe()
            weakProbe = probe
            session = try await ControlSession.start(
                environment: .loopback(initPort: console.port), address: "127.0.0.1", target: .ps5v1,
                registKey: SessionVector.registKey, rpKey: SessionVector.rpKey, options: ControlOptions(),
                events: { [probe] _, _ in _ = probe })
        }
        #expect(weakProbe != nil)
        session.stop()
        #expect(await waitUntil { weakProbe == nil })
        #expect(session.endReason == .stoppedByClient)
    }

    // MARK: Observed on the PS5

    @Test func observedStartWithoutPINRequest() async throws {
        let console = FakeSessionConsole { peer, _ in
            peer.sendHead()
            peer.send(0x05, [0])
            sleepSeconds(0.05)
            peer.send(0x33, sessionIDPlain)
            peer.send(0x16, [0x01, 0xff])
            for _ in 0..<3 {
                sleepSeconds(0.1)
                peer.send(0xfe)
            }
            peer.pump()
        }
        defer { console.stop() }
        let log = EventLog()
        let session = try await SessionLoopbackTests.start(console, log: log)
        #expect(await log.wait { $0.contains(.heartbeat(count: 3)) })
        #expect(log.all == [
            .sessionInitialized(version: .ps5v1, attempts: 1),
            .connected(model: .ps5, pictureProhibited: false),
            .loginPINResult(accepted: true),
            .sessionID(SessionID(value: SessionVector.sessionIDText)),
            .displayNotice(.b(payload: [1, 0xff], clearsState: true)),
            .heartbeat(count: 1), .heartbeat(count: 2), .heartbeat(count: 3),
        ])
        // Every request was answered.
        let peer = try #require(console.peers.with { $0.first })
        #expect(await waitUntil { peer.received.with { $0.filter { $0.type == 0x1fe }.count } == 3 })
        // No PIN was requested, so there is none to send.
        #expect(throws: ControlCommandError.noPINRequested) { try session.sendLoginPIN("1234") }
        session.stop()
        _ = await log.waitForEnd()
    }

    @Test func goToBedSequence() async throws {
        let console = FakeSessionConsole { peer, _ in
            peer.sendHead()
            peer.send(0x33, sessionIDPlain)
            while let frame = peer.receive(timeout: 3), frame.type != 0x50 {}
            peer.send(0x8050, [0, 0, 0, 1])
            peer.send(0x03, [0, 0, 0, 2])
            peer.send(0xfe)
            peer.finish()
            peer.waitForClose()
        }
        defer { console.stop() }
        let log = EventLog()
        let session = try await SessionLoopbackTests.start(console, log: log)
        #expect(await log.wait { $0.contains(where: Self.isSessionID) })
        try session.goToBed()
        #expect(await log.waitForEnd() == .consoleClosed)
        let tail = Array(log.all.suffix(4))
        #expect(tail == [
            .notice(type: 0x8050, payload: [0, 0, 0, 1]), .notice(type: 0x03, payload: [0, 0, 0, 2]),
            .heartbeat(count: 1), .ended(.consoleClosed),
        ])
        let peer = try #require(console.peers.with { $0.first })
        #expect(peer.received.with { $0.contains { $0.type == 0x50 && $0.wire.isEmpty } })
    }

    @Test func aPS4ThatAnswersFiveToNineIsNotRetriedWithNine() async {
        let console = FakeSessionConsole(initReplies: { _ in .refuse(reason: "80108b11", version: "5.0") })
        defer { console.stop() }
        #expect(await SessionLoopbackTests.failure(console, target: .ps4v9) == .versionMismatch)
        #expect(console.initRequests.with { $0.count } == 1)
        let head = MiniHTTP.ResponseHead(
            status: 403, headers: ["rp-application-reason": "80108bff", "rp-version": "5.0"], length: 0)
        #expect(SessionInit.interpret(head, sent: .ps4v9) == .failure(.versionMismatch))
        #expect(SessionInit.interpret(head, sent: .ps4v10) == .retry(.ps4v9))
    }

    @Test func ctrlResetMessage() {
        #expect(SessionError.ctrlResetRepeatedly.userMessage(ps5: true)
            == "The PS5 kept closing the connection while the session started. Wait a few seconds and try again.")
    }
}
