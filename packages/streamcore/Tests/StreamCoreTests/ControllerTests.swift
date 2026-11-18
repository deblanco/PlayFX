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

@Suite struct TouchpadTests {
    @Test func fingerReadingsBecomeTopLeftCoordinates() {
        #expect(ControllerInput.finger(0, 0) == nil) // GameController's "no finger"
        #expect(ControllerInput.finger(-1, 1) == [0, 0]) // top-left
        #expect(ControllerInput.finger(1, -1) == [1, 1]) // bottom-right
        #expect(ControllerInput.finger(0.5, 0) == [0.75, 0.5])
    }

    @Test func aFingerKeepsItsIDWhileDownAndNewTouchesGetNewOnes() {
        var ids = TouchIDs()
        let first = ids.touches([[0.1, 0.2], nil])
        #expect(first == [ControllerState.Touch(id: 0, x: 0.1, y: 0.2)])
        #expect(ids.touches([[0.3, 0.2], nil]).map(\.id) == [0]) // same finger moving: same id
        #expect(ids.touches([[0.3, 0.2], [0.8, 0.8]]).map(\.id) == [0, 1]) // a second finger joins
        #expect(ids.touches([nil, [0.8, 0.9]]).map(\.id) == [1]) // the first lifts
        #expect(ids.touches([[0.5, 0.5], nil]).map(\.id) == [2]) // a new touch: a new id
        #expect(ids.touches([]).isEmpty)
    }

    @Test func idsWrapWithinSevenBits() {
        var ids = TouchIDs()
        for _ in 0..<128 { _ = ids.touches([[0.5, 0.5]]); _ = ids.touches([nil]) }
        #expect(ids.touches([[0.5, 0.5]]).first?.id == 0)
    }

    @Test func convertsToTheShimsState() {
        var s = ControllerState()
        s.buttons = UInt32(PSRP_BTN_TOUCHPAD.rawValue)
        s.l2 = 10
        s.rightY = -5
        s.touches = [ControllerState.Touch(id: 3, x: 0.5, y: 1), ControllerState.Touch(id: 200, x: 2, y: -1)]
        let c = s.psrp
        #expect(c.buttons == UInt32(PSRP_BTN_TOUCHPAD.rawValue) && c.l2 == 10 && c.right_y == -5)
        #expect(c.touches.0.id == 3 && c.touches.0.x == 960 && c.touches.0.y == UInt16(PSRP_TOUCHPAD_HEIGHT))
        #expect(c.touches.1.id == 200 & 0x7F && c.touches.1.x == UInt16(PSRP_TOUCHPAD_WIDTH) && c.touches.1.y == 0) // clamped
        #expect(ControllerState().psrp.touches.0.id == -1 && ControllerState().psrp.touches.1.id == -1) // no fingers
    }

    @Test func mergingKeepsThePadsTouches() {
        var pad = ControllerState()
        pad.touches = [ControllerState.Touch(id: 1, x: 0.2, y: 0.2)]
        #expect(ControllerInput.merge(pad: pad, keys: ControllerState()).touches == pad.touches)
    }
}

@Suite struct MotionTests {
    @Test func readingsBecomeRadiansPerSecondAndTotalG() {
        let m = ControllerInput.motion(rotation: GCRotationRate(x: 0.5, y: -1, z: 2),
                                       gravity: GCAcceleration(x: 0, y: -1, z: 0),
                                       user: GCAcceleration(x: 0.25, y: 0.5, z: -0.125), at: 12.5)
        #expect(m.gyro == [0.5, -1, 2])
        #expect(m.accel == [0.25, -0.5, -0.125]) // gravity + user acceleration
        #expect(m.timestampMicros == 12_500_000)
        // Long uptimes wrap like the console's 32-bit microsecond clock.
        let late = ControllerInput.motion(rotation: GCRotationRate(), gravity: GCAcceleration(),
                                          user: GCAcceleration(), at: 5000)
        #expect(late.timestampMicros == UInt32(truncatingIfNeeded: Int64(5_000_000_000)))
    }

    @Test func motionReachesTheShimOnlyWhenPresent() {
        var s = ControllerState()
        #expect(!s.psrp.motion)
        s.motion = ControllerState.Motion(gyro: [1, 2, 3], accel: [0, -1, 0], timestampMicros: 42)
        let c = s.psrp
        #expect(c.motion && c.gyro_x == 1 && c.gyro_z == 3 && c.accel_y == -1 && c.motion_timestamp_us == 42)
    }
}
