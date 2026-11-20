import CoreVideo
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

    @Test func startsOverWhenFramesKeepArrivingLate() throws {
        // A "60" stream that really sends 50 frames a second: every frame lands later on the clock, faster than
        // even the sliding phase follows. A frame more than a quarter second late starts the clock over, so
        // lateness stays bounded instead of growing for as long as the stream lasts.
        var clock = StreamClock(fps: 60)
        var worst = 0.0, restarts = 0, last = -Double.infinity
        for i in 0..<1500 { // 30 s
            let arrival = Double(i) / 50
            let t = try tick(&clock, UInt64(i), arrival)
            if t.restarted { restarts += 1 }
            worst = max(worst, arrival - t.time)
            #expect(t.time > last) // never back, across a restart too
            last = t.time
        }
        #expect(restarts > 1)
        #expect(worst < 0.4, "\(worst)")
    }

    /// The pattern behind most restarts in a 7-minute session (`t3.log`, 2026-11-20): frames arrive 50 ms
    /// behind the clock for a second, then a ~95 ms stall, then the held frames all within a few ms. The clock
    /// used to start over at the stall (a second of frames all late), and the renderer again at each frame of
    /// the burst (each far earlier than a clock just anchored on a late one): seven starts over, each throwing
    /// the in-between images away.
    static func stallPattern(_ i: Int) -> Double {
        let nominal = { (i: Int) in 10 + Double(i) / 60 }
        let jitter = Double((i * 7919) % 4) / 1000
        if i < 120 { return nominal(i) + jitter }
        if (180...185).contains(i) { return nominal(185) + 0.052 - Double(185 - i) * 0.0015 } // held, then a burst
        return nominal(i) + 0.05 + jitter
    }

    @Test func aLateStretchAStallAndItsBurstKeepTheClock() throws {
        var clock = StreamClock(fps: 60)
        let interval = 1.0 / 60
        var times: [Double] = []
        for i in 0..<300 {
            let t = try tick(&clock, UInt64(i), Self.stallPattern(i))
            #expect(!t.restarted || i == 0, "\(i)")
            times.append(t.time)
        }
        // Frames stay a frame interval apart (to within 8%) through the stall and the burst: the playhead shows
        // them in order, and the only hold is the stall's own.
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
        #expect(gaps.allSatisfy { abs($0 - interval) <= interval * Playhead.stretch + 1e-9 }, "\(gaps.min() ?? 0)…\(gaps.max() ?? 0)")
    }

    @Test func slidesThroughALateStretchInsteadOfStartingOver() throws {
        // A stall shifts the stream's cadence 100 ms later for good: every frame from then on arrives 100 ms
        // behind the clock. The phase slides after it, never more than 8% of a frame per frame, so the frames
        // stay evenly spaced, and the lateness is gone within a couple of seconds.
        var clock = StreamClock(fps: 60)
        let interval = 1.0 / 60
        var times: [Double] = [], lateness = 0.0
        for i in 0..<600 {
            let arrival = 10 + Double(i) * interval + (i >= 120 ? 0.1 : 0)
            let t = try tick(&clock, UInt64(i), arrival)
            #expect(!t.restarted || i == 0)
            times.append(t.time)
            lateness = arrival - t.time
        }
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
        #expect(gaps.allSatisfy { $0 >= interval * (1 - 1e-9) && $0 <= interval * (1 + Playhead.stretch) + 1e-9 },
                "\(gaps.min() ?? 0)…\(gaps.max() ?? 0)")
        #expect(gaps.contains { $0 > interval * 1.05 }) // it did slide
        #expect(abs(lateness) < 0.002, "\(lateness)")
    }

    @Test func slidesBackWhenFramesComeEarlierThanTheClock() throws {
        // The clock started on a frame that was 100 ms late (the first after a gap); the rest, from the next
        // that got through, come on time, far earlier than it expects. It slides back by up to 8% of a frame
        // per frame: never a jump, never back in time.
        var clock = StreamClock(fps: 60)
        let interval = 1.0 / 60
        #expect(try tick(&clock, 0, 10.1).restarted)
        var times: [Double] = [], lead = 0.0
        for i in 7..<300 {
            let arrival = 10 + Double(i) * interval
            let t = try tick(&clock, UInt64(i), arrival)
            #expect(!t.restarted)
            times.append(t.time)
            lead = t.time - arrival
        }
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
        #expect(gaps.allSatisfy { $0 >= interval * (1 - Playhead.stretch) - 1e-9 && $0 <= interval * (1 + 1e-9) },
                "\(gaps.min() ?? 0)…\(gaps.max() ?? 0)")
        #expect(abs(lead) < 0.002, "\(lead)")
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

    @Test func neverStepsBackToAnOlderImage() {
        var timeline = FrameTimeline<String>()
        timeline.add(image("b", 2))
        #expect(timeline.next(now: 2, delay: 0)?.image == "b")
        // The in-between image of a and b, finished after b was shown: dropped, not shown next.
        timeline.add(image("ab", 1.5, generated: true))
        #expect(timeline.entries.isEmpty && timeline.skippedGenerated == 1)
        #expect(timeline.next(now: 3, delay: 0) == nil)
    }

    @Test func dropsTheOldestBeyondCapacity() {
        var timeline = FrameTimeline<String>(capacity: 2)
        for i in 0..<4 { timeline.add(image("\(i)", Double(i))) }
        #expect(timeline.entries.map(\.image) == ["2", "3"])
        #expect(timeline.skippedReal == 2)
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
        #expect(RungSelector(width: 1920, height: 1080).rungs.map(\.height) == [1080, 720, 544])
        #expect(RungSelector(width: 1280, height: 720).rungs.map(\.width) == [1280, 960])
        #expect(RungSelector(width: 960, height: 540).rungs.map(\.width) == [960])
        // Sides not a multiple of 16 come out empty from VideoToolbox: the stream's own size rounds down.
        #expect(RungSelector(width: 960, height: 540).rungs.map(\.height) == [528])
        #expect(RungSelector(width: 640, height: 360).rungs.map(\.height) == [352])
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

    @Test func triesTheLargerSizeAgainAfterASpike() {
        // At 30 fps the budget is 25 ms. One 1080p image took 30 ms (a hitch): down to 720p. The spike says
        // nothing about 1080p's steady cost, so once the 30 s block is over it's tried again.
        var s = RungSelector(width: 1920, height: 1080)
        s.observe(cost: 0.030, budget: 0.025, now: 0)
        #expect(s.size.width == 1280)
        s.observe(cost: 0.007, budget: 0.025, now: 20)
        #expect(s.size.width == 1280) // still blocked
        s.observe(cost: 0.007, budget: 0.025, now: 31)
        #expect(s.size.width == 1920) // back up
        s.observe(cost: 0.014, budget: 0.025, now: 32)
        #expect(s.size.width == 1920) // and it fits
    }

    @Test func dropsASizeThatDoesNotWork() {
        var s = RungSelector(width: 1920, height: 1080)
        let first = s.markBroken()
        #expect(first && s.size.width == 1280)
        let second = s.markBroken()
        #expect(second && s.size.width == 960)
        let third = s.markBroken()
        #expect(!third) // none left
        s.observe(cost: 0.001, budget: 1, now: 100) // lots of room, much later: broken sizes stay out
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

@Suite struct PresentationCountsTests {
    @Test func countsPresentedImagesAndDropsReportedAsZero() {
        var counts = PresentationCounts()
        for i in 0..<90 {
            let shown = counts.report(presentedAt: 10 + Double(i) / 60, generated: i % 2 == 1, now: 10)
            #expect(shown)
        }
        #expect(abs(counts.all.perSecond(now: 11.5) - 60) < 1)
        #expect(abs(counts.generated.perSecond(now: 11.5) - 30) < 1) // every other image
        let dropped = !counts.report(presentedAt: 0, generated: false, now: 11.6) // a drop
        #expect(dropped)
        #expect(counts.handled == 91 && counts.unpresented == 1)
    }

    @Test func displaysThatNeverReportTimesStillCount() {
        var counts = PresentationCounts()
        var shown = 0
        for i in 0..<60 where counts.report(presentedAt: 0, generated: false, now: Double(i) / 30) { shown += 1 }
        #expect(shown == 30) // the first 30 zeros are drops; after that the display just doesn't report times
        let timed = counts.report(presentedAt: 3, generated: false, now: 3) // a real time: back to normal
        let zero = counts.report(presentedAt: 0, generated: false, now: 3.1)
        #expect(timed && !zero)
    }
}

extension StreamRendererTests {
    /// The stall pattern (`StreamClockTests.stallPattern`) through the renderer, a 60 fps stream on a 120 Hz
    /// screen: the clock never starts over, every frame shown is newer than the last, the only hold is the stall
    /// itself, and from the burst on a new frame shows every frame interval. Before, the clock started over
    /// seven times here, and after the burst the picture held for a whole delay.
    @Test func aStallAndItsBurstNeitherStartOverNorHoldLongerThanTheStall() throws {
        let r = try #require(StreamRenderer(inputWidth: 16, inputHeight: 16))
        r.params.upscaler = .bilinear
        r.params.sharpness = 0
        r.streamFrameRate = 60
        // Frame i: its hundreds in the left half's luma, the rest in the right half's.
        func frame(_ i: Int) throws -> CVPixelBuffer {
            try makeNV12(width: 16, height: 16, cb: 128, cr: 128) { x, _ in x < 8 ? UInt8(30 + 40 * (i / 100)) : UInt8(20 + 2 * (i % 100)) }
        }
        func shown(_ p: [UInt8]) -> Int {
            func luma(_ x: Int) -> Double { Double(pixel(p, width: 16, x: x, y: 8).g) * 219 / 255 + 16 }
            return Int(((luma(2) - 30) / 40).rounded()) * 100 + Int(((luma(13) - 20) / 2).rounded())
        }
        let arrival = StreamClockTests.stallPattern
        let refresh = 1.0 / 120
        var next = 0, last = -1, lastNew = 10.0, now = 10.0
        var holds: [(from: Double, length: Double)] = []
        while now < 14.9 {
            while next < 300, arrival(next) <= now {
                r.display(try frame(next), index: UInt64(next), arrival: arrival(next))
                next += 1
            }
            let i = shown(try render(r, size: (16, 16), now: now))
            if i != last {
                #expect(i > last, "frame \(i) after \(last)")
                holds.append((lastNew, now - lastNew))
                (last, lastNew) = (i, now)
            }
            now += refresh
        }
        #expect(r.pacingParts.restarts == 1, "\(r.pacingParts.restarts)") // the stream's start
        let stall = arrival(180) - arrival(179)
        #expect(holds.allSatisfy { $0.length <= stall + refresh * 1.5 }, "\(holds.map(\.length).max() ?? 0)")
        let afterStall = holds.filter { $0.from >= arrival(180) }
        #expect(!afterStall.isEmpty && afterStall.allSatisfy { $0.length <= 1.0 / 60 + refresh * 1.5 },
                "\(afterStall.map(\.length).max() ?? 0)")
    }
}
