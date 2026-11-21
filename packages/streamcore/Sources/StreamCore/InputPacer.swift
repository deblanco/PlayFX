import Foundation

/// Paces the input loop's reads (pure: times go in, periods come out, so it is tested without a pad).
///
/// While the pad's readings change, the loop reads at half the interval those readings arrive with —
/// an average of the gaps between distinct readings, so one slow reading doesn't slow the lane — never
/// faster than `fastest` and never slower than `heartbeat`. Whatever rate a pad reports at (a DualSense
/// on a cable reports faster than the same pad over Bluetooth, a gamepad's rumbling hand slower still),
/// the loop is never more than one period behind a reading. After `quietAfter` without a distinct
/// reading it settles on the heartbeat, which bounds how long a first press can wait for the loop when
/// the main thread is busy: GameController delivers its own callbacks there, behind rendering and UI,
/// and the loop is the lane that doesn't queue behind it.
struct InputPacer {
    /// The loop's fastest read period (s): 500 Hz.
    static let fastest = 0.002
    /// Its period when nothing has changed for a while (s): 125 Hz.
    static let heartbeat = 0.008
    /// This long without a distinct reading (s) and the loop is on the heartbeat again.
    static let quietAfter = 1.0
    /// Gaps longer than this (s) teach nothing: that's a pause in play, not the pad's rate.
    static let teachesBelow = 0.05
    /// How much of the last gap the learned period keeps (an average weighted toward the recent).
    private static let keeps = 0.5

    /// Half the interval distinct readings arrive with, learned (s, already clamped).
    private var learned = fastest
    /// When the last distinct reading came (s on a monotonic clock), nil before any.
    private var lastDistinct: Double?

    /// The loop's next read period (s): the heartbeat before anything has changed and again after
    /// quiet, otherwise half the learned interval.
    func period(at now: Double) -> Double {
        guard let lastDistinct, now - lastDistinct < Self.quietAfter else { return Self.heartbeat }
        return Self.clamped(learned)
    }

    static func clamped(_ period: Double) -> Double { max(fastest, min(heartbeat, period)) }

    /// A reading came at `now` (`distinct`: it changed the state the console sees). Distinct readings
    /// teach the lane their pace — only gaps short enough to be the pad's own reporting rate.
    mutating func reading(at now: Double, distinct: Bool) {
        guard distinct else { return }
        if let last = lastDistinct, now - last <= Self.teachesBelow {
            learned = Self.clamped(Self.keeps * learned + (1 - Self.keeps) * (now - last) / 2)
        }
        lastDistinct = now
    }
}
