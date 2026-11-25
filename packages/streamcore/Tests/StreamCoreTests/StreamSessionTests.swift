import CoreMedia
import CoreVideo
import Foundation
import os
import Testing
@testable import StreamCore

@Suite struct StreamEventTests {
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
        #expect(stats == ["framesDecoded": 0, "decodeErrors": 0, "framesLost": 0, "width": 0, "height": 0, "bytesReceived": 0,
                          "rttMs": 0, "decodeMs": 0, "targetBitrateKbps": 0, "reorderWaitMs": 0, "reorderHolesFilled": 0,
                          "reorderLatePackets": 0, "reorderHolesLost": 0, "reorderQueueFull": 0])
    }

    @Test func statsTakeEachReorderField() {
        var stats = StreamSession.Stats()
        stats.setEngine(StreamEngineStats(
            rttMicros: 1500, targetBitrate: 15_000_999,
            reorder: StreamEngineStats.Reorder(waitMicros: 7500, holesFilled: 1, latePackets: 2, holesLost: 3, queueFullSkips: 4)))
        #expect(stats.reorderWaitMs == 7.5 && stats.reorderHolesFilled == 1 && stats.reorderLatePackets == 2
            && stats.reorderHolesLost == 3 && stats.reorderQueueFull == 4)
        #expect(stats.rttMs == 1.5 && stats.targetBitrateKbps == 15_000)
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

        @Test func eventsBeforeAHandlerAreKeptUntilOneIsSet() throws {
            let session = try StreamSession(credentials: fakeCredentials(address: "203.0.113.1"))
            defer { session.stop() }
            session.onEvent = nil
            session.deliver(.remoteProgress(.linking)) // e.g. internet setup starting right away
            session.deliver(.nickname("PS5"))
            var seen: [String] = []
            session.onEvent = { event in
                switch event {
                case .remoteProgress(let stage): seen.append("progress \(stage.rawValue)")
                case .nickname(let n): seen.append("nickname \(n)")
                default: break
                }
            }
            #expect(seen == ["progress linking", "nickname PS5"])
            session.deliver(.nickname("later"))
            #expect(seen.last == "nickname later")
            #expect(session.onEvent != nil)
        }

        @Test func theHandlerDoesNotGrowWithEveryEvent() throws {
            // Haptics arrive constantly from the console. The handler kept in the session must be called
            // through the same number of frames on the 2,000th event as on the first; a closure kept in the
            // lock's state grew by two frames per event and overflowed the receive thread (seen on a PS5).
            let session = try StreamSession(credentials: fakeCredentials(address: "203.0.113.1"))
            defer { session.stop() }
            var depths: [Int] = []
            session.onEvent = { _ in depths.append(Thread.callStackReturnAddresses.count) } // no symbol lookup: cheap
            session.deliver(.nickname("first"))
            for _ in 0..<2_000 { session.deliver(.nickname("again")) }
            session.deliver(.nickname("last"))
            #expect(depths.first == depths.last, "call depth \(depths.first ?? 0) → \(depths.last ?? 0)")
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
            let frames = OSAllocatedUnfairLock(initialState: 0)
            session.onFrame = { _, _ in frames.withLock { $0 += 1 } }
            let samples = OSAllocatedUnfairLock(initialState: [(index: UInt64, bytes: Int)]())
            session.onVideoSample = { index, bytes in samples.withLock { $0.append((index, bytes)) } }
            #expect(session.onVideoSample != nil)

            let encoded = try encodeFrames(codec: kCMVideoCodecType_H264, count: 3)
            for (i, f) in encoded.enumerated() {
                #expect(f.annexB.withUnsafeBytes { session.handleVideo($0, framesLost: i == 1 ? 2 : 0) })
            }
            #expect(![UInt8]([0, 0, 0, 1, 0x67, 0xFF]).withUnsafeBytes { session.handleVideo($0, framesLost: 0) })
            session.waitForDecodedFrames() // decoded asynchronously
            let stats = session.stats
            #expect(stats.framesDecoded == 3 && frames.withLock { $0 } == 3)
            #expect(stats.framesLost == 2 && stats.decodeErrors == 1)
            #expect(stats.width == 320 && stats.height == 240)
            #expect(stats.bytesReceived == encoded.reduce(6) { $0 + $1.annexB.count })
            #expect(session.latestFrame.map(CVPixelBufferGetWidth) == 320)
            // Each sample with its place (counting the 2 lost) and its size.
            let seen = samples.withLock { $0 }
            #expect(seen.map(\.index) == [1, 4, 5, 6])
            #expect(seen.first?.bytes == encoded.first?.annexB.count)
            session.onVideoSample = nil
            #expect(session.onVideoSample == nil)
        }
    }
}
