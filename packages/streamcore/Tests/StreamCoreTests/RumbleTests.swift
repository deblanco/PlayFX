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

    @Test func hapticsRumbleEndsWhenTheHapticsStop() {
        // The console sends nothing (not silence) once a haptic effect ends: the rumble must end anyway.
        let rumble = Rumble()
        rumble.applyHaptics(left: 200, right: 100)
        #expect(rumble.levels == .init(left: 200, right: 100))
        Thread.sleep(forTimeInterval: Rumble.hapticsTimeout + 0.1)
        #expect(rumble.levels == .init(left: 0, right: 0))
    }

    @Test func hapticsRumbleLastsWhileItKeepsComing() {
        let rumble = Rumble()
        var lastRefresh = ProcessInfo.processInfo.systemUptime
        for _ in 0..<8 { // refreshed every 50 ms, as the shim does, for 0.4 s: longer than the timeout
            rumble.applyHaptics(left: 120, right: 0)
            lastRefresh = ProcessInfo.processInfo.systemUptime
            Thread.sleep(forTimeInterval: 0.05)
        }
        let levels = rumble.levels
        // Only meaningful when the last sleep stayed under the timeout: on CI's loaded VM one 50 ms sleep took longer.
        if ProcessInfo.processInfo.systemUptime - lastRefresh < Rumble.hapticsTimeout {
            #expect(levels == .init(left: 120, right: 0))
        }
        rumble.applyHaptics(left: 0, right: 0) // a silent packet stops it at once
        #expect(rumble.levels == .init(left: 0, right: 0))
    }

    @Test func theConsolesOwnRumbleDoesNotExpire() {
        let rumble = Rumble()
        rumble.applyHaptics(left: 90, right: 0)
        rumble.apply(left: 60, right: 30) // the console's rumble takes over: it lasts until the console ends it
        Thread.sleep(forTimeInterval: Rumble.hapticsTimeout + 0.1)
        #expect(rumble.levels == .init(left: 60, right: 30))
        #expect(!Rumble.hapticsExpired(until: nil, now: 100))
        #expect(Rumble.hapticsExpired(until: 1, now: 1) && !Rumble.hapticsExpired(until: 2, now: 1))
    }

    @Test func noControllersIsANoOp() {
        let rumble = Rumble()
        rumble.apply(left: 255, right: 255)
        rumble.stop() // waits for the queued apply; nothing to drive without a pad
        rumble.stop()
    }
}
