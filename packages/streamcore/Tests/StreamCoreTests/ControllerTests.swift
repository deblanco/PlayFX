import CChiaki
import GameController
import Testing
@testable import StreamCore

@Suite struct ControllerMappingTests {
    func bit(_ b: PsrpButton) -> UInt32 { UInt32(b.rawValue) }

    @Test func buttonNamesCoverEveryButton() {
        #expect(ControllerState.buttonNames.count == 16)
        #expect(ControllerState.buttonNames.values.reduce(0, |) == 0xFFFF)
        #expect(ControllerState.buttonNames["cross"] == bit(PSRP_BTN_CROSS))
    }

    @Test func axisClampsAndScales() {
        #expect(ControllerInput.axis(0) == 0)
        #expect(ControllerInput.axis(1) == Int16.max)
        #expect(ControllerInput.axis(-1) == -Int16.max)
        #expect(ControllerInput.axis(3) == Int16.max)
        #expect(ControllerInput.axis(-3) == -Int16.max)
        #expect(ControllerInput.axis(0.5) == Int16(0.5 * Float(Int16.max)))
    }

    @Test func keyboardMapping() {
        let pressed: Set<GCKeyCode> = [.spacebar, .escape, .keyQ, .keyE, .leftArrow, .rightArrow, .upArrow, .downArrow,
                                       .one, .two, .tab, .keyH, .keyT, .three, .keyD, .keyW]
        let s = ControllerInput.state(isKeyDown: { pressed.contains($0) })
        let expected: [PsrpButton] = [PSRP_BTN_CROSS, PSRP_BTN_CIRCLE, PSRP_BTN_SQUARE, PSRP_BTN_TRIANGLE,
                                      PSRP_BTN_DPAD_LEFT, PSRP_BTN_DPAD_RIGHT, PSRP_BTN_DPAD_UP, PSRP_BTN_DPAD_DOWN,
                                      PSRP_BTN_L1, PSRP_BTN_R1, PSRP_BTN_OPTIONS, PSRP_BTN_PS, PSRP_BTN_TOUCHPAD]
        #expect(s.buttons == expected.map(bit).reduce(0, |))
        #expect(s.l2 == 255)
        #expect(s.r2 == 0)
        #expect(s.leftX == Int16.max)
        #expect(s.leftY == -Int16.max)

        let other = ControllerInput.state(isKeyDown: { [.returnOrEnter, .deleteOrBackspace, .four, .keyA, .keyS].contains($0) })
        #expect(other.buttons == bit(PSRP_BTN_CROSS) | bit(PSRP_BTN_CIRCLE))
        #expect(other.r2 == 255)
        #expect(other.leftX == -Int16.max)
        #expect(other.leftY == Int16.max)

        #expect(ControllerInput.state(isKeyDown: { _ in false }) == ControllerState())
    }

    @Test func mergeCombinesPadAndKeyboard() {
        var pad = ControllerState()
        pad.buttons = bit(PSRP_BTN_CROSS)
        pad.l2 = 100
        pad.r2 = 200
        pad.leftX = 10
        pad.leftY = 20
        pad.rightX = 30
        var keys = ControllerState()
        keys.buttons = bit(PSRP_BTN_SQUARE)
        keys.l2 = 255
        var m = ControllerInput.merge(pad: pad, keys: keys)
        #expect(m.buttons == bit(PSRP_BTN_CROSS) | bit(PSRP_BTN_SQUARE))
        #expect(m.l2 == 255 && m.r2 == 200)
        #expect(m.leftX == 10 && m.leftY == 20 && m.rightX == 30) // keyboard stick idle: pad wins

        keys.leftY = -Int16.max
        m = ControllerInput.merge(pad: pad, keys: keys)
        #expect(m.leftX == 0 && m.leftY == -Int16.max) // keyboard stick overrides
    }

    @Test func gamepadMapping() throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        #expect(ControllerInput.state(from: pad) == ControllerState())

        pad.buttonA.setValue(1)
        pad.buttonB.setValue(1)
        pad.buttonX.setValue(1)
        pad.buttonY.setValue(1)
        pad.dpad.setValueForXAxis(-1, yAxis: 1) // left + up
        pad.leftShoulder.setValue(1)
        pad.rightShoulder.setValue(1)
        pad.leftThumbstickButton?.setValue(1)
        pad.rightThumbstickButton?.setValue(1)
        pad.buttonMenu.setValue(1)
        pad.buttonOptions?.setValue(1)
        pad.buttonHome?.setValue(1)
        pad.leftTrigger.setValue(1)
        pad.rightTrigger.setValue(0.5)
        pad.leftThumbstick.setValueForXAxis(1, yAxis: 1)
        pad.rightThumbstick.setValueForXAxis(-1, yAxis: -1)

        let s = ControllerInput.state(from: pad)
        var expected: UInt32 = [PSRP_BTN_CROSS, PSRP_BTN_CIRCLE, PSRP_BTN_SQUARE, PSRP_BTN_TRIANGLE, PSRP_BTN_DPAD_LEFT,
                                PSRP_BTN_DPAD_UP, PSRP_BTN_L1, PSRP_BTN_R1, PSRP_BTN_OPTIONS].map(bit).reduce(0, |)
        if pad.leftThumbstickButton != nil { expected |= bit(PSRP_BTN_L3) }
        if pad.rightThumbstickButton != nil { expected |= bit(PSRP_BTN_R3) }
        if pad.buttonOptions != nil { expected |= bit(PSRP_BTN_SHARE) }
        if pad.buttonHome != nil { expected |= bit(PSRP_BTN_PS) }
        #expect(s.buttons == expected)
        #expect(s.l2 == 255)
        #expect(s.r2 == 127)
        // GameController +y is up; PlayStation +y is down.
        #expect(s.leftX == Int16.max && s.leftY == -Int16.max)
        #expect(s.rightX == -Int16.max && s.rightY == Int16.max)
    }
}

@Suite struct ControllerInputTests {
    @Test @MainActor func emitsMergedStateWhenAttachedPadChanges() async throws {
        let input = ControllerInput()
        var states: [ControllerState] = []
        input.onChange = { states.append($0) }
        let controller = GCController.withExtendedGamepad()
        input.attach(controller)
        let pad = try #require(controller.extendedGamepad)
        pad.buttonA.setValue(1)
        // Snapshot controllers may deliver valueChangedHandler synchronously or on the handler queue.
        if let handler = pad.valueChangedHandler { handler(pad, pad.buttonA) }
        let delivered = await waitUntil(timeout: 2) { !states.isEmpty }
        #expect(delivered)
        #expect(states.last?.buttons == UInt32(PSRP_BTN_CROSS.rawValue))
        // Same state again: not re-emitted.
        let count = states.count
        pad.valueChangedHandler?(pad, pad.buttonA)
        #expect(states.count == count)
    }

    @Test @MainActor func attachesControllersAsTheyConnect() async throws {
        let input = ControllerInput()
        var states: [ControllerState] = []
        input.onChange = { states.append($0) }
        let controller = GCController.withExtendedGamepad()
        NotificationCenter.default.post(name: .GCControllerDidConnect, object: controller)
        let pad = try #require(controller.extendedGamepad)
        #expect(pad.valueChangedHandler != nil)
        pad.buttonB.setValue(1)
        pad.valueChangedHandler?(pad, pad.buttonB)
        #expect(await waitUntil(timeout: 2) { states.last?.buttons == UInt32(PSRP_BTN_CIRCLE.rawValue) })
    }
}
