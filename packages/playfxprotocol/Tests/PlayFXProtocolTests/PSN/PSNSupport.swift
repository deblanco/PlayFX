import Foundation

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

// The PSN fakes (`FakePSN`, `FakeWebSocket`, `PSNVector`) are in PlayFXProtocolTestSupport, shared with StreamCore's tests.

/// Polls until `condition` holds or `seconds` pass.
func eventually(_ seconds: TimeInterval = 2, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
