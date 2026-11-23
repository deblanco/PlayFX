/// The client-side controller model and its wire forms (stream.md section 10): the feedback-state body
/// (sticks and motion), the feedback-history events (buttons, triggers, touches), and the orientation
/// quaternion. Takion (takion.md) frames the packets; these are the body bytes.

/// Button bits (section 10.1; PlayFX's own API values, not wire values).
public struct ControllerButtons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let cross = ControllerButtons(rawValue: 1 << 0)
    public static let circle = ControllerButtons(rawValue: 1 << 1)
    public static let square = ControllerButtons(rawValue: 1 << 2)
    public static let triangle = ControllerButtons(rawValue: 1 << 3)
    public static let dpadLeft = ControllerButtons(rawValue: 1 << 4)
    public static let dpadRight = ControllerButtons(rawValue: 1 << 5)
    public static let dpadUp = ControllerButtons(rawValue: 1 << 6)
    public static let dpadDown = ControllerButtons(rawValue: 1 << 7)
    public static let l1 = ControllerButtons(rawValue: 1 << 8)
    public static let r1 = ControllerButtons(rawValue: 1 << 9)
    public static let l3 = ControllerButtons(rawValue: 1 << 10)
    public static let r3 = ControllerButtons(rawValue: 1 << 11)
    public static let options = ControllerButtons(rawValue: 1 << 12)
    public static let share = ControllerButtons(rawValue: 1 << 13)
    public static let touchpad = ControllerButtons(rawValue: 1 << 14)
    public static let ps = ControllerButtons(rawValue: 1 << 15)
}

/// A unit quaternion in the order the wire uses: (x, y, z, w).
public struct Quaternion: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var z: Float
    public var w: Float

    public init(x: Float, y: Float, z: Float, w: Float) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    public static let identity = Quaternion(x: 0, y: 0, z: 0, w: 1)

    /// The compressed form `Q(q)` (section 10.4): the largest component is dropped, the others take 9 bits
    /// each. The wire sends this value little-endian.
    public var compressed: UInt32 {
        var q = SIMD4<Float>(x, y, z, w)
        for i in 0..<4 where q[i].isNaN { q[i] = 0 }
        var largest = 0
        for i in 1..<4 where abs(q[i]) > abs(q[largest]) { largest = i }
        var bits: UInt32 = (q[largest] < 0 ? 1 : 0) | UInt32(largest) << 1
        let half = Float(0.5).squareRoot()  // 1/sqrt(2) in single precision
        let scale = 511 / 2.0.squareRoot()  // the constant 511/sqrt(2) stays double
        var slot: UInt32 = 0
        for i in 0..<4 where i != largest {
            let v = min(max(q[i], -half), half)
            let u = min(UInt32(Float(Double(v + half) * scale)), 511)
            bits |= u << (3 + 9 * slot)
            slot += 1
        }
        return bits
    }
}

/// One finger on the touchpad (section 10.2): `id` 0...127, `x` 0...1919, `y` 0...1079 (12-bit values).
public struct TouchPoint: Sendable, Equatable {
    public var id: UInt8
    public var x: UInt16
    public var y: UInt16

    public init(id: UInt8, x: UInt16, y: UInt16) {
        self.id = id
        self.x = x
        self.y = y
    }
}

/// Hands out touch ids: each new finger takes the next one, `(previous + 1) mod 128`, from 0 for the session.
public struct TouchIdAllocator: Sendable, Equatable {
    private var next: UInt8 = 0
    public init() {}
    public mutating func allocate() -> UInt8 {
        defer { next = (next + 1) & 0x7f }
        return next
    }
}

/// Everything the pad reports at one moment (section 10.1).
public struct ControllerState: Sendable, Equatable {
    /// How many touches the protocol carries.
    public static let touchSlots = 2

    public var buttons: ControllerButtons
    /// L2 and R2, 0 (released) to 255.
    public var l2: UInt8
    public var r2: UInt8
    /// Sticks, -32768...32767; y is negative up.
    public var leftStickX: Int16
    public var leftStickY: Int16
    public var rightStickX: Int16
    public var rightStickY: Int16
    /// The two touch slots; nil is "no finger".
    public var touches: [TouchPoint?]
    /// rad/s.
    public var gyro: SIMD3<Float>
    /// g, gravity included.
    public var accelerometer: SIMD3<Float>
    /// Unit quaternion (see `OrientationEstimator`).
    public var orientation: Quaternion
    /// The motion sample's time stamp in microseconds (a 32-bit counter that may wrap).
    public var motionTimestamp: UInt32

    public init(
        buttons: ControllerButtons = [], l2: UInt8 = 0, r2: UInt8 = 0, leftStickX: Int16 = 0, leftStickY: Int16 = 0,
        rightStickX: Int16 = 0, rightStickY: Int16 = 0, touches: [TouchPoint?] = [nil, nil],
        gyro: SIMD3<Float> = .zero, accelerometer: SIMD3<Float> = SIMD3(0, 1, 0), orientation: Quaternion = .identity,
        motionTimestamp: UInt32 = 0
    ) {
        self.buttons = buttons
        self.l2 = l2
        self.r2 = r2
        self.leftStickX = leftStickX
        self.leftStickY = leftStickY
        self.rightStickX = rightStickX
        self.rightStickY = rightStickY
        self.touches = touches
        self.gyro = gyro
        self.accelerometer = accelerometer
        self.orientation = orientation
        self.motionTimestamp = motionTimestamp
    }

    /// No buttons, triggers 0, sticks 0, no touches, gyro 0, accelerometer (0, 1, 0), identity orientation.
    public static let idle = ControllerState()

    /// The touch in a slot, nil when empty or out of range.
    public func touch(slot: Int) -> TouchPoint? { touches.indices.contains(slot) ? touches[slot] : nil }
}

// MARK: Feedback state (section 10.3)

public enum FeedbackState {
    /// `U16(v, R)`: `trunc(65535 * (v + R) / (2R))` in single precision, `v` clamped to `[-R, R]`.
    static func scaled(_ value: Float, range r: Float) -> UInt16 {
        let v = min(max(value.isNaN ? 0 : value, -r), r)
        return UInt16(65535 * (v + r) / (2 * r))
    }

    /// The body of a feedback-state packet: 28 bytes for a PS5 (Takion 12), 25 for a PS4 (Takion 9).
    public static func body(_ state: ControllerState, ps5: Bool) -> [UInt8] {
        var out: [UInt8] = [0xa0]
        func littleEndian16(_ v: UInt16) { out += [UInt8(v & 0xff), UInt8(v >> 8)] }
        func bigEndian16(_ v: Int16) {
            let u = UInt16(bitPattern: v)
            out += [UInt8(u >> 8), UInt8(u & 0xff)]
        }
        for i in 0..<3 { littleEndian16(scaled(state.gyro[i], range: 30)) }
        for i in 0..<3 { littleEndian16(scaled(state.accelerometer[i], range: 5)) }
        let q = state.orientation.compressed
        out += [UInt8(q & 0xff), UInt8(q >> 8 & 0xff), UInt8(q >> 16 & 0xff), UInt8(q >> 24)]
        bigEndian16(state.leftStickX)
        bigEndian16(state.leftStickY)
        bigEndian16(state.rightStickX)
        bigEndian16(state.rightStickY)
        if ps5 { out += [0x00, 0x00, 0x01] }
        return out
    }

    /// True when sticks or motion differ, which makes a new state packet due (section 10.3: also at least
    /// every 200 ms otherwise). Buttons, triggers and touches don't count: they travel as history events.
    public static func needsSend(old: ControllerState, new: ControllerState) -> Bool {
        old.leftStickX != new.leftStickX || old.leftStickY != new.leftStickY || old.rightStickX != new.rightStickX
            || old.rightStickY != new.rightStickY || old.gyro != new.gyro || old.accelerometer != new.accelerometer
            || old.orientation != new.orientation
    }
}

/// One feedback-state packet's content (takion.md section 9.3): Takion adds the type byte, key position, GMAC and
/// encryption.
public struct FeedbackStatePacket: Sendable, Equatable {
    /// Header sequence number: 0 for the first state packet of the stream connection, then +1 per packet.
    public var sequence: UInt16
    public var body: [UInt8]
}

/// Numbers the feedback-state packets of one stream connection.
public struct FeedbackStateBuilder: Sendable, Equatable {
    public let ps5: Bool
    private var next: UInt16 = 0

    public init(ps5: Bool) { self.ps5 = ps5 }

    public mutating func packet(for state: ControllerState) -> FeedbackStatePacket {
        defer { next &+= 1 }
        return FeedbackStatePacket(sequence: next, body: FeedbackState.body(state, ps5: ps5))
    }
}

// MARK: Feedback history (section 10.2)

/// One history event.
public enum ControllerEvent: Sendable, Equatable {
    /// A single button (one bit of `ControllerButtons`), pressed or released.
    case button(ControllerButtons, pressed: Bool)
    case l2(UInt8)
    case r2(UInt8)
    /// A finger down or moved.
    case touchDown(TouchPoint)
    /// A finger lifted; carries its last position.
    case touchLift(TouchPoint)

    /// Buttons that send a state byte: (button, code).
    private static let stateByteCodes: [(ControllerButtons, UInt8)] = [
        (.dpadUp, 0x80), (.dpadDown, 0x81), (.dpadLeft, 0x82), (.dpadRight, 0x83), (.l1, 0x84), (.r1, 0x85),
        (.cross, 0x88), (.circle, 0x89), (.square, 0x8a), (.triangle, 0x8b),
    ]
    /// Buttons with press and release codes: (button, press, release).
    private static let pairCodes: [(ControllerButtons, UInt8, UInt8)] = [
        (.options, 0xac, 0x8c), (.share, 0xad, 0x8d), (.ps, 0xae, 0x8e), (.l3, 0xaf, 0x8f), (.r3, 0xb0, 0x90),
        (.touchpad, 0xb1, 0x91),
    ]

    /// The event's wire bytes (3, 2 or 5 of them).
    public var bytes: [UInt8] {
        switch self {
        case .button(let button, let pressed):
            if let code = Self.stateByteCodes.first(where: { $0.0 == button })?.1 {
                return [0x80, code, pressed ? 0xff : 0x00]
            }
            if let codes = Self.pairCodes.first(where: { $0.0 == button }) {
                return [0x80, pressed ? codes.1 : codes.2]
            }
            return []
        case .l2(let value): return [0x80, 0x86, value]
        case .r2(let value): return [0x80, 0x87, value]
        case .touchDown(let t): return Self.touchBytes(0xd0, t)
        case .touchLift(let t): return Self.touchBytes(0xc0, t)
        }
    }

    private static func touchBytes(_ kind: UInt8, _ t: TouchPoint) -> [UInt8] {
        let x = t.x & 0xfff, y = t.y & 0xfff
        return [kind, t.id & 0x7f, UInt8(x >> 4), UInt8((x & 0x0f) << 4 | y >> 8), UInt8(y & 0xff)]
    }

    /// The events for one state change, in the order existing clients emit them (section 10.2): button
    /// releases in bit order, touch changes for slot 0 then 1, button presses in bit order, then L2, then R2.
    public static func events(from old: ControllerState, to new: ControllerState) -> [ControllerEvent] {
        var out: [ControllerEvent] = []
        out.reserveCapacity(4)
        let released = old.buttons.subtracting(new.buttons), pressed = new.buttons.subtracting(old.buttons)
        for bit in 0..<16 where released.rawValue & (1 << bit) != 0 {
            out.append(.button(ControllerButtons(rawValue: 1 << bit), pressed: false))
        }
        for slot in 0..<ControllerState.touchSlots {
            let before = old.touch(slot: slot), now = new.touch(slot: slot)
            if let before, now?.id != before.id {
                out.append(.touchLift(before))
            } else if let now, now != before {
                out.append(.touchDown(now))
            }
        }
        for bit in 0..<16 where pressed.rawValue & (1 << bit) != 0 {
            out.append(.button(ControllerButtons(rawValue: 1 << bit), pressed: true))
        }
        if old.l2 != new.l2 { out.append(.l2(new.l2)) }
        if old.r2 != new.r2 { out.append(.r2(new.r2)) }
        return out
    }
}

/// One feedback-history packet's content (takion.md section 9.4); Takion adds the header fields and crypto.
public struct FeedbackHistoryPacket: Sendable, Equatable {
    /// The header's 16-bit sequence number: the new event's number.
    public var sequence: UInt16
    /// Header byte 3: the number of events in `body` minus one.
    public var eventCountMinusOne: UInt8
    /// The new event followed by up to 8 earlier ones, newest first.
    public var body: [UInt8]
}

/// Numbers events and builds one packet per event, each repeating up to 8 earlier events (so the console
/// recovers a lost packet). Resending the last packet at 20, 50, 100 and 200 ms is Takion's job.
public struct FeedbackHistoryBuilder: Sendable, Equatable {
    /// Earlier events carried along with the new one.
    public static let carriedEvents = 8

    private var number: UInt16 = 0
    private var recent: [[UInt8]] = []  // newest first

    public init() {}

    public mutating func append(_ event: ControllerEvent) -> FeedbackHistoryPacket {
        let bytes = event.bytes
        var body = bytes
        for earlier in recent { body += earlier }
        let packet = FeedbackHistoryPacket(
            sequence: number, eventCountMinusOne: UInt8(recent.count), body: body)
        number &+= 1
        recent.insert(bytes, at: 0)
        if recent.count > Self.carriedEvents { recent.removeLast() }
        return packet
    }

    /// One packet per event, in order.
    public mutating func append(_ events: [ControllerEvent]) -> [FeedbackHistoryPacket] {
        events.map { append($0) }
    }
}
