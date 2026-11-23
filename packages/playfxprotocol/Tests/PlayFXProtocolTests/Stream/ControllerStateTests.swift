import Foundation
import Testing

@testable import PlayFXProtocol

@Suite struct ControllerStateTests {
    // MARK: Button bits

    @Test func buttonBitValues() {
        let expected: [(ControllerButtons, UInt16)] = [
            (.cross, 0), (.circle, 1), (.square, 2), (.triangle, 3), (.dpadLeft, 4), (.dpadRight, 5),
            (.dpadUp, 6), (.dpadDown, 7), (.l1, 8), (.r1, 9), (.l3, 10), (.r3, 11), (.options, 12), (.share, 13),
            (.touchpad, 14), (.ps, 15),
        ]
        for (button, bit) in expected { #expect(button.rawValue == 1 << bit) }
    }

    // MARK: V-ST9 feedback state

    static let motionState = ControllerState(
        leftStickX: 12345, leftStickY: -32768, rightStickX: 32767, rightStickY: -100,
        gyro: SIMD3(0.5, -1.25, 3.0), accelerometer: SIMD3(0.1, 0.95, -0.2),
        orientation: Quaternion(x: 0.1025978, y: -0.2051957, z: 0.3077935, w: 0.9233805))

    @Test func idleBody() {
        #expect(
            FeedbackState.body(.idle, ps5: true) == hex("a0 ff7f ff7f ff7f ff7f 9999 ff7f fef7ef1f 0000 0000 0000 0000 000001"))
        #expect(FeedbackState.body(.idle, ps5: false).count == 25)
        #expect(FeedbackState.body(.idle, ps5: true).count == 28)
    }

    @Test func motionBody() {
        let ps5 = hex("a0 2182 aa7a cc8c 8e82 5198 e07a 2659cb2d 3039 8000 7fff ff9c 000001")
        #expect(FeedbackState.body(Self.motionState, ps5: true) == ps5)
        #expect(FeedbackState.body(Self.motionState, ps5: false) == Array(ps5.dropLast(3)))
    }

    @Test func takionVectorT7() {
        let state = ControllerState(
            leftStickX: 1000, leftStickY: -2000, rightStickX: -32768, rightStickY: 32767,
            gyro: SIMD3(0.5, -1.25, 0), accelerometer: SIMD3(0.1, 0.98, -0.2),
            orientation: Quaternion(x: 0.1, y: 0.2, z: 0.3, w: 0.927362))
        let v9 = hex("a02182aa7aff7f8e821599e07a1e79742d03e8f83080007fff")
        #expect(FeedbackState.body(state, ps5: false) == v9)
        #expect(FeedbackState.body(state, ps5: true) == v9 + hex("000001"))
    }

    @Test func outOfRangeValuesClampAndNaNIsZero() {
        let wild = ControllerState(
            gyro: SIMD3(1000, -1000, .nan), accelerometer: SIMD3(99, -99, .infinity))
        let body = FeedbackState.body(wild, ps5: false)
        #expect(Array(body[1...2]) == [0xff, 0xff])  // +30 rad/s
        #expect(Array(body[3...4]) == [0x00, 0x00])  // -30 rad/s
        #expect(Array(body[5...6]) == [0xff, 0x7f])  // NaN as 0
        #expect(Array(body[7...8]) == [0xff, 0xff])
        #expect(Array(body[9...10]) == [0x00, 0x00])
        #expect(Array(body[11...12]) == [0xff, 0xff])
    }

    @Test func stateSendDecision() {
        #expect(!FeedbackState.needsSend(old: .idle, new: .idle))
        var pressed = ControllerState.idle
        pressed.buttons = .cross
        pressed.l2 = 5
        pressed.touches = [TouchPoint(id: 0, x: 1, y: 1), nil]
        #expect(!FeedbackState.needsSend(old: .idle, new: pressed))
        for change: (inout ControllerState) -> Void in [
            { $0.leftStickX = 1 }, { $0.leftStickY = 1 }, { $0.rightStickX = 1 }, { $0.rightStickY = 1 },
            { $0.gyro.x = 1 }, { $0.accelerometer.z = 1 }, { $0.orientation.x = 0.5 },
        ] {
            var changed = ControllerState.idle
            change(&changed)
            #expect(FeedbackState.needsSend(old: .idle, new: changed))
        }
    }

    @Test func stateSequenceNumbersCountFromZero() {
        var builder = FeedbackStateBuilder(ps5: true)
        let first = builder.packet(for: .idle)
        #expect(first.sequence == 0 && first.body.count == 28)
        #expect(builder.packet(for: Self.motionState).sequence == 1)
        var ps4 = FeedbackStateBuilder(ps5: false)
        #expect(ps4.packet(for: .idle).body.count == 25)
        for _ in 0..<65535 { _ = builder.packet(for: .idle) }
        #expect(builder.packet(for: .idle).sequence == 1)  // wrapped past 65535
    }

    // MARK: Quaternion compression

    @Test func quaternionCompression() {
        #expect(Quaternion.identity.compressed == 0x1feff7fe)
        #expect(Quaternion(x: 0, y: -0.8, z: 0.6, w: 0).compressed == 0x1ffd87fb)
        #expect(Quaternion(x: 0, y: 0.6, z: 0, w: -0.8).compressed == 0x1ffd87ff)
        #expect(Quaternion(x: 0.1, y: 0.2, z: 0.3, w: 0.927362).compressed == 0x2d74791e)
    }

    @Test func compressionTiesNaNAndRange() {
        // The first of equal magnitudes is the largest.
        #expect(Quaternion(x: 0.5, y: 0.5, z: 0.5, w: 0.5).compressed & 0b110 == 0)
        #expect(Quaternion(x: .nan, y: 0, z: 0, w: 1).compressed == Quaternion.identity.compressed)
        for q in [Quaternion(x: 0.7071, y: 0.7071, z: 0, w: 0), Quaternion(x: 1, y: 1, z: 1, w: 1), Quaternion(x: -3, y: 0, z: 0, w: 0)] {
            let bits = q.compressed
            #expect(bits >> 30 == 0)
            for j: UInt32 in 0..<3 { #expect((bits >> (3 + 9 * j)) & 0x1ff <= 511) }
        }
    }

    // MARK: V-ST10 events

    @Test func eventBytes() {
        #expect(ControllerEvent.button(.cross, pressed: true).bytes == hex("8088ff"))
        #expect(ControllerEvent.button(.cross, pressed: false).bytes == hex("808800"))
        #expect(ControllerEvent.button(.r3, pressed: true).bytes == hex("80b0"))
        #expect(ControllerEvent.button(.r3, pressed: false).bytes == hex("8090"))
        #expect(ControllerEvent.l2(128).bytes == hex("808680"))
        #expect(ControllerEvent.r2(7).bytes == hex("808707"))
        #expect(ControllerEvent.touchDown(TouchPoint(id: 5, x: 1000, y: 500)).bytes == hex("d0053e81f4"))
        #expect(ControllerEvent.touchLift(TouchPoint(id: 127, x: 1919, y: 1079)).bytes == hex("c07f77f437"))
        #expect(ControllerEvent.touchLift(TouchPoint(id: 200, x: 0xffff, y: 0xffff)).bytes == hex("c0 48 ff ff ff"))
        #expect(ControllerEvent.button([.cross, .circle], pressed: true).bytes == [])
    }

    @Test func everyButtonCodeMatchesTheTable() {
        let withState: [(ControllerButtons, UInt8)] = [
            (.dpadUp, 0x80), (.dpadDown, 0x81), (.dpadLeft, 0x82), (.dpadRight, 0x83), (.l1, 0x84), (.r1, 0x85),
            (.cross, 0x88), (.circle, 0x89), (.square, 0x8a), (.triangle, 0x8b),
        ]
        for (button, code) in withState {
            #expect(ControllerEvent.button(button, pressed: true).bytes == [0x80, code, 0xff])
            #expect(ControllerEvent.button(button, pressed: false).bytes == [0x80, code, 0x00])
        }
        let pairs: [(ControllerButtons, UInt8, UInt8)] = [
            (.options, 0xac, 0x8c), (.share, 0xad, 0x8d), (.ps, 0xae, 0x8e), (.l3, 0xaf, 0x8f), (.r3, 0xb0, 0x90),
            (.touchpad, 0xb1, 0x91),
        ]
        for (button, press, release) in pairs {
            #expect(ControllerEvent.button(button, pressed: true).bytes == [0x80, press])
            #expect(ControllerEvent.button(button, pressed: false).bytes == [0x80, release])
        }
    }

    @Test func eventOrder() {
        var old = ControllerState.idle
        old.buttons = [.cross, .l3, .touchpad]
        old.l2 = 10
        old.touches = [TouchPoint(id: 1, x: 10, y: 20), TouchPoint(id: 2, x: 30, y: 40)]
        var new = ControllerState.idle
        new.buttons = [.circle, .l3, .ps, .dpadUp]
        new.l2 = 200
        new.r2 = 9
        // Slot 0 changes id (lift only), slot 1 moves.
        new.touches = [TouchPoint(id: 3, x: 5, y: 5), TouchPoint(id: 2, x: 31, y: 40)]
        #expect(
            ControllerEvent.events(from: old, to: new) == [
                .button(.cross, pressed: false), .button(.touchpad, pressed: false),
                .touchLift(TouchPoint(id: 1, x: 10, y: 20)), .touchDown(TouchPoint(id: 2, x: 31, y: 40)),
                .button(.circle, pressed: true), .button(.dpadUp, pressed: true), .button(.ps, pressed: true),
                .l2(200), .r2(9),
            ])
    }

    @Test func touchTransitions() {
        func change(_ a: TouchPoint?, _ b: TouchPoint?) -> [ControllerEvent] {
            var old = ControllerState.idle, new = ControllerState.idle
            old.touches = [a, nil]
            new.touches = [b, nil]
            return ControllerEvent.events(from: old, to: new)
        }
        let p = TouchPoint(id: 4, x: 100, y: 100)
        #expect(change(nil, nil).isEmpty)
        #expect(change(nil, p) == [.touchDown(p)])
        #expect(change(p, p).isEmpty)
        #expect(change(p, TouchPoint(id: 4, x: 101, y: 100)) == [.touchDown(TouchPoint(id: 4, x: 101, y: 100))])
        #expect(change(p, nil) == [.touchLift(p)])
        #expect(change(p, TouchPoint(id: 5, x: 100, y: 100)) == [.touchLift(p)])
        // A state with fewer slots than the protocol has is read as empty slots.
        var short = ControllerState.idle
        short.touches = []
        #expect(short.touch(slot: 1) == nil)
        #expect(ControllerEvent.events(from: short, to: .idle).isEmpty)
    }

    @Test func touchIdsWrapAt128() {
        var ids = TouchIdAllocator()
        #expect((0..<130).map { _ in ids.allocate() }.suffix(3) == [127, 0, 1])
    }

    // MARK: History packets

    @Test func historyPacketsCarryEarlierEvents() {
        var builder = FeedbackHistoryBuilder()
        let first = builder.append(.button(.cross, pressed: true))
        #expect(first == FeedbackHistoryPacket(sequence: 0, eventCountMinusOne: 0, body: hex("8088ff")))
        let second = builder.append(.touchDown(TouchPoint(id: 3, x: 1000, y: 500)))
        #expect(second.sequence == 1 && second.eventCountMinusOne == 1)
        #expect(second.body == hex("d0033e81f4") + hex("8088ff"))
        var last = second
        for _ in 0..<12 { last = builder.append(.l2(1)) }
        #expect(last.eventCountMinusOne == 8)
        #expect(last.body.count == 9 * 3)
        #expect(last.sequence == 13)
    }

    @Test func takionVectorT8Body() {
        var builder = FeedbackHistoryBuilder()
        _ = builder.append(.touchDown(TouchPoint(id: 3, x: 1000, y: 500)))
        let packet = builder.append(.button(.cross, pressed: true))
        #expect(packet.body == hex("8088ffd0033e81f4"))
        #expect(packet.eventCountMinusOne == 1)
    }

    @Test func historySequenceWraps() {
        var builder = FeedbackHistoryBuilder()
        var packets: [FeedbackHistoryPacket] = []
        for _ in 0..<65538 { packets.append(builder.append(.l2(0))) }
        #expect(packets[65535].sequence == 65535 && packets[65536].sequence == 0)
        let several = builder.append([.l2(1), .r2(2)])
        #expect(several.map(\.sequence) == [2, 3])
    }

    // MARK: Orientation estimator

    @Test func startsAtIdentity() {
        let estimator = OrientationEstimator()
        let q = estimator.orientation
        #expect(abs(q.x) < 1e-6 && abs(q.y) < 1e-6 && abs(q.z) < 1e-6 && abs(q.w - 1) < 1e-6)
        #expect(q.compressed == Quaternion.identity.compressed)
    }

    @Test func restingPadStaysAtIdentity() {
        var estimator = OrientationEstimator()
        var t: UInt32 = 1000
        for _ in 0..<200 {
            t &+= 4000
            estimator.update(gyro: .zero, accelerometer: SIMD3(0, 1, 0), timestamp: t)
        }
        let q = estimator.orientation
        #expect(abs(q.w - 1) < 1e-4 && abs(q.x) < 1e-4 && abs(q.y) < 1e-4 && abs(q.z) < 1e-4)
    }

    @Test func integratesAGyroRotation() {
        var estimator = OrientationEstimator()
        var t: UInt32 = 0
        estimator.update(gyro: .zero, accelerometer: SIMD3(0, 1, 0), timestamp: t)
        // 1 rad/s about the pad's X axis for one second. The accelerometer follows gravity less strongly
        // than a real pad would, so only check that the angle is close to 1 rad and about X.
        for _ in 0..<250 {
            t &+= 4000
            estimator.update(gyro: SIMD3(1, 0, 0), accelerometer: SIMD3(0, 1, 0), timestamp: t)
        }
        let q = estimator.orientation
        let angle = 2 * atan2(Double((q.x * q.x + q.y * q.y + q.z * q.z).squareRoot()), Double(q.w))
        #expect(angle > 0.5 && angle < 1.5)
        #expect(abs(q.x) > abs(q.y) && abs(q.x) > abs(q.z))
    }

    @Test func timestampsWrapAndBadGapsAreSkipped() {
        var estimator = OrientationEstimator()
        estimator.update(gyro: .zero, accelerometer: SIMD3(0, 1, 0), timestamp: UInt32.max - 1000)
        let before = estimator.orientation
        estimator.update(gyro: SIMD3(0, 0, 1), accelerometer: SIMD3(0, 1, 0), timestamp: 3000)  // wraps: 4 ms
        #expect(estimator.orientation != before)
        let afterWrap = estimator.orientation
        estimator.update(gyro: SIMD3(0, 0, 1), accelerometer: SIMD3(0, 1, 0), timestamp: 3000)  // same time
        estimator.update(gyro: SIMD3(0, 0, 1), accelerometer: SIMD3(0, 1, 0), timestamp: 3000 &+ 5_000_000)  // 5 s gap
        #expect(estimator.orientation == afterWrap)
    }

    @Test func zeroAccelerometerStillIntegrates() {
        var estimator = OrientationEstimator()
        estimator.update(gyro: .zero, accelerometer: .zero, timestamp: 0)
        estimator.update(gyro: SIMD3(0, 0, 5), accelerometer: .zero, timestamp: 100_000)
        #expect(estimator.orientation != Quaternion.identity)
    }

    @Test func motionResetMakesTheCurrentOrientationTheOrigin() {
        var estimator = OrientationEstimator()
        var t: UInt32 = 0
        estimator.update(gyro: .zero, accelerometer: SIMD3(0, 1, 0), timestamp: t)
        for _ in 0..<100 {
            t &+= 4000
            estimator.update(gyro: SIMD3(0, 2, 0), accelerometer: SIMD3(0, 1, 0), timestamp: t)
        }
        #expect(abs(estimator.orientation.w - 1) > 0.01)
        estimator.reset()
        let q = estimator.orientation
        #expect(abs(q.w - 1) < 1e-5 && abs(q.x) < 1e-5 && abs(q.y) < 1e-5 && abs(q.z) < 1e-5)
    }

    @Test func highGainThenLowGain() {
        // After 29 updates the gain drops; a tilted accelerometer pulls the filter slower afterwards.
        func tilt(updates: Int) -> Float {
            var e = OrientationEstimator()
            var t: UInt32 = 0
            e.update(gyro: .zero, accelerometer: SIMD3(0, 1, 0), timestamp: t)
            for _ in 0..<updates {
                t &+= 4000
                e.update(gyro: .zero, accelerometer: SIMD3(0.5, 0.866, 0), timestamp: t)
            }
            return abs(e.orientation.z)
        }
        let early = tilt(updates: 29)
        let late = tilt(updates: 58) - early
        #expect(early > late)
        #expect(OrientationEstimator.highGainUpdates == 29)
    }
}
