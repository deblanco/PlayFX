import CChiaki
import Testing
@testable import StreamCore

@Suite struct MicrophoneTests {
    @Test func cutsSamplesIntoTenMillisecondFrames() {
        var framer = MicFramer()
        var frames: [[Int16]] = []
        let collect = { (p: UnsafePointer<Int16>) in frames.append(Array(UnsafeBufferPointer(start: p, count: MicFramer.frameValues))) }
        let first = (0..<1500).map { Int16($0 % 1000) }
        first.withUnsafeBufferPointer { framer.append($0, emit: collect) }
        #expect(frames.count == 1 && frames[0].count == 960 && frames[0][0] == 0 && frames[0][959] == 959 % 1000)
        // The 540 left over join the next samples.
        let second = [Int16](repeating: 7, count: 420)
        second.withUnsafeBufferPointer { framer.append($0, emit: collect) }
        #expect(frames.count == 2 && frames[1][0] == Int16(960 % 1000) && frames[1][959] == 7)
    }

    @Test func refusesWhenThisBuildCantAsk() async {
        // The test runner has no microphone usage description, so it must not touch the microphone.
        #expect(!Microphone.canAsk)
        let state = await withCheckedContinuation { done in
            Microphone().start(frames: { _ in }) { done.resume(returning: $0) }
        }
        #expect(state == .unavailable)
        #expect(microphonePayload(.denied)["state"] as? String == "denied")
    }

    @Test func aStartAfterStopDoesNothing() {
        // The permission prompt was still open when the stream ended: the user's Allow arrives after stop()
        // and must not start feeding a session that's gone.
        let mic = Microphone()
        mic.stop()
        var fed = false
        #expect(mic.begin { _ in fed = true } == .off)
        #expect(!fed)
    }
}

@Suite struct HapticsRumbleTests {
    func rumble(_ samples: [Int16]) -> (UInt8, UInt8) {
        var l: UInt8 = 0, r: UInt8 = 0
        samples.withUnsafeBufferPointer { psrp_haptics_to_rumble($0.baseAddress, samples.count / 2, &l, &r) }
        return (l, r)
    }

    @Test func turnsTheHapticsStreamIntoRumble() {
        #expect(rumble([Int16](repeating: 0, count: 60)) == (0, 0)) // silence
        #expect(rumble([Int16](repeating: 40, count: 60)) == (0, 0)) // below the noise floor
        // Strong left channel, weak right: mean |x|·2 = 16000 → 62; 1000 → 3.
        #expect(rumble((0..<30).flatMap { _ in [Int16(8000), Int16(-500)] }) == (62, 3))
        #expect(rumble((0..<30).flatMap { _ in [Int16.max, Int16.min] }) == (255, 255)) // clamped
    }
}
