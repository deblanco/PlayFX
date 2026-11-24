import CoreVideo
import Foundation

// The latency test (a dev tool): over Remote Play, open the PS5's control centre, then press Right and
// Left to move its highlight, and time each press → the first new picture decoded on the Mac. That covers
// the console, the network and decoding; the renderer's own time to the screen is added from its
// measurement. Not a physical controller-to-photon figure: the pad's own delay and the display aren't in it,
// and it's the PS5 menu's response, not a game's. (PS itself is no probe: the control centre only starts to
// show about 0.5 s after the press, measured on a PS5.)

/// Decides when the picture answered a press: the difference of the bottom of the picture to the last
/// frame before the press stands out from the frame-to-frame motion measured before it.
struct LatencyDetector {
    /// The part of the picture compared: the bottom 45%, where the control centre's cards are.
    static let top = 0.55
    static let columns = 64, rows = 24
    /// The least difference (0–255, mean over the samples) that counts as an answer, whatever the noise.
    /// Measured on a PS5: an open control centre changes by 0.01–0.04 on its own; a highlight move's
    /// first picture by 0.5–2.
    static let floor = 0.4

    private var base: [UInt8]?
    private var previous: [UInt8]?
    private var noise = 0.0
    private(set) var samples = 0

    /// A picture seen before the press to judge an answer against.
    var ready: Bool { base != nil }
    var threshold: Double { max(Self.floor, noise * 3) }

    /// A frame before the press.
    mutating func before(_ region: [UInt8]) {
        if let previous { noise = max(noise, Self.difference(previous, region)) }
        previous = region
        base = region
        samples += 1
    }

    /// Whether a frame after the press shows the answer.
    func answered(_ region: [UInt8]) -> Bool {
        guard let base else { return false }
        return Self.difference(base, region) > threshold
    }

    /// Mean absolute difference of two regions (0–255); 0 for regions of different sizes.
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var total = 0
        for i in a.indices { total += abs(Int(a[i]) - Int(b[i])) }
        return Double(total) / Double(a.count)
    }

    /// The compared region's luma, sampled on a grid; `luma(x, y)` reads the frame (0–255).
    static func region(width: Int, height: Int, luma: (Int, Int) -> UInt8) -> [UInt8] {
        let start = Int(Double(height) * top)
        var out: [UInt8] = []
        out.reserveCapacity(columns * rows)
        for gy in 0..<rows {
            let y = start + (gy * 2 + 1) * (height - start) / (rows * 2)
            for gx in 0..<columns { out.append(luma((gx * 2 + 1) * width / (columns * 2), y)) }
        }
        return out
    }

    /// The region of an 8-bit NV12 frame.
    static func region(_ frame: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(frame, 0)?.assumingMemoryBound(to: UInt8.self) else { return [] }
        let row = CVPixelBufferGetBytesPerRowOfPlane(frame, 0)
        return region(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame)) { base[$1 * row + $0] }
    }
}

/// Runs the trials: opens the control centre (PS), then for each trial watches the picture, presses Right
/// or Left in turn and times the answer, letting the menu settle in between; closes it (Circle) at the end.
/// Everything it touches is passed in, so the sequence is tested with a stand-in console.
struct LatencyProbe {
    struct Summary: Equatable, Encodable {
        var trials = 0, answered = 0
        /// Press → answering frame decoded (ms).
        var medianMs = 0.0, meanMs = 0.0, minMs = 0.0, maxMs = 0.0
        /// The renderer's own time from a decoded frame to the screen (ms), to add for the whole figure.
        var displayMs = 0.0
    }

    /// The newest decoded frame: its number (frames decoded so far: decoded buffers are reused, so they
    /// can't tell frames apart), and its region.
    var latest: () -> (id: Int, region: [UInt8])?
    /// Holds `buttons` (`ControllerButton` bits); 0 releases.
    var press: (UInt32) -> Void
    var now: () -> Double
    var sleep: (Double) -> Void

    /// `open`: the control centre's time to show; `baseline`: watching the picture before a press (a still
    /// menu sends no new frames, so the last one is the baseline then).
    static let pressHold = 0.1, open = 1.5, baseline = 0.3, answerTimeout = 1.0, settle = 0.8, poll = 0.001
    /// Circle presses at most to close the control centre, and the change that says it closed (measured: ~45).
    static let closeTries = 3, closed = 10.0

    func run(trials: Int) -> Summary {
        tap(ControllerButton.ps.rawValue)
        sleep(Self.open)
        var times: [Double] = []
        for k in 0..<max(0, trials) {
            let button: ControllerButton = k % 2 == 0 ? .dpadRight : .dpadLeft
            if let ms = trial(button: button.rawValue) { times.append(ms) }
            sleep(Self.settle)
        }
        close()
        return Self.summarize(times, trials: trials)
    }

    /// Circle until the control centre is gone (its cards leave the bottom of the picture): with the
    /// highlight off the first card, Circle may only bring it back there first.
    private func close() {
        for _ in 0..<Self.closeTries {
            let before = latest()?.region
            tap(ControllerButton.circle.rawValue)
            sleep(Self.settle)
            guard let before, let after = latest()?.region else { return }
            if LatencyDetector.difference(before, after) > Self.closed { return }
        }
    }

    private func tap(_ buttons: UInt32) {
        press(buttons)
        sleep(Self.pressHold)
        press(0)
    }

    /// One press; the time to the answering frame (ms), nil when none came in time.
    private func trial(button: UInt32) -> Double? {
        var detector = LatencyDetector()
        var seen: Int?
        // The picture as it is, and how much it moves on its own.
        let start = now()
        while now() - start < Self.baseline {
            if let frame = latest(), frame.id != seen {
                seen = frame.id
                detector.before(frame.region)
            }
            sleep(Self.poll)
        }
        guard detector.ready else { return nil }
        let pressed = now()
        press(button)
        defer { press(0) }
        var released = false
        while now() - pressed < Self.answerTimeout {
            if !released, now() - pressed >= Self.pressHold { press(0); released = true }
            if let frame = latest(), frame.id != seen {
                seen = frame.id
                if detector.answered(frame.region) { return (now() - pressed) * 1000 }
            }
            sleep(Self.poll)
        }
        return nil
    }

    static func summarize(_ ms: [Double], trials: Int) -> Summary {
        var s = Summary(trials: trials, answered: ms.count)
        guard !ms.isEmpty else { return s }
        let sorted = ms.sorted()
        s.medianMs = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        s.meanMs = ms.reduce(0, +) / Double(ms.count)
        s.minMs = sorted[0]
        s.maxMs = sorted[sorted.count - 1]
        return s
    }
}

extension StreamSession {
    /// Runs the latency test on this session (blocks for a few seconds per trial; not on the main thread).
    public func latencyTest(trials: Int, displayMs: Double) -> Data {
        let probe = LatencyProbe(
            latest: { [weak self] in
                guard let latest = self?.latestNumberedFrame else { return nil }
                return (latest.number, LatencyDetector.region(latest.frame))
            },
            press: { [weak self] buttons in
                var state = ControllerState()
                state.buttons = buttons
                self?.setController(state)
            },
            now: { ProcessInfo.processInfo.systemUptime },
            sleep: { Thread.sleep(forTimeInterval: $0) })
        var summary = probe.run(trials: trials)
        summary.displayMs = displayMs
        return (try? JSONEncoder().encode(summary)) ?? Data("{}".utf8)
    }
}
