import CoreVideo
import Foundation
import Testing
@testable import StreamCore

/// Frame generation from the game's own frame rate: repeats left out, the game's rate measured, its pictures
/// put on an even grid, and one image planned per screen refresh.
@Suite struct GameRateTests {
    /// The mean change between two 1920×1080 luma planes made by `a(x, y)` and `b(x, y)`.
    func difference(_ a: (Int, Int) -> UInt8, _ b: (Int, Int) -> UInt8, width: Int = 1920, height: Int = 1080) -> Double {
        let pa = (0..<width * height).map { a($0 % width, $0 / width) }
        let pb = (0..<width * height).map { b($0 % width, $0 / width) }
        return pa.withUnsafeBufferPointer { ra in
            pb.withUnsafeBufferPointer { rb in
                RepeatDetector.difference(width: width, height: height, a: ra.baseAddress!, aRow: width, b: rb.baseAddress!, bRow: width)
            }
        }
    }

    @Test func measuresHowMuchThePictureChanged() {
        let still: (Int, Int) -> UInt8 = { x, y in UInt8((x * 3 + y * 7) % 200) }
        #expect(difference(still, still) == 0)
        #expect(difference(still, { x, y in still(x, y) &+ 2 }) == 2)
        // A 4-pixel square, anywhere, is seen.
        for (ox, oy) in [(900, 500), (2, 1070), (1916, 6)] {
            let moved: (Int, Int) -> UInt8 = { x, y in (ox..<ox + 4).contains(x) && (oy..<oy + 4).contains(y) ? 250 : still(x, y) }
            #expect(difference(still, moved) > RepeatDetector.unchanged, "(\(ox), \(oy))")
        }
        // An edge moving 2 pixels is seen wherever it lands (a fixed every-4th-pixel grid misses half of them).
        for x in stride(from: 100, to: 108, by: 2) {
            let bar: (Int) -> (Int, Int) -> UInt8 = { at in { px, _ in px >= at && px < at + 60 ? 220 : 40 } }
            #expect(difference(bar(x), bar(x + 2)) > RepeatDetector.unchanged, "at \(x)")
        }
        #expect(difference(still, still, width: 0, height: 0) == 0)
    }

    /// Each frame's mean change from the one before; true where it's a repeat.
    func repeats(_ differences: [Double]) -> [Bool] {
        var detector = RepeatDetector()
        return differences.map { detector.isRepeat(difference: $0) }
    }

    @Test func tellsTheEncodersRefinedRepeatsFromNewPictures() {
        // Measured on a PS5, GTA VI (30 fps) in a 1080p60 stream: the repeats aren't exact copies.
        #expect(repeats([0.96, 0.08, 0.94, 0.06, 0.98, 0.10, 0.90, 0.42, 0.95, 0.17]) ==
                [false, true, false, true, false, true, false, true, false, true])
        // A 60 fps game: every frame is new, as its motion speeds up and slows down.
        #expect(repeats([0.9, 0.95, 0.6, 0.85, 1.5, 2.8, 3.0, 2.0, 1.2, 0.7]).allSatisfy { !$0 })
        // 20 fps: two repeats after each picture.
        #expect(repeats([1.0, 0.1, 0.08, 0.9, 0.12, 0.05, 1.1]) == [false, true, true, false, true, true, false])
        // An exact copy is a repeat, even first.
        #expect(repeats([0, 0.5, 0]) == [true, false, true])
    }

    @Test func aSceneThatSlowsDownStillGetsItsPicturesThrough() {
        // The camera stops: pictures change far less than before. A few are taken for repeats, then they count.
        let seen = repeats([2.0] + Array(repeating: 0.3, count: 10))
        let missed = seen.dropFirst().prefix { $0 }.count
        #expect(missed <= 2)
        #expect(seen.suffix(10 - missed).allSatisfy { !$0 })
        // A still screen, then a small cursor moving: once the stillness has settled, each move is new.
        var detector = RepeatDetector()
        _ = detector.isRepeat(difference: 1.0)
        let still = (0..<60).map { _ in detector.isRepeat(difference: 0) }
        let cursor = (0..<10).map { _ in detector.isRepeat(difference: 0.002) }
        #expect(still.allSatisfy { $0 } && cursor.allSatisfy { !$0 })
        detector.reset()
        let first = detector.isRepeat(difference: 0.002)
        #expect(!first)
    }

    @Test func measuresTheChangeInDecodedFrames() throws {
        let a = try makeNV12(width: 640, height: 360, y: 80, cb: 128, cr: 128)
        let same = try makeNV12(width: 640, height: 360, y: 81, cb: 128, cr: 128)
        let other = try makeNV12(width: 640, height: 360, cb: 128, cr: 128) { x, _ in x > 320 ? 200 : 80 }
        #expect(InterpolationLane.difference(a, same) == 1)
        #expect((InterpolationLane.difference(a, other) ?? 0) > 50)
        #expect(InterpolationLane.difference(a, try makeNV12(width: 320, height: 180, y: 80, cb: 128, cr: 128)) == nil)
        #expect(StreamSession.pictureDifference(a, a) == 0)
    }

    @Test func measuresTheGamesRateEvenWhenItsCadenceIsUneven() {
        var rate = ContentRate()
        #expect(rate.interval == nil)
        // 30 fps in a 60 fps stream: every other stream frame.
        for k in 0..<12 { rate.add(time: Double(k) * 2 / 60) }
        #expect(abs((rate.interval ?? 0) - 1.0 / 30) < 1e-9)
        // 40 fps: 1, 2, 1, 2 stream frames apart; the mean says 40 (a median would say 30 or 60).
        rate.reset()
        var t = 0.0
        for k in 0..<13 { rate.add(time: t); t += (k % 2 == 0 ? 1 : 2) / 60.0 }
        #expect(abs(1 / (rate.interval ?? 1) - 40) < 1.5)
        rate.reset()
        #expect(rate.interval == nil)
        // A pause (the picture held for seconds) isn't the game's rate: the count starts over after it.
        for k in 0..<12 { rate.add(time: Double(k) / 30, maxGap: 0.075) }
        rate.add(time: 5, maxGap: 0.075)
        #expect(rate.interval == nil && rate.last == 5)
        for k in 1..<6 { rate.add(time: 5 + Double(k) / 30, maxGap: 0.075) }
        #expect(abs((rate.interval ?? 0) - 1.0 / 30) < 1e-9)
    }

    @Test func putsTheGamesPicturesOnAnEvenGrid() {
        var cadence = CadenceClock()
        // 40 fps on a 60 fps stream grid: 0, 16.7, 50, 66.7, 100 ms … become 25 ms apart, never earlier.
        let arrivals = [0.0, 1, 3, 4, 6, 7, 9].map { $0 / 60 }
        let times = arrivals.map { cadence.time(for: $0, interval: 1.0 / 40) }
        for (time, arrival) in zip(times, arrivals) { #expect(time >= arrival - 1e-9) }
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        for gap in gaps.dropFirst() { #expect(abs(gap - 0.025) < 0.0005, "\(gaps)") }
        // A break in the cadence (a pause) starts over at the picture.
        #expect(cadence.time(for: 2.0, interval: 1.0 / 40) == 2.0)
        // Unknown rate: the picture's own time.
        #expect(cadence.time(for: 2.5, interval: nil) == 2.5)
    }

    @Test(arguments: [[1.0, 2], [1, 1, 2], [2]])
    func keepsTheGridEvenWithTheMeasuredRate(cadenceFrames: [Double]) {
        // As the renderer drives it: ContentRate's measured interval, which wobbles from picture to picture
        // when the cadence doesn't divide its window, fed into the clock for every new picture.
        var rate = ContentRate()
        var cadence = CadenceClock()
        var arrival = 0.0
        var times: [Double] = []
        for k in 0..<600 {
            rate.add(time: arrival)
            times.append(cadence.time(for: arrival, interval: rate.interval))
            arrival += (cadenceFrames[k % cadenceFrames.count]) / 60
        }
        let expected = cadenceFrames.reduce(0, +) / Double(cadenceFrames.count) / 60
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }.dropFirst(60)
        for gap in gaps { #expect(abs(gap - expected) < 0.002, "\(1 / expected) fps: \(gap * 1000) ms") }
    }

    @Test func stampsEachImageWithItsOwnMomentBetweenTwoPictures() {
        // Halves: one image, halfway in time too.
        let half = InBetween.images(start: 1, end: 1 + 1.0 / 30, steps: 1)
        #expect(half.map(\.phase) == [0.5] && abs(half[0].time - (1 + 1.0 / 60)) < 1e-9)
        // Quarters: three, evenly spaced between the two pictures, whatever the screen does.
        let quarters = InBetween.images(start: 1, end: 1 + 1.0 / 30, steps: 2)
        #expect(quarters.map(\.phase) == [0.25, 0.5, 0.75])
        for (image, k) in zip(quarters, 1...) { #expect(abs(image.time - (1 + Double(k) / 120)) < 1e-9) }
        // Nothing between pictures at the same time, or out of order.
        #expect(InBetween.images(start: 1, end: 1, steps: 1).isEmpty)
        #expect(InBetween.images(start: 2, end: 1, steps: 2).isEmpty)
        #expect(InBetween.images(start: 1, end: 2, steps: 0).isEmpty)
    }

    @Test func choosesQuartersOnlyWhenTheScreenIsWellOverTwiceAsFast() {
        #expect(InBetween.steps(interval: 1.0 / 30, refreshInterval: 1.0 / 60) == 1)
        #expect(InBetween.steps(interval: 1.0 / 30, refreshInterval: 1.0 / 120) == 2)
        #expect(InBetween.steps(interval: 1.0 / 30, refreshInterval: 1.0 / 75) == 2)
        #expect(InBetween.steps(interval: 1.0 / 60, refreshInterval: 1.0 / 75) == 1) // one image is all 75 Hz can show
        #expect(InBetween.steps(interval: 1.0 / 60, refreshInterval: 1.0 / 120) == 1)
        #expect(InBetween.steps(interval: 0, refreshInterval: 1.0 / 60, current: 1) == 1) // unknown: kept
        // A rate wandering near the edge doesn't flip it back and forth (each flip rebuilds VideoToolbox's session).
        let edge = 1.0 / 55, refresh = 1.0 / 120 // 2.18×
        #expect(InBetween.steps(interval: edge, refreshInterval: refresh, current: 2) == 2)
        #expect(InBetween.steps(interval: edge, refreshInterval: refresh, current: 1) == 1)
        #expect(InBetween.steps(interval: 1.0 / 50, refreshInterval: refresh, current: 1) == 2) // 2.4×: left
    }

    @Test func remembersTheScreensFastestRecentRefresh() {
        // A ProMotion screen dipping to 60 Hz for a moment: still a 120 Hz screen.
        var interval = InBetween.fastest(0, 1.0 / 120)
        #expect(interval == 1.0 / 120)
        for _ in 0..<60 { interval = InBetween.fastest(interval, 1.0 / 60) }
        #expect(interval < 1.0 / 105)
        interval = InBetween.fastest(interval, 1.0 / 120)
        #expect(interval == 1.0 / 120) // back at once
        // A screen that really is slower gets there in seconds.
        for _ in 0..<3_000 { interval = InBetween.fastest(interval, 1.0 / 60) }
        #expect(abs(interval - 1.0 / 60) < 0.0001)
        #expect(InBetween.fastest(interval, 0) == interval)
    }

    @Test func knowsTheProcessorsPoints() {
        #expect(FrameInterpolator.isPoint(0.5, steps: 1))
        #expect(!FrameInterpolator.isPoint(0.25, steps: 1))
        #expect(FrameInterpolator.isPoint(0.75, steps: 2))
        #expect(!FrameInterpolator.isPoint(0, steps: 2) && !FrameInterpolator.isPoint(1, steps: 2))
        #expect(!FrameInterpolator.isPoint(0.3, steps: 2))
    }

    @Test func interpolatesFromSixtyOnSeventyFiveHertzButNotOnSixty() {
        #expect(FrameInterpolator.helps(streamInterval: 1.0 / 60, displayInterval: 1.0 / 75))
        #expect(!FrameInterpolator.helps(streamInterval: 1.0 / 60, displayInterval: 1.0 / 60))
    }
}

extension StreamRendererTests {
    /// A 30 fps game in a 60 fps stream on a 60 Hz screen: every other stream frame repeats the picture.
    /// The repeats are counted and left out, the game's rate is measured, and an image is made halfway
    /// between its pictures, so the screen moves every refresh.
    @Test func interpolatesBetweenTheGamesPicturesNotTheStreamsFrames() throws {
        let r = try #require(StreamRenderer(inputWidth: 640, inputHeight: 360))
        r.params.upscaler = .bilinear
        r.params.sharpness = 0
        r.params.frameInterpolation = true
        r.streamFrameRate = 60
        func bar(at x: Int) throws -> CVPixelBuffer {
            try makeNV12(width: 640, height: 360, cb: 128, cr: 128) { px, _ in px >= x && px < x + 60 ? 220 : 40 }
        }
        let refresh = 1.0 / 60
        for k in 0..<24 {
            // The picture changes on even stream frames only.
            r.display(try bar(at: 100 + 10 * (k / 2)), index: UInt64(k), arrival: Double(k) * refresh)
            r.waitForInterpolation()
            _ = try render(r, size: (64, 36), now: Double(k) * refresh)
        }
        #expect(r.repeatedFrames == 12)
        #expect(abs(r.pipeline.gameFps - 30) < 1)
        #expect(abs(r.pipeline.streamFps - 60) < 1) // the stream's own rate, not the game's
        if FrameInterpolator.isAvailable {
            #expect(r.pipeline.interpolation == .on)
            // The game holds its picture (a pause): said apart from "not making any".
            _ = try render(r, size: (64, 36), now: 24 * refresh + 0.5)
            #expect(r.pipeline.interpolation == .still)
        } else {
            #expect(r.pipeline.interpolation == .unsupported)
        }
    }
}

/// The playhead: where in the stream's time the screen is.
@Suite struct PlayheadTests {
    let refresh = 1.0 / 120

    @Test func followsTheClockBehindByTheDelay() {
        var playhead = Playhead()
        #expect(playhead.position == nil)
        #expect(playhead.advance(now: 10, delay: 0.05) == 9.95) // starts where it should be
        var at = 0.0
        for k in 1...240 { at = playhead.advance(now: 10 + Double(k) * refresh, delay: 0.05) }
        #expect(abs(at - 11.95) < 1e-9)
    }

    @Test func aChangedDelayChangesTheSpeedNotThePosition() {
        // The delay grows by 20 ms: the old way stood still for 20 ms. The playhead runs 4% slower for a while.
        var playhead = Playhead()
        var last = playhead.advance(now: 10, delay: 0.05)
        var slowest = 1.0, fastest = 1.0
        for k in 1...600 {
            let at = playhead.advance(now: 10 + Double(k) * refresh, delay: 0.07)
            let speed = (at - last) / refresh
            slowest = min(slowest, speed)
            fastest = max(fastest, speed)
            last = at
        }
        #expect(slowest >= 1 - Playhead.stretch - 1e-9 && slowest < 0.97 && fastest <= 1 + 1e-9)
        #expect(abs(last - (15 - 0.07)) < 0.001) // and it gets there
        // The delay shrinks again: a little faster, never a jump.
        for k in 601...1200 {
            let at = playhead.advance(now: 10 + Double(k) * refresh, delay: 0.05)
            fastest = max(fastest, (at - last) / refresh)
            last = at
        }
        #expect(fastest <= 1 + Playhead.stretch + 1e-9 && fastest > 1.03)
        #expect(abs(last - (20 - 0.05)) < 0.001)
    }

    @Test func waitsBeforeALatePictureThenCatchesUpWithoutAJump() {
        var playhead = Playhead()
        _ = playhead.advance(now: 10, delay: 0.05)
        // Nothing is there past 10: it stops just there (a picture is 30 ms late).
        var at = 0.0
        for k in 1...10 { at = playhead.advance(now: 10 + Double(k) * refresh, delay: 0.05, limit: 10) }
        #expect(at == 10)
        // The picture and the images towards it arrive: it moves on from where it was, a little fast.
        var last = at, largest = 0.0
        for k in 11...600 {
            at = playhead.advance(now: 10 + Double(k) * refresh, delay: 0.05, limit: 100)
            largest = max(largest, at - last)
            last = at
        }
        #expect(largest <= refresh * (1 + Playhead.stretch) + 1e-9) // never more than 8% over one refresh's worth
        #expect(abs(at - (15 - 0.05)) < 0.001)
        // A limit behind it doesn't pull it back.
        #expect(playhead.advance(now: 15 + refresh, delay: 0.05, limit: 3) == at)
    }

    @Test func aWobblyDrawCallbackDoesNotMakeItsStepsUneven() {
        // Draws come 6.8–9.9 ms apart on a 120 Hz screen (measured); the playhead still moves one steady
        // refresh period at a time, so it lands on the same side of each image's moment.
        var steady = Playhead(), raw = Playhead()
        var now = 10.0, lastSteady = steady.advance(now: now, delay: 0.05, refresh: refresh)
        var lastRaw = raw.advance(now: now, delay: 0.05)
        var steadySpread = 0.0, rawSpread = 0.0
        for k in 1...600 {
            now = 10 + Double(k) * refresh + (k % 2 == 0 ? 0.0015 : -0.0015)
            let a = steady.advance(now: now, delay: 0.05, refresh: refresh), b = raw.advance(now: now, delay: 0.05)
            steadySpread = max(steadySpread, abs(a - lastSteady - refresh))
            rawSpread = max(rawSpread, abs(b - lastRaw - refresh))
            lastSteady = a
            lastRaw = b
        }
        #expect(steadySpread < 0.0001 && rawSpread > 0.002)
        #expect(abs(lastSteady - (15 - 0.05)) < 0.002) // and it stays where it should be
        // A skipped refresh (twice the period) moves it by the real gap.
        let before = lastSteady
        #expect(abs(steady.advance(now: now + 2 * refresh, delay: 0.05, refresh: refresh) - before - 2 * refresh) < 0.0005)
    }

    @Test func movesAtOnceWhenFarOff() {
        var playhead = Playhead()
        _ = playhead.advance(now: 10, delay: 0.05)
        // A pause: held at the limit while the clock runs on, then the game goes on a second later.
        for k in 1...120 { _ = playhead.advance(now: 10 + Double(k) * refresh, delay: 0.05, limit: 9.96) }
        #expect(playhead.position == 9.96)
        #expect(abs(playhead.advance(now: 11 + refresh, delay: 0.05, limit: 100) - (11 + refresh - 0.05)) < 1e-9)
        // The same refresh again changes nothing.
        let at = playhead.position
        #expect(playhead.advance(now: 11 + refresh, delay: 0.05, limit: 100) == at)
        // A first refresh after a long wait goes there at once too.
        #expect(abs(playhead.advance(now: 13, delay: 0.05, limit: 100) - 12.95) < 1e-9)
    }

    @Test func startsOverAtAFrameAndGoesOnFromItNeverBack() {
        // A new stream: the first image shows at once.
        var playhead = Playhead()
        playhead.start(at: 5)
        #expect(playhead.advance(now: 5.001, delay: 0.1) == 5)
        // After a gap the clock starts over at a frame that arrived just now, a whole delay ahead of where the
        // playhead should be. It shows that frame at once and slows down (never back) until it's behind by
        // the delay again, instead of holding the picture for the delay.
        playhead = Playhead()
        _ = playhead.advance(now: 10, delay: 0.1)
        playhead.start(at: 10.3)
        playhead.start(at: 10.2) // a start before where it is doesn't pull it back
        var last = playhead.advance(now: 10.3 + refresh, delay: 0.1)
        #expect(last >= 10.3)
        var slowest = 1.0
        for k in 2...1200 {
            let at = playhead.advance(now: 10.3 + Double(k) * refresh, delay: 0.1)
            #expect(at > last)
            slowest = min(slowest, (at - last) / refresh)
            last = at
        }
        #expect(slowest >= 1 - Playhead.stretch - 1e-9)
        #expect(abs(last - (10.3 + 1200 * refresh - 0.1)) < 0.001) // back to its delay
        // Even a delay far longer than it was all at once (more than a jump) slows it rather than pulling it back.
        let before = last
        #expect(playhead.advance(now: 10.3 + 1201 * refresh, delay: 0.5) > before)
    }

    /// The lane holds a pair for a second or more while VideoToolbox builds a model (a stream's start, a new
    /// size): the playhead waits for that pair's images only for `wait`, then goes on from the newest picture
    /// instead of holding the one before the pair until they're made.
    @Test func aPairHeldWhileAModelIsBuiltHoldsThePictureOnlyBriefly() {
        let picture = 1.0 / 30, step = picture / 4, delay = 0.05, wait = delay + picture
        var playhead = Playhead()
        let pairFrom = 10.0, handed = 10.0 + delay + picture // the pair after the picture at 10, in hand from then
        var now = 10.0 + delay, last = 0.0, longest = 0.0, held = now
        while now < 12 {
            let newest = 10 + ((now - delay - 10) / picture).rounded(.down) * picture // pictures keep coming
            let limit = Playhead.limit(populated: pairFrom, newest: newest, pendingSince: now >= handed ? handed : nil,
                                       now: now, wait: wait, step: step)
            let at = playhead.advance(now: now, delay: delay, limit: limit, refresh: refresh)
            if at > last + 1e-9 { (last, held) = (at, now) } else { longest = max(longest, now - held) }
            now += refresh
        }
        #expect(longest <= wait + delay, "\(longest)") // before, the whole build: here two seconds and counting
        #expect(abs(last - (12 - delay)) < 0.1, "\(last)")
        // Not waiting on the lane, or not for long: up to the last picture with all its images.
        #expect(Playhead.limit(populated: 10, newest: 11, pendingSince: nil, now: 12, wait: wait, step: step) == 10 + step * 0.99)
        #expect(Playhead.limit(populated: 10, newest: 11, pendingSince: 11.95, now: 12, wait: wait, step: step) == 10 + step * 0.99)
        #expect(Playhead.limit(populated: 10, newest: 11, pendingSince: 11, now: 12, wait: wait, step: step) == 11 + step * 0.99)
        #expect(Playhead.limit(populated: nil, newest: nil, pendingSince: nil, now: 12, wait: wait, step: step) == nil)
    }

    /// What the screen shows over a stretch of a 30 fps game with quarters made, on a 118.8 Hz screen, while
    /// the delay drifts as it does on a real connection (eased up to 1 ms per picture): the images each
    /// refresh shows, as steps of 1/120 s.
    @Test func everyRefreshShowsTheNextImageWhileTheDelayDrifts() {
        var timeline = FrameTimeline<Int>(capacity: 16)
        var playhead = Playhead()
        let picture = 1.0 / 30, screen = 1.0 / 118.8
        var delay = 0.08, now = 10.0, added = 0, shown: [Int] = []
        for refreshIndex in 0..<1_200 {
            now = 10 + Double(refreshIndex) * screen
            // Each picture, with the three images before it, is in the timeline 20 ms after its own time.
            while Double(added) * picture <= now - 10 - 0.02 {
                for q in (added == 0 ? 0 : -3)...0 { timeline.add(TimedImage(image: added * 4 + q, time: 10 + (Double(added) + Double(q) / 4) * picture, generated: q != 0, arrival: now)) }
                added += 1
            }
            delay += refreshIndex % 240 < 120 ? 0.00025 : -0.00025 // up 30 ms, down 30 ms
            if let item = timeline.next(now: playhead.advance(now: now, delay: delay), delay: 0) { shown.append(item.image) }
        }
        let steps = zip(shown, shown.dropFirst()).map { $1 - $0 }
        #expect(steps.allSatisfy { $0 == 1 || $0 == 2 }) // never back, never more than one image skipped
        // New images on nearly every refresh (the screen is a little slower than 120, and the playhead
        // slows by up to 8% while the delay grows).
        #expect(Double(shown.count) / 1_200 > 0.9, "\(shown.count)")
    }
}
