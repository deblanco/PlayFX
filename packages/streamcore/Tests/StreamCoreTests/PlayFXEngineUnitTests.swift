import COpus
import Foundation
import os
import Testing
@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport
@testable import StreamCore

/// The PlayFX engine's pieces on their own: the haptic-to-rumble rule, the controller mapping, the settings, how a
/// library end maps to a quit, the sink gate, the Opus wrappers, and choosing the engine.
@Suite struct PlayFXEngineUnitTests {
    // MARK: Haptic rumble

    private func frame(_ left: Int16, _ right: Int16, pairs: Int = 30) -> [Int16] { (0..<pairs).flatMap { _ in [left, right] } }

    private func process(_ rumble: inout PlayFXHapticRumble, _ samples: [Int16], at micros: UInt64) -> [UInt8]? {
        samples.withUnsafeBufferPointer { rumble.process($0, nowMicros: micros) }.map { [$0.left, $0.right] }
    }

    @Test func rumbleFollowsEachChannelsLoudnessAndRepeatsEvery50ms() {
        var rumble = PlayFXHapticRumble()
        #expect(process(&rumble, frame(0, 0), at: 1_000_000) == nil)            // silence at the start: nothing
        let loud = process(&rumble, frame(12000, 0), at: 1_010_000)
        #expect(loud?[0] ?? 0 > 0 && loud?[1] == 0)
        #expect(process(&rumble, frame(12000, 0), at: 1_020_000) == nil)        // unchanged, too soon
        #expect(process(&rumble, frame(12000, 0), at: 1_059_000) == nil)
        #expect(process(&rumble, frame(12000, 0), at: 1_060_000) == loud)        // 50 ms since the last one: repeated
        #expect(process(&rumble, frame(12000, 0), at: 1_070_000) == nil)
        let both = process(&rumble, frame(-30000, 30000), at: 1_071_000)         // a change goes out at once
        #expect(both?[0] == both?[1] && both?[0] ?? 0 > loud?[0] ?? 0)
        #expect(process(&rumble, frame(0, 0), at: 1_072_000) == [0, 0])          // the end of the effect
        #expect(process(&rumble, frame(0, 0), at: 1_200_000) == nil)             // silence is never repeated
        #expect(process(&rumble, frame(12000, 0), at: 1_210_000) == loud)
        rumble.reset()
        #expect(process(&rumble, frame(12000, 0), at: 1_211_000) == loud)        // afresh: sent again
    }

    @Test func rumbleStrengthRisesWithLoudnessFromTheGateToFullScale() {
        func strength(_ amplitude: Int16) -> UInt8 {
            PlayFXHapticRumble.strength(sumOfSquares: Float(amplitude) * Float(amplitude) * 30, count: 30)
        }
        #expect(strength(0) == 0 && strength(20) == 0)   // near-silence
        #expect(strength(140) > 0)                        // just over the gate (0.004 of full scale)
        var last: UInt8 = 0
        for amplitude in stride(from: 200, through: 23170, by: 400) {
            let now = strength(Int16(amplitude))
            #expect(now >= last)
            last = now
        }
        #expect(strength(23170) == 255 && strength(32767) == 255)   // a full-scale sine's RMS, and more, saturate
        // The levels are coarse (64 of them) so a wobble isn't an event each frame.
        #expect(Set((1...300).map { strength(Int16($0 * 100)) }).count <= 64)
    }

    @Test func rumbleIgnoresAnEmptyFrame() {
        var rumble = PlayFXHapticRumble()
        #expect([Int16]().withUnsafeBufferPointer { rumble.process($0, nowMicros: 1) } == nil)
        #expect([Int16(5)].withUnsafeBufferPointer { rumble.process($0, nowMicros: 1) } == nil)   // not a whole pair
    }

    // MARK: Controller mapping

    @Test func theControllerMapsToTheLibrarysStateAndKeepsEachFingerInItsSlot() {
        var input = PlayFXInput()
        #expect(input.latest == nil)
        var state = CoreController()
        state.buttons = 0xFFFF
        state.l2 = 9
        state.r2 = 10
        (state.leftX, state.leftY, state.rightX, state.rightY) = (1, -2, 3, -4)
        let mapped = input.map(state)
        #expect(mapped.buttons == [.cross, .circle, .square, .triangle, .dpadLeft, .dpadRight, .dpadUp, .dpadDown, .l1, .r1, .l3, .r3, .options, .share, .touchpad, .ps])
        #expect(mapped.l2 == 9 && mapped.r2 == 10 && mapped.leftStickX == 1 && mapped.leftStickY == -2 && mapped.rightStickX == 3 && mapped.rightStickY == -4)
        // No motion: the pad at rest, upright.
        #expect(mapped.gyro == .zero && mapped.accelerometer == SIMD3(0, 1, 0) && mapped.orientation == .identity && mapped.touches == [nil, nil])
        #expect(input.latest == mapped)

        // Fingers: ids keep their slot; positions scale to the touchpad's 12-bit range, out-of-range values clamp.
        state.touches = [CoreController.Touch(id: 3, x: 1, y: 1), CoreController.Touch(id: 0x85, x: -1, y: .nan)]
        var touches = input.map(state).touches
        #expect(touches == [TouchPoint(id: 3, x: 1919, y: 1079), TouchPoint(id: 5, x: 0, y: 0)])   // 0x85 counts as 5
        state.touches = [CoreController.Touch(id: 5, x: 0.5, y: 0.5)]   // the first finger lifts
        touches = input.map(state).touches
        #expect(touches == [nil, TouchPoint(id: 5, x: 960, y: 540)])
        state.touches = [CoreController.Touch(id: 5, x: 0.5, y: 0.5), CoreController.Touch(id: 9, x: 0, y: 0), CoreController.Touch(id: 10, x: 0, y: 0)]
        touches = input.map(state).touches
        #expect(touches == [TouchPoint(id: 9, x: 0, y: 0), TouchPoint(id: 5, x: 960, y: 540)])   // a third finger is ignored
        state.touches = []
        #expect(input.map(state).touches == [nil, nil])
    }

    @Test func motionBecomesAnOrientationAndAResetMakesItTheOrigin() {
        var input = PlayFXInput()
        var state = CoreController()
        for n in 0..<40 {
            state.motion = CoreController.Motion(gyro: [0, 0, 2], accel: [0, 1, 0], timestampMicros: UInt32(n) * 4000)
            _ = input.map(state)
        }
        let turned = input.latest!
        #expect(turned.gyro == [0, 0, 2] && turned.accelerometer == [0, 1, 0] && turned.motionTimestamp == 39 * 4000)
        #expect(turned.orientation != .identity)
        input.resetMotion()
        state.motion = CoreController.Motion(gyro: [0, 0, 0], accel: [0, 1, 0], timestampMicros: 40 * 4000)
        let q = input.map(state).orientation
        #expect(abs(q.w) > 0.999)
    }

    // MARK: Settings

    private func config(height: Int = 1080, fps: Int = 60, codec: StreamEngineConfig.Codec = .hevc, bitrate: Int = 0,
                        ps5: Bool = true, downgrade: Bool = true) -> StreamEngineConfig {
        var config = PlayFXHarness.config(ps5: ps5, codec: codec)
        (config.height, config.fps, config.bitrateKbps, config.autoDowngrade) = (height, fps, bitrate, downgrade)
        return config
    }

    @Test func theSettingsFollowTheConfig() {
        func resolution(_ height: Int) -> StreamResolution { PlayFXEngine.settings(for: config(height: height)).resolution }
        #expect([100, 360, 400, 540, 719, 720, 900, 1080, 2160].map(resolution) == [.p360, .p360, .p360, .p540, .p540, .p720, .p720, .p1080, .p1080])
        func rate(_ fps: Int) -> StreamFrameRate { PlayFXEngine.settings(for: config(fps: fps)).frameRate }
        #expect([0, 30, 59, 60, 120].map(rate) == [.fps30, .fps30, .fps30, .fps60, .fps60])
        func codec(_ codec: StreamEngineConfig.Codec, ps5: Bool = true) -> StreamCodec {
            PlayFXEngine.settings(for: config(codec: codec, ps5: ps5)).codec
        }
        #expect(codec(.h264) == .h264 && codec(.hevc) == .hevc && codec(.hevcHDR) == .hevcHDR)
        #expect(codec(.hevc, ps5: false) == .h264 && codec(.hevcHDR, ps5: false) == .h264)   // a PS4 streams H.264
        // 0 asks for the library's preset for the resolution; anything else is the app's number.
        #expect(PlayFXEngine.settings(for: config(bitrate: 0)).bitrate == .preset)
        #expect(PlayFXEngine.settings(for: config(bitrate: 8000)).bitrate == .kbps(8000))
        let presets = [360, 540, 720, 1080].map { PlayFXEngine.settings(for: config(height: $0)).launchRequest(target: .ps5v1, model: .ps5).bitrateKbps }
        #expect(presets == [2000, 6000, 10000, 15000])
        #expect(PlayFXEngine.settings(for: config(downgrade: false)).autoDowngrade == false)
        #expect(PlayFXEngine.settings(for: config(downgrade: true)).autoDowngrade == true)
    }

    // MARK: Quits

    @Test func theLibrarysEndsMapToQuitKinds() {
        func quit(_ code: StreamEndCode, text: String? = nil) -> PlayFXEngine.Quit {
            PlayFXEngine.quit(for: StreamEndReason(code: code, remoteText: text), console: .ps5)
        }
        #expect(quit(.stoppedByClient) == .init(reason: "The stream was stopped.", error: false, kind: .stopped))
        #expect(quit(.consoleBusy).kind == .busy && quit(.consoleBusy).error)
        #expect(quit(.streamFailed).kind == .dropped && quit(.ctrlFailed).kind == .dropped && quit(.streamFailed).error)
        for code in [StreamEndCode.unknown, .sessionInitUnknown, .sessionInitRefused, .remotePlayCrashed, .versionMismatch, .ctrlConnectFailed, .ctrlRefused, .streamRemoteDisconnected, .psnRegistrationFailed] {
            #expect(quit(code).kind == .final)
        }
        #expect(quit(.streamRemoteShutdown).kind == .final && !quit(.streamRemoteShutdown).error)
        #expect(quit(.streamRemoteDisconnected, text: "Another device").reason.hasSuffix("(Another device)"))
        #expect(PlayFXEngine.quit(for: StreamEndReason(consoleDisconnect: "Server shutting down"), console: .ps4).reason.contains("PS4"))
    }

    @Test func aFailedStartMapsToBusyFinalOrStopped() {
        func quit(_ error: Error) -> PlayFXEngine.Quit { PlayFXEngine.quit(forStartFailure: error, console: .ps5) }
        #expect(quit(StreamStartError.session(.consoleBusy, stage: .sessionInit)).kind == .busy)
        #expect(quit(StreamStartError.session(.noAnswer(.connectionRefused), stage: .sessionInit)) .kind == .final)
        // A connection that was never made isn't "dropped", even where the library calls its end that.
        let failed = quit(StreamStartError.stream(StreamEndReason(code: .streamFailed), detail: "no HelloReply"))
        #expect(failed.kind == .final && failed.error)
        #expect(quit(StreamStartError.cancelled) == .init(reason: "Stopped", error: false, kind: .stopped))
        let other = quit(ConsoleError.message("boom"))
        #expect(other.kind == .final && other.error && other.reason.contains("boom"))
    }

    // MARK: The sink gate

    @Test func theGateStopsCallsAfterClosingAndQuitComesOnce() {
        let gate = PlayFXSinkGate()
        #expect(!gate.isInsideCall && gate.enter() && gate.isInsideCall)
        gate.leave()
        #expect(!gate.isInsideCall)
        #expect(gate.enterForQuit())          // the quit's call
        #expect(!gate.enter() && !gate.enterForQuit() && !gate.claimQuit())   // nothing else once it's claimed
        gate.leave()

        let closed = PlayFXSinkGate()
        closed.close()
        #expect(!closed.enter() && !closed.enterForQuit())
        #expect(closed.claimQuit() && !closed.claimQuit())   // `stop()` takes the quit when no one has
    }

    @Test func theGateWaitsForOtherThreadsCallsButNotItsOwn() {
        let gate = PlayFXSinkGate()
        #expect(gate.enter())            // this thread is inside a call: waiting must not wait for it
        gate.waitForOtherCalls()
        gate.leave()

        let inCall = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        Thread {
            _ = gate.enter()
            inCall.signal()
            release.wait()
            gate.leave()
        }.start()
        inCall.wait()
        let waiting = OSAllocatedUnfairLock(initialState: true)
        let done = DispatchSemaphore(value: 0)
        Thread {
            gate.waitForOtherCalls()
            waiting.withLock { $0 = false }
            done.signal()
        }.start()
        Thread.sleep(forTimeInterval: 0.1)
        #expect(waiting.withLock { $0 })      // the other thread's call is still running
        release.signal()
        #expect(done.wait(timeout: .now() + 5) == .success)
    }

    // MARK: Opus

    @Test func theDecoderRefusesHeadersLibopusCantDecode() {
        func header(channels: Int = 2, rate: Int = 48000, frameSize: Int = 480) -> AudioHeader {
            AudioHeader(channels: channels, bitsPerSample: 16, sampleRate: rate, frameSize: frameSize)
        }
        #expect(PlayFXOpusPlayback(header(channels: 0)) == nil && PlayFXOpusPlayback(header(channels: 6)) == nil)
        #expect(PlayFXOpusPlayback(header(rate: 44100)) == nil && PlayFXOpusPlayback(header(rate: 0)) == nil)
        let ok = PlayFXOpusPlayback(header())
        #expect(ok?.channels == 2 && ok?.sampleRate == 48000 && ok?.concealFrames == 480)
        // A frame size that isn't a multiple of 2.5 ms (or is absent) conceals 10 ms.
        #expect(PlayFXOpusPlayback(header(frameSize: 481))?.concealFrames == 480)
        #expect(PlayFXOpusPlayback(header(frameSize: 0))?.concealFrames == 480)
        #expect(PlayFXOpusPlayback(header(frameSize: 100_000))?.concealFrames == 480)
        #expect(PlayFXOpusPlayback(header(frameSize: 960))?.concealFrames == 960)
        let mono = PlayFXOpusPlayback(header(channels: 1, rate: 16000, frameSize: 160))
        #expect(mono?.channels == 1 && mono?.concealFrames == 160)
    }

    @Test func theDecoderDecodesConcealsAndResetsAndRefusesJunk() throws {
        let decoder = try #require(PlayFXOpusPlayback(AudioHeader(channels: 2, bitsPerSample: 16, sampleRate: 48000, frameSize: 480)))
        let packet = try #require(opusTone(first: 0, frames: 1)[0])
        let decoded = packet.withUnsafeBytes { decoder.decode($0) }
        #expect(decoded?.frames == 480)
        #expect(decoder.conceal()?.frames == 480)
        decoder.reset()
        #expect([UInt8]().withUnsafeBytes { decoder.decode($0) } == nil)             // nothing to decode
        #expect([UInt8(0x03), 0].withUnsafeBytes { decoder.decode($0) } == nil)     // not a packet libopus accepts
        // The same packet again after a reset decodes as it did at the start.
        let again = packet.withUnsafeBytes { decoder.decode($0) }
        #expect(again.map { Array(UnsafeBufferPointer(start: $0.samples, count: 960)) } == decoded.map { _ in referenceDecode([packet])[0] })
    }

    @Test func theMicrophoneEncoderMakesFortyBytePacketsOnlyForAWholeFrame() throws {
        let encoder = try #require(PlayFXOpusMicrophone())
        let silence = [Int16](repeating: 0, count: 960)
        let packet = silence.withUnsafeBufferPointer { encoder.encode($0) }
        #expect(packet?.count == 40 && packet?[0] == 0xf4)   // CELT-only, 10 ms, stereo, one frame (av.md V-AV13)
        #expect([Int16](repeating: 0, count: 959).withUnsafeBufferPointer { encoder.encode($0) } == nil)
        #expect([Int16]().withUnsafeBufferPointer { encoder.encode($0) } == nil)
        let noise = (0..<960).map { _ in Int16.random(in: .min ... .max) }
        #expect(noise.withUnsafeBufferPointer { encoder.encode($0) }?.count == 40)   // constant bit rate
    }

    // MARK: The receive thread's buffer

    @Test func theKeyFrameBufferGrowsForALargerFrameAndIsReused() {
        let state = PlayFXReceiveState()
        state.parameterSets = [1, 2, 3]
        let small = [UInt8](repeating: 7, count: 10)
        let first = small.withUnsafeBytes { Array(state.joinedUnit($0)) }
        #expect(first == [1, 2, 3] + small)
        let large = [UInt8](repeating: 9, count: 5000)
        #expect(large.withUnsafeBytes { Array(state.joinedUnit($0)) } == [1, 2, 3] + large)
        #expect(small.withUnsafeBytes { Array(state.joinedUnit($0)) } == first)
        #expect(UnsafeRawBufferPointer(start: nil, count: 0).withMemoryRebound(to: UInt8.self) { Array(state.joinedUnit(UnsafeRawBufferPointer($0))) } == [1, 2, 3])
    }

    // MARK: Choosing the engine

    @Test func optionsDecodeTheEngineWithTheChiakiDefault() throws {
        func decode(_ json: String, environment: [String: String] = [:]) throws -> CoreSession.Options {
            let decoder = JSONDecoder()
            decoder.userInfo[CoreSession.Options.environmentKey] = environment
            return try decoder.decode(CoreSession.Options.self, from: Data(json.utf8))
        }
        // PLAYFX_ENGINE (dev only, temporary) is the default for JSON that doesn't name an engine.
        #expect(try decode("{}", environment: ["PLAYFX_ENGINE": "playfx"]).engine == "playfx")
        #expect(try decode(#"{"fps":30}"#, environment: ["PLAYFX_ENGINE": "playfx"]).engine == "playfx")
        #expect(try decode("{}", environment: ["PLAYFX_ENGINE": "chiaki"]).engine == "chiaki")
        #expect(try decode("{}", environment: ["PLAYFX_ENGINE": "nonsense"]).engine == "chiaki")
        #expect(try decode(#"{"engine":"chiaki"}"#, environment: ["PLAYFX_ENGINE": "playfx"]).engine == "chiaki")
        #expect(try decode(#"{"engine":"playfx"}"#, environment: ["PLAYFX_ENGINE": "chiaki"]).engine == "playfx")
        #expect(CoreSession.Options.defaultEngine(environment: [:]) == "chiaki")
        // Without an injected environment the process's is read; the choice is one of the two.
        let real = try JSONDecoder().decode(CoreSession.Options.self, from: Data("{}".utf8))
        #expect(real.engine == "chiaki" || real.engine == "playfx")
        #expect(CoreSession.Options().engine == "chiaki")
        #expect(try decode("{}").engine == "chiaki")
        #expect(try decode(#"{"height":720}"#).engine == "chiaki")   // an older host's JSON
        #expect(try decode(#"{"engine":"playfx","fps":30}"#).engine == "playfx")
        var options = CoreSession.Options()
        options.engine = "playfx"
        let again = try JSONDecoder().decode(CoreSession.Options.self, from: JSONEncoder().encode(options))
        #expect(again.engine == "playfx")
    }

    @Test func thePlayFXEngineIsChosenByNameForTheLocalNetworkAndTheInternet() {
        var options = CoreSession.Options()
        #expect(!CoreSession.usesPlayFX(options))
        options.engine = "playfx"
        #expect(CoreSession.usesPlayFX(options))
        options.engine = "something else"
        #expect(!CoreSession.usesPlayFX(options))
    }
}

extension Serial {
    @Suite struct PlayFXEngineSelectionTests {
        /// The public initialiser with `engine: "playfx"` starts the PlayFX engine: on an unused loopback port it is
        /// refused at once, as PlayFXProtocol reports it (final, an error), and a stop after that adds nothing.
        @Test func thePublicInitialiserStartsThePlayFXEngine() async throws {
            var options = CoreSession.Options()
            options.engine = "playfx"
            options.audio = false
            let session = try CoreSession(credentials: fakeCredentials(address: "127.0.0.1"), options: options)
            let seen = LockedLines()
            session.onEvent = { seen.append(label($0)) }
            #expect(await waitUntil { !seen.lines.isEmpty })
            #expect(seen.lines.count == 1 && seen.lines[0].hasPrefix("quit final true "))
            session.stop()
            #expect(seen.lines.count == 1)
        }
    }
}
