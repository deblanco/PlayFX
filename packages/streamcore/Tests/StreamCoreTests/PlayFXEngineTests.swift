import COpus
import CryptoKit
import Foundation
import os
import Testing
@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport
@testable import StreamCore

/// The PlayFX engine end to end: `PlayFXEngine` on PlayFXProtocol's `StreamSession`, over real loopback sockets, against
/// the fake console of PlayFXProtocolTestSupport. The sink is a recorder that checks the contract as it goes.
extension Serial {
    @Suite struct PlayFXEngineSessionTests {
        func sha(_ bytes: ArraySlice<UInt8>) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

        // MARK: A whole session

        @Test func aWholeSessionReachesTheSinkInOrder() async throws {
            let h = try PlayFXHarness()
            #expect(await h.connect())
            #expect(await waitUntil { h.sink.units.count >= 2 && !h.sink.haptics.isEmpty && h.sink.audio.count >= 2 })
            // The first frame carries the parameter sets of its resolution, as the contract has it; the second doesn't.
            let units = h.sink.units
            #expect(units[0].bytes.prefix(9) == ArraySlice(SessionBytes.dummyProfile0Header))
            #expect(sha(units[0].bytes.dropFirst(9)) == captureExpected[1]?.sha)
            #expect(sha(units[1].bytes[...]) == captureExpected[2]?.sha)
            #expect(units[0].framesLost == 0 && units[1].framesLost == 0)
            // Frames 3 and 4 never come: the next unit says two were lost, the one after says none.
            h.console.sendExtraFrames(first: 5, count: 2)
            #expect(await waitUntil { h.sink.units.count >= 4 })
            #expect(h.sink.units[2] == RecordingSink.Unit(bytes: [0, 0, 0, 1, 0x41, 9, 9], framesLost: 2))
            #expect(h.sink.units[3].framesLost == 0)
            // `connected` first (once), the audio format before any audio, stereo 48 kHz, 10 ms of PCM a packet.
            let order = h.sink.order
            #expect(order.first == "connected" && order.filter { $0 == "connected" }.count == 1)
            let format = try #require(order.firstIndex(of: "audioFormat"))
            #expect(format < (try #require(order.firstIndex(of: "audio"))))
            #expect(h.sink.state.withLock { $0.audioFormats.map { [$0.channels, $0.rate] } } == [[2, 48000]])
            #expect(h.sink.audio.allSatisfy { !$0.isEmpty && $0.count % 2 == 0 })
            // Haptics reach the sink as the console sent them (little-endian pairs).
            #expect(h.sink.haptics.first == [1, 2, 3, -1, -32768, 0x1234])
            // The sink wasn't a pad: the engine made rumble out of them.
            #expect(await waitUntil { !h.sink.hapticRumbles.isEmpty })
            // The contract's rules held: nothing on the main thread, nothing overlapping.
            #expect(h.sink.state.withLock { $0.mainThreadCalls == 0 && $0.overlaps == 0 })
            h.engine.stop()
            #expect(h.sink.quits == ["quit stopped false Stopped"] && h.sink.labels.last == h.sink.quits.last)
            #expect(h.sink.state.withLock { $0.callsAfterQuit } == 0)
        }

        @Test func rejectedFramesAskForAKeyFrameOnceUntilOneArrives() async throws {
            let now = OSAllocatedUnfairLock(initialState: 0.0)
            let h = try PlayFXHarness(tweak: { $0.clock = { now.withLock { $0 } } })
            h.console.streams = false
            #expect(await h.connect())
            let session = try #require(h.librarySession.withLock { $0 })
            func idrRequests() -> Int { h.console.received(channel: 2).filter { $0 == hex("0819") }.count }
            func inject(_ index: Int, key: Bool?) {
                let info = VideoFrameInfo(
                    frameIndex: UInt16(index), framesLost: 0, recovered: false, isKeyFrame: key, fecRecovered: false,
                    profileIndex: 0, codec: nil)
                [UInt8]([0, 0, 0, 1, key == true ? 0x65 : 0x41, 1, 2]).withUnsafeBytes {
                    h.engine.handle(.videoAccessUnit($0, info), session)
                }
            }
            h.sink.videoResult = { _ in false }
            let header = SessionBytes.dummyProfile0Header
            h.engine.handle(.parameterSets(profileIndex: 0, profile: VideoProfile(width: 1, height: 1, header: header), codec: nil), session)
            now.withLock { $0 = 10 }
            inject(1, key: true)       // refused: a key frame is asked for
            #expect(await waitUntil { idrRequests() == 1 })
            #expect(h.sink.units[0].bytes == header + [0, 0, 0, 1, 0x65, 1, 2])   // key frame: parameter sets first
            now.withLock { $0 = 20 }   // far past the library's own one-a-second limit
            inject(2, key: false)
            inject(3, key: nil)
            // A refused unit means the decoder may start again: the next one, however the library classed it, has them too.
            #expect(h.sink.units[1].bytes == header + [0, 0, 0, 1, 0x41, 1, 2] && h.sink.units[2].bytes == header + [0, 0, 0, 1, 0x41, 1, 2])
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(idrRequests() == 1)  // refused again, but one request is enough until a key frame arrives
            h.sink.videoResult = { _ in true }
            now.withLock { $0 = 30 }
            inject(4, key: true)       // a key frame arrives: the wait is over
            h.sink.videoResult = { _ in false }
            now.withLock { $0 = 40 }
            inject(5, key: false)
            #expect(await waitUntil { idrRequests() == 2 })
            // A resolution switch puts the parameter sets in front of the next frame, key frame or not.
            h.sink.videoResult = { _ in true }
            h.engine.handle(.parameterSets(profileIndex: 1, profile: VideoProfile(width: 1, height: 1, header: [9, 9]), codec: nil), session)
            inject(6, key: false)
            inject(7, key: false)
            #expect(h.sink.units[5].bytes == [9, 9, 0, 0, 0, 1, 0x41, 1, 2] && h.sink.units[6].bytes == [0, 0, 0, 1, 0x41, 1, 2])
            // A resolution with no parameter sets leaves frames as they are.
            h.engine.handle(.parameterSets(profileIndex: 2, profile: VideoProfile(width: 1, height: 1, header: []), codec: nil), session)
            inject(8, key: true)
            #expect(h.sink.units[7].bytes == [0, 0, 0, 1, 0x65, 1, 2])
            h.engine.stop()
        }

        @Test func everyRefusalReachesTheLibraryAndAsksForOneKeyFrame() async throws {
            let h = try PlayFXHarness()
            h.sink.videoResult = { _ in false }   // the capture's two frames are both refused
            #expect(await h.connect())
            #expect(await waitUntil { h.sink.units.count >= 2 })
            let session = try #require(h.librarySession.withLock { $0 })
            #expect(await waitUntil { session.link?.snapshot().decoderRejects == 2 })   // the library counted both
            #expect(await waitUntil { h.console.received(channel: 2).contains(hex("0819")) })
            #expect(h.console.received(channel: 2).filter { $0 == hex("0819") }.count == 1)
            h.engine.stop()
        }

        @Test func aKeyFrameRequestFromTheAppIsSentAndThrottled() async throws {
            let h = try PlayFXHarness()
            h.console.streams = false
            #expect(await h.connect())
            h.engine.requestKeyFrame()
            h.engine.requestKeyFrame()
            #expect(await waitUntil { h.console.received(channel: 2).contains(hex("0819")) })
            #expect(h.console.received(channel: 2).filter { $0 == hex("0819") }.count == 1)
            h.engine.stop()
        }

        // MARK: How a session ends

        @Test func stoppingEndsWithOneQuitBeforeStopReturns() async throws {
            let h = try PlayFXHarness()
            #expect(await h.connect())
            h.engine.stop()
            #expect(h.sink.quits == ["quit stopped false Stopped"])   // already there when stop returns
            h.engine.stop()
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(h.sink.quits.count == 1 && h.sink.labels.last == h.sink.quits[0])
            #expect(h.sink.state.withLock { $0.callsAfterQuit } == 0)
            #expect(await waitUntil { h.console.count(SessionBytes.clientDisconnect) == 1 })   // the console was told
        }

        @Test func aBusyConsoleIsABusyQuitThatNeverConnected() async throws {
            let console = try StreamConsole(initReplies: { _ in .refuse(reason: "80108b10") })
            let h = try PlayFXHarness(console: console)
            #expect(await waitUntil { !h.sink.quits.isEmpty })
            let quit = try #require(h.sink.events.first)
            guard case .quit(let reason, let error, let kind) = quit else { Issue.record("not a quit: \(quit)"); return }
            #expect(kind == .busy && error && reason.contains("already streaming"))
            h.engine.stop()
            #expect(h.sink.labels.count == 1)   // no connected, and stop adds nothing
        }

        @Test func aConnectionThatCouldntBeMadeIsFinal() async throws {
            let console = try StreamConsole(initReplies: { _ in .refuse(reason: nil) })
            let h = try PlayFXHarness(console: console)
            #expect(await waitUntil { !h.sink.quits.isEmpty })
            guard case .quit(_, let error, let kind) = try #require(h.sink.events.first) else { return }
            #expect(kind == .final && error)
            h.engine.stop()
            #expect(h.sink.quits.count == 1)
        }

        @Test func aLostConnectionIsDropped() async throws {
            let h = try PlayFXHarness()
            #expect(await h.connect())
            h.console.stopStreamLink()
            #expect(await waitUntil { !h.sink.quits.isEmpty })
            guard case .quit(let reason, let error, let kind) = try #require(h.sink.events.last) else { return }
            #expect(kind == .dropped && error && reason.contains("lost"))
            h.engine.stop()
            #expect(h.sink.quits.count == 1 && h.sink.state.withLock { $0.callsAfterQuit } == 0)
        }

        @Test func theConsoleEndingItOnPurposeIsFinal() async throws {
            let h = try PlayFXHarness()
            #expect(await h.connect())
            h.console.send(SessionBytes.disconnect("Another device took over"))
            #expect(await waitUntil { !h.sink.quits.isEmpty })
            guard case .quit(let reason, let error, let kind) = try #require(h.sink.events.last) else { return }
            #expect(kind == .final && error && reason.contains("Another device took over"))
            h.engine.stop()
            #expect(h.sink.quits.count == 1)
        }

        @Test func restModeIsAFinalQuitThatIsNotAnError() async throws {
            let h = try PlayFXHarness()
            #expect(await h.connect())
            h.engine.goToBed()
            let peer = try #require(h.console.ctrlPeer)
            #expect(await waitUntil { peer.received.with { $0.contains { $0.type == 0x50 } } })
            peer.finish()   // the console goes to rest mode: ctrl closes
            #expect(await waitUntil { !h.sink.quits.isEmpty })
            guard case .quit(_, let error, let kind) = try #require(h.sink.events.last) else { return }
            #expect(kind == .final && !error)
            h.engine.stop()
            #expect(h.sink.quits.count == 1)
        }

        // MARK: Stopping from awkward places

        @Test func stopFromInsideASinkCallReturnsAndQuitsOnce() async throws {
            let quitInsideStop = OSAllocatedUnfairLock(initialState: [Bool]())
            let sinkRef = OSAllocatedUnfairLock<RecordingSink?>(initialState: nil)
            let h = try PlayFXHarness(onEvent: { event, engine in
                if case .connected = event {
                    engine.stop()
                    // The contract: never synchronously from inside stop(); it comes when this call has returned.
                    quitInsideStop.withLock { $0.append(sinkRef.withLock { $0 }?.quits.isEmpty == false) }
                }
            }, sinkReady: { sink in sinkRef.withLock { $0 = sink } })
            #expect(await waitUntil { !h.sink.quits.isEmpty })
            #expect(quitInsideStop.withLock { $0 } == [false])
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(h.sink.labels == ["connected", "quit stopped false Stopped"])
            #expect(h.sink.state.withLock { $0.callsAfterQuit } == 0)
            h.engine.stop()
            #expect(h.sink.quits.count == 1)
        }

        @Test func stopFromInsideAControlEventOnTheLibrarysQueueReturnsAndQuitsOnce() async throws {
            let h = try PlayFXHarness { event, engine in if case .rumble = event { engine.stop() } }
            h.console.streams = false
            #expect(await h.connect())
            h.console.send(dataType: 7, SessionBytes.rumble)
            #expect(await waitUntil { !h.sink.quits.isEmpty })
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(h.sink.labels == ["connected", "rumble 128 64", "quit stopped false Stopped"])
            #expect(h.sink.state.withLock { $0.callsAfterQuit } == 0)
        }

        @Test func stopWaitsForASinkCallInFlightAndNothingFollowsIt() async throws {
            let inVideo = OSAllocatedUnfairLock(initialState: false)
            let release = DispatchSemaphore(value: 0)
            let h = try PlayFXHarness()
            h.sink.onVideo = { index in
                guard index == 0 else { return }
                inVideo.withLock { $0 = true }
                release.wait()
            }
            #expect(await waitUntil { inVideo.withLock { $0 } })
            let returned = OSAllocatedUnfairLock(initialState: false)
            Thread {
                h.engine.stop()
                returned.withLock { $0 = true }
            }.start()
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(!returned.withLock { $0 })   // the video call is still running: stop waits for it
            release.signal()
            #expect(await waitUntil { returned.withLock { $0 } })
            #expect(h.sink.quits == ["quit stopped false Stopped"] && h.sink.labels.last == h.sink.quits[0])
            #expect(h.sink.state.withLock { $0.callsAfterQuit } == 0)
            let calls = h.sink.order.count
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(h.sink.order.count == calls)
        }

        @Test func stopWhileStillConnectingEndsTheAttempt() async throws {
            let console = try StreamConsole(initReplies: { _ in .hang })
            let h = try PlayFXHarness(console: console)
            try await Task.sleep(nanoseconds: 150_000_000)
            let started = Date()
            h.engine.stop()
            #expect(Date().timeIntervalSince(started) < 5)
            #expect(h.sink.labels == ["quit stopped false Stopped"])
        }

        @Test func releasingTheStreamSessionStopsThePlayFXEngine() async throws {
            let console = try StreamConsole()
            var options = CoreSession.Options()
            options.audio = false
            var credentials = fakeCredentials()
            credentials.registKey = Data(SessionVector.registKey).base64EncodedString()
            credentials.rpKey = Data(SessionVector.rpKey).base64EncodedString()
            let seen = LockedLines()
            var session: CoreSession? = try CoreSession(
                credentials: credentials, options: options,
                engine: PlayFXEngine.factory(start: { _, target, regist, rp, settings, options, events in
                    try await PlayFXLibrarySession.start(
                        environment: loopbackStreamEnvironment(console), address: "127.0.0.1", target: target,
                        registKey: regist, rpKey: rp, settings: settings, transport: .bsd, options: options, events: events)
                }))
            session?.onEvent = { seen.append(label($0)) }
            #expect(await waitUntil { seen.lines.contains("connected") })
            // The decoder can't use the fake console's frames, so the engine is told and asks for a key frame.
            #expect(await waitUntil { (session?.stats.decodeErrors ?? 0) > 0 })
            #expect(await waitUntil { console.received(channel: 2).contains(hex("0819")) })
            session = nil   // deinit stops the engine, which delivers its quit before it returns
            #expect(seen.lines.last == "quit stopped false Stopped")
            #expect(seen.lines.filter { $0.hasPrefix("quit") }.count == 1)
            console.stop()
        }

        @Test func commandsAfterStopDoNothing() async throws {
            let h = try PlayFXHarness()
            h.console.streams = false
            #expect(await h.connect())
            h.engine.stop()
            h.engine.setController(CoreController())
            h.engine.setLoginPin("1")
            h.engine.setMicrophone(true)
            [Int16](repeating: 0, count: 960).withUnsafeBufferPointer { h.engine.sendMicrophoneFrame($0) }
            h.engine.setKeyboardText("x")
            h.engine.finishKeyboard(accept: true)
            h.engine.requestKeyFrame()
            h.engine.goToBed()
            #expect(h.engine.stats() == StreamEngineStats())
            try await Task.sleep(nanoseconds: 200_000_000)
            #expect(h.console.received(channel: 2).isEmpty)
            let types = h.console.ctrlPeer?.received.with { $0.map(\.type) } ?? []
            #expect(!types.contains(0x50) && !types.contains(0x23) && !types.contains(0x30))
        }

        @Test func commandsAreIgnoredOnceStoppedEvenWithTheLibraryStillRunning() async throws {
            let h = try PlayFXHarness()
            h.console.streams = false
            #expect(await h.connect())
            let peer = try #require(h.console.ctrlPeer)
            let before = (peer.received.with { $0.count }, h.console.historyPackets().count)
            // The engine is marked stopped but its library session still runs: only the engine's own guards are left.
            h.engine.locked { $0.stopCalled = true }
            var state = CoreController()
            state.buttons = 1 << 3
            h.engine.setController(state)
            h.engine.setLoginPin("1")
            h.engine.setMicrophone(true)
            [Int16](repeating: 100, count: 960).withUnsafeBufferPointer { h.engine.sendMicrophoneFrame($0) }
            h.engine.setKeyboardText("x")
            h.engine.finishKeyboard(accept: true)
            h.engine.requestKeyFrame()
            h.engine.goToBed()
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(h.console.received(channel: 2).isEmpty && h.console.streamConsole.packets(ofType: 3).isEmpty)
            #expect(peer.received.with { $0.count } == before.0)   // no ctrl message of any kind
            #expect(h.console.historyPackets().count == before.1)
            h.engine.locked { $0.stopCalled = false }
            h.engine.stop()
        }
    }
}
