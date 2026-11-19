import GameController
import Testing
@testable import StreamCore

@Suite struct RumbleTests {
    @Test func levelsAreMotorBytesAsIntensities() {
        let levels = Rumble.Levels(left: 255, right: 51)
        #expect(levels.low == 1 && abs(levels.high - 0.2) < 1e-6)
        #expect(Rumble.Levels(left: 0, right: 0) == Rumble.Levels(left: 0, right: 0))
    }

    @Test func padsWithTwoHandlesGetOneMotorEach() {
        let layout = Rumble.Layout(supported: [.default, .handles, .leftHandle, .rightHandle])
        #expect(layout == .handles)
        let targets = layout.targets(Rumble.Levels(left: 255, right: 0))
        #expect(targets.map(\.0) == [.leftHandle, .rightHandle])
        #expect(targets.map(\.1) == [1, 0])
        // The heavy motor feels heavy (low sharpness), the light one crisp.
        #expect(targets[0].2 < targets[1].2)
    }

    @Test func singleActuatorPadsPlayTheStrongerMotor() {
        let layout = Rumble.Layout(supported: [.default])
        #expect(layout == .single)
        let heavy = layout.targets(Rumble.Levels(left: 200, right: 50))
        #expect(heavy.count == 1 && heavy[0].0 == .default && abs(heavy[0].1 - 200.0 / 255) < 1e-6 && heavy[0].2 < 0.5)
        let light = layout.targets(Rumble.Levels(left: 10, right: 120))
        #expect(abs(light[0].1 - 120.0 / 255) < 1e-6 && light[0].2 > 0.5)
    }

    @Test func aFreshPlayerStartsWhenNoneIsPlayingOrTheCurrentOneNearsItsEnd() {
        #expect(Rumble.needsNewPlayer(playingSince: nil, now: 100))
        #expect(!Rumble.needsNewPlayer(playingSince: 100, now: 100 + Rumble.renewAfter - 1))
        #expect(Rumble.needsNewPlayer(playingSince: 100, now: 100 + Rumble.renewAfter))
        #expect(Rumble.renewAfter < Rumble.eventDuration)
    }

    @Test func noControllersIsANoOp() {
        let rumble = Rumble()
        rumble.apply(left: 255, right: 255)
        rumble.stop() // waits for the queued apply; nothing to drive without a pad
        rumble.stop()
    }
}
