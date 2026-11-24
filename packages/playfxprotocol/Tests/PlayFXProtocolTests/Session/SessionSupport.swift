import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

/// The session tests open real sockets and threads; running them one after the other (rather than alongside each
/// other and the rest of the suite) keeps the timing-sensitive tests elsewhere steady.
@Suite(.serialized) enum StreamSessionSuites {}

/// The error `start` throws.
func startFailure(
    _ console: StreamConsole, recorder: EventRecorder = EventRecorder(), settings: StreamSettings = avcSettings,
    transport: StreamTransport = .bsd, tweak: (inout StreamEnvironment) -> Void = { _ in }
) async -> StreamStartError? {
    do {
        let session = try await startSession(console, recorder: recorder, settings: settings, transport: transport, tweak: tweak)
        session.stop()
        return nil
    } catch let error as StreamStartError {
        return error
    } catch {
        Issue.record("unexpected error \(error)")
        return nil
    }
}

