import GameController
import Testing
@testable import StreamCore

@Suite struct ControllerMappingTests {
    func bit(_ b: ControllerButton) -> UInt32 { b.rawValue }

    @Test func buttonNamesCoverEveryButton() {
        #expect(ControllerState.buttonNames.count == 16)
        #expect(ControllerState.buttonNames.values.reduce(0, |) == 0xFFFF)
        #expect(ControllerState.buttonNames["cross"] == bit(.cross))
    }

    @Test func axisClampsAndScales() {
        #expect(ControllerInput.axis(0) == 0)
        #expect(ControllerInput.axis(1) == Int16.max)
        #expect(ControllerInput.axis(-1) == -Int16.max)
        #expect(ControllerInput.axis(3) == Int16.max)
        #expect(ControllerInput.axis(-3) == -Int16.max)
        #expect(ControllerInput.axis(0.5) == Int16(0.5 * Float(Int16.max)))
    }

    @Test func keysFromTheWebUIMergeWithThePad() {
        let input = ControllerInput()
        var sent: [ControllerState] = []
        input.onChange = { sent.append($0) }
        var keys = ControllerState()
        keys.buttons = bit(.square)
        keys.rightX = Int16.max // L on the keyboard: the right stick
        input.setKeys(keys)
        #expect(sent.last?.buttons == bit(.square) && sent.last?.rightX == Int16.max)
        input.setKeys(ControllerState())
        #expect(sent.last == ControllerState())
        input.setKeys(ControllerState()) // nothing changed: nothing sent
        #expect(sent.count == 2)
    }

    @Test func mergeCombinesPadAndKeyboard() {
        var pad = ControllerState()
        pad.buttons = bit(.cross)
        pad.l2 = 100
        pad.r2 = 200
        pad.leftX = 10
        pad.leftY = 20
        pad.rightX = 30
        var keys = ControllerState()
        keys.buttons = bit(.square)
        keys.l2 = 255
        var m = ControllerInput.merge(pad: pad, keys: keys)
        #expect(m.buttons == bit(.cross) | bit(.square))
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
        var expected: UInt32 = ([.cross, .circle, .square, .triangle, .dpadLeft, .dpadUp, .l1, .r1, .options]
                                as [ControllerButton]).map(bit).reduce(0, |)
        if pad.leftThumbstickButton != nil { expected |= bit(.l3) }
        if pad.rightThumbstickButton != nil { expected |= bit(.r3) }
        if pad.buttonOptions != nil { expected |= bit(.share) }
        if pad.buttonHome != nil { expected |= bit(.ps) }
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
        #expect(states.last?.buttons == ControllerButton.cross.rawValue)
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
        #expect(await waitUntil(timeout: 2) { states.last?.buttons == ControllerButton.circle.rawValue })
    }

    @Test @MainActor func aPadThatDisconnectsLetsGoOfWhatItHeld() async throws {
        // GameController sends no last reading when a pad goes away (asleep, battery, Bluetooth): what it held
        // must not stay pressed, touched or tilted on the console.
        let input = ControllerInput()
        var sent: [ControllerState] = []
        input.onChange = { sent.append($0) }
        let controller = GCController.withExtendedGamepad()
        input.attach(controller)
        let pad = try #require(controller.extendedGamepad)
        pad.buttonA.setValue(1)
        pad.valueChangedHandler?(pad, pad.buttonA)
        #expect(await waitUntil(timeout: 2) { sent.last?.buttons == ControllerButton.cross.rawValue })
        NotificationCenter.default.post(name: .GCControllerDidDisconnect, object: controller)
        #expect(await waitUntil(timeout: 2) { sent.last == ControllerState() })
        // Not a controller: ignored.
        let count = sent.count
        NotificationCenter.default.post(name: .GCControllerDidDisconnect, object: nil)
        #expect(sent.count == count)
    }

    @Test func aDisconnectReleasesTheTouchButtonsAndMotionOfThatPadOnly() {
        let input = ControllerInput()
        var sent: [ControllerState] = []
        input.onChange = { sent.append($0) }
        let (padA, padB) = (GCController.withExtendedGamepad(), GCController.withExtendedGamepad())
        var held = ControllerState()
        held.buttons = ControllerButton.touchpad.rawValue | ControllerButton.r1.rawValue
        held.leftX = 100
        let motion = ControllerState.Motion(gyro: [1, 0, 0], accel: [0, -1, 0], timestampMicros: 5)
        input.padChanged(held, fingers: [[0.25, 0.5], nil], from: ObjectIdentifier(padA))
        input.motionChanged(motion, from: ObjectIdentifier(padB))
        #expect(sent.last?.touches == [ControllerState.Touch(id: 0, x: 0.25, y: 0.5)] && sent.last?.motion == motion)
        // Another pad going away leaves this one's reading alone.
        input.disconnected(ObjectIdentifier(padB))
        #expect(sent.last?.buttons == held.buttons && sent.last?.touches.count == 1 && sent.last?.motion == nil)
        // The pad that held them: everything is released, the finger lifts.
        input.disconnected(ObjectIdentifier(padA))
        #expect(sent.last == ControllerState())
        // Its next touch is a new one.
        input.padChanged(ControllerState(), fingers: [[0.5, 0.5], nil], from: ObjectIdentifier(padA))
        #expect(sent.last?.touches.map(\.id) == [1])
        // The keyboard keeps working after a disconnect.
        var keys = ControllerState()
        keys.buttons = ControllerButton.cross.rawValue
        input.setKeys(keys)
        input.disconnected(ObjectIdentifier(padA))
        #expect(sent.last == keys)
    }

    @Test @MainActor func aTestRunReadsOnlyItsOwnStandInControllers() {
        // In the app every pad is read; in a test run only snapshots (the tests' own), never a real pad.
        let standIn = GCController.withExtendedGamepad()
        #expect(standIn.isSnapshot && ControllerInput.reads(standIn) && ControllerInput.reads(standIn, allowed: true))
        #expect(PadHardware.controllers().isEmpty) // no real pad is attached at start
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

    @Test func mergingKeepsThePadsTouches() {
        var pad = ControllerState()
        pad.touches = [ControllerState.Touch(id: 1, x: 0.2, y: 0.2)]
        #expect(ControllerInput.merge(pad: pad, keys: ControllerState()).touches == pad.touches)
        #expect(ControllerInput.merge(pad: pad, keys: ControllerState(), touches: true).touches == pad.touches)
    }

    @Test func withoutTouchesOnlyTheClickIsMerged() {
        var pad = ControllerState()
        pad.buttons = ControllerButton.touchpad.rawValue
        pad.leftX = 10
        pad.touches = [ControllerState.Touch(id: 1, x: 0.2, y: 0.2), ControllerState.Touch(id: 2, x: 0.8, y: 0.8)]
        var keys = ControllerState()
        keys.buttons = ControllerButton.cross.rawValue
        let m = ControllerInput.merge(pad: pad, keys: keys, touches: false)
        #expect(m.touches.isEmpty)
        #expect(m.buttons == ControllerButton.touchpad.rawValue | ControllerButton.cross.rawValue) // the click stays
        #expect(m.leftX == 10)
    }

    @Test func aPadsTouchesAreSentOnlyWhileTheSettingIsOn() {
        let input = ControllerInput()
        var sent: [ControllerState] = []
        input.onChange = { sent.append($0) }
        var clicked = ControllerState()
        clicked.buttons = ControllerButton.touchpad.rawValue
        // On (the default): the finger reaches the console.
        input.padChanged(clicked, fingers: [[0.25, 0.5], nil])
        #expect(sent.last?.touches == [ControllerState.Touch(id: 0, x: 0.25, y: 0.5)])
        // Turned off with the finger still down: the console sees it lift, the click stays.
        input.sendsTouches = false
        #expect(sent.last?.touches == [] && sent.last?.buttons == clicked.buttons)
        // While off, the finger moving or a new one sends nothing new; the click is still sent.
        let count = sent.count
        input.padChanged(clicked, fingers: [[0.5, 0.5], [0.75, 0.75]])
        #expect(sent.count == count)
        input.padChanged(ControllerState(), fingers: [[0.5, 0.5], nil])
        #expect(sent.last == ControllerState()) // click released, still no touch
        input.padChanged(clicked, fingers: [nil, nil])
        #expect(sent.last?.buttons == clicked.buttons && sent.last?.touches == [])
        // Back on: the next finger is sent again.
        input.sendsTouches = true
        input.padChanged(ControllerState(), fingers: [[0.1, 0.1], nil])
        #expect(sent.last?.touches.count == 1)
    }

    @Test func aFingerRestingWhenTouchesComeBackOnIsANewTouch() throws {
        // The console saw the finger lift when touches went off; back on, it gets a new id, not the lifted one.
        let input = ControllerInput()
        var sent: [ControllerState] = []
        input.onChange = { sent.append($0) }
        input.padChanged(ControllerState(), fingers: [[0.25, 0.5], [0.75, 0.5]])
        let before = try #require(sent.last?.touches.map(\.id))
        #expect(before == [0, 1])
        input.sendsTouches = false
        #expect(sent.last?.touches == [])
        input.padChanged(ControllerState(), fingers: [[0.3, 0.5], [0.75, 0.5]]) // still resting, moved a little
        input.sendsTouches = true
        #expect(sent.last?.touches == [ControllerState.Touch(id: 2, x: 0.3, y: 0.5), ControllerState.Touch(id: 3, x: 0.75, y: 0.5)])
        // Setting it on again changes nothing.
        let count = sent.count
        input.sendsTouches = true
        #expect(sent.count == count)
    }

    @Test func thePointerAsATouchpadIgnoresTheSetting() {
        // The pad's fingers are left out before the session adds the pointer's: a deliberate touch on the Mac's
        // trackpad still reaches the console.
        let input = ControllerInput()
        var sent: [ControllerState] = []
        input.onChange = { sent.append($0) }
        input.sendsTouches = false
        input.padChanged(ControllerState(), fingers: [[0.25, 0.5], nil])
        let pointer = StreamSession.PointerTouch(touch: ControllerState.Touch(id: 100, x: 0.5, y: 0.5), pressed: true)
        let out = StreamSession.merged(sent.last ?? ControllerState(), pointer)
        #expect(out.touches == [ControllerState.Touch(id: 100, x: 0.5, y: 0.5)])
        #expect(out.buttons == ControllerButton.touchpad.rawValue)
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
}
