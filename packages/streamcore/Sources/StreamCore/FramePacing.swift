import Foundation

// Frame pacing: when each decoded (or generated) image goes on screen. Frames are shown by a clock built
// from their stream index, not when they happen to arrive, so network jitter neither drops nor bunches
// them. Pure value types with time passed in; the renderer owns them. See docs/FRAME_INTERPOLATION.md.

/// Timestamps for stream frames from their index and arrival (in seconds, on the host clock).
///
/// A frame's time is `anchor + (index − first) / fps + phase`. The phase follows the *lower envelope* of
/// `arrival − nominal` over the last second: network jitter only ever adds delay, so the earliest arrivals
/// show the stream's true timing. The phase moves at most 0.5% of a frame per frame, so a burst of jitter
/// can't make times jump or run backwards; the stream's real rate (59.94 for "60") is followed through
/// the phase. A gap of over 200 ms, or a jump of more than half a second of frames, starts over; so does
/// a second of frames all more than two intervals late (the stream fell behind its clock for good, e.g. it
/// runs slower than its nominal rate, or a stall shifted its cadence), which the slow phase can't catch.
struct StreamClock {
    let fps: Double
    private var anchor = 0.0
    private var firstIndex: UInt64 = 0
    private var lastIndex: UInt64 = 0
    private var lastArrival = 0.0
    private var lastTime = 0.0
    private var phase = 0.0
    private var anchored = false
    /// Consecutive frames more than two intervals behind the clock.
    private var lateRun = 0
    /// (arrival, error) pairs, error increasing: the window's minimum is at the front.
    private var window: [(arrival: Double, error: Double)] = []

    init(fps: Double) { self.fps = fps > 0 ? fps : 60 }

    var interval: Double { 1 / fps }

    /// The frame's time, and whether the clock started over at it; nil for a frame out of order.
    mutating func time(index: UInt64, arrival: Double) -> (time: Double, restarted: Bool)? {
        if anchored, index <= lastIndex || arrival < lastArrival { return nil }
        var restarted = !anchored
        if !anchored || arrival - lastArrival > 0.2 || Double(index - lastIndex) > fps / 2 || Double(lateRun) >= fps {
            anchor = arrival
            firstIndex = index
            phase = 0
            window.removeAll()
            anchored = true
            restarted = true
            lateRun = 0
        }
        let nominal = anchor + Double(index - firstIndex) / fps
        let error = arrival - nominal
        window.removeAll { $0.arrival <= arrival - 1 }
        while let last = window.last, last.error >= error { window.removeLast() }
        window.append((arrival, error))
        let maxSlew = interval / 200
        phase += min(max((window.first?.error ?? error) - phase, -maxSlew), maxSlew)
        var time = nominal + phase
        if !restarted { time = max(time, lastTime + 1e-6) }
        lateRun = arrival - time > 2 * interval ? lateRun + 1 : 0
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

    /// Forgets everything (a new stream or a clock restart).
    mutating func clear() {
        entries.removeAll()
        shownTime = -.infinity
    }

    private mutating func count(_ skipped: TimedImage<Image>) {
        if skipped.generated { skippedGenerated += 1 } else { skippedReal += 1 }
    }
}

/// How far behind the stream clock images are shown. Without interpolation it covers the network's
/// jitter; with it, also half an interval and the time an in-between image takes, so that image is
/// ready by its moment. Changes are eased (at most 1 ms per frame up, 0.25 ms down) so motion never steps.
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

    /// The delay wanted now, eased from the current one; call once per stream frame.
    mutating func update(interval: Double, interpolating: Bool) -> Double {
        var wanted = jitter + margin
        if interpolating { wanted += interval / 2 + generationCost }
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
