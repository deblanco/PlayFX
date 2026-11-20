import Testing
@testable import StreamCore

/// No test may drive a real controller: one attached to the Mac would play the tests' rumble and trigger
/// effects, and keep playing after the test process ends mid-effect.
@Suite struct PadHardwareTests {
    @Test func aTestRunNeverReachesARealPad() {
        #expect(!PadHardware.allowed)
        #expect(PadHardware.controllers().isEmpty)
        #expect(Rumble.controllers().isEmpty && PadLight.controllers().isEmpty)
        #expect(DualSenseHaptics.devices().isEmpty && DualSenseHaptics.bluetoothPad() == nil)
    }

    @Test func tellsATestRunFromTheApp() {
        #expect(PadHardware.isTestRun(processName: "swiftpm-testing-helper", xcTestLoaded: false))
        #expect(PadHardware.isTestRun(processName: "xctest", xcTestLoaded: false))
        #expect(PadHardware.isTestRun(processName: "anything", xcTestLoaded: true))
        #expect(!PadHardware.isTestRun(processName: "psrp-desktop", xcTestLoaded: false))
        #expect(!PadHardware.isTestRun(processName: "psrp", xcTestLoaded: false))
    }
}
