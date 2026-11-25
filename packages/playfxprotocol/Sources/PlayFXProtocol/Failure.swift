import Darwin
import Foundation

/// What went wrong on the network or in the console's answer. Sockets and connections throw it; registration
/// wraps it in a `RegistrationError`.
public enum FailureKind: Error, Sendable, Equatable {
    case timeout
    case connectionRefused
    case networkUnreachable
    case hostDown
    case badAddress
    /// The connection closed or was reset before the exchange was over.
    case disconnected
    /// The console answered with a status other than 200.
    case httpNotOK(status: Int)
    /// The answer was not a usable HTTP reply (garbage, missing `Content-Length`, ...).
    case invalidResponse
    /// The answer decoded, but a required field was missing or malformed.
    case invalidData
    /// The caller's input was unusable (wrong account ID length, ...).
    case invalidInput
    /// The system refused the traffic (EPERM/EACCES): typically macOS Local Network access was denied.
    case permissionDenied
    /// The caller cancelled the task. Not a failure to show: see `RegistrationError.userMessage(ps5:)`.
    case cancelled
    /// Any other errno.
    case other(errno: Int32)

    /// Maps an errno from a socket or connection.
    init(errno code: Int32) {
        switch code {
        case ETIMEDOUT: self = .timeout
        case ECONNREFUSED: self = .connectionRefused
        case ENETUNREACH, ENETDOWN, ENETRESET: self = .networkUnreachable
        case EHOSTDOWN, EHOSTUNREACH: self = .hostDown
        case EINVAL, EAFNOSUPPORT, EADDRNOTAVAIL, EDESTADDRREQ: self = .badAddress
        case EPERM, EACCES: self = .permissionDenied
        case ECONNRESET, ECONNABORTED, EPIPE, ENOTCONN: self = .disconnected
        default: self = .other(errno: code)
        }
    }
}

/// Console `RP-Application-Reason` codes (registration.md section 6.1).
public enum RPReason {
    /// Registration failed: the PIN is wrong or has expired.
    public static let registrationFailed: UInt32 = 0x80108b09
    /// The PSN account ID does not belong to the console user who opened the pairing screen.
    public static let invalidPSNID: UInt32 = 0x80108b02
    /// Remote Play is already in use.
    public static let inUse: UInt32 = 0x80108b10
    /// `RP-Version` mismatch.
    public static let versionMismatch: UInt32 = 0x80108b11
    /// Remote Play on the console crashed.
    public static let crashed: UInt32 = 0x80108b15
    /// Unknown error.
    public static let unknown: UInt32 = 0x80108bff
}

/// A failed registration.
public struct RegistrationError: Error, Sendable, Equatable {
    /// What failed.
    public let kind: FailureKind
    /// The console's `RP-Application-Reason`, when it gave one.
    public let reasonCode: UInt32?
    /// Whether the console had answered the UDP search before this failure.
    public let consoleAnswered: Bool

    public init(kind: FailureKind, reasonCode: UInt32? = nil, consoleAnswered: Bool) {
        self.kind = kind
        self.reasonCode = reasonCode
        self.consoleAnswered = consoleAnswered
    }

    /// A user-facing explanation and fix. Empty for `.cancelled`: the caller asked for the stop, so there is
    /// nothing to show (check `kind == .cancelled` before presenting an error).
    ///
    /// Order: the console's reason code, then bad input and bad address, then whether it had answered, then
    /// the kind of network failure.
    public func userMessage(ps5: Bool) -> String {
        let console = ps5 ? "PS5" : "PS4"
        let screen = ps5 ? "Pair Device" : "Add Device"
        if kind == .cancelled { return "" }
        if let reason = reasonCode {
            switch reason {
            case RPReason.registrationFailed:
                return "The code is wrong or has expired. Get a new one: \(screen) on the \(console) shows a new code."
            case RPReason.invalidPSNID:
                return "The PlayStation account ID PlayFX used doesn't belong to the \(console) user who opened "
                    + "\(screen). Open \(screen) as that user, or sign in as that user (or paste their account ID)."
            case RPReason.versionMismatch:
                return "The \(console)'s Remote Play version doesn't match PlayFX's. Update the \(console)'s "
                    + "system software and PlayFX, then pair again."
            case RPReason.inUse:
                return "The \(console) is already in a Remote Play session. End it on the other device, or wait "
                    + "a few seconds, then pair again."
            case RPReason.crashed:
                return "Remote Play on the \(console) stopped working. Restart the \(console), then pair again."
            default:
                let digits = String(reason, radix: 16)
                let code = String(repeating: "0", count: max(0, 8 - digits.count)) + digits
                return "The \(console) refused pairing (reason 0x\(code)). Open \(screen) again and pair with "
                    + "the new code."
            }
        }
        switch kind {
        case .invalidInput:
            return "The PlayStation account ID must be 8 bytes. Sign in to PSN again, or paste the account ID."
        case .badAddress:
            return "That isn't a valid console address. Enter its IP address, such as 192.168.1.20."
        default:
            break
        }
        let unusableReply: Bool
        switch kind {
        case .httpNotOK, .invalidResponse, .invalidData: unusableReply = true
        default: unusableReply = false
        }
        if consoleAnswered && !unusableReply {
            return "The \(console) stopped answering partway through pairing. Keep \(screen) open on the "
                + "\(console), and pair again with the code it shows."
        }
        switch kind {
        case .timeout, .connectionRefused:
            return "The \(console) didn't answer. Keep \(screen) open on the \(console) while you pair, and "
                + "check that it's on the same network as this Mac."
        case .networkUnreachable, .hostDown, .disconnected, .permissionDenied:
            return "Couldn't reach the \(console). Allow PlayFX in System Settings › Privacy & Security › "
                + "Local Network, and turn off any VPN."
        default:
            return "Registration failed: check the PIN (it expires after a few minutes) and that the console "
                + "is on the same network."
        }
    }
}

/// Lets a caller stop blocking work from another thread (Swift task cancellation). The blocking code checks
/// `isCancelled` between short waits and registers closers for connections it must close to wake up.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [() -> Void] = []

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Marks the token cancelled and runs the registered handlers once.
    func cancel() {
        lock.lock()
        let run = cancelled ? [] : handlers
        cancelled = true
        handlers = []
        lock.unlock()
        for handler in run { handler() }
    }

    /// Runs `handler` on cancel (immediately if already cancelled).
    func onCancel(_ handler: @escaping () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
        } else {
            handlers.append(handler)
            lock.unlock()
        }
    }
}
