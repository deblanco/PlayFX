import CoreMedia
import Foundation
import os
import Testing
@testable import StreamCore

/// A short name for an event, to compare sequences of them.
func label(_ event: StreamSession.Event) -> String {
    switch event {
    case .connected: "connected"
    case .remoteProgress(let stage): "progress \(stage.rawValue)"
    case .quit(let reason, let error, let kind): "quit \(kind.rawValue) \(error) \(reason)"
    case .loginPinRequested(let incorrect): "pin \(incorrect)"
    case .rumble(let left, let right): "rumble \(left) \(right)"
    case .hapticRumble(let left, let right): "haptic rumble \(left) \(right)"
    case .triggerEffects(let left, let right): "triggers \(left) \(right)"
    case .light(let red, let green, let blue): "light \(red) \(green) \(blue)"
    case .playerIndex(let index): "player \(index)"
    case .nickname(let name): "nickname \(name)"
    case .keyboard(let change, let text): "keyboard \(change.rawValue) \(text)"
    }
}

extension Serial {
    /// StreamSession on a stand-in engine: what crosses the seam, both ways.
    @Suite struct StreamSessionEngineTests {
        @Test func buildsTheEngineConfigFromTheCredentialsAndOptions() throws {
            var options = StreamSession.Options()
            options.height = 720
            options.fps = 30
            options.bitrate = 5000
            options.autoDowngrade = false
            options.hdr = true
            let remote = StreamSession.Remote(token: "token", duid: String(repeating: "ab", count: 32))
            let credentials = fakeCredentials(address: "192.0.2.7")
            let (session, engine) = try FakeStreamEngine.session(credentials: credentials, options: options, remote: remote)
            defer { session.stop() }
            let c = engine.config
            #expect(c.host == "192.0.2.7" && c.ps5 && c.height == 720 && c.fps == 30 && c.bitrateKbps == 5000 && !c.autoDowngrade)
            #expect(c.registKey == Data(base64Encoded: credentials.registKey) && c.registKey.count == StreamEngineConfig.registKeySize)
            #expect(c.rpKey == Data(base64Encoded: credentials.rpKey) && c.accountID == Data(base64Encoded: credentials.accountId))
            #expect(c.codec == .hevcHDR && c.remote?.token == "token" && c.remote?.duid == remote.duid)
        }

        @Test func asksForTheCodecTheConsoleAndOptionsAllow() throws {
            func codec(ps5: Bool, hevc: Bool, hdr: Bool) throws -> StreamEngineConfig.Codec {
                var credentials = fakeCredentials()
                credentials.ps5 = ps5
                var options = StreamSession.Options()
                options.hevc = hevc
                options.hdr = hdr
                let (session, engine) = try FakeStreamEngine.session(credentials: credentials, options: options)
                session.stop()
                #expect(engine.config.remote == nil)
                return engine.config.codec
            }
            #expect(try codec(ps5: true, hevc: true, hdr: false) == .hevc)
            #expect(try codec(ps5: true, hevc: true, hdr: true) == .hevcHDR)
            #expect(try codec(ps5: true, hevc: false, hdr: true) == .h264) // HDR needs HEVC
            #expect(try codec(ps5: false, hevc: true, hdr: true) == .h264) // a PS4 only streams H.264
        }

        @Test func anEngineThatCantStartFailsTheSession() {
            #expect(throws: ConsoleError.message("No thread")) {
                try StreamSession(credentials: fakeCredentials()) { _, _ in throw ConsoleError.message("No thread") }
            }
            var started = false
            var broken = fakeCredentials()
            broken.rpKey = "AAAA"
            #expect(throws: ConsoleError.message("Invalid console credentials")) {
                try StreamSession(credentials: broken) { config, sink in
                    started = true
                    return FakeStreamEngine(config: config, sink: sink)
                }
            }
            #expect(!started) // malformed keys never reach an engine
        }

        @Test func eventsReachTheHandlerInOrderEvenBeforeItIsSet() throws {
            let (session, engine) = try FakeStreamEngine.session()
            defer { session.stop() }
            engine.send(.remoteProgress(.linking)) // e.g. internet setup, right as the engine starts
            let seen = LockedLines()
            session.onEvent = { seen.append(label($0)) }
            engine.send(.loginPinRequested(incorrect: false))
            engine.send(.connected)
            engine.sendTriggerEffects(0x01, [0, 255], 0x05, []) // simple feedback from the start, full strength; off
            engine.send(.hapticRumble(left: 40, right: 7))
            engine.send(.keyboard(.open, text: "hi"))
            #expect(seen.lines == [
                "progress linking", "pin false", "connected",
                "triggers \(TriggerEffect.feedback([Float](repeating: 1, count: 10))) \(TriggerEffect.off)",
                "haptic rumble 40 7", "keyboard open hi",
            ])
        }

        @Test func videoGoesToTheDecoderAndStatsAddTheEnginesFigures() throws {
            var options = StreamSession.Options()
            options.audio = false
            options.hevc = false
            let (session, engine) = try FakeStreamEngine.session(options: options)
            defer { session.stop() }
            let indices = OSAllocatedUnfairLock(initialState: [UInt64]())
            session.onVideoSample = { index, _ in indices.withLock { $0.append(index) } }

            let encoded = try encodeFrames(codec: kCMVideoCodecType_H264, count: 3)
            #expect(engine.sendVideo(encoded[0].annexB) == true)
            #expect(engine.sendVideo(encoded[1].annexB, framesLost: 1) == true)
            #expect(engine.sendVideo(encoded[2].annexB) == true)
            // Rejected: the engine is told to ask for a key frame.
            #expect(engine.sendVideo(Data([0, 0, 0, 1, 0x67, 0xFF])) == false)
            session.waitForDecodedFrames()
            engine.report(StreamEngineStats(
                rttMicros: 2500, targetBitrate: 15_000_999,
                reorder: .init(waitMicros: 7500, holesFilled: 1, latePackets: 2, holesLost: 3, queueFullSkips: 4)))

            let stats = session.stats
            #expect(stats.framesDecoded == 3 && stats.framesLost == 1 && stats.decodeErrors == 1 && stats.width == 320)
            #expect(stats.rttMs == 2.5 && stats.targetBitrateKbps == 15_000 && stats.reorderWaitMs == 7.5)
            #expect(stats.reorderHolesFilled == 1 && stats.reorderLatePackets == 2 && stats.reorderHolesLost == 3
                && stats.reorderQueueFull == 4)
            #expect(indices.withLock { $0 } == [1, 3, 4, 5]) // the lost frame keeps its place
            // Audio with sound off goes nowhere.
            #expect(engine.sendAudio(channels: 2, rate: 48000, [Int16](repeating: 0, count: 960)) == true)

            session.stop()
            let after = session.stats
            #expect(after.rttMs == 0 && after.targetBitrateKbps == 0 && after.reorderWaitMs == 0) // no engine any more
            #expect(after.framesDecoded == 3) // the session's own counts stay
        }

        @Test func hapticsWithoutAPadComeBackForTheEngineToRumble() throws {
            let (session, engine) = try FakeStreamEngine.session()
            defer { session.stop() }
            // A test run sees no pad: not played, so the engine makes rumble from it.
            #expect(engine.sendHaptics([Int16](repeating: 1000, count: 60)) == false)
        }

        @Test func hapticsPlayOnAUSBPad() async throws {
            let (realDevices, realOpen) = (DualSenseHaptics.devices, DualSenseHaptics.open)
            defer { (DualSenseHaptics.devices, DualSenseHaptics.open) = (realDevices, realOpen) }
            let pad = DualSenseHaptics.Device(id: 7, name: "DualSense Wireless Controller", outputChannels: 4)
            let opened = OSAllocatedUnfairLock<[DualSenseHapticsTests.StandInOutput]>(initialState: [])
            DualSenseHaptics.devices = { [pad] }
            DualSenseHaptics.open = { _, _ in
                let output = DualSenseHapticsTests.StandInOutput()
                opened.withLock { $0.append(output) }
                return output
            }
            let (session, engine) = try FakeStreamEngine.session()
            defer { session.stop() }
            let frame = [Int16](repeating: 1000, count: 60)
            // The pad is found off the receive thread: once it's open, frames are played (no rumble needed).
            #expect(await waitUntil(timeout: 5) { engine.sendHaptics(frame) == true })
            session.stop()
            #expect(opened.withLock { $0.count == 1 && $0.allSatisfy { $0.stopped.withLock { $0 } } }) // stops with the session
            #expect(engine.sendHaptics(frame) == nil) // nothing reaches the session after stop
        }

        @Test func theControllerAndThePointerReachTheEngineMerged() throws {
            let (session, engine) = try FakeStreamEngine.session()
            defer { session.stop() }
            var pad = ControllerState()
            pad.buttons = ControllerState.buttonNames["cross"] ?? 0
            pad.touches = [ControllerState.Touch(id: 5, x: 0.9, y: 0.9), ControllerState.Touch(id: 6, x: 0.1, y: 0.1)]
            pad.motion = ControllerState.Motion(gyro: [0.1, 0, 0], accel: [0, -1, 0], timestampMicros: 4000)
            session.setController(pad)
            let finger = ControllerState.Touch(id: 9, x: 0.5, y: 0.5)
            session.setPointerTouch(StreamSession.PointerTouch(touch: finger, pressed: true))
            session.setPointerTouch(.none)
            var merged = pad
            merged.touches = [finger, pad.touches[0]] // the pointer first, two fingers at most
            merged.buttons |= ControllerState.touchpadButton
            #expect(engine.commands == [.controller(pad), .controller(merged), .controller(pad)])
        }

        @Test func commandsReachTheEngine() async throws {
            let (session, engine) = try FakeStreamEngine.session()
            defer { session.stop() }
            session.setLoginPin("1234")
            session.setKeyboardText("hello")
            session.finishKeyboard(accept: true)
            session.finishKeyboard(accept: false)
            session.requestKeyframe()
            session.sleepConsole()
            // This test runner can't ask for the microphone: turning it on reports so and never reaches the engine.
            let on = await withCheckedContinuation { done in session.setMicrophone(true) { done.resume(returning: $0) } }
            let off = await withCheckedContinuation { done in session.setMicrophone(false) { done.resume(returning: $0) } }
            #expect(on == .unavailable && off == .off)
            #expect(engine.commands == [.loginPin("1234"), .keyboardText("hello"), .keyboardDone(accept: true),
                                        .keyboardDone(accept: false), .keyFrame, .goToBed, .microphone(false)])
        }

        @Test func stopEndsTheEngineOnceAndNothingCrossesAfter() async throws {
            let (session, engine) = try FakeStreamEngine.session()
            let seen = LockedLines()
            session.onEvent = { seen.append(label($0)) }
            session.stop()
            #expect(seen.lines == ["quit stopped false Stopped"]) // delivered before stop returned
            session.stop()
            session.setController(ControllerState())
            session.setPointerTouch(StreamSession.PointerTouch(touch: nil, pressed: true))
            session.setLoginPin("1")
            session.setKeyboardText("x")
            session.finishKeyboard(accept: true)
            session.requestKeyframe()
            session.sleepConsole()
            let mic = await withCheckedContinuation { done in session.setMicrophone(true) { done.resume(returning: $0) } }
            #expect(mic == .off)
            #expect(engine.commands == [.stop]) // once, and nothing after it
            #expect(engine.sendVideo(Data([0, 0, 0, 1, 0x65])) == nil && engine.send(.connected) == nil)
            #expect(seen.lines.count == 1)
        }

        @Test func aQuitFromTheConsoleIsntRepeatedByStop() throws {
            let (session, engine) = try FakeStreamEngine.session()
            let seen = LockedLines()
            session.onEvent = { seen.append(label($0)) }
            engine.send(.quit(reason: "Remote Play in use", error: true, kind: .busy))
            session.stop()
            #expect(seen.lines == ["quit busy true Remote Play in use"])
        }

        @Test func releasingTheSessionStopsItsEngine() throws {
            var engine: FakeStreamEngine?
            do {
                let (session, made) = try FakeStreamEngine.session()
                engine = made
                withExtendedLifetime(session) {}
            }
            #expect(engine?.isStopped == true && engine?.commands == [.stop])
        }
    }
}
