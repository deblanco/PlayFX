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
    public init() {}

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

    private func attach(_ controller: GCController) {
        controller.extendedGamepad?.valueChangedHandler = { [weak self] pad, _ in
            self?.padState = Self.state(from: pad)
            self?.emit()
        }
    }

    private func attach(_ keyboard: GCKeyboard) {
        keyboard.keyboardInput?.keyChangedHandler = { [weak self] input, _, _, _ in
            self?.keyState = Self.state(from: input)
            self?.emit()
        }
    }

    private func emit() {
        var s = padState
        s.buttons |= keyState.buttons
        s.l2 = max(s.l2, keyState.l2)
        s.r2 = max(s.r2, keyState.r2)
        if keyState.leftX != 0 || keyState.leftY != 0 { s.leftX = keyState.leftX; s.leftY = keyState.leftY }
        guard s != last else { return }
        last = s
        onChange?(s)
    }

    private static func state(from pad: GCExtendedGamepad) -> ControllerState {
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
        var s = ControllerState()
        func down(_ key: GCKeyCode) -> Bool { kb.button(forKeyCode: key)?.isPressed ?? false }
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

    private static func axis(_ v: Float) -> Int16 {
        Int16(max(-1, min(1, v)) * Float(Int16.max))
    }
}
