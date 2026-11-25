import Darwin
import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

// The expectations of `InternetRig` (the rig itself is in PlayFXProtocolTestSupport, which has no swift-testing).

extension InternetRig {
    func startFailure(recorder: EventRecorder = EventRecorder()) async -> InternetStartError? {
        do {
            let session = try await start(recorder: recorder)
            session.stop()
            return nil
        } catch let error as InternetStartError {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    /// What every ending must leave behind: the PSN session left (when one was made) and the push channel closed, every
    /// mapped port removed (the ctrl hole's, and the data hole's when it was made), the RUDP thread gone and no
    /// descriptor still connected to the console.
    func expectGivenBack(leftSession: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) async {
        let mappedPorts = Set(mapper.mapped.with { $0 })
        let ok = await waitUntil {
            (!leftSession || leftPSN) && (mappedPorts.isEmpty || !mapper.removed.with { $0.isEmpty })
                && psn.socket.closeCount >= 1
        }
        #expect(ok, "the PSN session is left and the mappings are removed", sourceLocation: sourceLocation)
        #expect(Set(mapper.removedPorts) == mappedPorts, sourceLocation: sourceLocation)
        #expect(psn.socket.closeCount >= 1, "the push channel is closed", sourceLocation: sourceLocation)
        if let rudp = link.with({ $0 })?.rudp {
            #expect(await waitUntil { !rudp.isReceiveThreadRunning }, "the RUDP thread ended", sourceLocation: sourceLocation)
        }
        #expect(LoopbackViolations.recorded.with { $0 }.isEmpty, "nothing left loopback", sourceLocation: sourceLocation)
        // The console's side of the ctrl bridge is its own business; the client's descriptors must all be closed.
        #expect(await waitUntil { descriptorsConnectedToTheConsole().isEmpty }, "no descriptor leaked",
                sourceLocation: sourceLocation)
    }
}
