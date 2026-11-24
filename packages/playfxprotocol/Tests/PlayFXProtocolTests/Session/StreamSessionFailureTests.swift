import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

/// Everything that goes wrong before the stream is up, and stopping or cancelling in each phase.
extension StreamSessionSuites {
    @Suite struct StreamSessionFailureTests {
        // MARK: Session init and ctrl

        @Test func aRefusedSessionInitThrowsWithTheEndReason() async throws {
            let console = try StreamConsole(initReplies: { _ in .refuse(reason: "80108b10") })
            defer { console.stop() }
            let recorder = EventRecorder()
            let error = try #require(await startFailure(console, recorder: recorder))
            #expect(error == .session(.consoleBusy, stage: .sessionInit))
            #expect(error.endReason?.code == .consoleBusy && error.endReason?.retryClass == .busy)
            #expect(error.userMessage(console: .ps5).contains("already streaming"))
            // A failed start delivers no `ended`.
            #expect(recorder.ended.isEmpty)
        }

        @Test func aClosedSessionInitPortIsARefusal() async throws {
            let console = try StreamConsole()
            console.ctrl.stop()
            defer { console.stop() }
            let error = try #require(await startFailure(console))
            guard case .session(let cause, .sessionInit) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(error.endReason?.code == (cause == .noAnswer(.connectionRefused) ? .sessionInitRefused : .sessionInitUnknown))
        }

        @Test func aCtrlRefusalIsAMappedSessionError() async throws {
            let console = try StreamConsole(ctrl: { peer in
                peer.sendHead(status: "403 Forbidden", serverType: nil, extra: ["RP-Application-Reason: 80108b15"])
                peer.waitForClose(limit: 1)
            })
            defer { console.stop() }
            let error = try #require(await startFailure(console))
            #expect(error == .session(.remotePlayCrashed, stage: .ctrl))
            #expect(error.endReason?.code == .remotePlayCrashed)
        }

        @Test func ctrlEndingBeforeTheSessionIDFailsTheStart() async throws {
            let console = try StreamConsole(ctrl: { peer in
                peer.sendHead()
                peer.closeNow()
            })
            defer { console.stop() }
            let error = try #require(await startFailure(console))
            guard case .stream(let reason, let detail) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(reason.code == .ctrlFailed && detail.contains("ctrl ended"))
            #expect(error.userMessage(console: .ps5).contains("lost"))
        }

        // MARK: The probe

        @Test func aSilentProbePortFallsBackAndTheStreamStillRuns() async throws {
            let console = try StreamConsole()
            console.probeScript = .silent
            console.probeConsole.replyToHandshake = false
            defer { console.stop() }
            let recorder = EventRecorder()
            let session = try await startSession(console, recorder: recorder, settings: hevcSettings) { $0.probe.connectTimeout = 0.4 }
            defer { session.stop() }
            let info = try #require(session.connectedInfo)
            #expect(!info.probeSucceeded && info.probe == .fallback && info.probeFailure != nil)
            #expect(info.probe.mtuIn == 1454 && info.probe.mtuOut == 1454 && info.probe.rttMilliseconds == 1)
            // With the fallbacks and the vector inputs, the Hello is V-ST4 to the byte, split 1378 + 31.
            let hello = try #require(console.hello)
            #expect(hello.bytes == hex(StreamVectors.ps5HelloHex))
            #expect(hello.chunks.map { $0.length } == [1378, 31] && hello.chunks.map { $0.flags } == [0, 1])
            #expect(hello.chunks.map { $0.continuation } == [false, true])
            #expect(await recorder.wait { _ in recorder.stats.last != nil })
            let stats = try #require(recorder.stats.last)
            #expect(!stats.probeSucceeded && stats.mtuIn == 1454 && stats.rttMicroseconds == 1000)
            // The stream still delivers.
            #expect(await recorder.wait { _ in recorder.videoFrames.count >= 2 })
        }

        @Test func aProbeThatNeverGetsAPongFailsAndFallsBack() async throws {
            let console = try StreamConsole()
            console.probeScript = .noPongs
            defer { console.stop() }
            let recorder = EventRecorder()
            let session = try await startSession(console, recorder: recorder) { $0.probe.pongTimeout = 0.05 }
            defer { session.stop() }
            let info = try #require(session.connectedInfo)
            #expect(!info.probeSucceeded && (info.probeFailure ?? "").contains("no pong") && info.probe == .fallback)
        }

        @Test(arguments: [(1454, 1454), (1200, 1100), (577, 576), (1454, 600)])
        func theProbeBisectsBothMTUsAndSendsTheSpecMessages(inLimit: Int, outLimit: Int) async throws {
            let console = try StreamConsole()
            console.probeScript = .answers(inLimit: inLimit, outLimit: outLimit)
            defer { console.stop() }
            let recorder = EventRecorder()
            let session = try await startSession(console, recorder: recorder) { $0.probe.pings = 10 }
            defer { session.stop() }
            let info = try #require(session.connectedInfo)
            #expect(info.probeSucceeded)
            #expect(info.probe.mtuIn == inLimit && info.probe.mtuOut == outLimit)
            #expect(info.probe.rttMicroseconds < 500_000)

            // The probe's own conversation (V-ST7 bytes), then its Disconnect.
            #expect(await waitUntil { console.probeMessages.with { $0.last?.bytes } == SessionBytes.clientDisconnect })
            let sent = console.probeMessages.with { $0 }
            #expect(sent.allSatisfy { $0.dataType == 0 })
            #expect(sent[0].channel == 1 && sent[0].bytes == hex("081ffa01020809"))
            #expect(sent[1].channel == 1 && sent[1].bytes == hex("08001208080912001a002200"))
            #expect(sent[2].channel == 8 && sent[2].bytes == hex("080c7206080012020801"))
            #expect(sent.contains { $0.channel == 8 && $0.bytes == hex("080c7206080012020800") })
            // Probe messages by command: inbound MTU requests (ids 1, 2, ... starting at 1454) and client MTU.
            func probeFields(_ m: ClientMessage) -> [(number: Int, varint: Int?, bytes: [UInt8]?)] {
                protoFields(protoFields(m.bytes).first { $0.number == 14 }?.bytes ?? [])
            }
            let mtuTests = sent.filter { probeFields($0).first { $0.number == 1 }?.varint == 1 }.map {
                protoFields(probeFields($0).first { $0.number == 3 }!.bytes!)
            }
            #expect(mtuTests.map { $0.first { $0.number == 1 }?.varint } == (1...mtuTests.count).map { $0 })
            #expect(mtuTests.first?.first { $0.number == 2 }?.varint == 1454)
            let clientMtus = sent.filter { probeFields($0).first { $0.number == 1 }?.varint == 4 }
            #expect(clientMtus.count == 2)
            let first = protoFields(probeFields(clientMtus[0]).first { $0.number == 5 }!.bytes!)
            #expect(first.map { $0.varint } == [1, inLimit, 1, inLimit])
            let last = protoFields(probeFields(clientMtus[1]).first { $0.number == 5 }!.bytes!)
            // `hi` is the first size that failed (one above the result), or 1454 when 1454 itself got through.
            #expect(last.map { $0.varint } == [2, outLimit == 1454 ? 1454 : outLimit + 1, 0, inLimit])
            if inLimit == 1454 && outLimit == 1454 {
                #expect(clientMtus[0].bytes == hex("080c720e08042a0a080110ae0b180120ae0b"))
                #expect(clientMtus[1].bytes == hex("080c720e08042a0a080210ae0b180020ae0b"))
                #expect(mtuTests.count == 1)
            }
            // Pings: the RTT test sends ten of 548 bytes, units 0...9; the MTU test sends IP size minus 28.
            let pings = console.pings.with { $0 }
            #expect(pings.prefix(10).map { $0.unit } == Array(0..<10) && pings.prefix(10).allSatisfy { $0.length == 548 })
            let accepted = pings.dropFirst(10).filter { $0.length + 28 <= outLimit }.map { $0.length + 28 }
            if outLimit > 576 { #expect(accepted.max() == outLimit) }
        }

        // MARK: The stream handshake

        @Test func theStreamHandshakeTimingOutThrowsStreamFailed() async throws {
            let console = try StreamConsole()
            console.streamConsole.replyToHandshake = false
            defer { console.stop() }
            let error = try #require(await startFailure(console) { $0.streamConnectTimeout = 0.4 })
            guard case .stream(let reason, let detail) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(reason.code == .streamFailed && reason.retryClass == .dropped && detail.contains("closed"))
            #expect(error.userMessage(console: .ps5).contains("lost"))
        }

        @Test(arguments: [
            (ReplyScript.versionRejected, "versionRejected"), (.keyRejected, "keyRejected"), (.noKey, "missingPublicKey"),
        ])
        func aRejectedHelloReplyFailsTheStartAndSaysGoodbye(script: ReplyScript, name: String) async throws {
            let console = try StreamConsole()
            console.replyScript = script
            defer { console.stop() }
            let error = try #require(await startFailure(console))
            guard case .stream(let reason, let detail) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(reason.code == .streamFailed && detail.contains(name))
            // A step failed after the Hello: the client sends its Disconnect (stream.md section 11.1) and closes ctrl.
            #expect(await waitUntil { console.count(SessionBytes.clientDisconnect) == 1 })
            #expect(await waitUntil { console.ctrlClosed.with { $0 } })
        }

        @Test func aSilentConsoleTimesOutWaitingForTheHelloReply() async throws {
            let console = try StreamConsole()
            console.replyScript = .silent
            defer { console.stop() }
            let error = try #require(await startFailure(console) { $0.helloReplyTimeout = 0.3 })
            guard case .stream(_, let detail) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(detail.contains("HelloReply"))
        }

        @Test func noStreamInfoTimesOut() async throws {
            let console = try StreamConsole()
            console.infoScript = .never
            defer { console.stop() }
            let error = try #require(await startFailure(console) { $0.streamInfoTimeout = 0.3 })
            guard case .stream(_, let detail) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(detail.contains("StreamInfo"))
        }

        @Test func anAudioHeaderOfTheWrongSizeFailsTheStart() async throws {
            let console = try StreamConsole()
            console.infoScript = .badAudio
            defer { console.stop() }
            let error = try #require(await startFailure(console))
            guard case .stream(let reason, let detail) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(reason.code == .streamFailed && detail.contains("audio header"))
        }

        @Test func aConsoleDisconnectDuringTheHandshakeIsARemoteDisconnect() async throws {
            let console = try StreamConsole()
            console.replyScript = .disconnect("Another device took over")
            defer { console.stop() }
            let error = try #require(await startFailure(console))
            #expect(error.endReason?.code == .streamRemoteDisconnected && error.endReason?.remoteText == "Another device took over")
        }

        @Test func aConsoleShuttingDownDuringTheHandshakeIsARemoteShutdown() async throws {
            let console = try StreamConsole()
            console.replyScript = .disconnect("Server shutting down")
            defer { console.stop() }
            let error = try #require(await startFailure(console))
            #expect(error.endReason?.code == .streamRemoteShutdown)
        }

        // MARK: Stopping and cancelling in each phase

        @Test func stoppingWhileTheLoginPINIsAwaitedCancelsTheStart() async throws {
            let console = try StreamConsole(ctrl: { peer in
                peer.sendHead()
                peer.send(0x04)
                peer.pump(limit: 5)
            })
            defer { console.stop() }
            let recorder = EventRecorder()
            recorder.onEvent = { event, session in
                if case .loginPINRequested = event { session.stop() }
            }
            let error = try #require(await startFailure(console, recorder: recorder))
            #expect(error == .cancelled && error.endReason == nil && error.userMessage(console: .ps5).isEmpty)
            #expect(recorder.all == [.loginPINRequested])
            #expect(await waitUntil { console.ctrlPeer?.received.with { _ in true } ?? false })
        }

        @Test func cancellingTheTaskWhileTheLoginPINIsAwaitedCancelsTheStart() async throws {
            let console = try StreamConsole(ctrl: { peer in
                peer.sendHead()
                peer.send(0x04)
                peer.pump(limit: 5)
            })
            defer { console.stop() }
            let recorder = EventRecorder()
            let task = Task { try await startSession(console, recorder: recorder) }
            #expect(await recorder.wait { $0.contains(.loginPINRequested) })
            task.cancel()
            let result = await task.result
            #expect(throws: StreamStartError.cancelled) { try result.get() }
        }

        /// A console whose ctrl asks for a login PIN first; the handler saves the session and answers.
        static func sessionHandle(_ recorder: EventRecorder) -> Locked<StreamSession?> {
            let box = Locked<StreamSession?>(nil)
            recorder.onEvent = { event, session in
                if case .loginPINRequested = event {
                    box.with { $0 = session }
                    try? session.sendLoginPIN("1234")
                }
            }
            return box
        }

        static func pinConsole() throws -> StreamConsole {
            try StreamConsole(ctrl: { peer in
                peer.sendHead()
                peer.send(0x04)
                _ = peer.receive()
                peer.send(0x05, [0])
                peer.send(0x33, sessionIDPlain)
                peer.pump(limit: 30)
            })
        }

        @Test func cancellingDuringTheProbeStopsPromptly() async throws {
            let console = try StreamConsole()
            console.probeScript = .silent
            console.probeConsole.replyToHandshake = false
            defer { console.stop() }
            let started = monotonicSeconds()
            let task = Task {
                try await startSession(console, recorder: EventRecorder()) {
                    $0.probe.connectTimeout = 10
                    $0.probe.stepTimeout = 5
                }
            }
            #expect(await waitUntil { console.probeConsole.initCount >= 1 })
            task.cancel()
            let result = await task.result
            #expect(throws: StreamStartError.cancelled) { try result.get() }
            #expect(monotonicSeconds() - started < 3)
            #expect(await waitUntil { console.ctrlClosed.with { $0 } })
        }

        @Test func stoppingDuringTheProbeCancelsTheStart() async throws {
            let console = try Self.pinConsole()
            console.probeScript = .silent
            console.probeConsole.replyToHandshake = false
            defer { console.stop() }
            let recorder = EventRecorder()
            let box = Self.sessionHandle(recorder)
            let task = Task {
                try await startSession(console, recorder: recorder) {
                    $0.probe.connectTimeout = 10
                    $0.probe.stepTimeout = 5
                }
            }
            #expect(await waitUntil { box.with { $0 } != nil && console.probeConsole.initCount >= 1 })
            box.with { $0 }?.stop()
            let result = await task.result
            #expect(throws: StreamStartError.cancelled) { try result.get() }
            #expect(await waitUntil { console.ctrlClosed.with { $0 } })
        }

        @Test func cancellingDuringTheHandshakeSaysGoodbye() async throws {
            let console = try StreamConsole()
            console.replyScript = .silent
            defer { console.stop() }
            let started = monotonicSeconds()
            let task = Task { try await startSession(console, recorder: EventRecorder()) { $0.helloReplyTimeout = 10 } }
            #expect(await waitUntil { console.hello != nil })
            task.cancel()
            let result = await task.result
            #expect(throws: StreamStartError.cancelled) { try result.get() }
            #expect(monotonicSeconds() - started < 3)
            #expect(await waitUntil { console.count(SessionBytes.clientDisconnect) == 1 })
            #expect(await waitUntil { console.ctrlClosed.with { $0 } })
        }

        @Test func stoppingDuringTheHandshakeCancelsTheStart() async throws {
            let console = try Self.pinConsole()
            console.replyScript = .silent
            defer { console.stop() }
            let recorder = EventRecorder()
            let box = Self.sessionHandle(recorder)
            let task = Task { try await startSession(console, recorder: recorder) { $0.helloReplyTimeout = 10 } }
            #expect(await waitUntil { console.hello != nil })
            box.with { $0 }?.stop()
            let result = await task.result
            #expect(throws: StreamStartError.cancelled) { try result.get() }
            #expect(await waitUntil { console.count(SessionBytes.clientDisconnect) == 1 })
        }

        @Test func ctrlEndingDuringTheHandshakeFailsTheStart() async throws {
            let console = try StreamConsole()
            console.replyScript = .silent
            defer { console.stop() }
            let task = Task { await startFailure(console) { $0.helloReplyTimeout = 10 } }
            #expect(await waitUntil { console.hello != nil })
            console.ctrlPeer?.closeNow(reset: true)
            let error = try #require(await task.value)
            guard case .stream(let reason, _) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(reason.code == .ctrlFailed)
            #expect(await waitUntil { console.count(SessionBytes.clientDisconnect) == 1 })
        }

        @Test func noEventAfterEndedWhateverTheCause() async throws {
            for cause in 0..<3 {
                let console = try StreamConsole()
                let recorder = EventRecorder()
                let session = try await startSession(console, recorder: recorder)
                switch cause {
                case 0: console.send(SessionBytes.disconnect("x"))
                case 1: session.stop()
                default: console.ctrlPeer?.closeNow(reset: true)
                }
                let reason = try #require(await recorder.waitForEnd())
                let count = recorder.all.count
                try await Task.sleep(nanoseconds: 300_000_000)
                #expect(recorder.all.count == count && recorder.ended == [reason])
                console.stop()
            }
        }
    }
}
