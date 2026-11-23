import Darwin
import Network
import Testing

@testable import PlayFXProtocol

@Suite struct FailureTests {
    static func message(_ kind: FailureKind, reason: UInt32? = nil, answered: Bool, ps5: Bool) -> String {
        RegistrationError(kind: kind, reasonCode: reason, consoleAnswered: answered).userMessage(ps5: ps5)
    }

    @Test func reasonMessages() {
        for ps5 in [true, false] {
            let console = ps5 ? "PS5" : "PS4", screen = ps5 ? "Pair Device" : "Add Device"
            // The reason wins whatever the failure kind and whether the console had answered.
            #expect(Self.message(.httpNotOK(status: 403), reason: 0x80108b09, answered: true, ps5: ps5)
                == "The code is wrong or has expired. Get a new one: \(screen) on the \(console) shows a new code.")
            #expect(Self.message(.httpNotOK(status: 403), reason: 0x80108b02, answered: true, ps5: ps5)
                == "The PlayStation account ID PlayFX used doesn't belong to the \(console) user who opened \(screen). Open \(screen) as that user, or sign in as that user (or paste their account ID).")
            #expect(Self.message(.httpNotOK(status: 403), reason: 0x80108b11, answered: true, ps5: ps5)
                == "The \(console)'s Remote Play version doesn't match PlayFX's. Update the \(console)'s system software and PlayFX, then pair again.")
            #expect(Self.message(.timeout, reason: 0x80108b09, answered: false, ps5: ps5).hasPrefix("The code is wrong"))
        }
    }

    @Test func stoppedAnswering() {
        let expected = "The PS5 stopped answering partway through pairing. Keep Pair Device open on the PS5, and pair again with the code it shows."
        for kind in [FailureKind.timeout, .connectionRefused, .disconnected, .networkUnreachable, .hostDown, .other(errno: 5)] {
            #expect(Self.message(kind, answered: true, ps5: true) == expected)
        }
        #expect(Self.message(.disconnected, answered: true, ps5: false)
            == "The PS4 stopped answering partway through pairing. Keep Add Device open on the PS4, and pair again with the code it shows.")
    }

    @Test func didNotAnswer() {
        let expected = "The PS4 didn't answer. Keep Add Device open on the PS4 while you pair, and check that it's on the same network as this Mac."
        for kind in [FailureKind.timeout, .connectionRefused] {
            #expect(Self.message(kind, answered: false, ps5: false) == expected)
        }
    }

    @Test func couldNotReach() {
        let expected = "Couldn't reach the PS5. Allow PlayFX in System Settings › Privacy & Security › Local Network, and turn off any VPN."
        for kind in [FailureKind.networkUnreachable, .hostDown, .disconnected, .permissionDenied] {
            #expect(Self.message(kind, answered: false, ps5: true) == expected)
        }
    }

    @Test func anythingElse() {
        let expected = "Registration failed: check the PIN (it expires after a few minutes) and that the console is on the same network."
        for kind in [FailureKind.httpNotOK(status: 500), .invalidResponse, .invalidData] {
            #expect(Self.message(kind, answered: true, ps5: true) == expected)
        }
        #expect(Self.message(.other(errno: 5), answered: false, ps5: true) == expected)
    }

    @Test func inUseAndCrashed() {
        for ps5 in [true, false] {
            let console = ps5 ? "PS5" : "PS4"
            #expect(Self.message(.httpNotOK(status: 403), reason: 0x80108b10, answered: true, ps5: ps5)
                == "The \(console) is already in a Remote Play session. End it on the other device, or wait a few seconds, then pair again.")
            #expect(Self.message(.httpNotOK(status: 500), reason: 0x80108b15, answered: true, ps5: ps5)
                == "Remote Play on the \(console) stopped working. Restart the \(console), then pair again.")
        }
    }

    @Test func anyOtherReasonIsShownAsACode() {
        #expect(Self.message(.httpNotOK(status: 403), reason: 0x80108bff, answered: true, ps5: true)
            == "The PS5 refused pairing (reason 0x80108bff). Open Pair Device again and pair with the new code.")
        #expect(Self.message(.httpNotOK(status: 403), reason: 0x1a, answered: true, ps5: false)
            == "The PS4 refused pairing (reason 0x0000001a). Open Add Device again and pair with the new code.")
        // A reason code wins over the failure kind.
        #expect(Self.message(.timeout, reason: 0x80108b20, answered: true, ps5: true).hasPrefix("The PS5 refused pairing"))
    }

    @Test func badInputAndAddress() {
        for answered in [false, true] {
            #expect(Self.message(.invalidInput, answered: answered, ps5: true)
                == "The PlayStation account ID must be 8 bytes. Sign in to PSN again, or paste the account ID.")
            #expect(Self.message(.badAddress, answered: answered, ps5: false)
                == "That isn't a valid console address. Enter its IP address, such as 192.168.1.20.")
        }
    }

    @Test func cancelledHasNoMessage() {
        #expect(Self.message(.cancelled, answered: true, ps5: true).isEmpty)
        #expect(Self.message(.cancelled, reason: 0x80108b09, answered: false, ps5: true).isEmpty)
    }

    @Test func errnoMapping() {
        #expect(FailureKind(errno: ETIMEDOUT) == .timeout)
        #expect(FailureKind(errno: ECONNREFUSED) == .connectionRefused)
        #expect(FailureKind(errno: ENETUNREACH) == .networkUnreachable)
        #expect(FailureKind(errno: ENETDOWN) == .networkUnreachable)
        #expect(FailureKind(errno: EHOSTDOWN) == .hostDown)
        #expect(FailureKind(errno: EHOSTUNREACH) == .hostDown)
        #expect(FailureKind(errno: EPERM) == .permissionDenied)
        #expect(FailureKind(errno: EACCES) == .permissionDenied)
        #expect(FailureKind(errno: EINVAL) == .badAddress)
        #expect(FailureKind(errno: EAFNOSUPPORT) == .badAddress)
        #expect(FailureKind(errno: ECONNRESET) == .disconnected)
        #expect(FailureKind(errno: EPIPE) == .disconnected)
        #expect(FailureKind(errno: EIO) == .other(errno: EIO))
    }

    @Test func networkFrameworkErrorMapping() {
        #expect(NWBlockingTCPConnection.failure(.posix(.ECONNREFUSED)) == .connectionRefused)
        #expect(NWBlockingTCPConnection.failure(.posix(.ETIMEDOUT)) == .timeout)
        #expect(NWBlockingTCPConnection.failure(.dns(-1)) == .badAddress)
        #expect(NWBlockingTCPConnection.failure(.tls(-1)) == .other(errno: 0))
    }

    private func outcome(_ state: NWConnection.State) -> Result<Bool, FailureKind>? {
        NWBlockingTCPConnection.connectOutcome(for: state)?.map { _ in true }
    }

    @Test func connectStatesMapToOutcomes() {
        #expect(outcome(.ready) == .success(true))
        #expect(outcome(.waiting(.posix(.ECONNREFUSED))) == .failure(.connectionRefused))
        #expect(outcome(.waiting(.posix(.ENETUNREACH))) == .failure(.networkUnreachable))
        #expect(outcome(.waiting(.posix(.EHOSTUNREACH))) == .failure(.hostDown))
        #expect(outcome(.failed(.posix(.ETIMEDOUT))) == .failure(.timeout))
        #expect(outcome(.cancelled) == .failure(.disconnected))
        #expect(outcome(.setup) == nil)
        #expect(outcome(.preparing) == nil)
    }

    @Test func reasonConstants() {
        #expect(RPReason.registrationFailed == 0x80108b09 && RPReason.invalidPSNID == 0x80108b02)
        #expect(RPReason.inUse == 0x80108b10 && RPReason.versionMismatch == 0x80108b11)
        #expect(RPReason.crashed == 0x80108b15 && RPReason.unknown == 0x80108bff)
    }
}
