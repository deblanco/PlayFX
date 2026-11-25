import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

/// Ownership, the start contract, the ending paths and their races.
extension StreamSessionSuites {
    @Suite struct StreamSessionLifecycleTests {
        // MARK: Ownership

        @Test func nothingStaysAliveAfterEnded() async throws {
            let console = try StreamConsole()
            defer { console.stop() }
            let recorder = EventRecorder()
            let session = try await startSession(console, recorder: recorder)
            weak let link = session.link
            weak let connection = session.connection
            #expect(link != nil && connection != nil)
            session.stop()
            #expect(await recorder.waitForEnd() != nil)
            // `session` is still held here: the link and the connection must be gone anyway.
            #expect(await waitUntil { link == nil && connection == nil })
            withExtendedLifetime(session) {}
        }

        @Test func nothingStaysAliveAfterAFailedStartAndTheKeyPairIsWiped() async throws {
            let console = try StreamConsole()
            console.replyScript = .silent
            defer { console.stop() }
            let keyPair = Locked<StreamKeyPair?>(nil)
            let transport = Locked<[Weak]>([])
            let error = await startFailure(console) { env in
                env.helloReplyTimeout = 0.3
                env.makeKeyPair = {
                    let pair = try vectorKeyPair()
                    keyPair.with { $0 = pair }
                    return pair
                }
                let base = env.makeTransport
                let streamPort = console.streamLink.port
                env.makeTransport = { kind, host, port, df in
                    let made = base(kind, host, port, df)
                    if port == streamPort { transport.with { $0.append(Weak(made)) } }
                    return made
                }
            }
            #expect(error != nil)
            let pair = try #require(keyPair.with { $0 })
            #expect(throws: (any Error).self) { try pair.sharedSecret(consolePublicKey: StreamInputs.publicB) }
            #expect(await waitUntil { transport.with { $0.allSatisfy { $0.value == nil } } && !transport.with { $0.isEmpty } })
        }

        // MARK: The start contract

        @Test func aSendFailureRightAfterTheStreamInfoIsAnEndNotAFailedStart() async throws {
            let console = try StreamConsole()
            let failing = Locked(false)
            console.infoScript = .afterHelloAck
            console.beforeStreamInfo = { failing.with { $0 = true } }
            defer { console.stop() }
            let recorder = EventRecorder()
            let session = try await startSession(console, recorder: recorder) { env in
                wrapTransport(&env, port: console.streamLink.port) { FlakyTransport($0, failing: failing) }
            }
            let reason = try #require(await recorder.waitForEnd())
            #expect(reason.code == .streamFailed)
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(recorder.ended == [reason])
            if case .ended = recorder.all.last {} else { Issue.record("`ended` was not the last event") }
            #expect(session.endReason == reason)
        }

        @Test func theNegotiatedInfoIsStillThereInTheEndedHandler() async throws {
            let console = try StreamConsole()
            defer { console.stop() }
            let recorder = EventRecorder()
            let seen = Locked<StreamConnectedInfo?>(nil)
            recorder.onEvent = { event, session in
                if case .ended = event { seen.with { $0 = session.connectedInfo } }
            }
            let session = try await startSession(console, recorder: recorder)
            session.stop()
            #expect(await recorder.waitForEnd() != nil)
            #expect(seen.with { $0 }?.takionVersion == 12)
        }

        // MARK: Disconnect, probe and MTU

        @Test func stoppingOverNetworkFrameworkSendsTheDisconnect() async throws {
            let console = try StreamConsole()
            defer { console.stop() }
            let recorder = EventRecorder()
            let session = try await startSession(console, recorder: recorder, transport: .nw)
            session.stop()
            #expect(await recorder.waitForEnd() != nil)
            #expect(await waitUntil { console.count(SessionBytes.clientDisconnect) == 1 })
        }

        @Test func aDatagramOverTheLocalMTUIsLostNotFatal() async throws {
            let harness = MemoryHarness(version: 7)
            try harness.handshake()
            harness.transport.failSend = .other(errno: EMSGSIZE)
            #expect(harness.connection.sendRaw([UInt8](repeating: 0, count: 2000)))
            #expect(harness.connection.isConnected && harness.delegate.closed.isEmpty)
            #expect(harness.connection.stats.sendErrors == 1)
            harness.transport.failSend = .other(errno: EPIPE)
            _ = harness.connection.sendRaw([0])
            #expect(!harness.connection.isConnected && harness.delegate.closed == [.socketError(EPIPE)])
        }

        @Test func theProbeSurvivesSizesTheSocketRefusesAndFindsTheLocalLimit() async throws {
            let console = try StreamConsole()
            console.probeScript = .answers(inLimit: 1400, outLimit: 1300)
            defer { console.stop() }
            let recorder = EventRecorder()
            let session = try await startSession(console, recorder: recorder) { env in
                // Datagrams of the outbound test are IP size - 28: a local limit of 1250 IP bytes.
                wrapTransport(&env, port: console.probeLink.port) { SizeLimitedTransport($0, limit: 1250 - 28) }
            }
            defer { session.stop() }
            let info = try #require(session.connectedInfo)
            #expect(info.probeSucceeded && info.probe.mtuIn == 1400 && info.probe.mtuOut == 1250)
        }

        @Test func theFarewellSendsTheDisconnectOnlyWhenAsked() async throws {
            let harness = MemoryHarness()
            try harness.handshake()
            let before = harness.transport.sent.count
            Farewell.close(harness.connection, disconnect: false, pause: false)
            #expect(harness.transport.sent.count == before && !harness.connection.isConnected)
            let second = MemoryHarness()
            try second.handshake()
            let count = second.transport.sent.count
            Farewell.close(second.connection, disconnect: true, pause: false)
            #expect(second.transport.sent.count == count + 1)
            Farewell.close(second.connection, disconnect: true, pause: true)  // closed already: nothing, no pause
            #expect(second.transport.sent.count == count + 1)
            Farewell.close(nil, disconnect: true, pause: false)
        }

        @Test func aProbeConnectionThatClosesFailsAtOnceNotAfterTheTimeout() async throws {
            let console = try StreamConsole()
            console.probeScript = .silent
            console.probeConsole.ackData = false  // the version request is neither acked nor answered: it is resent
            defer { console.stop() }
            let recorder = EventRecorder()
            let started = monotonicSeconds()
            // The console's probe socket goes away right after the handshake: the next send gets a socket error.
            console.probeConsole.onPacket = { [console] d in
                if d.count > 13, d[13] == 0x00 { Thread.detachNewThread { console.stopProbeLink() } }
            }
            let session = try await startSession(console, recorder: recorder) { $0.probe.answerTimeout = 30 }
            defer { session.stop() }
            #expect(monotonicSeconds() - started < 10)
            #expect(try #require(session.connectedInfo).probeSucceeded == false)
        }

        // MARK: Ctrl and the console's reason

        @Test func theConsolesDisconnectArrivingJustAfterCtrlClosesKeepsItsText() async throws {
            let console = try StreamConsole()
            defer { console.stop() }
            let recorder = EventRecorder()
            _ = try await startSession(console, recorder: recorder) { $0.ctrlEndGrace = 1 }
            console.ctrlPeer?.reset()
            try await Task.sleep(nanoseconds: 100_000_000)
            console.send(SessionBytes.disconnect("Another device took over"))
            let reason = try #require(await recorder.waitForEnd())
            #expect(reason.code == .streamRemoteDisconnected && reason.remoteText == "Another device took over")
            #expect(recorder.ended.count == 1)
        }

        @Test func commandsThatFailDoNotLatchTheirFlags() async throws {
            let console = try StreamConsole()
            defer { console.stop() }
            let recorder = EventRecorder()
            var options = StreamSessionOptions()
            options.microphone = true
            let session = try await startSession(console, recorder: recorder, options: options) { $0.ctrlEndGrace = 1.5 }
            console.ctrlPeer?.reset()
            // Ctrl is down but the stream is not over yet (the grace): the commands fail.
            try await Task.sleep(nanoseconds: 400_000_000)
            #expect(throws: ControlCommandError.notRunning) { try session.goToBed() }
            #expect(throws: ControlCommandError.notRunning) { try session.setMicrophone(on: true) }
            let flags = session.commandFlags
            #expect(!flags.goToBed && !flags.microphoneConnected)
            let reason = try #require(await recorder.waitForEnd())
            #expect(reason.code == .ctrlFailed)
        }

        // MARK: Stopping from everywhere

        @Test func stoppingFromInsideTheVideoHandlerEndsOnce() async throws {
            let console = try StreamConsole()
            defer { console.stop() }
            let recorder = EventRecorder()
            recorder.onEvent = { event, session in
                if case .videoAccessUnit = event { session.stop() }
            }
            _ = try await startSession(console, recorder: recorder)
            let reason = try #require(await recorder.waitForEnd())
            #expect(reason.code == .stoppedByClient)
            let count = recorder.all.count
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(recorder.all.count == count && recorder.ended == [reason])
        }

        @Test func stoppingFromInsideTheEndedHandlerIsHarmless() async throws {
            let console = try StreamConsole()
            defer { console.stop() }
            let recorder = EventRecorder()
            recorder.onEvent = { event, session in
                if case .ended = event {
                    session.stop()
                    _ = session.setControllerState(.idle)
                }
            }
            let session = try await startSession(console, recorder: recorder)
            console.send(SessionBytes.disconnect("bye"))
            let reason = try #require(await recorder.waitForEnd())
            session.stop()
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(recorder.ended == [reason])
        }

        @Test func stoppingWhileTheConsoleDisconnectsEndsOnceWithoutDeadlock() async throws {
            for _ in 0..<5 {
                let console = try StreamConsole()
                let recorder = EventRecorder()
                let session = try await startSession(console, recorder: recorder)
                console.send(SessionBytes.disconnect("race"))
                session.stop()
                let reason = try #require(await recorder.waitForEnd())
                #expect(reason.code == .stoppedByClient || reason.code == .streamRemoteDisconnected)
                let count = recorder.all.count
                try await Task.sleep(nanoseconds: 150_000_000)
                #expect(recorder.all.count == count && recorder.ended == [reason])
                console.stop()
            }
        }
    }
}

/// A weak box, so a test can watch for an object going away.
final class Weak: @unchecked Sendable {
    weak var value: AnyObject?
    init(_ value: AnyObject) { self.value = value }
}
