import CChiaki
import Foundation
import GameController

/// PlayStation controller state in libchiaki's terms.
public struct ControllerState: Equatable, Sendable {
    public var buttons: UInt32 = 0
    public var l2: UInt8 = 0
    public var r2: UInt8 = 0
    public var leftX: Int16 = 0, leftY: Int16 = 0
    public var rightX: Int16 = 0, rightY: Int16 = 0
    /// Fingers on the touchpad (at most 2).
    public var touches: [Touch] = []
    /// The controller's motion sensors, when it has them.
    public var motion: Motion?
    public init() {}

    /// One motion-sensor reading: rotation rate in rad/s, acceleration in g (gravity included), and when
    /// it was taken (µs, wrapping).
    public struct Motion: Equatable, Sendable {
        public var gyro: SIMD3<Float>
        public var accel: SIMD3<Float>
        public var timestampMicros: UInt32
        public init(gyro: SIMD3<Float>, accel: SIMD3<Float>, timestampMicros: UInt32) {
            self.gyro = gyro
            self.accel = accel
            self.timestampMicros = timestampMicros
        }
    }

    /// A finger on the touchpad: `id` stays the same while it's down (0–127); x/y from the top-left, 0–1.
    public struct Touch: Equatable, Sendable {
        public var id: UInt8
        public var x: Float
        public var y: Float
        public init(id: UInt8, x: Float, y: Float) {
            self.id = id
            self.x = x
            self.y = y
        }
    }

    /// The C shim's form of this state.
    var psrp: PsrpControllerState {
        var c = PsrpControllerState()
        c.buttons = buttons
        c.l2 = l2
        c.r2 = r2
        c.left_x = leftX
        c.left_y = leftY
        c.right_x = rightX
        c.right_y = rightY
        func touch(_ i: Int) -> PsrpTouch {
            guard i < touches.count else { return PsrpTouch(id: -1, x: 0, y: 0) }
            let t = touches[i]
            func scale(_ v: Float, _ max: Int32) -> UInt16 { UInt16((min(1, Swift.max(0, v)) * Float(max)).rounded()) }
            return PsrpTouch(id: Int8(t.id & 0x7F), x: scale(t.x, PSRP_TOUCHPAD_WIDTH), y: scale(t.y, PSRP_TOUCHPAD_HEIGHT))
        }
        c.touches = (touch(0), touch(1))
        if let motion {
            c.motion = true
            (c.gyro_x, c.gyro_y, c.gyro_z) = (motion.gyro.x, motion.gyro.y, motion.gyro.z)
            (c.accel_x, c.accel_y, c.accel_z) = (motion.accel.x, motion.accel.y, motion.accel.z)
            c.motion_timestamp_us = motion.timestampMicros
        }
        return c
    }

    public static let buttonNames: [String: UInt32] = [
        "cross": UInt32(PSRP_BTN_CROSS.rawValue), "circle": UInt32(PSRP_BTN_CIRCLE.rawValue),
        "square": UInt32(PSRP_BTN_SQUARE.rawValue), "triangle": UInt32(PSRP_BTN_TRIANGLE.rawValue),
        "left": UInt32(PSRP_BTN_DPAD_LEFT.rawValue), "right": UInt32(PSRP_BTN_DPAD_RIGHT.rawValue),
        "up": UInt32(PSRP_BTN_DPAD_UP.rawValue), "down": UInt32(PSRP_BTN_DPAD_DOWN.rawValue),
        "l1": UInt32(PSRP_BTN_L1.rawValue), "r1": UInt32(PSRP_BTN_R1.rawValue),
        "l3": UInt32(PSRP_BTN_L3.rawValue), "r3": UInt32(PSRP_BTN_R3.rawValue),
        "options": UInt32(PSRP_BTN_OPTIONS.rawValue), "share": UInt32(PSRP_BTN_SHARE.rawValue),
        "touchpad": UInt32(PSRP_BTN_TOUCHPAD.rawValue), "ps": UInt32(PSRP_BTN_PS.rawValue),
    ]
}

/// Reads physical gamepads (DualSense, DualShock 4, Xbox, MFi) via
/// GameController, merging them into one ControllerState.
public final class ControllerInput {
    /// Called on the main queue whenever the merged state changes.
    public var onChange: ((ControllerState) -> Void)?
    private var padState = ControllerState()
    /// The last reading's fingers, kept to give them fresh ids when touches are turned back on.
    private var padFingers: [SIMD2<Float>?] = []
    private var touchIDs = TouchIDs()
    private var motionState: ControllerState.Motion?
    /// The controllers whose readings `padState` and `motionState` hold, to let go of them when it disconnects.
    private var padSource: ObjectIdentifier?
    private var motionSource: ObjectIdentifier?
    private var keyState = ControllerState()
    private var last = ControllerState()
    private var observers: [NSObjectProtocol] = []

    public init() {
        #if os(macOS)
        GCController.shouldMonitorBackgroundEvents = true
        #endif
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            guard let controller = n.object as? GCController, Self.reads(controller) else { return }
            self?.attach(controller)
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            guard let controller = n.object as? GCController else { return }
            self?.disconnected(ObjectIdentifier(controller))
        })
        PadHardware.controllers().forEach(attach)
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Whether to read a controller that connected: any in the app; in a test run only the tests' own stand-ins
    /// (snapshots), so a real pad in someone's hands can't feed its buttons into a test (see `PadHardware`).
    static func reads(_ controller: GCController, allowed: Bool = PadHardware.allowed) -> Bool {
        allowed || controller.isSnapshot
    }

    func attach(_ controller: GCController) {
        let pad = controller.extendedGamepad
        Log.info(.input, "Controller: \(controller.vendorName ?? "unknown") — "
            + "haptics \(controller.haptics == nil ? "no" : "yes"), "
            + "adaptive triggers \(pad is GCDualSenseGamepad ? "yes" : "no"), "
            + "motion \(controller.motion == nil ? "no" : "yes")")
        // Every button belongs to the console: by default macOS keeps some (PS, Options) for its own
        // gestures and never reports them.
        for element in controller.physicalInputProfile.allElements { element.preferredSystemGestureState = .disabled }
        let source = ObjectIdentifier(controller)
        controller.extendedGamepad?.valueChangedHandler = { [weak self] pad, _ in
            self?.padChanged(Self.state(from: pad), fingers: Self.fingers(on: pad), from: source)
        }
        if let motion = controller.motion {
            // The DualSense and DualShock only report motion once asked to.
            if motion.sensorsRequireManualActivation { motion.sensorsActive = true }
            motion.valueChangedHandler = { [weak self] m in
                self?.motionChanged(Self.motion(rotation: m.rotationRate, gravity: m.gravity,
                                                user: m.userAcceleration, at: ProcessInfo.processInfo.systemUptime),
                                    from: source)
            }
        }
    }

    /// A reading from a pad: its buttons, triggers and sticks, and the fingers on its touchpad (internal for tests).
    func padChanged(_ state: ControllerState, fingers: [SIMD2<Float>?], from source: ObjectIdentifier? = nil) {
        padState = state
        padFingers = fingers
        padState.touches = touchIDs.touches(fingers)
        padSource = source
        emit()
    }

    /// A motion-sensor reading from a controller (internal for tests).
    func motionChanged(_ motion: ControllerState.Motion, from source: ObjectIdentifier) {
        motionState = motion
        motionSource = source
        emit()
    }

    /// A controller went away (internal for tests). GameController sends no last reading, so whatever it held
    /// (buttons, sticks, a finger on the touchpad, motion) is released on the console here, or it stays stuck.
    func disconnected(_ controller: ObjectIdentifier) {
        if controller == padSource {
            padState = ControllerState()
            padFingers = []
            touchIDs.forget()
            padSource = nil
        }
        if controller == motionSource {
            motionState = nil
            motionSource = nil
        }
        emit()
    }

    /// Whether the fingers on a pad's touchpad reach the console (the "Touchpad touches" setting). Off, only its
    /// click does: some games act on a resting thumb (GTA VI opens the map). Turning it off mid-touch lifts the
    /// finger on the console at once; turning it back on with a finger resting sends that finger as a new touch.
    public var sendsTouches = true {
        didSet {
            if sendsTouches && !oldValue {
                touchIDs.forget()
                padState.touches = touchIDs.touches(padFingers)
            }
            emit()
        }
    }

    /// The Mac keyboard as a controller, from the web UI (which knows when keys belong to a text field, a
    /// dialog or the settings instead): merged with the pad. Reading the keyboard here too (GameController
    /// sees every key, even while typing in the console's text field) sent H as PS while typing "hello".
    public func setKeys(_ keys: ControllerState) {
        keyState = keys
        emit()
    }

    private func emit() {
        var s = Self.merge(pad: padState, keys: keyState, touches: sendsTouches)
        s.motion = motionState
        guard s != last else { return }
        last = s
        onChange?(s)
    }

    /// Gamepad and keyboard combined: buttons OR'd, triggers maxed, a keyboard stick (WASD, IJKL) in use
    /// overrides the pad's. Without `touches`, the pad's fingers are left out (its touchpad click stays).
    static func merge(pad: ControllerState, keys: ControllerState, touches: Bool = true) -> ControllerState {
        var s = pad
        if !touches { s.touches = [] }
        s.buttons |= keys.buttons
        s.l2 = max(s.l2, keys.l2)
        s.r2 = max(s.r2, keys.r2)
        if keys.leftX != 0 || keys.leftY != 0 { s.leftX = keys.leftX; s.leftY = keys.leftY }
        if keys.rightX != 0 || keys.rightY != 0 { s.rightX = keys.rightX; s.rightY = keys.rightY }
        return s
    }

    static func state(from pad: GCExtendedGamepad) -> ControllerState {
        var s = ControllerState()
        func set(_ pressed: Bool, _ button: PsrpButton) { if pressed { s.buttons |= UInt32(button.rawValue) } }
        set(pad.buttonA.isPressed, PSRP_BTN_CROSS)
        set(pad.buttonB.isPressed, PSRP_BTN_CIRCLE)
        set(pad.buttonX.isPressed, PSRP_BTN_SQUARE)
        set(pad.buttonY.isPressed, PSRP_BTN_TRIANGLE)
        set(pad.dpad.left.isPressed, PSRP_BTN_DPAD_LEFT)
        set(pad.dpad.right.isPressed, PSRP_BTN_DPAD_RIGHT)
        set(pad.dpad.up.isPressed, PSRP_BTN_DPAD_UP)
        set(pad.dpad.down.isPressed, PSRP_BTN_DPAD_DOWN)
        set(pad.leftShoulder.isPressed, PSRP_BTN_L1)
        set(pad.rightShoulder.isPressed, PSRP_BTN_R1)
        set(pad.leftThumbstickButton?.isPressed ?? false, PSRP_BTN_L3)
        set(pad.rightThumbstickButton?.isPressed ?? false, PSRP_BTN_R3)
        set(pad.buttonMenu.isPressed, PSRP_BTN_OPTIONS)
        set(pad.buttonOptions?.isPressed ?? false, PSRP_BTN_SHARE)
        set(pad.buttonHome?.isPressed ?? false, PSRP_BTN_PS)
        if let ds = pad as? GCDualSenseGamepad { set(ds.touchpadButton.isPressed, PSRP_BTN_TOUCHPAD) }
        if let ds4 = pad as? GCDualShockGamepad { set(ds4.touchpadButton.isPressed, PSRP_BTN_TOUCHPAD) }
        s.l2 = UInt8(pad.leftTrigger.value * 255)
        s.r2 = UInt8(pad.rightTrigger.value * 255)
        // GameController: +y is up. PlayStation: +y is down.
        s.leftX = axis(pad.leftThumbstick.xAxis.value)
        s.leftY = axis(-pad.leftThumbstick.yAxis.value)
        s.rightX = axis(pad.rightThumbstick.xAxis.value)
        s.rightY = axis(-pad.rightThumbstick.yAxis.value)
        return s
    }

    /// Finger positions on a PlayStation pad's touchpad (top-left origin, 0–1), primary first.
    /// GameController reports a lifted finger as (0, 0), so a finger exactly at the center reads as lifted.
    static func fingers(on pad: GCExtendedGamepad) -> [SIMD2<Float>?] {
        let pads: [GCControllerDirectionPad]
        if let ds = pad as? GCDualSenseGamepad { pads = [ds.touchpadPrimary, ds.touchpadSecondary] }
        else if let ds4 = pad as? GCDualShockGamepad { pads = [ds4.touchpadPrimary, ds4.touchpadSecondary] }
        else { return [] }
        return pads.map { finger($0.xAxis.value, $0.yAxis.value) }
    }

    /// One touchpad reading (-1…1, +y up) → top-left based 0–1, or nil when no finger.
    static func finger(_ x: Float, _ y: Float) -> SIMD2<Float>? {
        x == 0 && y == 0 ? nil : [(x + 1) / 2, (1 - y) / 2]
    }

    /// A GameController motion reading → what the console expects: rad/s, and total acceleration in g.
    static func motion(rotation: GCRotationRate, gravity: GCAcceleration, user: GCAcceleration,
                       at seconds: TimeInterval) -> ControllerState.Motion {
        ControllerState.Motion(
            gyro: [Float(rotation.x), Float(rotation.y), Float(rotation.z)],
            accel: [Float(gravity.x + user.x), Float(gravity.y + user.y), Float(gravity.z + user.z)],
            timestampMicros: UInt32(truncatingIfNeeded: Int64(seconds * 1_000_000)))
    }

    static func axis(_ v: Float) -> Int16 {
        Int16(max(-1, min(1, v)) * Float(Int16.max))
    }
}

/// Gives each finger on the touchpad an id that stays the same while it's down and changes for every
/// new touch — how the console tells a swipe from two taps.
struct TouchIDs {
    private var ids: [UInt8?] = [nil, nil]
    private var next: UInt8 = 0

    /// Touches for this reading: `fingers[i]` is slot i (primary, secondary), nil when lifted.
    mutating func touches(_ fingers: [SIMD2<Float>?]) -> [ControllerState.Touch] {
        var out: [ControllerState.Touch] = []
        for slot in 0..<ids.count {
            guard slot < fingers.count, let p = fingers[slot] else { ids[slot] = nil; continue }
            let id = ids[slot] ?? { defer { next = (next + 1) & 0x7F }; return next }()
            ids[slot] = id
            out.append(ControllerState.Touch(id: id, x: p.x, y: p.y))
        }
        return out
    }

    /// Lets go of every finger's id, so the fingers of the next reading are new touches (ids keep counting on).
    mutating func forget() { ids = [nil, nil] }
}

