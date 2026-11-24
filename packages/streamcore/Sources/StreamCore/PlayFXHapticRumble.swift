import Foundation

/// Turns the DualSense haptics stream (3000 Hz, stereo, left motor then right) into the rumble the contract asks
/// of an engine when no pad plays it (`StreamEngineSink.handleHaptics` returned false).
///
/// Each frame's strength per motor comes from that channel's loudness: the RMS of its samples, scaled so a full-scale
/// sine reads 1 (`rms * sqrt(2) / 32768`, at most 1), is 0 below `gate` (near-silence) and otherwise
/// `255 * sqrt(loudness)` (the square root lifts weak effects, which would hardly be felt on a linear scale), then
/// rounded to one of 64 levels so a wobbling waveform doesn't make an event per frame. A value that differs from the
/// last one sent is sent at once; an unchanged non-zero one is repeated every `repeatMicros` (50 ms) while frames keep
/// coming. Nothing is sent when the haptics stop: the app ends the rumble when the events do.
struct PlayFXHapticRumble {
    /// Below this loudness (about -48 dBFS) a channel is silent.
    static let gate: Float = 0.004
    static let repeatMicros: UInt64 = 50_000
    /// The levels a strength is rounded to (0 ... 63, spread over 0 ... 255).
    static let levels = 63

    typealias Strength = (left: UInt8, right: UInt8)

    private var last: Strength = (0, 0)
    private var lastSentAt: UInt64 = 0

    /// A pad played the frames (or the stream ended): the next frame starts afresh.
    mutating func reset() {
        last = (0, 0)
        lastSentAt = 0
    }

    /// The rumble to send for this frame (interleaved stereo), or nil when nothing is due. `nowMicros` is a
    /// monotonic clock in µs.
    mutating func process(_ samples: UnsafeBufferPointer<Int16>, nowMicros: UInt64) -> Strength? {
        let pairs = samples.count / 2
        guard pairs > 0 else { return nil }
        var left: Float = 0, right: Float = 0
        for i in 0..<pairs {
            let l = Float(samples[2 * i]), r = Float(samples[2 * i + 1])
            left += l * l
            right += r * r
        }
        let now: Strength = (Self.strength(sumOfSquares: left, count: pairs), Self.strength(sumOfSquares: right, count: pairs))
        let changed = now.left != last.left || now.right != last.right
        let due = (now.left != 0 || now.right != 0) && nowMicros &- lastSentAt >= Self.repeatMicros
        guard changed || due else { return nil }
        last = now
        lastSentAt = nowMicros
        return now
    }

    static func strength(sumOfSquares: Float, count: Int) -> UInt8 {
        let rms = (sumOfSquares / Float(count)).squareRoot()
        let loudness = min(rms * Float(2).squareRoot() / 32768, 1)
        guard loudness >= gate else { return 0 }
        let level = (loudness.squareRoot() * Float(levels)).rounded()
        return UInt8((level * 255 / Float(levels)).rounded())
    }
}
