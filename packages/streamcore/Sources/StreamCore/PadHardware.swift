import Foundation
import GameController

/// The gate between StreamCore and real controllers: rumble, adaptive triggers, the light bar and the
/// DualSense's haptics all find their pads through here. Closed in a test run: tests build those outputs and
/// play effects on them, and a pad attached to the Mac would play them, and keep playing after the test
/// process exits in the middle of one (a rumble or trigger effect lasts until something stops it).
enum PadHardware {
    /// Whether this process may drive real controllers.
    static let allowed = !isTestRun(processName: ProcessInfo.processInfo.processName,
                                    xcTestLoaded: NSClassFromString("XCTestCase") != nil)

    /// A test run: `swift test`'s helper or `xctest` (both load XCTest, which an app never does).
    static func isTestRun(processName: String, xcTestLoaded: Bool) -> Bool {
        xcTestLoaded || ["swiftpm-testing-helper", "xctest"].contains(processName)
    }

    /// The connected controllers, none in a test run.
    static func controllers() -> [GCController] { allowed ? GCController.controllers() : [] }
}
