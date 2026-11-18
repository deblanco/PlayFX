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

/// Reads physical gamepads (DualSense, DualShock 4, Xbox, MFi) and the keyboard via
/// GameController, merging them into one ControllerState.
public final class ControllerInput {
    /// Called on the main queue whenever the merged state changes.
    public var onChange: ((ControllerState) -> Void)?
    private var padState = ControllerState()
    private var touchIDs = TouchIDs()
    private var motionState: ControllerState.Motion?
    private var keyState = ControllerState()
    private var last = ControllerState()
    private var observers: [NSObjectProtocol] = []

    public init() {
        #if os(macOS)
        GCController.shouldMonitorBackgroundEvents = true
        #endif
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            (n.object as? GCController).map { self?.attach($0) }
        })
        observers.append(nc.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] n in
            (n.object as? GCKeyboard).map { self?.attach($0) }
        })
        GCController.controllers().forEach(attach)
        GCKeyboard.coalesced.map(attach)
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func attach(_ controller: GCController) {
        let pad = controller.extendedGamepad
        Log.info(.input, "Controller: \(controller.vendorName ?? "unknown") — "
            + "haptics \(controller.haptics == nil ? "no" : "yes"), "
            + "adaptive triggers \(pad is GCDualSenseGamepad ? "yes" : "no"), "
            + "motion \(controller.motion == nil ? "no" : "yes")")
        controller.extendedGamepad?.valueChangedHandler = { [weak self] pad, _ in
            guard let self else { return }
            var state = Self.state(from: pad)
            state.touches = touchIDs.touches(Self.fingers(on: pad))
            padState = state
            emit()
        }
        if let motion = controller.motion {
            // The DualSense and DualShock only report motion once asked to.
            if motion.sensorsRequireManualActivation { motion.sensorsActive = true }
            motion.valueChangedHandler = { [weak self] m in
                self?.motionState = Self.motion(rotation: m.rotationRate, gravity: m.gravity,
                                                user: m.userAcceleration, at: ProcessInfo.processInfo.systemUptime)
                self?.emit()
            }
        }
    }

    func attach(_ keyboard: GCKeyboard) {
        keyboard.keyboardInput?.keyChangedHandler = { [weak self] input, _, _, _ in
            self?.keyState = Self.state(from: input)
            self?.emit()
        }
    }

    private func emit() {
        var s = Self.merge(pad: padState, keys: keyState)
        s.motion = motionState
        guard s != last else { return }
        last = s
        onChange?(s)
    }

    /// Gamepad and keyboard combined: buttons OR'd, triggers maxed, keyboard WASD overrides the left stick.
    static func merge(pad: ControllerState, keys: ControllerState) -> ControllerState {
        var s = pad
        s.buttons |= keys.buttons
        s.l2 = max(s.l2, keys.l2)
        s.r2 = max(s.r2, keys.r2)
        if keys.leftX != 0 || keys.leftY != 0 { s.leftX = keys.leftX; s.leftY = keys.leftY }
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

    /// Keyboard fallback: arrows = D-pad, WASD = left stick, Enter/Space = ✕, Backspace/Esc = ○,
    /// Q = □, E = △, 1/2 = L1/R1, 3/4 = L2/R2, Tab = Options, H = PS, T = touchpad.
    private static func state(from kb: GCKeyboardInput) -> ControllerState {
        state(isKeyDown: { kb.button(forKeyCode: $0)?.isPressed ?? false })
    }

    static func state(isKeyDown down: (GCKeyCode) -> Bool) -> ControllerState {
        var s = ControllerState()
        func set(_ pressed: Bool, _ button: PsrpButton) { if pressed { s.buttons |= UInt32(button.rawValue) } }
        set(down(.returnOrEnter) || down(.spacebar), PSRP_BTN_CROSS)
        set(down(.deleteOrBackspace) || down(.escape), PSRP_BTN_CIRCLE)
        set(down(.keyQ), PSRP_BTN_SQUARE)
        set(down(.keyE), PSRP_BTN_TRIANGLE)
        set(down(.leftArrow), PSRP_BTN_DPAD_LEFT)
        set(down(.rightArrow), PSRP_BTN_DPAD_RIGHT)
        set(down(.upArrow), PSRP_BTN_DPAD_UP)
        set(down(.downArrow), PSRP_BTN_DPAD_DOWN)
        set(down(.one), PSRP_BTN_L1)
        set(down(.two), PSRP_BTN_R1)
        set(down(.tab), PSRP_BTN_OPTIONS)
        set(down(.keyH), PSRP_BTN_PS)
        set(down(.keyT), PSRP_BTN_TOUCHPAD)
        s.l2 = down(.three) ? 255 : 0
        s.r2 = down(.four) ? 255 : 0
        s.leftX = (down(.keyD) ? Int16.max : 0) + (down(.keyA) ? -Int16.max : 0)
        s.leftY = (down(.keyS) ? Int16.max : 0) + (down(.keyW) ? -Int16.max : 0)
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
}

