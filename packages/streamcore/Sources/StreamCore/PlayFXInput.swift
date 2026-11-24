import Foundation
import PlayFXProtocol

/// StreamCore's `ControllerState` in PlayFXProtocol's terms: the buttons (the same bit layout), triggers and
/// sticks (+y down on both sides) as they are; each touch placed on the console's touchpad (12-bit coordinates)
/// and kept in one of the two touch slots for as long as its finger is down; the motion as the pad's orientation,
/// from `OrientationEstimator`.
struct PlayFXInput {
    private var slots: [UInt8?] = [nil, nil]
    private var estimator = OrientationEstimator()
    /// The last state mapped, to send again once the stream is up.
    private(set) var latest: PlayFXProtocol.ControllerState?

    /// The console's touchpad, in the 12-bit coordinates the wire carries (stream.md section 10.2).
    static let touchpadWidth: Float = 1919
    static let touchpadHeight: Float = 1079

    mutating func map(_ state: ControllerState) -> PlayFXProtocol.ControllerState {
        var out = PlayFXProtocol.ControllerState(
            buttons: ControllerButtons(rawValue: UInt16(truncatingIfNeeded: state.buttons)), l2: state.l2, r2: state.r2,
            leftStickX: state.leftX, leftStickY: state.leftY, rightStickX: state.rightX, rightStickY: state.rightY)
        out.touches = touchPoints(state.touches)
        if let motion = state.motion {
            out.gyro = motion.gyro
            out.accelerometer = motion.accel
            out.motionTimestamp = motion.timestampMicros
            out.orientation = estimator.update(
                gyro: motion.gyro, accelerometer: motion.accel, timestamp: motion.timestampMicros)
        }
        latest = out
        return out
    }

    /// The console asked for a motion reset: the pad's orientation now is the new origin.
    mutating func resetMotion() { estimator.reset() }

    /// Two slots; a finger takes the first free one when it lands and keeps it until its id is gone.
    private mutating func touchPoints(_ touches: [ControllerState.Touch]) -> [TouchPoint?] {
        let fingers = touches.prefix(PlayFXProtocol.ControllerState.touchSlots)
        let ids = fingers.map { $0.id & 0x7f }
        for i in slots.indices where slots[i].map({ !ids.contains($0) }) ?? false { slots[i] = nil }
        for id in ids where !slots.contains(id) {
            if let free = slots.firstIndex(where: { $0 == nil }) { slots[free] = id }
        }
        var points: [TouchPoint?] = [nil, nil]
        for finger in fingers {
            let id = finger.id & 0x7f
            guard let slot = slots.firstIndex(of: id) else { continue }
            points[slot] = TouchPoint(
                id: id, x: Self.coordinate(finger.x, Self.touchpadWidth), y: Self.coordinate(finger.y, Self.touchpadHeight))
        }
        return points
    }

    private static func coordinate(_ value: Float, _ maximum: Float) -> UInt16 {
        guard !value.isNaN else { return 0 }
        return UInt16((min(max(value, 0), 1) * maximum).rounded())
    }
}
