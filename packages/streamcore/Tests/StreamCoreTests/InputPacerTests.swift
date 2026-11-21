import Testing
@testable import StreamCore

/// The input loop's pacing (pure: times in, periods out — no pad, no clock, no thread).
@Suite struct InputPacerTests {
    @Test func waitsOnTheHeartbeatUntilSomethingChanges() {
        var pacer = InputPacer()
        #expect(pacer.period(at: 0) == InputPacer.heartbeat)
        pacer.reading(at: 1, distinct: false) // a quiet read: nothing happened, nothing is learned
        #expect(pacer.period(at: 1.5) == InputPacer.heartbeat)
    }

    @Test func aDistinctReadingPutsTheLoopOnTheFastLane() {
        var pacer = InputPacer()
        pacer.reading(at: 1, distinct: true)
        // Nothing learned yet, so the lane runs at its fastest until the pad's pace shows.
        #expect(pacer.period(at: 1.1) == InputPacer.fastest)
    }

    @Test func learnsHalfThePadsReportingInterval() {
        // A pad reporting every 10 ms (over Bluetooth, say): the loop settles on ~5 ms, never more than
        // one read behind a reading.
        var pacer = InputPacer()
        for k in 0..<6 { pacer.reading(at: Double(k) * 0.01, distinct: true) }
        #expect(abs(pacer.period(at: 0.06) - 0.005) < 0.0003)
    }

    @Test func aPauseTeachesNothing() {
        var pacer = InputPacer()
        for k in 0..<6 { pacer.reading(at: Double(k) * 0.01, distinct: true) }
        pacer.reading(at: 0.06 + 0.2, distinct: true) // a pause in play, not the pad's rate
        #expect(abs(pacer.period(at: 1) - 0.005) < 0.0003)
    }

    @Test func backToTheHeartbeatAfterQuiet() {
        var pacer = InputPacer()
        pacer.reading(at: 0, distinct: true)
        #expect(pacer.period(at: 0.9) == InputPacer.fastest)
        #expect(pacer.period(at: 1.1) == InputPacer.heartbeat) // a second without a change
    }

    @Test func aSlowPadIsStillReadNoSlowerThanTheHeartbeat() {
        // A pad reporting every 16 ms (60 Hz): its half-gap is the heartbeat, which caps the lane.
        var pacer = InputPacer()
        for k in 0..<10 { pacer.reading(at: Double(k) * 0.016, distinct: true) }
        #expect(abs(pacer.period(at: 0.2) - InputPacer.heartbeat) < 0.0005)
    }

    @Test func clampedStaysBetweenTheFastLaneAndTheHeartbeat() {
        #expect(InputPacer.clamped(0.0001) == InputPacer.fastest)
        #expect(InputPacer.clamped(0.02) == InputPacer.heartbeat)
        #expect(InputPacer.clamped(0.004) == 0.004)
    }
}
