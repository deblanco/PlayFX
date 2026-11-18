import CChiaki
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import StreamCore

@Suite struct StreamEventTests {
    typealias Event = StreamSession.Event

    func event(_ type: PsrpEventType, _ a: Int32 = 0, _ b: Int32 = 0, _ message: String = "") -> Event? {
        Event(type: Int32(type.rawValue), a: a, b: b, message: message)
    }

    @Test func mapsEveryEventType() {
        guard case .connected = event(PSRP_EVENT_CONNECTED) else { Issue.record("connected"); return }
        guard case .quit(let reason, let error, .final) = event(PSRP_EVENT_QUIT, 1, 0, "Stopped") else { Issue.record("quit"); return }
        #expect(reason == "Stopped" && error)
        guard case .quit(_, false, .final) = event(PSRP_EVENT_QUIT, 0) else { Issue.record("quit ok"); return }
        guard case .quit(_, true, .busy) = event(PSRP_EVENT_QUIT, 1, 1) else { Issue.record("quit busy"); return }
        guard case .quit(_, true, .dropped) = event(PSRP_EVENT_QUIT, 1, 2) else { Issue.record("quit dropped"); return }
        guard case .quit(_, false, .stopped) = event(PSRP_EVENT_QUIT, 0, 3) else { Issue.record("quit stopped"); return }
        guard case .remoteProgress(.linking) = event(PSRP_EVENT_REMOTE_PROGRESS, 1) else { Issue.record("linking"); return }
        guard case .remoteProgress(.data) = event(PSRP_EVENT_REMOTE_PROGRESS, 2) else { Issue.record("data"); return }
        guard case .remoteProgress(.connected) = event(PSRP_EVENT_REMOTE_PROGRESS, 3) else { Issue.record("connected"); return }
        guard case .loginPinRequested(true) = event(PSRP_EVENT_LOGIN_PIN_REQUEST, 1) else { Issue.record("pin"); return }
        guard case .loginPinRequested(false) = event(PSRP_EVENT_LOGIN_PIN_REQUEST, 0) else { Issue.record("pin"); return }
        guard case .rumble(255, 0) = event(PSRP_EVENT_RUMBLE, 300, -5) else { Issue.record("rumble"); return }
        guard case .nickname("PS5-1") = event(PSRP_EVENT_NICKNAME, 0, 0, "PS5-1") else { Issue.record("nickname"); return }
        #expect(Event(type: 99, a: 0, b: 0, message: "") == nil)
    }

    @Test func optionsDefaultsAndJSON() throws {
        let o = StreamSession.Options()
        #expect(o.height == 1080 && o.fps == 60 && o.hevc && o.bitrate == 0 && o.audio && o.autoDowngrade)
        let decoded = try JSONDecoder().decode(StreamSession.Options.self,
                                               from: Data(#"{"height":720,"fps":30,"hevc":false,"bitrate":5000,"audio":false}"#.utf8))
        #expect(decoded.height == 720 && decoded.fps == 30 && !decoded.hevc && decoded.bitrate == 5000 && !decoded.audio)
        #expect(decoded.autoDowngrade) // missing key keeps the default
        let full = try JSONDecoder().decode(StreamSession.Options.self, from: Data(#"{"autoDowngrade":false}"#.utf8))
        #expect(!full.autoDowngrade && full.height == 1080 && full.bitrate == 0)
        let stats = try JSONSerialization.jsonObject(with: JSONEncoder().encode(StreamSession.Stats())) as? [String: Int]
        #expect(stats == ["framesDecoded": 0, "decodeErrors": 0, "framesLost": 0, "width": 0, "height": 0, "bytesReceived": 0])
    }
}

extension Serial {
    @Suite struct StreamSessionTests {
        @Test func rejectsMalformedCredentials() {
            for broken in [\ConsoleCredentials.registKey, \.rpKey, \.accountId] {
                var c = fakeCredentials()
                c[keyPath: broken] = "AAAA"
                #expect(throws: ConsoleError.message("Invalid console credentials")) { try StreamSession(credentials: c) }
            }
        }

        @Test func internetPlayNeedsAPS5AndADeviceID() {
            #expect(throws: ConsoleError.message("Internet play needs a PS5 and its PSN device ID")) {
                try StreamSession(credentials: fakeCredentials(), remote: StreamSession.Remote(token: "t", duid: "not-hex"))
            }
            var ps4 = fakeCredentials()
            ps4.ps5 = false
            #expect(throws: ConsoleError.message("Internet play needs a PS5 and its PSN device ID")) {
                try StreamSession(credentials: ps4, remote: StreamSession.Remote(token: "t", duid: String(repeating: "ab", count: 32)))
            }
        }

        @Test func connectsToNothingAndQuits() async throws {
            var options = StreamSession.Options()
            options.height = 720
            options.fps = 30
            options.hevc = false
            options.autoDowngrade = false
            let session = try StreamSession(credentials: fakeCredentials(), options: options)
            let events = LockedLines()
            session.onEvent = { event in
                if case .quit(let reason, let error, _) = event { events.append("quit \(error) \(reason)") }
            }
            session.setController(ControllerState())
            var moving = ControllerState()
            moving.touches = [ControllerState.Touch(id: 1, x: 0.5, y: 0.5)]
            for t in 0..<3 { // the shim's orientation tracker needs two readings to integrate
                moving.motion = ControllerState.Motion(gyro: [0.1, 0, 0], accel: [0, -1, 0], timestampMicros: UInt32(t) * 4000)
                session.setController(moving)
            }
            session.setLoginPin("1234")
            #expect(session.stats.framesDecoded == 0)
            #expect(session.latestFrame == nil)
            // Nobody listens on loopback's Remote Play port: the session request fails and the session quits.
            #expect(await waitUntil { !events.lines.isEmpty })
            #expect(events.lines.first?.hasPrefix("quit true") == true)
            session.stop()
            session.stop()
            // After stop the handle is gone: these are no-ops.
            session.requestKeyframe()
            session.sleepConsole()
            session.setController(ControllerState())
        }

        @Test func decodesVideoAndCountsStats() async throws {
            var options = StreamSession.Options()
            options.audio = false
            options.hevc = true
            var credentials = fakeCredentials()
            credentials.ps5 = false // PS4 is always H.264
            let session = try StreamSession(credentials: credentials, options: options)
            defer { session.stop() }
            var frames = 0
            session.onFrame = { _ in frames += 1 }

            let encoded = try encodeFrames(codec: kCMVideoCodecType_H264, count: 3)
            for (i, f) in encoded.enumerated() {
                #expect(f.annexB.withUnsafeBytes { session.handleVideo($0, framesLost: i == 1 ? 2 : 0) })
            }
            #expect(![UInt8]([0, 0, 0, 1, 0x67, 0xFF]).withUnsafeBytes { session.handleVideo($0, framesLost: 0) })
            let stats = session.stats
            #expect(stats.framesDecoded == 3 && frames == 3)
            #expect(stats.framesLost == 2 && stats.decodeErrors == 1)
            #expect(stats.width == 320 && stats.height == 240)
            #expect(stats.bytesReceived == encoded.reduce(6) { $0 + $1.annexB.count })
            #expect(session.latestFrame.map(CVPixelBufferGetWidth) == 320)
        }
    }
}
