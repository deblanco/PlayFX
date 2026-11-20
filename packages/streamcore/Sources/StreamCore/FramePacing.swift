import Foundation

// Frame pacing: when each decoded (or generated) image goes on screen. Frames are shown by a clock built
// from their stream index, not when they happen to arrive, so network jitter neither drops nor bunches
// them. Pure value types with time passed in; the renderer owns them. See docs/FRAME_INTERPOLATION.md.

/// Timestamps for stream frames from their index and arrival (in seconds, on the host clock).
///
/// A frame's time is `anchor + (index − first) / fps + phase`. The phase follows the *lower envelope* of
/// `arrival − nominal` over the last second: network jitter only ever adds delay, so the earliest arrivals
/// show the stream's true timing. The phase moves at most 0.5% of a frame per frame, so a burst of jitter
/// can't make times jump; the stream's real rate (59.94 for "60") is followed through the phase.
///
/// When the envelope is more than half a frame from the phase (frames earlier than the clock expects, or the
/// earliest of the last second late: a stall shifted the stream's cadence), the phase slides there by up to
/// `Playhead.stretch` of a frame per frame instead: frames stay evenly spaced to within that, and the
/// playhead plays through them, so the screen doesn't see the change (starting the clock over there threw the
/// in-between images away and stepped the picture). Only a gap of over 200 ms, a jump of more than half a
/// second of frames, or a frame more than `reach` off the clock (a stream too far from its nominal rate to
/// slide after) starts over. Times always increase, across a start-over too, so nothing shown is ever older
/// than what was shown before.
struct StreamClock {
    let fps: Double
    /// Further off the clock than this (seconds), a frame starts it over: sliding can't follow.
    static let reach = 0.25
    private var anchor = 0.0
    private var firstIndex: UInt64 = 0
    private var lastIndex: UInt64 = 0
    private var lastArrival = 0.0
    private var lastTime = -Double.infinity
    private var phase = 0.0
    private var anchored = false
    /// (arrival, error) pairs, error increasing: the window's minimum is at the front.
    private var window: [(arrival: Double, error: Double)] = []

    init(fps: Double) { self.fps = fps > 0 ? fps : 60 }

    var interval: Double { 1 / fps }

    /// The frame's time, and whether the clock started over at it; nil for a frame out of order.
    mutating func time(index: UInt64, arrival: Double) -> (time: Double, restarted: Bool)? {
        if anchored, index <= lastIndex || arrival < lastArrival { return nil }
        let expected = anchor + Double(index - firstIndex) / fps + phase
        let restarted = !anchored || arrival - lastArrival > 0.2 || Double(index - lastIndex) > fps / 2
            || abs(arrival - max(expected, lastTime)) > Self.reach
        if restarted {
            anchor = arrival
            firstIndex = index
            phase = 0
            window.removeAll()
            anchored = true
        }
        let nominal = anchor + Double(index - firstIndex) / fps
        let error = arrival - nominal
        window.removeAll { $0.arrival <= arrival - 1 }
        while let last = window.last, last.error >= error { window.removeLast() }
        window.append((arrival, error))
        let target = window.first?.error ?? error
        let maxSlew = abs(target - phase) > interval / 2 ? interval * Playhead.stretch : interval / 200
        phase += min(max(target - phase, -maxSlew), maxSlew)
        let time = max(nominal + phase, lastTime + 1e-6)
        lastIndex = index
        lastArrival = arrival
        lastTime = time
        return (time, restarted)
    }
}

/// An image waiting to be shown: a decoded frame or one made between two of them.
struct TimedImage<Image> {
    let image: Image
    /// On the stream clock (seconds).
    let time: Double
    let generated: Bool
    /// When it reached the renderer (for the display-latency stat).
    let arrival: Double
}

/// The images about to be shown, in time order. Each refresh shows the newest one that is due
/// (its time plus the delay has passed); older due ones are skipped, and counted.
struct FrameTimeline<Image> {
    private(set) var entries: [TimedImage<Image>] = []
    private(set) var skippedReal = 0
    private(set) var skippedGenerated = 0
    /// The time of the image shown last: anything older that turns up afterwards (an in-between image
    /// finished late) would step the picture back, so it's dropped.
    private var shownTime = -Double.infinity
    /// How many images may wait; more means the screen is not keeping up, and the oldest go.
    let capacity: Int

    init(capacity: Int = 8) { self.capacity = capacity }

    var newestRealTime: Double? { entries.last(where: { !$0.generated })?.time }

    mutating func add(_ item: TimedImage<Image>) {
        guard item.time > shownTime else { return count(item) }
        let at = entries.firstIndex { $0.time > item.time } ?? entries.endIndex
        entries.insert(item, at: at)
        while entries.count > capacity { count(entries.removeFirst()) }
    }

    /// The image to show at `now`, given the delay; nil when nothing new is due.
    mutating func next(now: Double, delay: Double) -> TimedImage<Image>? {
        guard let last = entries.lastIndex(where: { $0.time + delay <= now }) else { return nil }
        let shown = entries[last]
        shownTime = shown.time
        for skipped in entries[..<last] { count(skipped) }
        entries.removeFirst(last + 1)
        return shown
    }

    private mutating func count(_ skipped: TimedImage<Image>) {
        if skipped.generated { skippedGenerated += 1 } else { skippedReal += 1 }
    }
}

/// How far behind the stream clock images are shown. Without interpolation it covers the network's
/// jitter; with it, also the part of an interval before the earliest in-between image (`lead`: half for one
/// image per pair, three quarters for quarters) and the time the images take, so they're ready by their
/// moment. Changes are eased (at most 1 ms per frame up, 0.25 ms down) so motion never steps.
struct DelayPlanner {
    /// Lateness of recent frames behind the clock (arrival − time), newest last.
    private var lateness: [Double] = []
    /// Recent time to make an in-between image.
    private var costs: [Double] = []
    private(set) var delay = 0.0
    /// Kept beyond the measured needs (seconds).
    let margin = 0.002

    mutating func observe(lateness value: Double) {
        lateness.append(max(0, value))
        if lateness.count > 120 { lateness.removeFirst(lateness.count - 120) }
    }

    mutating func observe(cost: Double) {
        costs.append(cost)
        if costs.count > 60 { costs.removeFirst(costs.count - 60) }
    }

    /// The 90th percentile of recent lateness behind the clock (0 before any).
    var jitter: Double { Self.percentile(lateness, 0.9) }

    /// The 90th percentile of recent generation cost (0 before any).
    var generationCost: Double { Self.percentile(costs, 0.9) }

    /// The delay wanted now, eased from the current one; call once per stream frame. `interval` is the
    /// time between the frames images are made between (the game's, when it runs slower than the stream).
    mutating func update(interval: Double, interpolating: Bool, lead: Double = 0.5) -> Double {
        var wanted = jitter + margin
        if interpolating { wanted += interval * lead + generationCost }
        let step = wanted > delay ? min(wanted - delay, 0.001) : max(wanted - delay, -0.00025)
        delay = max(0, delay + step)
        return delay
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }
}

/// The size in-between images are made at: the frame's own when there is time, smaller when not
/// (the Neural Engine's fast path, at or below 1280×720). Leaves a size at once when it misses its
/// budget, and doesn't try it again for 30 s; moves to a larger one after the choice has stood for 10 s,
/// when that size's measured cost fits with room to spare or it was last left over a cost spike.
struct RungSelector {
    /// Largest first. Each is a frame size the in-between images can be made at.
    let rungs: [(width: Int, height: Int)]
    private(set) var current = 0
    private var lastCost: [Int: Double] = [:]
    private var blockedUntil: [Int: Double] = [:]
    private var since = 0.0

    /// The rungs for a stream: its own size, then 1280×720 and 960×544 where they are smaller. At or below
    /// 1280×720 (VideoToolbox's fast path) both sides must be a multiple of 16, so a stream's own size is
    /// rounded down there and the lane scales back to the frame's size: otherwise VideoToolbox writes an empty
    /// image (measured at 960×540, 854×480 and 640×360; 1920×1080, on the slow path, is fine).
    init(width: Int, height: Int) {
        let fastPath = width * height <= 1280 * 720
        var list = [fastPath ? (width & ~15, height & ~15) : (width, height)]
        for r in [(1280, 720), (960, 544)] where r.0 * r.1 < width * height { list.append(r) }
        rungs = list
    }

    /// The current size doesn't work at all: never use it again, and move to the next smaller one.
    /// False when there is none left.
    mutating func markBroken() -> Bool {
        blockedUntil[current] = .infinity
        guard current + 1 < rungs.count else { return false }
        current += 1
        return true
    }

    var size: (width: Int, height: Int) { rungs[current] }

    /// Records the cost of an image made at the current rung; `budget` is the time it may take.
    mutating func observe(cost: Double, budget: Double, now: Double) {
        lastCost[current] = cost
        if cost > budget, current + 1 < rungs.count {
            // The cost that made it step down says little about the size's steady cost (often a one-off
            // spike), and nothing updates it while working smaller: forget it, so once the block is over the
            // size is tried again (and left again at once if it really is too slow).
            lastCost[current] = nil
            blockedUntil[current] = now + 30
            current += 1
            since = now
        } else if current > 0, now - since >= 10, now >= blockedUntil[current - 1, default: 0],
                  lastCost[current - 1].map({ $0 <= budget * 0.6 }) ?? true {
            current -= 1
            since = now
        }
    }
}

/// Whether two frames are across a cut (nothing to interpolate between): the mean difference of their
/// luma, sampled on a coarse grid, is large.
enum SceneCut {
    static let threshold = 40.0

    /// `luma(x, y)` for frame A and B, 0–255; the frame is sampled on a 32×18 grid.
    static func isCut(width: Int, height: Int, a: (Int, Int) -> UInt8, b: (Int, Int) -> UInt8) -> Bool {
        var total = 0.0, n = 0.0
        for gy in 0..<18 {
            for gx in 0..<32 {
                let x = (gx * 2 + 1) * width / 64, y = (gy * 2 + 1) * height / 36
                total += abs(Double(a(x, y)) - Double(b(x, y)))
                n += 1
            }
        }
        return total / n > threshold
    }
}

/// Repeated frames: a game running slower than the stream (30 fps in a 60 fps stream) is sent with each
/// picture twice, or unevenly (1/2/1/2 times for 40 fps). The encoder doesn't send the repeat as an exact
/// copy: it spends a few KB refining the same picture, so its luma differs a little everywhere and a lot
/// at a few pixels. Measured on a PS5 (GTA VI, 30 fps in a 1080p60 HEVC stream): a repeat's mean luma
/// change from the frame before is 0.02–0.4 against 0.6–8 for a new picture, with single pixels off by
/// up to 60 in both. So a frame is a repeat when its mean change is well under the last new picture's.
/// The reference shrinks with each repeat, so a scene that slows down still gets its new pictures through;
/// on a still screen a small moving object (a cursor) is all the change there is, and counts as new.
public struct RepeatDetector {
    /// A repeat changes less than this share of the last new picture's change (measured: up to about 0.45).
    static let ratio = 0.5
    /// The reference shrinks this much with each repeat: a camera that stops loses a frame or two, not more.
    static let decay = 0.5
    /// No more change than this (mean, 0–255) is the same picture whatever came before.
    static let unchanged = 0.001
    /// Every 4th pixel both ways: about 0.1 ms at 1080p. It runs on the decoder's thread for every frame, and
    /// a slow callback holds up the next decode and with it the receiving of packets (they get dropped).
    static let step = 4

    private var reference: Double?

    public init() {}

    /// The mean luma change between two frames, every `step` pixels both ways (staggered): `a` / `b` are their luma
    /// planes (0–255), `aRow` / `bRow` the bytes from one row to the next.
    @_optimize(speed) // optimized in debug builds too: a debug loop takes ~10 ms, most of a frame
    static func difference(width: Int, height: Int, a: UnsafePointer<UInt8>, aRow: Int,
                           b: UnsafePointer<UInt8>, bRow: Int) -> Double {
        guard width > 0, height > 0 else { return 0 }
        var total = 0, count = 0, y = 0
        // Plain loops: `stride` and `abs` aren't specialized in a debug build. Each sampled row starts one
        // column further on, so every column is read somewhere: an edge moving 2 pixels can't fall between
        // the samples of every row.
        while y < height {
            let ra = a + y * aRow, rb = b + y * bRow
            var x = (y / step) % step
            while x < width {
                let d = Int(ra[x]) &- Int(rb[x])
                total &+= d < 0 ? -d : d
                count &+= 1
                x &+= step
            }
            y &+= step
        }
        return Double(total) / Double(count)
    }

    /// Whether a frame that changed by `difference` from the one before repeats its picture.
    public mutating func isRepeat(difference: Double) -> Bool {
        if difference <= Self.unchanged || reference.map({ difference < Self.ratio * $0 }) == true {
            reference = reference.map { $0 * Self.decay }
            return true
        }
        reference = difference
        return false
    }

    mutating func reset() { reference = nil }
}

/// The game's own frame rate, from the stream-clock times of its new pictures (repeats left out): the mean
/// gap over the last ones, which also gives the right rate for an uneven cadence (40 fps in a 60 fps stream
/// arrives 1/2/1/2 stream frames apart; a median would say 30 or 60).
struct ContentRate {
    private var times: [Double] = []
    /// Pictures needed before there's a rate, and kept for it.
    static let window = 12

    /// A picture at `time`. One more than `maxGap` after the last (the game paused, its picture held) starts
    /// the count over: the pause isn't the game's rate.
    mutating func add(time: Double, maxGap: Double = .infinity) {
        if let last = times.last, time - last > maxGap { times.removeAll() }
        times.append(time)
        if times.count > Self.window { times.removeFirst(times.count - Self.window) }
    }

    /// The last picture's time.
    var last: Double? { times.last }

    mutating func reset() { times.removeAll() }

    /// Seconds between the game's pictures; nil until enough have come.
    var interval: Double? {
        guard times.count >= 5, let first = times.first, let last = times.last, last > first else { return nil }
        return (last - first) / Double(times.count - 1)
    }
}

/// Even times for the game's pictures. They reach the stream on its frame grid, so a 40 fps game's arrive
/// 16.7 and 33.3 ms apart, though the game made them 25 ms apart; frames made between them would move
/// unevenly. Once the rate is known this puts each picture on an even grid at that rate, never earlier than
/// its own time (it can't show before it arrives), starting over when the cadence breaks. Each picture is one
/// interval after the grid's last point, not a count of them after where it began: the measured interval
/// wobbles a little from picture to picture, and a count would multiply that.
struct CadenceClock {
    private var anchor = 0.0
    private var anchored = false
    private var last = -Double.infinity

    mutating func reset() { anchored = false }

    /// The time to show a picture whose stream-clock time is `time`, for a game `interval` apart (nil: unknown).
    mutating func time(for time: Double, interval: Double?) -> Double {
        guard let interval, interval > 0 else { reset(); last = time; return time }
        if anchored {
            let expected = anchor + interval
            if abs(time - expected) > interval * 0.6 {
                anchored = false // the cadence broke (a pause, a rate change): start over at this picture
            } else {
                // Never before its own time: move the grid later when a picture is later than it.
                anchor = max(expected, time)
                last = max(anchor, last + 1e-6)
                return last
            }
        }
        anchor = time
        anchored = true
        last = max(time, last + 1e-6)
        return last
    }
}

/// The in-between images for a pair of the game's pictures at stream-clock times `start` and `end`: every
/// point VideoToolbox makes between the two (`steps` = 1: ½; 2: ¼, ½, ¾), each stamped with its own moment
/// in the game. Which refresh shows which is the playhead's business (see `Playhead`), so nothing here
/// depends on guessing when the screen will refresh.
enum InBetween {
    struct Image: Equatable {
        /// Where between the two pictures (0–1, one of the processor's points).
        let phase: Float
        /// The stream-clock time it shows at: its own moment between the two pictures.
        let time: Double
    }

    static func images(start: Double, end: Double, steps: Int) -> [Image] {
        let span = end - start
        guard span > 0, steps >= 1 else { return [] }
        let points = 1 << steps
        return (1..<points).map { Image(phase: Float($0) / Float(points), time: start + span * Double($0) / Double(points)) }
    }

    /// How many points to make for a game `interval` apart on a screen refreshing every `refreshInterval`:
    /// halves (one image) while the screen shows about two refreshes per picture or fewer, quarters (three)
    /// beyond that. Each change rebuilds VideoToolbox's session, so a game whose rate wanders near the edge
    /// (50–57 fps on 120 Hz) keeps what it has: quarters are taken from 2.3× and kept down to 2.1×.
    static func steps(interval: Double, refreshInterval: Double, current: Int = 2) -> Int {
        guard interval > 0, refreshInterval > 0 else { return current }
        return interval / refreshInterval < (current == 1 ? 2.3 : 2.1) ? 1 : 2
    }

    /// The screen's fastest recent refresh interval, from one more measured `sample`: it follows a faster
    /// screen at once and a slower one over seconds. A display that changes its rate from moment to moment
    /// (ProMotion goes between 60 and 120 Hz) would otherwise flip the choice of points back and forth.
    static func fastest(_ current: Double, _ sample: Double) -> Double {
        guard sample > 0 else { return current }
        return current <= 0 ? sample : min(sample, current + (sample - current) * 0.002)
    }
}

/// Where in the stream's time the screen is: each refresh shows the newest image at or before it.
///
/// It follows `now − delay`, but as a moving point with a speed, not a subtraction: the speed may leave 1 by
/// at most `stretch`, so when the delay changes, or after a wait, the motion runs a little slower or faster
/// for a moment instead of standing still and then jumping. And it never passes `limit`, the last moment
/// whose images are all there: when a picture is late, it waits just before the gap and, once the picture and
/// the images towards it exist, moves through every one of them while catching up. This is what a voice call
/// does with late sound (play out a little slower or faster); the images made between the game's pictures
/// are what make it possible for video, since they give moments close enough together to pass through at a
/// changed speed.
struct Playhead {
    /// How far the speed may leave 1: 8%, too little to see as a change of speed.
    static let stretch = 0.08
    /// The speed leaves 1 by (the distance to where it should be) / `gain`: 40 ms off gives the full 8%.
    static let gain = 0.5
    /// Further behind where it should be than this (seconds), it moves there at once: a start, the end of a
    /// pause. Ahead of it, it only ever slows down: it never goes back.
    static let jump = 0.25

    private(set) var position: Double?
    private var last = 0.0

    /// The stream starts over at `time` (a new stream, or a gap): the image there shows at once, and the playhead
    /// goes on from it, slowing to fall back to its delay, rather than snapping back a whole delay behind it and
    /// holding the picture that long. Never back: when it's past `time` already, it stays.
    mutating func start(at time: Double) { position = max(position ?? time, time) }

    /// The `limit` while images are made between the game's pictures: just before the first picture whose images
    /// aren't all made yet, the one after `populated` (until then the picture before it is what shows anyway).
    /// Once the lane has had a pair in hand (since `pendingSince`) for longer than `wait`, as while VideoToolbox
    /// builds a model for a new size (a second or more), it counts from the `newest` picture instead: the screen
    /// goes on without that pair's images rather than holding one picture until they're made. `step`: the time
    /// between images.
    static func limit(populated: Double?, newest: Double?, pendingSince: Double?, now: Double, wait: Double,
                      step: Double) -> Double? {
        let stalled = pendingSince.map { now - $0 > wait } ?? false
        return (stalled ? newest : populated).map { $0 + step * 0.99 }
    }

    /// Moves to the refresh at `now` and returns the stream time to show. `limit`: don't pass this (nil: free).
    /// `refresh` is the screen's steady time between refreshes (0: unknown): the draw callback's own timing
    /// wobbles by a millisecond or two, enough to land on the wrong side of an image's moment, so one
    /// refresh moves it by the steady period, and `now` only says where it should be overall.
    mutating func advance(now: Double, delay: Double, limit: Double? = nil, refresh: Double = 0) -> Double {
        let target = now - delay
        defer { last = now }
        // A first refresh, one again, one after a long wait or a target far ahead: move there at once.
        guard let from = position, now > last, now - last <= Self.jump, target - from <= Self.jump else {
            let to = max(min(target, limit ?? target), position ?? -.infinity) // never back
            position = to
            return to
        }
        // How far off it would be after this refresh at normal speed decides the speed.
        let gap = now - last
        let step = refresh > 0 && abs(gap - refresh) < refresh / 2 ? refresh : gap
        let speed = 1 + min(max((target - from - step) / Self.gain, -Self.stretch), Self.stretch)
        var to = from + step * speed
        if let limit { to = min(to, max(limit, from)) }
        position = to
        return to
    }
}

/// The pair the interpolation lane has in hand, as the renderer counts it. A pair is marked before it's handed
/// over: the lane can be done with it (a cut, a size that fails at once) before `submit` has even returned, and
/// marking it after would leave it counted in hand with nothing there.
struct LaneHandoff {
    /// When the lane was handed the pair it is making images for (nil: none in hand).
    private(set) var since: Double?
    private var inHand = 0

    /// A pair is about to be handed over, at `arrival`.
    mutating func handing(at arrival: Double) {
        inHand += 1
        if since == nil { since = arrival }
    }

    /// The lane took the pair or not. True when nothing is in hand any more (one not taken was the last).
    mutating func handed(taken: Bool, at arrival: Double) -> Bool {
        guard taken else { return finished() }
        if inHand > 0 { since = arrival } // taken: the one before it is done
        return false
    }

    /// The lane is done with a pair. True when nothing is in hand any more.
    mutating func finished() -> Bool {
        inHand -= 1
        guard inHand == 0 else { return false }
        since = nil
        return true
    }
}
