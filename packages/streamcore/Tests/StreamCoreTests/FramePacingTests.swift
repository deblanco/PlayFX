import Testing
@testable import StreamCore

/// A clock reading that must exist (a mutating call can't sit inside `#require`).
func tick(_ clock: inout StreamClock, _ index: UInt64, _ arrival: Double) throws -> (time: Double, restarted: Bool) {
    let reading = clock.time(index: index, arrival: arrival)
    return try #require(reading)
}

@Suite struct StreamClockTests {
    @Test func jitterDoesNotMoveTheTimes() throws {
        var clock = StreamClock(fps: 60)
        // Frames every 1/60 s, each arriving 0–8 ms late (pseudo-random), never early.
        var times: [Double] = []
        for i in 0..<240 {
            let late = Double((i * 7919) % 9) / 1000
            let t = try tick(&clock, UInt64(100 + i), 10 + Double(i) / 60 + late)
            times.append(t.time)
        }
        // After settling, consecutive times are a steady 1/60 s apart despite the jitter.
        let gaps = zip(times.dropFirst(120), times.dropFirst(121)).map { $1 - $0 }
        #expect(gaps.allSatisfy { abs($0 - 1.0 / 60) < 0.0002 }, "\(gaps.min() ?? 0)…\(gaps.max() ?? 0)")
    }

    @Test func followsTheStreamsRealRate() throws {
        var clock = StreamClock(fps: 60)
        // A "60" stream that really runs at 59.94: the phase follows it, so frames are never shown early.
        var last = (time: 0.0, arrival: 0.0)
        for i in 0..<600 {
            let arrival = Double(i) / 59.94
            last = (try tick(&clock, UInt64(i), arrival).time, arrival)
        }
        #expect(abs(last.arrival - last.time) < 0.002)
    }

    @Test func restartsAfterAGapAndRefusesOldFrames() throws {
        var clock = StreamClock(fps: 30)
        #expect(try tick(&clock, 1, 5).restarted)
        #expect(clock.time(index: 2, arrival: 5 + 1.0 / 30)?.restarted == false)
        #expect(clock.time(index: 2, arrival: 5.1) == nil) // same index again
        #expect(clock.time(index: 3, arrival: 5.0) == nil) // arrival going back
        let after = try tick(&clock, 3, 6) // a second without frames
        #expect(after.restarted && after.time == 6)
        #expect(try tick(&clock, 200, 6.05).restarted) // half a second of frames skipped
        #expect(StreamClock(fps: 0).fps == 60)
    }
}

@Suite struct FrameTimelineTests {
    func image(_ name: String, _ time: Double, generated: Bool = false) -> TimedImage<String> {
        TimedImage(image: name, time: time, generated: generated, arrival: time)
    }

    @Test func showsTheNewestDueImageAndCountsTheSkipped() {
        var timeline = FrameTimeline<String>()
        timeline.add(image("b", 2))
        timeline.add(image("a", 1))
        timeline.add(image("ab", 1.5, generated: true))
        #expect(timeline.newestRealTime == 2)
        #expect(timeline.next(now: 0.9, delay: 0) == nil)
        #expect(timeline.next(now: 1.1, delay: 0)?.image == "a")
        #expect(timeline.next(now: 1.4, delay: 0) == nil) // nothing new: keep showing "a"
        // A late refresh: "ab" was due but "b" is due too, so "ab" is skipped.
        #expect(timeline.next(now: 3, delay: 0.5)?.image == "b")
        #expect(timeline.skippedGenerated == 1 && timeline.skippedReal == 0)
        #expect(timeline.entries.isEmpty)
    }

    @Test func dropsTheOldestBeyondCapacity() {
        var timeline = FrameTimeline<String>(capacity: 2)
        for i in 0..<4 { timeline.add(image("\(i)", Double(i))) }
        #expect(timeline.entries.map(\.image) == ["2", "3"])
        #expect(timeline.skippedReal == 2)
        timeline.clear()
        #expect(timeline.entries.isEmpty)
    }
}

@Suite struct DelayPlannerTests {
    @Test func coversJitterAndInterpolationEasingTowardsIt() {
        var planner = DelayPlanner()
        for i in 0..<100 { planner.observe(lateness: i % 5 == 0 ? 0.006 : 0.001) } // a fifth arrive 6 ms late
        planner.observe(lateness: -1) // early arrivals count as on time
        var delay = 0.0
        for _ in 0..<50 { delay = planner.update(interval: 1.0 / 30, interpolating: false) }
        #expect(abs(delay - (0.006 + planner.margin)) < 0.0005, "\(delay)") // the 90th percentile
        // Interpolating: also half an interval and the cost of an in-between image, reached gradually.
        for _ in 0..<20 { planner.observe(cost: 0.014) }
        #expect(planner.generationCost == 0.014)
        let first = planner.update(interval: 1.0 / 30, interpolating: true)
        #expect(first - delay <= 0.001 + 1e-9) // no jump
        for _ in 0..<60 { delay = planner.update(interval: 1.0 / 30, interpolating: true) }
        #expect(abs(delay - (0.006 + planner.margin + 1.0 / 60 + 0.014)) < 0.001, "\(delay)")
        // Turned off: it comes back down slowly.
        let down = planner.update(interval: 1.0 / 30, interpolating: false)
        #expect(delay - down <= 0.00025 + 1e-9)
        #expect(DelayPlanner.percentile([], 0.9) == 0)
    }
}

@Suite struct RungSelectorTests {
    @Test func offersSmallerSizesOnlyBelowTheStreams() {
        #expect(RungSelector(width: 1920, height: 1080).rungs.map(\.width) == [1920, 1280, 960])
        #expect(RungSelector(width: 1280, height: 720).rungs.map(\.width) == [1280, 960])
        #expect(RungSelector(width: 960, height: 540).rungs.map(\.width) == [960])
    }

    @Test func stepsDownAtOnceAndUpOnlyWithRoomAfterAWhile() {
        var s = RungSelector(width: 1920, height: 1080)
        s.observe(cost: 0.014, budget: 0.010, now: 0) // 1080p misses a 10 ms budget
        #expect(s.size.width == 1280)
        s.observe(cost: 0.004, budget: 0.010, now: 5) // 720p fits, but too soon to climb
        #expect(s.size.width == 1280)
        s.observe(cost: 0.004, budget: 0.030, now: 20) // more time now, but 1080p is blocked for 30 s
        #expect(s.size.width == 1280)
        s.observe(cost: 0.004, budget: 0.030, now: 31) // 1080p cost 14 ms ≤ 60% of 30 ms: back up
        #expect(s.size.width == 1920)
        s.observe(cost: 0.050, budget: 0.010, now: 32)
        s.observe(cost: 0.050, budget: 0.010, now: 33)
        s.observe(cost: 0.050, budget: 0.010, now: 34) // already the smallest
        #expect(s.size.width == 960)
    }
}

@Suite struct SceneCutTests {
    @Test func tellsACutFromMotion() {
        let gradient: (Int, Int) -> UInt8 = { x, _ in UInt8(x * 255 / 1920) }
        let shifted: (Int, Int) -> UInt8 = { x, _ in UInt8(min(1919, x + 24) * 255 / 1920) } // a pan
        let other: (Int, Int) -> UInt8 = { x, _ in UInt8(255 - x * 255 / 1920) } // a different shot
        #expect(!SceneCut.isCut(width: 1920, height: 1080, a: gradient, b: shifted))
        #expect(SceneCut.isCut(width: 1920, height: 1080, a: gradient, b: other))
    }
}
