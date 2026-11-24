import COpus
import Foundation
import os
import Testing
@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport
@testable import StreamCore

/// The PlayFX engine's streams and commands against the fake console: game audio, haptics, what the console sends
/// besides, and what the app sends back.
extension Serial {
    @Suite struct PlayFXEngineStreamTests {
        // MARK: Game audio

        @Test func opusIsDecodedToPCMAndALostFrameConcealed() async throws {
            let h = try PlayFXHarness()
            h.console.streams = false
            #expect(await h.connect())
            let packets = opusTone(first: 98, frames: 17)   // frames 98 ... 114
            for frame in UInt16(100)...106 { h.sendAudio(frame: frame, packets: packets) }
            // Packets 107, 108 and 109 are lost, and the repeats of frame 107 with them: one frame to conceal.
            for frame in UInt16(110)...114 { h.sendAudio(frame: frame, packets: packets) }
            #expect(await waitUntil { h.sink.audio.count >= 17 })
            // The engine's PCM is what libopus makes of the same packets in order, the missing one concealed.
            var sent: [[UInt8]?] = (98...106).map { packets[UInt16($0)] }
            sent.append(nil)
            sent += (108...114).map { packets[UInt16($0)] }
            let reference = referenceDecode(sent)
            #expect(h.sink.audio == reference)
            #expect(h.sink.audio[9].contains { $0 != 0 })   // the concealment isn't silence
            #expect(h.sink.audio.allSatisfy { $0.count == 960 })
            #expect(h.sink.state.withLock { $0.audioFormats.count } == 1)
            let order = h.sink.order
            #expect(try #require(order.firstIndex(of: "audioFormat")) < (try #require(order.firstIndex(of: "audio"))))
            h.engine.stop()
        }

        @Test func aGapTooLongToConcealResetsTheDecoder() async throws {
            let h = try PlayFXHarness()
            h.console.streams = false
            #expect(await h.connect())
            let near = opusTone(first: 98, frames: 3)
            let far = opusTone(first: 298, frames: 3)
            for frame in UInt16(100)...100 { h.sendAudio(frame: frame, packets: near) }
            // The next packet is 200 frames on: 64 are concealed, the rest skipped, the decoder starts afresh.
            h.sendAudio(frame: 300, packets: far)
            #expect(await waitUntil { h.sink.audio.count >= 3 + 64 + 3 })
            let reference = referenceDecode([near[98], near[99], near[100]])
                + (0..<64).map { _ in [Int16]() }   // (the concealed ones are checked below)
            #expect(Array(h.sink.audio.prefix(3)) == Array(reference.prefix(3)))
            #expect(h.sink.audio[3..<67].allSatisfy { $0.count == 960 })
            let afterReset = referenceDecode([far[298], far[299], far[300]])
            #expect(Array(h.sink.audio.suffix(3)) == afterReset)
            h.engine.stop()
        }

        // MARK: Haptics

        @Test func hapticsTurnIntoRumbleWhenNoPadPlaysThem() async throws {
            let h = try PlayFXHarness()
            h.console.streams = false
            #expect(await h.connect())
            func frame(_ left: Int16, _ right: Int16) -> [Int16] { (0..<30).flatMap { _ in [left, right] } }
            let loud = PlayFXHapticRumble.strength(sumOfSquares: 10000 * 10000 * 30, count: 30)
            // Five frames of the same effect in a burst: one event, the left motor only.
            for n in 1...5 { h.sendHaptics(frame: UInt16(n), samples: frame(10000, 0)) }
            #expect(await waitUntil { h.sink.haptics.count == 5 })
            #expect(h.sink.hapticRumbles.count == 1 && h.sink.hapticRumbles[0] == (loud, 0) && loud > 0)
            // Unchanged and still coming, 60 ms later: repeated.
            try await Task.sleep(nanoseconds: 60_000_000)
            h.sendHaptics(frame: 6, samples: frame(10000, 0))
            #expect(await waitUntil { h.sink.hapticRumbles.count == 2 })
            #expect(h.sink.hapticRumbles[1] == (loud, 0))
            // A change is sent at once; silence ends it, and silence again says nothing.
            h.sendHaptics(frame: 7, samples: frame(0, -20000))
            h.sendHaptics(frame: 8, samples: frame(0, 0))
            h.sendHaptics(frame: 9, samples: frame(0, 0))
            #expect(await waitUntil { h.sink.haptics.count == 9 })
            let rumbles = h.sink.hapticRumbles
            #expect(rumbles.count == 4 && rumbles[2].0 == 0 && rumbles[2].1 > 0 && rumbles[3] == (0, 0))
            h.engine.stop()
            #expect(h.sink.labels.last == "quit stopped false Stopped")
        }

        @Test func hapticsPlayedOnAPadMakeNoRumbleAndTheNextRumbleStartsAfresh() async throws {
            let h = try PlayFXHarness()
            h.console.streams = false
            #expect(await h.connect())
            let session = try #require(h.librarySession.withLock { $0 })
            let loud = [Int16](repeating: 20000, count: 60)
            func inject(_ frame: UInt16) {
                loud.withUnsafeBufferPointer { h.engine.handle(.haptics(frameIndex: frame, samples: $0), session) }
            }
            inject(1)                      // no pad: rumble, and the engine is now in a non-zero rumble state
            #expect(h.sink.hapticRumbles.count == 1)
            h.sink.hapticsPlayed = true
            inject(2)
            inject(3)
            #expect(h.sink.hapticRumbles.count == 1 && h.sink.haptics.count == 3)   // played on the pad: nothing more
            // The pad goes away. Microseconds later (far under the 50 ms repeat), the same frame still rumbles: the
            // state was reset when a pad took over. Without that reset it would count as unchanged and wait.
            h.sink.hapticsPlayed = false
            inject(4)
            #expect(h.sink.hapticRumbles.count == 2)
            h.engine.stop()
        }

        // MARK: Everything else the console sends

        @Test func rumbleLightPlayerIndexTriggersAndQualityReachTheSink() async throws {
            let h = try PlayFXHarness()
            h.console.streams = false
            #expect(await h.connect())
            h.console.send(dataType: 7, SessionBytes.rumble)
            h.console.send(dataType: 11, SessionBytes.triggers)
            h.console.send(dataType: 9, SessionBytes.pad25)
            h.console.send(hex("08 10 8a 01 03 08 e8 07"))   // ConnectionQuality {targetBitrate 1000}
            #expect(await waitUntil { h.sink.labels.contains("player 1") && !h.sink.state.withLock { $0.triggers }.isEmpty })
            #expect(h.sink.labels == ["connected", "rumble 128 64", "light 255 116 166", "player 1"])
            let triggers = h.sink.state.withLock { $0.triggers }
            #expect(triggers.count == 1 && triggers[0].0 == 0x25 && triggers[0].1 == Array(1...10).map { UInt8($0) })
            #expect(triggers[0].2 == 0x26 && triggers[0].3 == Array(0x11...0x1a).map { UInt8($0) })
            #expect(await waitUntil { h.engine.stats().targetBitrate == 1000 })
            #expect(await waitUntil { h.engine.stats().rttMicros > 0 })
            h.engine.stop()
            #expect(h.engine.stats() == StreamEngineStats())
        }

        @Test func eachReorderFigureMapsToItsOwnLibraryField() async throws {
            let h = try PlayFXHarness(tweak: { $0.statsInterval = 1000 })   // only the statistics injected here
            h.console.streams = false
            #expect(await h.connect())
            let session = try #require(h.librarySession.withLock { $0 })
            var stats = StreamStats()
            stats.reorder = StreamReorderStats(
                waitMicros: 7500, holesFilled: 11, latePackets: 22, holesLost: 33, queueFullSkips: 44, timeoutSkips: 55,
                duplicates: 66)
            h.engine.handle(.stats(stats), session)
            #expect(h.engine.stats().reorder == StreamEngineStats.Reorder(
                waitMicros: 7500, holesFilled: 11, latePackets: 22, holesLost: 33, queueFullSkips: 44))
            #expect(h.engine.stats().rttMicros > 0)   // the probe's round trip stays
            h.engine.stop()
        }

        @Test func theConsolesPINRequestsAndKeyboardPassThrough() async throws {
            let opened = [UInt8](repeating: 0, count: 28) + be32(3) + Array("abc".utf8)
            let changed = be32(2) + be32(0) + be32(2) + [UInt8](repeating: 0, count: 24) + be32(2) + Array("ab".utf8)
            let console = try StreamConsole(ctrl: { peer in
                peer.sendHead()
                peer.send(0x04)
                _ = peer.receive()
                peer.send(0x05, [1])   // wrong: asked again
                peer.send(0x04)
                _ = peer.receive()
                peer.send(0x05, [0])
                peer.send(0x33, sessionIDPlain)
                peer.send(0x21, opened)
                peer.send(0x24, changed)
                peer.send(0x22, [0])
                peer.pump(limit: 30)
            })
            let h = try PlayFXHarness(console: console, onEvent: { event, engine in
                if case .loginPinRequested(let incorrect) = event { engine.setLoginPin(incorrect ? "2222" : "1111") }
            })
            #expect(await waitUntil { h.sink.labels.contains("keyboard close ") && h.sink.labels.contains("connected") })
            // The PIN requests come first; the keyboard events (from ctrl) and `connected` (from the stream) race.
            let labels = h.sink.labels
            #expect(Array(labels.prefix(2)) == ["pin false", "pin true"])
            #expect(labels.filter { $0.hasPrefix("keyboard") } == ["keyboard open abc", "keyboard change ab", "keyboard close "])
            #expect(labels.filter { $0 == "connected" }.count == 1)
            let peer = try #require(console.ctrlPeer)
            #expect(peer.received.with { $0.filter { $0.type == 0x8004 }.map(\.plain) } == [Array("1111".utf8), Array("2222".utf8)])
            // The app's side of the keyboard.
            h.engine.setKeyboardText("x")
            h.engine.finishKeyboard(accept: true)
            h.engine.finishKeyboard(accept: false)
            #expect(await waitUntil { peer.received.with { $0.filter { $0.type == 0x25 }.count } == 2 })
            let ctrl = peer.received.with { $0 }
            #expect(ctrl.contains { $0.type == 0x23 })
            #expect(ctrl.filter { $0.type == 0x25 }.map(\.plain) == [be32(0), be32(1)])
            // The PIN isn't asked for any more: a stray answer is dropped.
            let answers = peer.received.with { $0.filter { $0.type == 0x8004 }.count }
            h.engine.setLoginPin("3333")
            try await Task.sleep(nanoseconds: 150_000_000)
            #expect(peer.received.with { $0.filter { $0.type == 0x8004 }.count } == answers)
            h.engine.stop()
        }

        // MARK: What the app sends

        @Test func theControllerStateReachesTheConsole() async throws {
            let h = try PlayFXHarness()
            h.console.streams = false
            // Set before the stream is up: it goes out once it is.
            var early = CoreController()
            early.buttons = 1 << 0   // cross
            h.engine.setController(early)
            #expect(await h.connect())
            func bodies() -> [[UInt8]] { h.console.historyPackets().map(\.body) }
            #expect(await waitUntil { bodies().contains { $0.starts(with: hex("8088ff")) } })
            // Buttons, triggers, one finger (id 5, mid-pad), sticks and motion.
            var state = CoreController()
            state.buttons = (1 << 3) | (1 << 15)   // triangle, PS
            state.l2 = 200
            state.touches = [CoreController.Touch(id: 5, x: 0.5, y: 0.5)]
            state.leftX = 12345
            state.leftY = -32768
            state.motion = CoreController.Motion(gyro: [0.5, -1.25, 3.0], accel: [0.1, 0.95, -0.2], timestampMicros: 1000)
            h.engine.setController(state)
            #expect(await waitUntil { bodies().contains { $0.starts(with: hex("80 8b ff")) } })
            let sent = bodies()
            #expect(sent.contains { $0.starts(with: hex("80 ae")) })        // PS pressed
            #expect(sent.contains { $0.starts(with: hex("80 86 c8")) })     // L2 at 200
            #expect(sent.contains { $0.starts(with: hex("d0 05 3c 02 1c")) })  // touch id 5 at (960, 540)
            #expect(sent.contains { $0.starts(with: hex("80 88 00")) })     // cross released
            // The feedback state: the stick values and the motion (stream.md V-ST9's gyro and accelerometer words).
            #expect(await waitUntil {
                h.console.streamConsole.packets(ofType: 6).contains { $0.body.count >= 17 && Array($0.body[1..<13]) == hex("2182 aa7a cc8c 8e82 5198 e07a") }
            })
            let state6 = try #require(h.console.streamConsole.packets(ofType: 6).last { Array($0.body[1..<13]) == hex("2182 aa7a cc8c 8e82 5198 e07a") })
            #expect(Array(state6.body[17..<21]) == hex("3039 8000"))   // left stick x 12345, y -32768 (big-endian)
            // A second finger takes the other slot and keeps it when the first one lifts.
            state.touches = [CoreController.Touch(id: 5, x: 0.5, y: 0.5), CoreController.Touch(id: 6, x: 0, y: 1)]
            h.engine.setController(state)
            state.touches = [CoreController.Touch(id: 6, x: 0, y: 1)]
            h.engine.setController(state)
            #expect(await waitUntil { bodies().contains { $0.starts(with: hex("c0 05")) } })   // finger 5 lifted
            h.engine.stop()
        }

        @Test func aMotionResetRestartsTheOrientation() async throws {
            let h = try PlayFXHarness()
            h.console.streams = false
            #expect(await h.connect())
            func motion(_ t: UInt32) -> CoreController {
                var s = CoreController()
                s.motion = CoreController.Motion(gyro: [0, 0, 1], accel: [0, 1, 0], timestampMicros: t)
                return s
            }
            for n in 0..<50 { h.engine.setController(motion(UInt32(n) * 4000)) }
            let before = h.engine.input.withLock { $0.latest }
            #expect(before?.orientation != .identity)   // the pad has turned
            h.console.send(dataType: 9, SessionBytes.pad25)   // pad info with the motion-reset flag
            #expect(await waitUntil { h.sink.labels.contains("player 1") })
            try await Task.sleep(nanoseconds: 150_000_000)
            h.engine.setController(motion(50 * 4000))
            let after = h.engine.input.withLock { $0.latest }
            let q = try #require(after?.orientation)
            #expect(abs(q.w) > 0.99 && abs(q.x) < 0.05 && abs(q.y) < 0.05 && abs(q.z) < 0.05)   // origin again
            h.engine.stop()
        }

        @Test func theMicrophoneSendsOnlyWhileOnAsFortyByteOpusPackets() async throws {
            let h = try PlayFXHarness()
            h.console.streams = false
            #expect(await h.connect())
            let tone = (0..<960).map { i in Int16(8000 * sin(2 * .pi * 440 * Double(i / 2) / 48000)) }
            func send() { tone.withUnsafeBufferPointer { h.engine.sendMicrophoneFrame($0) } }
            send()   // capture runs a little before the microphone is on: dropped
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(h.console.streamConsole.packets(ofType: 3).isEmpty)
            h.engine.setMicrophone(true)
            let peer = try #require(h.console.ctrlPeer)
            #expect(await waitUntil { peer.received.with { $0.suffix(2).map(\.type) } == [0x30, 0x36] })
            send()
            send()
            #expect(await waitUntil { h.console.streamConsole.packets(ofType: 3).count >= 2 })
            let mic = h.console.streamConsole.packets(ofType: 3)
            #expect(mic.allSatisfy { $0.gmacOK == true && $0.bytes.count == 140 })
            // The announced StreamInfo went out at the start.
            #expect(h.console.count(SessionBytes.micStreamInfo) == 1)
            // Each packet carries the new frame and the two before it: the first decodes to the tone.
            let payload = RefCrypto(index: 2).crypt(Array(mic[0].bytes[20...]), keyPos: mic[0].keyPos)
            #expect(payload.count == 120 && Array(payload[0..<40]) == Array(payload[40..<80]))
            #expect(referenceDecode([Array(payload[0..<40])])[0].count == 960)
            #expect(referenceDecode([Array(payload[0..<40])])[0].contains { abs($0) > 1000 })
            // Off again: nothing more goes out.
            h.engine.setMicrophone(false)
            #expect(await waitUntil { peer.received.with { $0.suffix(2).map(\.type) } == [0x36, 0x36] })
            let count = h.console.streamConsole.packets(ofType: 3).count
            send()
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(h.console.streamConsole.packets(ofType: 3).count == count)
            // A frame of the wrong size isn't sent either.
            h.engine.setMicrophone(true)
            [Int16](repeating: 0, count: 480).withUnsafeBufferPointer { h.engine.sendMicrophoneFrame($0) }
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(h.console.streamConsole.packets(ofType: 3).count == count)
            h.engine.stop()
        }


        @Test func turningTheMicrophoneOffBeforeAnyOnDoesNotSetUpTheMicrophone() async throws {
            let h = try PlayFXHarness()
            h.console.streams = false
            #expect(await h.connect())
            let peer = try #require(h.console.ctrlPeer)
            try await Task.sleep(nanoseconds: 200_000_000)
            let known = peer.received.with { $0.count }   // (the library's own start-up messages included)
            h.engine.setMicrophone(false)
            try await Task.sleep(nanoseconds: 200_000_000)
            #expect(peer.received.with { $0.count } == known)   // nothing at all was sent
            h.engine.setMicrophone(true)
            #expect(await waitUntil { peer.received.with { $0.suffix(2).map(\.type) } == [0x30, 0x36] })
            h.engine.stop()
        }

        @Test func aMicrophoneAskedForBeforeTheStreamIsUpIsTurnedOnWhenItIs() async throws {
            let h = try PlayFXHarness()
            h.console.streams = false
            h.engine.setMicrophone(true)       // right away: nothing to send it on yet
            #expect(await h.connect())
            let peer = try #require(h.console.ctrlPeer)
            #expect(await waitUntil { peer.received.with { $0.suffix(2).map(\.type) } == [0x30, 0x36] })
            let tone = [Int16](repeating: 3000, count: 960)
            tone.withUnsafeBufferPointer { h.engine.sendMicrophoneFrame($0) }
            #expect(await waitUntil { !h.console.streamConsole.packets(ofType: 3).isEmpty })
            h.engine.stop()
        }

        @Test func aMicrophoneRequestWithdrawnBeforeTheStreamIsUpIsNotApplied() async throws {
            let h = try PlayFXHarness()
            h.console.streams = false
            h.engine.setMicrophone(true)
            h.engine.setMicrophone(false)
            #expect(await h.connect())
            try await Task.sleep(nanoseconds: 200_000_000)
            let peer = try #require(h.console.ctrlPeer)
            #expect(!peer.received.with { $0.map(\.type) }.contains(0x30))   // the microphone stream was never set up
            h.engine.stop()
        }
    }
}
