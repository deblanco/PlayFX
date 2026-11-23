import Foundation

extension RPTarget {
    /// The protocol version text sent as `Rp-Version` / `RP-Version` (session.md section 3).
    public var protocolVersion: String {
        switch self {
        case .ps4v8: "8.0"
        case .ps4v9: "9.0"
        case .ps4v10: "10.0"
        case .ps5v1: "1.0"
        }
    }

    /// Session-init path (session.md section 3).
    var sessionInitPath: String {
        switch self {
        case .ps4v8, .ps4v9: "/sce/rp/session"
        case .ps4v10: "/sie/ps4/rp/sess/init"
        case .ps5v1: "/sie/ps5/rp/sess/init"
        }
    }

    /// Ctrl path (session.md section 3).
    var ctrlPath: String {
        switch self {
        case .ps4v8, .ps4v9: "/sce/rp/session/ctrl"
        case .ps4v10: "/sie/ps4/rp/sess/ctrl"
        case .ps5v1: "/sie/ps5/rp/sess/ctrl"
        }
    }

    /// The target for a version a console reported, within the family of `self` (session.md section 5.3).
    /// A PS4 that reports `5.0` is retried as `9.0`. Nil for anything else.
    func target(forReportedVersion version: String) -> RPTarget? {
        if isPS5 { return version == "1.0" ? .ps5v1 : nil }
        switch version {
        case "8.0": return .ps4v8
        case "9.0", "5.0": return .ps4v9
        case "10.0": return .ps4v10
        default: return nil
        }
    }
}

/// Why a session start failed (session init or the ctrl connection).
public enum SessionError: Error, Sendable, Equatable {
    /// `80108b10`: Remote Play is in use.
    case consoleBusy
    /// `80108b15`: Remote Play on the console crashed.
    case remotePlayCrashed
    /// `80108b11` / `80108bff` with no version to retry, or still a mismatch after the last attempt.
    case versionMismatch
    /// Any other refusal; nil when the console sent no reason.
    case refused(reason: UInt32?)
    /// The ctrl request got a status other than 200 and no reason code.
    case ctrlRejected(status: Int)
    /// A TCP connect or an answer timed out, or the connection was refused (`.timeout`, `.connectionRefused`).
    case noAnswer(FailureKind)
    /// The ctrl connection was reset or closed on every attempt while the session started.
    case ctrlResetRepeatedly
    /// The network failed (unreachable, permission denied, reset, ...).
    case network(FailureKind)
    /// The console's answer was not usable (garbage, bad nonce, too large).
    case invalidResponse
    /// A key or other input had the wrong size.
    case invalidInput
    /// The caller cancelled. Not a failure to show: `userMessage` is empty.
    case cancelled
    /// The cipher could not run.
    case cryptoFailure

    /// Maps what the sockets throw.
    static func from(_ kind: FailureKind) -> SessionError {
        switch kind {
        case .timeout, .connectionRefused: .noAnswer(kind)
        case .cancelled: .cancelled
        case .invalidResponse, .invalidData: .invalidResponse
        case .invalidInput: .invalidInput
        case .httpNotOK(let status): .ctrlRejected(status: status)
        default: .network(kind)
        }
    }

    /// Maps an `RP-Application-Reason` (session.md section 5.4).
    static func from(reason: UInt32) -> SessionError {
        switch reason {
        case RPReason.inUse: .consoleBusy
        case RPReason.crashed: .remotePlayCrashed
        case RPReason.versionMismatch: .versionMismatch
        default: .refused(reason: reason)
        }
    }

    /// A user-facing explanation and fix. Empty for `.cancelled`.
    public func userMessage(ps5: Bool) -> String {
        let console = ps5 ? "PS5" : "PS4"
        switch self {
        case .cancelled:
            return ""
        case .consoleBusy:
            return "The \(console) is already streaming to another device. End that session, or wait a few "
                + "seconds and try again."
        case .remotePlayCrashed:
            return "Remote Play on the \(console) stopped working. Restart the \(console) and try again."
        case .versionMismatch:
            return "The \(console)'s Remote Play version doesn't match PlayFX's. Update the \(console)'s "
                + "system software and PlayFX."
        case .noAnswer:
            return "The \(console) didn't answer. Check that it's on and on the same network as this Mac."
        case .network:
            return "Couldn't reach the \(console). Allow PlayFX in System Settings › Privacy & Security › "
                + "Local Network, and turn off any VPN."
        case .refused(let reason?):
            let digits = String(reason, radix: 16)
            let code = String(repeating: "0", count: max(0, 8 - digits.count)) + digits
            return "The \(console) refused the session (reason 0x\(code))."
        case .refused(nil):
            return "The \(console) refused the session (no reason given)."
        case .ctrlRejected(let status):
            return "The \(console) refused the session (HTTP status \(status))."
        case .ctrlResetRepeatedly:
            return "The \(console) kept closing the connection while the session started. Wait a few seconds "
                + "and try again."
        case .invalidResponse:
            return "The \(console) sent an answer PlayFX couldn't read. Try again; if it keeps happening, "
                + "restart the \(console)."
        case .invalidInput:
            return "PlayFX's pairing data for this \(console) is incomplete. Pair it again."
        case .cryptoFailure:
            return "PlayFX couldn't set up the encrypted session with the \(console). Try again."
        }
    }
}
