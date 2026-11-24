import Foundation
import os
import Testing
@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport
@testable import StreamCore

/// Stopping and releasing the PlayFX engine in awkward ways, and what the session around it does about them.
private final class WeakEngine {
    weak var value: PlayFXEngine?
    init(_ value: PlayFXEngine?) { self.value = value }
}

extension Serial {
    @Suite struct PlayFXEngineRobustnessTests {
        /// The app's event handler may call a command, or `stop()` again, from inside the quit that `stop()` delivers
        /// (the engine thread runs it while the stopping thread waits): the session mustn't hold its lock then.
        @Test func aHandlerThatCallsBackDuringStopDoesNotDeadlock() async throws {
            let (session, _) = try FakeStreamEngine.session()
            let called = OSAllocatedUnfairLock(initialState: false)
            session.onEvent = { event in
                guard case .quit = event else { return }
                session.requestKeyframe()
                session.setLoginPin("1")
                session.stop()
                called.withLock { $0 = true }
            }
            let returned = OSAllocatedUnfairLock(initialState: false)
            nonisolated(unsafe) let stopping = session
            Thread {
                stopping.stop()
                returned.withLock { $0 = true }
            }.start()
            #expect(await waitUntil(timeout: 8) { returned.withLock { $0 } })
            #expect(called.withLock { $0 })
            session.onEvent = nil
        }

        /// Nothing of the engine retains the sink after `stop()` returns (in the session's `deinit` it is being freed).
        @Test func stopLeavesNoReferenceToTheSink() async throws {
            let h = try PlayFXHarness()
            #expect(await h.connect())
            let before = CFGetRetainCount(h.sink)
            h.engine.stop()
            #expect(CFGetRetainCount(h.sink) == before)
        }

        @Test func anEngineReleasedWithoutStopEndsTheLibrarySessionQuietly() async throws {
            let console = try StreamConsole()
            let sink = RecordingSink()
            var engine: PlayFXEngine? = try PlayFXEngine(
                config: PlayFXHarness.config(), sink: sink, start: PlayFXHarness.starter(console))
            #expect(await waitUntil(timeout: 10) { sink.labels.contains("connected") && engine?.session != nil })
            let weakEngine = WeakEngine(engine)
            engine = nil
            #expect(weakEngine.value == nil)
            #expect(await waitUntil { console.count(SessionBytes.clientDisconnect) == 1 })   // the console was told goodbye
            let calls = sink.order.count
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(sink.order.count == calls && sink.quits.isEmpty)   // and the sink heard nothing more
            console.stop()
        }

        @Test func stopRacingTheConsolesOwnEndDeliversOneQuit() async throws {
            for round in 0..<6 {
                let h = try PlayFXHarness()
                h.console.streams = false
                #expect(await h.connect())
                let finished = OSAllocatedUnfairLock(initialState: false)
                Thread {
                    h.engine.stop()
                    finished.withLock { $0 = true }
                }.start()
                if round % 2 == 0 { h.console.send(SessionBytes.disconnect("Another device took over")) }
                else { h.console.stopStreamLink() }
                #expect(await waitUntil { finished.withLock { $0 } })
                try await Task.sleep(nanoseconds: 150_000_000)
                #expect(h.sink.quits.count == 1)
                #expect(h.sink.labels.last?.hasPrefix("quit") == true)
                #expect(h.sink.state.withLock { $0.callsAfterQuit } == 0)
            }
        }

        @Test func aPS4StreamsEndToEnd() async throws {
            var config = PlayFXHarness.config(ps5: false, codec: .hevc)
            config.height = 720
            let console = try StreamConsole(serverType: 0)
            let h = try PlayFXHarness(console: console, config: config)
            #expect(await h.connect())
            #expect(await waitUntil { h.sink.units.count >= 1 })
            let info = try #require(h.librarySession.withLock { $0 }?.connectedInfo)
            #expect(info.target == .ps4v10 && info.requested.codec == .h264 && info.requested.height == 720)
            h.engine.stop()
            #expect(h.sink.quits == ["quit stopped false Stopped"])
        }

        @Test func eachGateKeepsItsOwnNesting() {
            let a = PlayFXSinkGate()
            let b = PlayFXSinkGate()
            #expect(a.enter())
            #expect(a.isInsideCall && !b.isInsideCall)   // inside A's call is not inside B's
            // B has a call in flight on another thread: waiting on B, from inside A's call, must wait for it.
            let inCall = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            Thread {
                _ = b.enter()
                inCall.signal()
                release.wait()
                b.leave()
            }.start()
            inCall.wait()
            #expect(!b.waitForOtherCalls(timeout: 0.1))
            release.signal()
            #expect(b.waitForOtherCalls(timeout: 5))
            a.leave()
        }

        @Test func aNestedQuitWaitsForTheThreadsOwnCallsToReturn() {
            let gate = PlayFXSinkGate()
            #expect(gate.enter() && gate.enter())
            #expect(gate.claimQuitLater() && !gate.claimQuitLater() && !gate.claimQuit())
            #expect(!gate.takePendingQuit())     // still inside two calls
            gate.leave()
            #expect(!gate.takePendingQuit())     // and one
            gate.leave()
            #expect(gate.takePendingQuit() && !gate.takePendingQuit())
            gate.quitDelivered()
            #expect(gate.waitForOtherCalls(timeout: 0.1))
        }

        @Test func aWaitForACallThatNeverReturnsGivesUp() {
            let gate = PlayFXSinkGate()
            let inCall = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            Thread {
                _ = gate.enter()
                inCall.signal()
                release.wait()
                gate.leave()
            }.start()
            inCall.wait()
            let started = Date()
            #expect(!gate.waitForOtherCalls(timeout: 0.2) && Date().timeIntervalSince(started) < 3)
            release.signal()
        }

        /// The microphone's encoder needs libopus 1.2 (phase inversion off): an older one fails here, loudly.
        @Test func theMicrophoneEncoderIsCreatedWithTheLinkedLibopus() {
            #expect(PlayFXOpusMicrophone() != nil)
        }
    }
}
