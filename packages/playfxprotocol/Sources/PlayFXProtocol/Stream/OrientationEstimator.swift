import Foundation

/// Orientation from gyro and accelerometer (stream.md section 10.5). The console takes the quaternion as
/// given, so this is a client choice; it follows the spec's description of what existing clients do:
///
/// - Madgwick's IMU gradient-descent filter (2010) in a frame rotated +90 degrees about X. The filter state
///   starts at `r = (cos 45, sin 45, 0, 0)` (w, x, y, z), which predicts gravity at the pad's own (0, +1, 0),
///   so the sensor values go in unchanged. The sent quaternion is `p * r` with `p` = -90 degrees about X,
///   which is the identity at the start.
/// - Gain 20 for the first 29 updates, 0.05 after. The step is the difference of the samples' microsecond
///   time stamps (a wrapping 32-bit counter); the first sample only sets the time.
/// - Per-component smoothing of the filter output with `f = 0.0007`.
/// - `reset()` (the console's motion reset) makes the current orientation the new origin: what is sent is
///   `conjugate(origin) * p * r`.
///
/// Gaps over one second are treated like a first sample (no step), so a paused pad doesn't jump.
public struct OrientationEstimator: Sendable, Equatable {
    private struct Quat: Equatable {
        var w, x, y, z: Double

        static func * (a: Quat, b: Quat) -> Quat {
            Quat(
                w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
                x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
                y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
                z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w)
        }

        var conjugate: Quat { Quat(w: w, x: -x, y: -y, z: -z) }
    }

    private static let half = Double.pi / 4
    private static let start = Quat(w: cos(half), x: sin(half), y: 0, z: 0)
    private static let frame = Quat(w: cos(-half), x: sin(-half), y: 0, z: 0)
    private static let smoothing = 0.0007

    /// Updates with the high gain.
    public static let highGainUpdates = 29

    private var filter = start
    private var smoothed = start
    private var origin = Quat(w: 1, x: 0, y: 0, z: 0)
    private var lastTimestamp: UInt32?
    private var updates = 0

    public init() {}

    /// The orientation to send now.
    public var orientation: Quaternion {
        let q = origin.conjugate * Self.frame * smoothed
        // The smoothing doesn't keep the filter output at unit length, so normalise what is sent.
        let length = (q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z).squareRoot()
        return Quaternion(x: Float(q.x / length), y: Float(q.y / length), z: Float(q.z / length), w: Float(q.w / length))
    }

    /// Takes the current orientation as the new origin.
    public mutating func reset() { origin = Self.frame * smoothed }

    /// Feeds one motion sample (rad/s, g, microseconds) and returns the orientation to send.
    @discardableResult
    public mutating func update(gyro: SIMD3<Float>, accelerometer: SIMD3<Float>, timestamp: UInt32) -> Quaternion {
        defer { lastTimestamp = timestamp }
        guard let last = lastTimestamp else { return orientation }
        let dt = Double(timestamp &- last) / 1_000_000
        guard dt > 0, dt <= 1 else { return orientation }
        let beta = updates < Self.highGainUpdates ? 20.0 : 0.05
        updates += 1
        step(gyro: SIMD3(Double(gyro.x), Double(gyro.y), Double(gyro.z)),
             accel: SIMD3(Double(accelerometer.x), Double(accelerometer.y), Double(accelerometer.z)),
             beta: beta, dt: dt)
        smooth()
        return orientation
    }

    /// One Madgwick IMU step.
    private mutating func step(gyro g: SIMD3<Double>, accel a: SIMD3<Double>, beta: Double, dt: Double) {
        let q = filter
        // Rate of change from the gyro: 0.5 * q * (0, g).
        var dw = 0.5 * (-q.x * g.x - q.y * g.y - q.z * g.z)
        var dx = 0.5 * (q.w * g.x + q.y * g.z - q.z * g.y)
        var dy = 0.5 * (q.w * g.y - q.x * g.z + q.z * g.x)
        var dz = 0.5 * (q.w * g.z + q.x * g.y - q.y * g.x)
        let norm = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
        if norm > 0 {
            let ax = a.x / norm, ay = a.y / norm, az = a.z / norm
            // Gravity predicted by q minus the measurement, and the gradient J^T f.
            let f1 = 2 * (q.x * q.z - q.w * q.y) - ax
            let f2 = 2 * (q.w * q.x + q.y * q.z) - ay
            let f3 = 2 * (0.5 - q.x * q.x - q.y * q.y) - az
            var sw = -2 * q.y * f1 + 2 * q.x * f2
            var sx = 2 * q.z * f1 + 2 * q.w * f2 - 4 * q.x * f3
            var sy = -2 * q.w * f1 + 2 * q.z * f2 - 4 * q.y * f3
            var sz = 2 * q.x * f1 + 2 * q.y * f2
            let sNorm = (sw * sw + sx * sx + sy * sy + sz * sz).squareRoot()
            // Below this the error is rounding noise, and normalising it would turn it into a full-size step.
            if sNorm > 1e-9 {
                sw /= sNorm
                sx /= sNorm
                sy /= sNorm
                sz /= sNorm
                dw -= beta * sw
                dx -= beta * sx
                dy -= beta * sy
                dz -= beta * sz
            }
        }
        var n = Quat(w: q.w + dw * dt, x: q.x + dx * dt, y: q.y + dy * dt, z: q.z + dz * dt)
        let length = (n.w * n.w + n.x * n.x + n.y * n.y + n.z * n.z).squareRoot()
        if length > 0 {
            n = Quat(w: n.w / length, x: n.x / length, y: n.y / length, z: n.z / length)
            filter = n
        }
    }

    /// The per-component smoothing of the filter output.
    private mutating func smooth() {
        let f = Self.smoothing
        func blend(_ old: Double, _ new: Double) -> Double {
            let d = abs(new - old)
            if d < f / 2 { return old }
            if d < f { return 0.75 * old + 0.25 * new }
            if d < 2 * f { return 0.6 * old + 0.4 * new }
            return new
        }
        smoothed = Quat(
            w: blend(smoothed.w, filter.w), x: blend(smoothed.x, filter.x), y: blend(smoothed.y, filter.y),
            z: blend(smoothed.z, filter.z))
    }
}
