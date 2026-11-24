import Foundation
import os

// The public types of internet Remote Play through PSN (docs/protocol/holepunch.md section 8): the console to reach,
// the progress the app can show, the options, and the typed errors.

/// A console reached through PSN instead of its LAN address.
///
/// The token is an ordinary PSN access token with the scopes of psn.md section 2, made with a client device ID
/// (`duid`) in the OAuth request. That ID is only part of the sign-in: no later call sends it, so nothing here asks
/// for it. The account ID comes back from PSN when the session is created (psn.md section 6.1), so it isn't asked
/// for either.
public struct PSNRemote: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The PSN access token. Never printed.
    public var accessToken: String
    /// A PS5's device ID (psn.md section 3.2: 64 hex characters, as the device list gives it). A PS4 is reached as the
    /// account's primary PS4 and its ID is learned when it joins, so this is ignored for `.ps4`.
    public var consoleDUID: String
    public var platform: PSNPlatform

    public init(accessToken: String, consoleDUID: String, platform: PSNPlatform = .ps5) {
        self.accessToken = accessToken
        self.consoleDUID = consoleDUID
        self.platform = platform
    }

    /// The version the session starts with: the only targets with a registration through PSN (registration.md
    /// section 8.1).
    public var target: RPTarget { platform == .ps5 ? .ps5v1 : .ps4v10 }

    public var description: String { "PSNRemote(\(platform.rawValue), accessToken: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["platform": platform], displayStyle: .struct) }
}

/// The stages of an internet start, in order, for an app that shows progress (holepunch.md section 8).
public enum InternetStage: String, Sendable, Equatable, CaseIterable {
    /// UPnP discovery, the push channel and the PSN session (steps 1 to 4).
    case linkingPSN
    /// The start command: the console is asked to join and wakes if it rests (step 6).
    case wakingConsole
    /// The ctrl hole: candidates, probes, ACCEPT (step 7).
    case ctrlHole
    /// The PIN-less registration over RUDP (step 8).
    case registering
    /// Session init over RUDP (step 9).
    case sessionInit
    /// Ctrl over RUDP, until the session ID (step 10).
    case ctrl
    /// The data hole (step 11).
    case dataHole
    /// The network probe on the data socket (step 12).
    case probing
    /// The switch message and the stream connection (steps 13 and 14).
    case streamConnecting
    /// The stream is up.
    case connected
}

/// Which hole.
public enum InternetHole: String, Sendable, Equatable {
    case ctrl, data
}

/// Choices for an internet start. Every default is the reference client's (holepunch.md section 9).
public struct InternetOptions: Sendable {
    /// Called as each stage starts, on whatever thread the work is on: keep it quick.
    public var progress: @Sendable (InternetStage) -> Void = { _ in }
    /// One line per notable step, for diagnosing a first run: the stage, the candidate lists (types and counts), the
    /// selected pair, timings; no tokens or keys. **The text can contain the console's and this network's public
    /// addresses** (the selected pair, the address a probe came from): the callback gets them and the app decides where
    /// they go. The default writes to the unified log (subsystem `PlayFXProtocol`, category `internet`) as `.private`,
    /// so they are redacted unless a debugger is attached or private data is enabled.
    public var log: @Sendable (String) -> Void = { line in
        Logger(subsystem: "PlayFXProtocol", category: "internet").notice("\(line, privacy: .private)")
    }
    /// Try UPnP before STUN (holepunch.md section 3.1).
    public var useUPnP = true
    /// Treat every STUN port as unpredictable even when it looks stable (holepunch.md section 4.2, sixth row).
    public var forcePortGuessing = false
    /// Who may probe in a hole punch. `.strict` (default) drops probes not from the console to us; `.logOnly` accepts
    /// them like the reference and logs the first mismatch of each hole, so a first hardware round can tell a wrong
    /// assumption about the console's probe fields from a forgery (holepunch.md section 10 question 1).
    public var probeIdentity = ProbeIdentityCheck.strict
    /// Development: one log line per datagram in and out on the ctrl hole once it is punched (the RUDP message types, `seq`
    /// and `ack`, lengths and the first 24 bytes of each message's data in hex, never more), per ctrl frame decoded, per
    /// message the frame check drops, and the RUDP counters every 2 s. For finding why a console drops the ctrl stage.
    public var rudpTrace = false
    /// The limits of the PSN calls and waits (psn.md section 10).
    public var psnTimeouts = PSNTimeouts()

    public init() {}
}

/// Why an internet start (or a PIN-less pairing) failed. Nothing is left behind: the PSN session was left and the UPnP
/// mappings removed before it is thrown.
public enum InternetStartError: Error, Sendable, Equatable {
    /// The caller cancelled. Not a failure to show: `userMessage` is empty.
    case cancelled
    /// A PSN step failed (psn.md section 9).
    case psn(PSNError)
    /// Neither UPnP nor STUN gave a public address (holepunch.md section 4.2, last row).
    case noPublicAddress
    /// The UDP socket of a hole couldn't be made.
    case socket(FailureKind)
    /// A hole could not be punched (holepunch.md section 5).
    case holePunch(hole: InternetHole, PunchError)
    /// The registration through PSN failed: the console refused (`consoleAnswered`) or never answered (stream.md
    /// section 11.2 reasons 13 and 14).
    case registration(RegistrationError)
    /// Session init or ctrl failed, over RUDP, as on the LAN.
    case session(SessionError, stage: StreamStartError.Stage)
    /// No ctrl `0x0034` answered the switch message within 5 s (rudp.md section 8).
    case switchNotAcknowledged
    /// The probe-to-StreamInfo stage failed, or ctrl ended, before the stream was up. `detail` has no secrets.
    case stream(StreamEndReason, detail: String)

    /// The end reason of stream.md section 11.2 this corresponds to (nil when cancelled).
    public var endReason: StreamEndReason? {
        switch self {
        case .cancelled: nil
        case .registration(let error):
            StreamEndReason(code: error.consoleAnswered ? .psnRegistrationFailed : .psnRegistrationUnanswered)
        case .session(let error, let stage): StreamStartError.reason(for: error, stage: stage)
        case .stream(let reason, _): reason
        case .psn, .noPublicAddress, .socket, .holePunch, .switchNotAcknowledged: StreamEndReason(code: .streamFailed)
        }
    }

    /// Whether a later try can help without the user changing anything (the console may still be busy from the last
    /// session: psn.md section 8 says to wait about 10 s).
    public var retryClass: StreamRetryClass {
        switch self {
        case .cancelled: .stopped
        case .session(.consoleBusy, _): .busy
        case .holePunch, .switchNotAcknowledged: .dropped
        default: endReason?.retryClass ?? .final
        }
    }

    /// A message for the user (empty when cancelled).
    public func userMessage(console: StreamConsoleName) -> String {
        let name = console.rawValue
        switch self {
        case .cancelled:
            return ""
        case .psn(let error):
            return Self.message(for: error, console: name)
        case .noPublicAddress:
            return "PlayFX couldn't find this Mac's address on the internet. Check the internet connection, and "
                + "that nothing blocks outgoing UDP."
        case .socket:
            return "PlayFX couldn't open a network port. Check that nothing else is using the network heavily, "
                + "and try again."
        case .holePunch(let hole, let error):
            switch error {
            case .cancelled: return ""
            case .signalingFailed:
                return "The \(name) stopped answering through PlayStation Network while the connection was being "
                    + "set up. Try again."
            case .consoleDidNotProbe, .hostUnreachable, .invalidOffer, .noPublicAddress:
                let which = hole == .ctrl ? "" : " (the video connection)"
                return "PlayFX couldn't open a direct connection to the \(name)\(which). The router at either end may "
                    + "block it: enable UPnP on the router, or try another network."
            }
        case .registration(let error):
            if error.consoleAnswered {
                return "The \(name) refused the pairing step of the internet connection"
                    + (error.reasonCode.map { String(format: " (reason 0x%08x)", $0) } ?? "")
                    + ". Make sure this PlayStation account is the one signed in on the \(name), then try again."
            }
            return "The \(name) didn't answer the internet connection. Try again in a moment."
        case .session(let error, _):
            return error.userMessage(ps5: console == .ps5)
        case .switchNotAcknowledged:
            return "The \(name) didn't switch to the video connection. Try again."
        case .stream(let reason, _):
            return reason.userMessage(console: console)
        }
    }

    private static func message(for error: PSNError, console name: String) -> String {
        switch error {
        case .unauthorized:
            return "PlayStation Network refused the sign-in. Sign in to PlayFX with your PlayStation account again."
        case .consoleUnreachable, .consoleMismatch, .ps4NotPrimary:
            return "The \(name) didn't join. Check that it's on, or in rest mode with \"Stay Connected to the "
                + "Internet\" enabled, that Remote Play is turned on, and that it's signed in with this account."
        case .terminated, .sessionEnded:
            return "PlayStation Network ended the connection. Try again."
        case .timedOut, .pushChannelClosed, .pushChannelNotResponding, .webSocketFailed, .transport:
            return "PlayFX couldn't reach PlayStation Network. Check the internet connection and try again."
        default:
            return "PlayStation Network sent an answer PlayFX couldn't use. Try again; if it keeps happening, sign "
                + "in again."
        }
    }
}
