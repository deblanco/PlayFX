import CryptoKit
import Foundation
import Testing

@testable import PlayFXProtocol

/// The whole flow against the fake console of SessionSupport, over real loopback sockets, on both transports.
extension StreamSessionSuites {
    @Suite struct StreamSessionEndToEndTests {
        /// The Hello's fields, read by hand: (clientVersion, sessionKey, launchSpec, encryptedKey, key, signature).
        static func helloFields(_ bytes: [UInt8]) -> (version: Int, sessionKey: String, launchSpec: String, key: [UInt8], signature: [UInt8])? {
            let wrapper = protoFields(bytes)
            guard wrapper.first(where: { $0.number == 1 })?.varint == 0, let payload = wrapper.first(where: { $0.number == 2 })?.bytes else {
                return nil
            }
            let f = protoFields(payload)
            guard let version = f.first(where: { $0.number == 1 })?.varint, let session = f.first(where: { $0.number == 2 })?.bytes,
                  let spec = f.first(where: { $0.number == 3 })?.bytes, let key = f.first(where: { $0.number == 5 })?.bytes,
                  let signature = f.first(where: { $0.number == 6 })?.bytes else { return nil }
            return (version, String(decoding: session, as: UTF8.self), String(decoding: spec, as: UTF8.self), key, signature)
        }

        /// The launch spec JSON the console reads: base64, then the keystream-only form of the session cipher at
        /// counter 0 (the cipher of the fake console's ctrl, written separately in SpecCipher).
        static func launchJSON(_ spec: String) -> String {
            let cipher = Array(Data(base64Encoded: spec) ?? Data())
            let keystream = SpecCipher.forVersion("1.0").apply([UInt8](repeating: 0, count: cipher.count), counter: 0, encrypt: true)
            let plain = zip(cipher, keystream).map { $0 ^ $1 }
            return String(decoding: plain.dropLast(), as: UTF8.self)
        }

        @Test(arguments: [(StreamTransport.bsd, nil as Int?), (.bsd, 5), (.nw, nil), (.nw, 5)])
        func theRealCaptureComesOutOfTheSessionIntact(transport: StreamTransport, drop: Int?) async throws {
            let console = try StreamConsole()
            console.dropUnits = drop.map { [$0] } ?? []
            defer { console.stop() }
            let recorder = EventRecorder()
            let session = try await startSession(console, recorder: recorder, transport: transport)
            defer { session.stop() }

            // av.md V-AV7: lengths, first bytes and SHA-256s of both access units, one unit of frame 2 dropped or not.
            #expect(await recorder.wait { _ in recorder.videoFrames.count >= 2 })
            let frames = recorder.videoFrames
            for (index, frame) in [UInt16(1), 2].enumerated() {
                let want = try #require(captureExpected[frame])
                let got = frames[index]
                #expect(got.info.frameIndex == frame)
                #expect(got.bytes.count == want.length)
                #expect(encodeHex(Array(got.bytes.prefix(16))) == want.head)
                #expect(sha256Hex(got.bytes) == want.sha)
            }
            #expect(frames[0].info.fecRecovered == false)
            #expect(frames[1].info.fecRecovered == (drop != nil))
            #expect(frames[1].info.framesLost == 0)

            // What `connected` says.
            let info = try #require(session.connectedInfo)
            #expect(info.probeSucceeded && info.probeFailure == nil)
            #expect(info.probe.mtuIn == 1400 && info.probe.mtuOut == 1300)
            #expect(info.takionVersion == 12 && info.target == .ps5v1 && info.transport == transport.name)
            #expect(info.videoCodec == .h264 && info.requested.codec == .h264 && info.requested.width == 1920)
            #expect(info.profiles.map(\.width) == [1920, 1280] && info.profiles.map(\.height) == [1080, 720])
            #expect(info.profiles[0].header == SessionBytes.dummyProfile0Header)
            #expect(info.audioHeader == AudioHeader(channels: 2, bitsPerSample: 16, sampleRate: 48000, frameSize: 480, unknown: 1))
            #expect(info.serverVersion == 12 && info.consoleSignatureMatches)
            let events = recorder.all
            #expect(events.first == .connected(info))
            let firstVideo = try #require(events.firstIndex { if case .video = $0 { true } else { false } })
            let connectedAt = try #require(events.firstIndex { if case .connected = $0 { true } else { false } })
            #expect(connectedAt < firstVideo)
            #expect(events[1] == .audioHeader(info.audioHeader))
            #expect(events.contains(.parameterSets(0, SessionBytes.dummyProfile0Header)))
            #expect(events.firstIndex(of: .parameterSets(0, SessionBytes.dummyProfile0Header))! < firstVideo)

            // The Hello: split as section 2.3 says for the measured MTUs, with the vector key pair and signature.
            let hello = try #require(console.hello)
            let m = min(1400, 1300) - 50
            #expect(hello.chunks.map { $0.length } == [m - 26, hello.bytes.count - (m - 26)])
            #expect(hello.chunks.map { $0.flags } == [0, 1])
            #expect(hello.channel == 1 && hello.dataType == 0)
            #expect(hello.bytes.count == 1409)  // V-ST4's size: "avc" and "hevc" encode to the same base64 length
            let fields = try #require(Self.helloFields(hello.bytes))
            #expect(fields.version == 12 && fields.sessionKey == SessionVector.sessionIDText)
            #expect(fields.key == StreamInputs.publicA && fields.signature == StreamInputs.signatureA)
            let json = Self.launchJSON(fields.launchSpec)
            #expect(json.contains(#""mtu":1400"#) && json.contains(#""videoCodec":"avc""#) && json.contains(#""bwKbpsSent":15000"#))
            #expect(json.hasSuffix(#""handshakeKey":"QEFCQ0RFRkdISUpLTE1OTw=="}"#))

            // After the StreamInfo, in order: ack on channel 9, then the DualSense ControllerConnection; no mic.
            #expect(await waitUntil { console.messages.with { $0.count } >= 3 })
            let sent = console.messages.with { $0.map { ($0.channel, $0.bytes) } }
            #expect(sent[1].0 == 9 && sent[1].1 == SessionBytes.streamInfoAck)
            #expect(sent[2].0 == 1 && sent[2].1 == SessionBytes.controllerConnectionDualSense)
            #expect(console.count(SessionBytes.micStreamInfo) == 0)

            // The first secured client packet is the ack of the bang, at key position 0, and every secured one checks.
            #expect(await waitUntil { console.streamConsole.packets(ofType: 6).count >= 3 && console.count(SessionBytes.heartbeat) >= 3 })
            let packets = console.streamConsole.packets
            let firstSecured = try #require(packets.first { $0.gmacOK != nil })
            #expect(firstSecured.chunkType == 3 && firstSecured.keyPos == 0 && firstSecured.gmacOK == true)
            #expect(packets.allSatisfy { $0.gmacOK != false })

            // Feedback state: numbered 0, 1, 2 ... with the idle body (V-ST9), repeated while nothing changes.
            let states = console.streamConsole.packets(ofType: 6)
            #expect(states.map { Int(readBE16($0.bytes, 1)) } == Array(0..<states.count))
            #expect(states.allSatisfy { $0.body == SessionBytes.idleState })
            #expect(states.map(\.keyPos) == states.map(\.keyPos).sorted())

            // Congestion reports are secured, and the last one is in the statistics.
            #expect(console.streamConsole.packets(ofType: 5).count >= 2)
            #expect(await recorder.wait { _ in recorder.stats.last.map { $0.videoFramesTotal == 2 && $0.lastCongestion != nil && $0.audioPackets >= 6 } ?? false })
            let stats = try #require(recorder.stats.last)
            #expect(stats.fecRecoveries == (drop != nil ? 1 : 0) && stats.fecFailures == 0 && stats.framesLost == 0)
            #expect(stats.transport == transport.name && !stats.timestampSource.isEmpty)
            #expect(stats.mtuIn == 1400 && stats.mtuOut == 1300 && stats.probeSucceeded && stats.rttMicroseconds >= 0)
            #expect(stats.seconds > 0 && stats.datagramsReceived > 20 && stats.droppedBadGMAC == 0)
            #expect((stats.lastCongestion?.count ?? 0) >= 1)

            // Audio: the source units of frames 100 ... 105 come out in order; haptics PCM comes out little-endian.
            #expect(await recorder.wait { events in
                events.contains { if case .haptics = $0 { true } else { false } }
                    && events.filter { if case .audioPacket = $0 { true } else { false } }.count >= 6
            })
            let audio = recorder.all.compactMap { event -> (UInt16, [UInt8])? in
                if case .audioPacket(let frame, let bytes) = event { (frame, bytes) } else { nil }
            }
            for n in 0..<6 {
                let played = try #require(audio.first { $0.0 == UInt16(100 + n) })
                #expect(played.1 == [UInt8](repeating: UInt8(n * 3), count: 40))
            }
            #expect(recorder.all.contains(.haptics(7, [1, 2, 3, -1, -32768, 0x1234])))

            // Where each event was delivered (BSD: the named receive thread).
            if transport == .bsd {
                for entry in recorder.entries.with({ $0 }) {
                    switch entry.event {
                    case .connected, .audioHeader, .video, .parameterSets, .audioPacket, .haptics:
                        #expect(entry.thread == "playfx.takion.rx")
                    default:
                        #expect(entry.thread != "playfx.takion.rx")
                    }
                }
            }
        }

        @Test func aDroppedUnitThatTheCodeCannotRebuildReportsAndAsksForAKeyFrame() async throws {
            let console = try StreamConsole()
            defer { console.stop() }
            // Frame 2 loses two source units: its one parity unit can't rebuild them.
            console.dropUnits = [3, 4]
            let recorder = EventRecorder()
            let session = try await startSession(console, recorder: recorder)
            defer { session.stop() }
            #expect(await waitUntil { console.received(channel: 2).count >= 2 })
            // A frame that can't be repaired: its first lost frame report and the IDR request, section 9.3/9.4.
            #expect(console.received(channel: 2).contains(hex("0819")))
            #expect(console.received(channel: 2).contains(hex("0805320408021002")))
            #expect(await recorder.wait { _ in recorder.stats.last.map { $0.fecFailures == 1 && $0.idrRequestsSent >= 1 && $0.corruptFrameReportsSent >= 1 } ?? false })
        }

        @Test func heartbeatsAndTheFeedbackKeepGoing() async throws {
            let console = try StreamConsole()
            defer { console.stop() }
            let recorder = EventRecorder()
            let session = try await startSession(console, recorder: recorder)
            defer { session.stop() }
            #expect(await waitUntil { console.count(SessionBytes.heartbeat) >= 4 })
            // Heartbeats are on channel 1 and the first comes after the interval, not before.
            #expect(console.count(SessionBytes.heartbeat, channel: 2) == 0)
            #expect(await recorder.wait { $0.contains { if case .stats = $0 { true } else { false } } })
            let stats = try #require(recorder.stats.first)
            #expect(stats.videoFrames >= 0 && stats.seconds >= 0.15)
        }

        // MARK: Controller input

        @Test func controllerChangesBecomeHistoryEventsAndStatePackets() async throws {
            let console = try StreamConsole()
            defer { console.stop() }
            let recorder = EventRecorder()
            let session = try await startSession(console, recorder: recorder)
            defer { session.stop() }
            #expect(await waitUntil { console.streamConsole.packets(ofType: 6).count >= 1 })

            var pressed = ControllerState.idle
            pressed.buttons = [.cross, .r3]
            pressed.l2 = 128
            #expect(session.setControllerState(pressed))
            #expect(await waitUntil { console.historyPackets().count >= 3 })
            var events = console.historyPackets()
            // One packet per event, numbered from 0, in the order of section 10.2: presses by bit, then L2.
            #expect(events.map { Int(readBE16($0.bytes, 1)) }.prefix(3) == [0, 1, 2])
            #expect(events[0].body == hex("8088ff"))
            #expect(events[1].body == hex("80b0") + hex("8088ff"))
            #expect(events[2].body == hex("808680") + hex("80b0") + hex("8088ff"))
            #expect(events.prefix(3).map { $0.bytes[3] } == [0, 1, 2])
            #expect(events.allSatisfy { $0.gmacOK == true })

            // The same state again sends nothing new; releasing sends the releases.
            let before = console.historyPackets().count
            #expect(session.setControllerState(pressed))
            pressed.buttons = []
            pressed.l2 = 0
            #expect(session.setControllerState(pressed))
            #expect(await waitUntil { console.historyPackets().count >= before + 3 })
            events = console.historyPackets()
            #expect(Array(events[3].body.prefix(3)) == hex("808800"))

            // Moving a stick makes a state packet at once, with the stick bytes big-endian (V-ST9).
            let states = console.streamConsole.packets(ofType: 6).count
            pressed.leftStickX = 12345
            pressed.leftStickY = -32768
            pressed.rightStickX = 32767
            pressed.rightStickY = -100
            #expect(session.setControllerState(pressed))
            #expect(await waitUntil { console.streamConsole.packets(ofType: 6).count > states })
            let body = try #require(console.streamConsole.packets(ofType: 6).first { $0.body.count == 28 && Array($0.body[17..<25]) == hex("3039 8000 7fff ff9c") }?.body)
            #expect(Array(body.suffix(3)) == hex("000001"))
        }

        @Test func aStateSetBeforeTheStreamIsUpIsRemembered() async throws {
            let console = try StreamConsole()
            defer { console.stop() }
            let recorder = EventRecorder()
            recorder.onEvent = { event, session in
                var state = ControllerState.idle
                state.buttons = .square
                if case .connected = event { _ = session.setControllerState(state) }
            }
            let session = try await startSession(console, recorder: recorder)
            defer { session.stop() }
            #expect(await waitUntil { console.historyPackets().count >= 1 })
            #expect(console.historyPackets()[0].body == hex("808aff"))
        }

        // MARK: Messages from the console

        @Test func rumbleTriggersPadInfoAndQualityReachTheApp() async throws {
            let console = try StreamConsole()
            defer { console.stop() }
            let recorder = EventRecorder()
            let session = try await startSession(console, recorder: recorder)
            defer { session.stop() }
            console.send(dataType: 7, SessionBytes.rumble)
            console.send(dataType: 11, SessionBytes.triggers)
            console.send(dataType: 9, SessionBytes.pad25)
            console.send(dataType: 9, SessionBytes.pad25)
            console.send(dataType: 9, SessionBytes.pad17)
            console.send(dataType: 7, [0, 1])  // too short: ignored
            console.send(dataType: 5, [1, 2, 3])  // an unknown data type: ignored
            console.send(hex("08 10 8a 01 03 08 e8 07"))  // ConnectionQuality {targetBitrate 1000}
            console.send(hex("08 03"))  // a Heartbeat from the console: nothing to do
            #expect(await recorder.wait { $0.contains(.quality) && $0.contains(.playerIndex(2)) })
            let control = recorder.all.filter {
                switch $0 {
                case .rumble, .triggers, .led, .playerIndex, .motionReset, .quality: true
                default: false
                }
            }
            // Pad info repeats nothing that didn't change, and the motion reset comes with each 25-byte form.
            #expect(control == [
                .rumble(left: 128, right: 64), .triggers(left: 0x25, right: 0x26), .led(0xff, 0x74, 0xa6), .playerIndex(1),
                .motionReset, .motionReset, .led(0, 0, 0xff), .playerIndex(2), .quality,
            ])
        }

        @Test func aConsoleDisconnectEndsTheSessionOnceAndTheClientAnswersWithItsOwn() async throws {
            let console = try StreamConsole()
            defer { console.stop() }
            let recorder = EventRecorder()
            let session = try await startSession(console, recorder: recorder)
            console.send(SessionBytes.disconnect("Another device took over"))
            console.send(SessionBytes.disconnect("again"))
            let reason = try #require(await recorder.waitForEnd())
            #expect(reason.code == .streamRemoteDisconnected && reason.remoteText == "Another device took over")
            #expect(reason.isError && reason.retryClass == .final)
            #expect(session.endReason == reason)
            #expect(await waitUntil { console.count(SessionBytes.clientDisconnect) == 1 })
            // Ctrl was closed too.
            #expect(await waitUntil { console.ctrlClosed.with { $0 } })
            // Nothing follows `ended`, and it came exactly once.
            let count = recorder.all.count
            try await Task.sleep(nanoseconds: 400_000_000)
            #expect(recorder.all.count == count)
            #expect(recorder.ended == [reason])
            if case .ended = recorder.all.last {} else { Issue.record("`ended` was not the last event") }
            #expect(!session.setControllerState(.idle) && !session.requestIDR())
        }

        @Test func serverShuttingDownIsNotAnError() async throws {
            let console = try StreamConsole()
            defer { console.stop() }
            let recorder = EventRecorder()
            _ = try await startSession(console, recorder: recorder)
            console.send(SessionBytes.serverShuttingDown)
            let reason = try #require(await recorder.waitForEnd())
            #expect(reason.code == .streamRemoteShutdown && !reason.isError && reason.kind == .consoleShuttingDown)
        }

        @Test func stopSendsTheClientDisconnectAndEndsOnce() async throws {
            let console = try StreamConsole()
            defer { console.stop() }
            let recorder = EventRecorder()
            let session = try await startSession(console, recorder: recorder)
            #expect(await waitUntil { console.count(SessionBytes.heartbeat) >= 1 })
            session.stop()
            session.stop()
            let reason = try #require(await recorder.waitForEnd())
            #expect(reason.code == .stoppedByClient && !reason.isError && reason.retryClass == .stopped)
            #expect(await waitUntil { console.count(SessionBytes.clientDisconnect) == 1 })
            #expect(await waitUntil { console.ctrlClosed.with { $0 } })
            let beats = console.count(SessionBytes.heartbeat)
            session.stop()
            try await Task.sleep(nanoseconds: 400_000_000)
            #expect(recorder.ended == [reason] && console.count(SessionBytes.heartbeat) == beats)
            #expect(console.count(SessionBytes.clientDisconnect) == 1)
        }

        @Test func aLostStreamConnectionEndsTheSession() async throws {
            let console = try StreamConsole()
            defer { console.stop() }
            let recorder = EventRecorder()
            _ = try await startSession(console, recorder: recorder)
            // The console's socket goes away: the next heartbeat gets a socket error.
            console.stopStreamLink()
            let reason = try #require(await recorder.waitForEnd())
            #expect(reason.code == .streamFailed && reason.kind == .connectionLost && reason.retryClass == .dropped)
            #expect(reason.userMessage(console: .ps5).contains("lost"))
        }

        @Test func theCtrlChannelEndingEndsTheStream() async throws {
            let console = try StreamConsole()
            defer { console.stop() }
            let recorder = EventRecorder()
            _ = try await startSession(console, recorder: recorder)
            try #require(console.ctrlPeer).reset()
            let reason = try #require(await recorder.waitForEnd())
            #expect(reason.code == .ctrlFailed && reason.retryClass == .dropped)
            #expect(await waitUntil { console.count(SessionBytes.clientDisconnect) == 1 })
            #expect(recorder.ended.count == 1)
        }

        @Test func goToBedThenTheConsoleClosingCtrlIsARemoteShutdown() async throws {
            let console = try StreamConsole()
            defer { console.stop() }
            let recorder = EventRecorder()
            let session = try await startSession(console, recorder: recorder)
            try session.goToBed()
            #expect(await waitUntil { console.ctrlPeer?.received.with { $0.contains { $0.type == 0x50 } } ?? false })
            console.ctrlPeer?.finish()
            let reason = try #require(await recorder.waitForEnd())
            #expect(reason.code == .streamRemoteShutdown && !reason.isError)
        }

        @Test func droppingTheSessionClosesEverythingWithoutEvents() async throws {
            let console = try StreamConsole()
            defer { console.stop() }
            let recorder = EventRecorder()
            var session: StreamSession? = try await startSession(console, recorder: recorder)
            recorder.session.with { $0 = nil }
            weak let weakSession = session
            session = nil
            #expect(await waitUntil { weakSession == nil })
            #expect(await waitUntil { console.ctrlClosed.with { $0 } })
            // The dropped session still says goodbye (section 11.1), and delivers nothing.
            #expect(await waitUntil { console.count(SessionBytes.clientDisconnect) == 1 })
            #expect(recorder.ended.isEmpty)
        }

        @Test func aStreamInfoBeforeTheHelloReplyIsAppliedAfterIt() async throws {
            let console = try StreamConsole()
            console.infoScript = .beforeReply
            defer { console.stop() }
            let recorder = EventRecorder()
            let session = try await startSession(console, recorder: recorder)
            defer { session.stop() }
            #expect(await recorder.wait { _ in recorder.videoFrames.count >= 2 })
            #expect(sha256Hex(recorder.videoFrames[1].bytes) == captureExpected[2]!.sha)
        }

        // MARK: The decoder's side

        @Test func rejectedFramesAreCountedAndRepeatedRejectionAsksForAKeyFrame() async throws {
            let console = try StreamConsole()
            defer { console.stop() }
            let recorder = EventRecorder()
            recorder.onEvent = { event, session in
                if case .videoAccessUnit = event { session.rejectVideoFrame() }
            }
            let session = try await startSession(console, recorder: recorder)
            defer { session.stop() }
            #expect(await recorder.wait { _ in recorder.videoFrames.count >= 2 })
            #expect(!console.received(channel: 2).contains(hex("0819")))
            // Six more frames, all rejected: from the fifth in a row the receiver reports the decoder rejecting,
            // and the session asks for a key frame (section 9.3). The two good frames before it would have reset
            // the count, so this also shows that rejected frames were not counted good.
            console.sendExtraFrames(first: 3, count: 6)
            #expect(await recorder.wait { _ in recorder.videoFrames.count >= 8 })
            #expect(await waitUntil { console.received(channel: 2).contains(hex("0819")) })
            #expect(await recorder.wait { _ in recorder.stats.last.map { $0.decoderRejects == 8 && $0.idrRequestsSent >= 1 } ?? false })
        }

        @Test func acceptedFramesNeverAskForAKeyFrame() async throws {
            let console = try StreamConsole()
            defer { console.stop() }
            let recorder = EventRecorder()
            let session = try await startSession(console, recorder: recorder)
            defer { session.stop() }
            console.sendExtraFrames(first: 3, count: 6)
            #expect(await recorder.wait { _ in recorder.videoFrames.count >= 8 })
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(!console.received(channel: 2).contains(hex("0819")))
            #expect(recorder.stats.last?.decoderRejects == 0)
        }

        @Test func idrRequestsAreThrottledToOnePerSecond() async throws {
            let console = try StreamConsole()
            defer { console.stop() }
            let recorder = EventRecorder()
            let now = Locked(1000.0)
            let session = try await startSession(console, recorder: recorder) { env in
                env.clock = { now.with { $0 } }
            }
            defer { session.stop() }
            #expect(session.requestIDR())
            #expect(!session.requestIDR())
            now.with { $0 += 0.9 }
            #expect(!session.requestIDR())
            now.with { $0 += 0.2 }
            #expect(session.requestIDR())
            #expect(await waitUntil { console.received(channel: 2).filter { $0 == hex("0819") }.count == 2 })
            #expect(await recorder.wait { _ in recorder.stats.last?.idrRequestsSent == 2 })
        }

    // MARK: Microphone, keyboard and PIN

        @Test func theMicrophoneIsAnnouncedOnlyWhenEnabled() async throws {
            let console = try StreamConsole()
            defer { console.stop() }
            let recorder = EventRecorder()
            var options = StreamSessionOptions()
            options.microphone = true
            let session = try await startSession(console, recorder: recorder, options: options)
            defer { session.stop() }
            #expect(await waitUntil { console.messages.with { $0.count } >= 4 })
            let sent = console.messages.with { $0.map { ($0.channel, $0.bytes) } }
            #expect(sent[3].0 == 1 && sent[3].1 == SessionBytes.micStreamInfo)

            // The ctrl signalling: connect once, then the state byte.
            try session.setMicrophone(on: true)
            try session.setMicrophone(on: false)
            let peer = try #require(console.ctrlPeer)
            #expect(await waitUntil { peer.received.with { $0.suffix(3).map(\.type) } == [0x30, 0x36, 0x36] })
            let ctrl = peer.received.with { Array($0.suffix(3)) }
            #expect(ctrl[1].plain == hex("00010159") && ctrl[2].plain == hex("00010059"))

            // 40-byte frames become secured microphone packets (V-ST11); other sizes don't.
            #expect(!session.sendMicrophoneFrame([UInt8](repeating: 1, count: 39)))
            #expect(session.sendMicrophoneFrame([UInt8](repeating: 0x10, count: 40)))
            #expect(session.sendMicrophoneFrame([UInt8](repeating: 0x11, count: 40)))
            #expect(await waitUntil { console.streamConsole.packets(ofType: 3).count >= 2 })
            let mic = console.streamConsole.packets(ofType: 3)
            #expect(mic.allSatisfy { $0.gmacOK == true && $0.bytes.count == 140 })
            #expect(Array(mic[0].bytes[0..<10]) == hex("03 0000 0001 00022821 05"))
            #expect(Array(mic[1].bytes[0..<10]) == hex("03 0001 0002 00022821 05"))
            let payload = RefCrypto(index: 2).crypt(Array(mic[1].bytes[20...]), keyPos: mic[1].keyPos)
            #expect(payload == [UInt8](repeating: 0x11, count: 40) + [UInt8](repeating: 0x10, count: 80))
        }

        @Test func withoutTheMicrophoneOptionTheMicrophoneCommandsRefuse() async throws {
            let console = try StreamConsole()
            defer { console.stop() }
            let recorder = EventRecorder()
            let session = try await startSession(console, recorder: recorder)
            defer { session.stop() }
            #expect(throws: StreamCommandError.microphoneNotEnabled) { try session.setMicrophone(on: true) }
            #expect(!session.sendMicrophoneFrame([UInt8](repeating: 1, count: 40)))
        }

        @Test func loginPINAndKeyboardPassThroughCtrl() async throws {
            let opened = [UInt8](repeating: 0, count: 28) + be32(3) + Array("abc".utf8)
            let changed = be32(2) + be32(0) + be32(2) + [UInt8](repeating: 0, count: 24) + be32(2) + Array("ab".utf8)
            let console = try StreamConsole(ctrl: { peer in
                peer.sendHead()
                peer.send(0x04)
                _ = peer.receive()  // the PIN
                peer.send(0x05, [0])
                peer.send(0x33, sessionIDPlain)
                peer.send(0x21, opened)
                peer.send(0x24, changed)
                peer.send(0x22, [0])
                peer.pump(limit: 30)
            })
            defer { console.stop() }
            let recorder = EventRecorder()
            recorder.onEvent = { event, session in
                if case .loginPINRequested = event { try? session.sendLoginPIN("1234") }
            }
            let session = try await startSession(console, recorder: recorder)
            defer { session.stop() }
            #expect(await recorder.wait { $0.contains(.keyboardClosed) })
            let ctrlEvents = recorder.all.filter {
                switch $0 {
                case .loginPINRequested, .loginPINResult, .keyboardOpened, .keyboardTextChanged, .keyboardClosed: true
                default: false
                }
            }
            #expect(ctrlEvents == [.loginPINRequested, .loginPINResult(true), .keyboardOpened("abc"), .keyboardTextChanged(2, "ab"), .keyboardClosed])
            try session.keyboardSetText("x")
            try session.keyboardDone()
            try session.keyboardCancel()
            try session.enableKeyboard()
            #expect(throws: ControlCommandError.noPINRequested) { try session.sendLoginPIN("1234") }
            let peer = try #require(console.ctrlPeer)
            #expect(await waitUntil { peer.received.with { $0.count } >= 8 })
            let types = peer.received.with { $0.map(\.type) }
            #expect(types.contains(0x8004) && types.contains(0x23) && types.contains(0x25))
        }
    }
}
