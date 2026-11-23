/// How a stream ends (stream.md section 11): the end-reason codes, what a console Disconnect maps to, and the
/// message shown to the user.

/// PlayFX's end-reason codes (section 11.2). The raw value is the code.
public enum StreamEndCode: Int, Sendable, Equatable, CaseIterable {
    case unknown = 0, stoppedByClient, sessionInitUnknown, sessionInitRefused, consoleBusy, remotePlayCrashed
    case versionMismatch, ctrlFailed, ctrlConnectFailed, ctrlRefused, streamFailed, streamRemoteDisconnected
    case streamRemoteShutdown, psnRegistrationFailed, psnRegistrationUnanswered
}

/// What PlayFX does after an end (section 11.2 retry classes).
public enum StreamRetryClass: Sendable, Equatable {
    /// Don't retry automatically.
    case final
    /// Retry after a few seconds (the console stays busy about 9 s after a session).
    case busy
    /// Worth reconnecting.
    case dropped
    /// Nothing to do.
    case stopped
}

/// The kind of ending, which picks the message.
public enum StreamEndKind: Sendable, Equatable {
    /// The app stopped the stream.
    case stoppedByClient
    /// The console is shutting down or going to rest mode (`Server shutting down`).
    case consoleShuttingDown
    /// Someone started playing on the console. The spec records no wire signal for it, so nothing maps here
    /// yet (see `StreamEndReason.consoleReasonKinds`).
    case someoneStartedPlaying
    /// Another Remote Play session took over. No wire signal is recorded either.
    case anotherSessionTookOver
    /// The ctrl or stream connection was lost without a Disconnect.
    case connectionLost
    /// Any other end: shown with its code.
    case other
}

/// Which console the messages name.
public enum StreamConsoleName: String, Sendable, Equatable {
    case ps5 = "PS5"
    case ps4 = "PS4"

    public init(target: RPTarget) { self = target.isPS5 ? .ps5 : .ps4 }
}

/// A typed end of the stream, with the raw code.
public struct StreamEndReason: Sendable, Equatable {
    public var code: StreamEndCode
    public var kind: StreamEndKind
    /// The console's Disconnect text, when the console ended the stream.
    public var remoteText: String?

    /// Reason texts the console is known to send, and what they mean. Only `Server shutting down` is
    /// recorded in the spec; others are shown as `.other` with their text. Add entries here when a console
    /// is seen to send them (stream.md section 11.1).
    public static let consoleReasonKinds: [String: StreamEndKind] = [
        DisconnectMessage.serverShuttingDownReason: .consoleShuttingDown
    ]

    /// The end for a code of section 11.2.
    public init(code: StreamEndCode, remoteText: String? = nil) {
        self.code = code
        self.remoteText = remoteText
        switch code {
        case .stoppedByClient: kind = .stoppedByClient
        case .streamRemoteShutdown: kind = .consoleShuttingDown
        case .ctrlFailed, .streamFailed: kind = .connectionLost
        default: kind = .other
        }
    }

    /// The end for a Disconnect the console sent: `Server shutting down` is a remote shutdown (code 12, not an
    /// error); any other text is a remote disconnect (code 11).
    public init(consoleDisconnect reason: String?) {
        let known = reason.flatMap { Self.consoleReasonKinds[$0] }
        if known == .consoleShuttingDown {
            self.init(code: .streamRemoteShutdown, remoteText: reason)
        } else {
            self.init(code: .streamRemoteDisconnected, remoteText: reason)
            if let known { kind = known }
        }
    }

    /// A code from outside (a stored or logged number); an unlisted one is `unknown` (0) but keeps no text.
    public init(rawCode: Int) {
        self.init(code: StreamEndCode(rawValue: rawCode) ?? .unknown)
    }

    /// Whether the end counts as an error.
    public var isError: Bool {
        switch code {
        case .stoppedByClient, .streamRemoteShutdown: false
        default: true
        }
    }

    public var retryClass: StreamRetryClass {
        switch code {
        case .stoppedByClient: .stopped
        case .consoleBusy: .busy
        case .ctrlFailed, .streamFailed: .dropped
        default: .final
        }
    }

    /// The message for the user.
    public func userMessage(console: StreamConsoleName) -> String {
        let name = console.rawValue
        switch kind {
        case .stoppedByClient: return "The stream was stopped."
        case .consoleShuttingDown:
            return "The \(name) ended the stream (it's shutting down or going to rest mode)."
        case .someoneStartedPlaying: return "Someone started playing on the \(name), so the stream ended."
        case .anotherSessionTookOver: return "Another device started Remote Play on the \(name)."
        case .connectionLost: return "The connection to the \(name) was lost."
        case .other: return "The \(name) ended the stream (reason \(code.rawValue))."
        }
    }
}
