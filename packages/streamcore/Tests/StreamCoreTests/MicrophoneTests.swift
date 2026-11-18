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
}
