import CChiaki
import GameController
import Testing
import os
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

    @Test func keysFromTheWebUIMergeWithThePad() {
        let input = ControllerInput()
        var sent: [ControllerState] = []
        input.onChange = { sent.append($0) }
        var keys = ControllerState()
        keys.buttons = bit(PSRP_BTN_SQUARE)
        keys.rightX = Int16.max // L on the keyboard: the right stick
        input.setKeys(keys)
        #expect(sent.last?.buttons == bit(PSRP_BTN_SQUARE) && sent.last?.rightX == Int16.max)
        input.setKeys(ControllerState())
        #expect(sent.last == ControllerState())
        input.setKeys(ControllerState()) // nothing changed: nothing sent
        #expect(sent.count == 2)
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

/// Serialized: a connect notification reaches every live `ControllerInput`, and the last to attach a controller
/// takes its callback, so another test's instance running alongside could take this suite's.
@Suite(.serialized) struct ControllerInputTests {
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
        #expect(await waitUntil(timeout: 2) { sent.last?.buttons == UInt32(PSRP_BTN_CROSS.rawValue) })
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
        held.buttons = UInt32(PSRP_BTN_TOUCHPAD.rawValue) | UInt32(PSRP_BTN_R1.rawValue)
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
        keys.buttons = UInt32(PSRP_BTN_CROSS.rawValue)
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

    @Test @MainActor func theLoopReadsPadsWithoutWaitingForTheMainQueue() throws {
        // The input loop's own read, off the main queue: given a stand-in pad it reads the same state the
        // callbacks would, and what it reads reaches the console through the same path.
        let input = ControllerInput()
        var sent: [ControllerState] = []
        input.onChange = { sent.append($0) }
        let controller = GCController.withExtendedGamepad()
        input.attach(controller)
        let pad = try #require(controller.extendedGamepad)
        pad.buttonA.setValue(1)
        input.pollPads([controller])
        #expect(sent.last?.buttons == UInt32(PSRP_BTN_CROSS.rawValue))
        // Nothing changed between reads: nothing is sent again.
        let count = sent.count
        input.pollPads([controller])
        #expect(sent.count == count)
        pad.leftThumbstick.setValueForXAxis(1, yAxis: 0)
        input.pollPads([controller])
        #expect(sent.last?.leftX == Int16.max && sent.last?.leftY == 0)
        // What the loop read is the pad's, so its disconnect still releases it.
        input.disconnected(ObjectIdentifier(controller))
        #expect(sent.last == ControllerState())
        // A read the loop started before the disconnect lands after it: dropped, or the pad's last reading
        // would hold its stick again with nothing left to release it.
        let released = sent.count
        input.pollPads([controller])
        #expect(sent.count == released && sent.last == ControllerState())
        // Connected again, it's read again.
        input.attach(controller)
        input.pollPads([controller])
        #expect(sent.last?.leftX == Int16.max)
    }

    @Test @MainActor func twoPadsDontTakeTurnsOnEveryRead() throws {
        // The loop reads every connected pad on each pass. A pad whose reading hasn't changed is no news, so the
        // one in use keeps its trigger held, and an idle second pad's first reading doesn't take over from it.
        let input = ControllerInput()
        var sent: [ControllerState] = []
        input.onChange = { sent.append($0) }
        let (inUse, idle) = (GCController.withExtendedGamepad(), GCController.withExtendedGamepad())
        input.attach(inUse)
        input.attach(idle)
        try #require(inUse.extendedGamepad).rightTrigger.setValue(1)
        input.pollPads([inUse, idle])
        // The pad in use: its buttons and its motion; the idle one's readings don't replace either.
        #expect(sent.count == 2 && sent.last?.r2 == 255)
        let motion = sent.last?.motion
        input.pollPads([inUse, idle])
        input.pollPads([idle, inUse])
        #expect(sent.count == 2 && sent.last?.motion == motion)
        // The other pad pressed: it's the one in use now, as with GameController's own callbacks.
        try #require(idle.extendedGamepad).buttonB.setValue(1)
        input.pollPads([inUse, idle])
        #expect(sent.last?.buttons == UInt32(PSRP_BTN_CIRCLE.rawValue) && sent.last?.r2 == 0)
        input.pollPads([inUse, idle])
        #expect(sent.count == 3)
    }

    @Test func eachPadsStillMotionIsDroppedOnItsOwn() {
        let input = ControllerInput()
        var sent: [ControllerState] = []
        input.onChange = { sent.append($0) }
        let pads = (GCController.withExtendedGamepad(), GCController.withExtendedGamepad()) // kept alive: distinct ids
        let (a, b) = (ObjectIdentifier(pads.0), ObjectIdentifier(pads.1))
        let still = ControllerState.Motion(gyro: [0, 0, 0], accel: [0, -1, 0], timestampMicros: 1)
        input.motionChanged(still, from: a)
        // The same sensors later: only the timestamp differs, nothing is sent.
        input.motionChanged(.init(gyro: still.gyro, accel: still.accel, timestampMicros: 2), from: a)
        #expect(sent.count == 1)
        // Another pad's first reading doesn't take over; its next one, a change, does.
        input.motionChanged(.init(gyro: [1, 0, 0], accel: [0, -1, 0], timestampMicros: 3), from: b)
        #expect(sent.count == 1)
        let tilted = ControllerState.Motion(gyro: [2, 0, 0], accel: [0, -1, 0], timestampMicros: 4)
        input.motionChanged(tilted, from: b)
        // A's stillness again is still no news, even after B's reading.
        input.motionChanged(.init(gyro: still.gyro, accel: still.accel, timestampMicros: 5), from: a)
        #expect(sent.count == 2 && sent.last?.motion == tilted)
    }

    @Test func aStateMergedBeforeAnyoneListensIsStillSent() {
        // The bridge sets `sendsTouches` before `onChange`; a reading merged then wasn't taken as sent, so it
        // goes out with the next change instead of being lost.
        let input = ControllerInput()
        var held = ControllerState()
        held.buttons = UInt32(PSRP_BTN_R1.rawValue)
        input.padChanged(held, fingers: [])
        input.sendsTouches = false
        var sent: [ControllerState] = []
        input.onChange = { sent.append($0) }
        input.setKeys(ControllerState())
        #expect(sent == [held])
    }

    @Test func statesFromTwoThreadsArriveOneAtATimeInTheOrderTheyWereMerged() async {
        // The loop and the main thread both merge states. Handed on after the lock, a state merged on one thread
        // could reach the console after a newer one from the other, leaving a released button held. So while one
        // is being handed on, a state merged on another thread waits for it.
        let input = ControllerInput()
        struct Seen { var inside = false, overlapped = false, sent: [ControllerState] = [] }
        let seen = OSAllocatedUnfairLock(initialState: Seen())
        var keys = ControllerState()
        keys.buttons = UInt32(PSRP_BTN_CROSS.rawValue)
        input.onChange = { s in
            let first = seen.withLock { seen -> Bool in
                if seen.inside { seen.overlapped = true }
                seen.inside = true
                seen.sent.append(s)
                return seen.sent.count == 1
            }
            if first {
                // Another thread merges a newer state while this one is still on its way.
                Thread.detachNewThread { input.setKeys(keys) }
                Thread.sleep(forTimeInterval: 0.05)
            }
            seen.withLock { $0.inside = false }
        }
        var pad = ControllerState()
        pad.leftX = 100
        input.padChanged(pad, fingers: [])
        let both = await waitUntil(timeout: 2) { seen.withLock { $0.sent.count } == 2 }
        var newest = pad
        newest.buttons = keys.buttons
        #expect(both && !seen.withLock { $0.overlapped } && seen.withLock { $0.sent.last } == newest)
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
        #expect(c.touches.1.id == Int8(200 & 0x7F) && c.touches.1.x == UInt16(PSRP_TOUCHPAD_WIDTH) && c.touches.1.y == 0) // clamped
        #expect(ControllerState().psrp.touches.0.id == -1 && ControllerState().psrp.touches.1.id == -1) // no fingers
    }

    @Test func mergingKeepsThePadsTouches() {
        var pad = ControllerState()
        pad.touches = [ControllerState.Touch(id: 1, x: 0.2, y: 0.2)]
        #expect(ControllerInput.merge(pad: pad, keys: ControllerState()).touches == pad.touches)
        #expect(ControllerInput.merge(pad: pad, keys: ControllerState(), touches: true).touches == pad.touches)
    }

    @Test func withoutTouchesOnlyTheClickIsMerged() {
        var pad = ControllerState()
        pad.buttons = UInt32(PSRP_BTN_TOUCHPAD.rawValue)
        pad.leftX = 10
        pad.touches = [ControllerState.Touch(id: 1, x: 0.2, y: 0.2), ControllerState.Touch(id: 2, x: 0.8, y: 0.8)]
        var keys = ControllerState()
        keys.buttons = UInt32(PSRP_BTN_CROSS.rawValue)
        let m = ControllerInput.merge(pad: pad, keys: keys, touches: false)
        #expect(m.touches.isEmpty)
        #expect(m.buttons == UInt32(PSRP_BTN_TOUCHPAD.rawValue) | UInt32(PSRP_BTN_CROSS.rawValue)) // the click stays
        #expect(m.leftX == 10)
    }

    @Test func aPadsTouchesAreSentOnlyWhileTheSettingIsOn() {
        let input = ControllerInput()
        var sent: [ControllerState] = []
        input.onChange = { sent.append($0) }
        var clicked = ControllerState()
        clicked.buttons = UInt32(PSRP_BTN_TOUCHPAD.rawValue)
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
        #expect(out.buttons == UInt32(PSRP_BTN_TOUCHPAD.rawValue))
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
