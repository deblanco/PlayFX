import Foundation

// Plain value types for the PSN web side of internet play (docs/protocol/psn.md). Nothing here is Codable on
// purpose: the JSON is written and read by hand (key order and spacing are part of the spec), and the
// hole-punching code maps these to its own types.

/// Console family, as PSN's session manager names it (`"PS5"`, `"PS4"`).
public enum PSNPlatform: String, Sendable, Equatable {
    case ps5 = "PS5"
    case ps4 = "PS4"
}

/// One console of the account, from the device list (psn.md section 4).
public struct PSNConsole: Sendable, Equatable {
    /// The console's name (its nickname as set on the console).
    public let name: String
    /// The console's device ID (psn.md section 3.2): 64 lowercase hex characters.
    public let duid: String
    /// Always `.ps5`: the device list is asked for PS5s only (psn.md section 4).
    public let platform: PSNPlatform
    /// The `device.enabledFeatures` strings.
    public let enabledFeatures: [String]
    /// True when `enabledFeatures` contains `"remotePlay"`.
    public var remotePlayEnabled: Bool { enabledFeatures.contains("remotePlay") }

    public init(name: String, duid: String, platform: PSNPlatform = .ps5, enabledFeatures: [String]) {
        self.name = name
        self.duid = duid
        self.platform = platform
        self.enabledFeatures = enabledFeatures
    }
}

/// The step an error belongs to (psn.md sections 9 and 10).
public enum PSNStep: String, Sendable, Equatable {
    case consoleList, pushServerAddress, webSocketConnect, createSession, inspectSession
    case startCommand, ps4Profile, ps4Wake, sessionMessage, leaveSession
    case waitSessionCreated, waitMemberJoined, waitCustomData, waitOffer, waitResult, waitAccept, waitDeletion
}

/// Why a PSN step failed (psn.md section 9). PSN's own error bodies are never read, so the cases say which step
/// failed and with what HTTP status, not why PSN refused.
public enum PSNError: Error, Sendable, Equatable {
    /// HTTP 401 or 403: token expired, revoked, lacking a scope, or made without a client device ID.
    case unauthorized(step: PSNStep, status: Int)
    /// Any other HTTP status the step doesn't accept (400 or more; for the device list anything but 200).
    case httpStatus(step: PSNStep, status: Int)
    /// PS4 wake answered 404: not the account's primary PS4, or it can't be reached.
    case ps4NotPrimary
    /// The request failed below HTTP (DNS, TLS, connection reset...).
    case transport(step: PSNStep, description: String)
    /// A request or a wait ran past its limit (psn.md section 10).
    case timedOut(step: PSNStep)
    /// The answer wasn't the expected JSON.
    case invalidResponse(step: PSNStep, reason: String)
    /// The push WebSocket couldn't be opened.
    case webSocketFailed(description: String)
    /// The push WebSocket closed or failed while notifications were still wanted.
    case pushChannelClosed
    /// No pong came within the deadline after a ping.
    case pushChannelNotResponding
    /// PSN reported `remotePlaySession:deleted` for this session.
    case sessionEnded
    /// No console member and `customData1` within the wait: off, resting without internet, Remote Play off,
    /// or another account on it (psn.md section 6.3).
    case consoleUnreachable
    /// A different console than the requested one joined (PS5 start).
    case consoleMismatch
    /// `customData1` isn't base64 of base64 of at least 16 bytes.
    case invalidCustomData
    /// A session message's payload isn't a valid message (psn.md section 7.5).
    case invalidMessage(reason: String)
    /// The console sent `TERMINATE`: it gave up.
    case terminated
    /// A call that needs an earlier step (for example messages before the console joined).
    case invalidState(reason: String)
    /// A parameter has the wrong size or shape.
    case invalidParameter(reason: String)
}

/// Time limits (psn.md section 10), in seconds. The defaults are the reference client's choices; tests shrink them.
public struct PSNTimeouts: Sendable, Equatable {
    /// Device list.
    public var deviceList: TimeInterval = 5
    /// Push server address, create, start, PS4 profile and wake, session message, DELETE, inspect.
    public var request: TimeInterval = 10
    /// Opening the push WebSocket (the connect limit and the wait for it to open are both 30 s).
    public var webSocketConnect: TimeInterval = 30
    /// WebSocket ping interval.
    public var pingInterval: TimeInterval = 5
    /// How long after a ping its pong may take.
    public var pongDeadline: TimeInterval = 5
    /// Each wait for a notification or a session message.
    public var notification: TimeInterval = 30
    /// The wait for the deletion notification when leaving.
    public var deletion: TimeInterval = 3

    public init() {}
}

/// Kind of a connectivity candidate (psn.md section 7.4).
public enum PSNCandidateType: String, Sendable, Equatable {
    case staticAddress = "STATIC"
    case local = "LOCAL"
    case stun = "STUN"
    case derived = "DERIVED"
}

/// One address candidate as it appears in `connRequest.candidate` (psn.md section 7.4). Addresses are dotted
/// IPv4 text; unused mapped fields are `"0.0.0.0"` and 0.
public struct PSNCandidate: Sendable, Equatable {
    public var type: PSNCandidateType
    public var address: String
    public var mappedAddress: String
    public var port: UInt16
    public var mappedPort: UInt16

    public init(
        type: PSNCandidateType, address: String, mappedAddress: String = "0.0.0.0", port: UInt16,
        mappedPort: UInt16 = 0
    ) {
        self.type = type
        self.address = address
        self.mappedAddress = mappedAddress
        self.port = port
        self.mappedPort = mappedPort
    }

    /// The candidate an ACCEPT carries (holepunch.md section 6): the console's selected candidate with
    /// `mappedAddress`/`mappedPort` set to the client's side of the pair. A `LOCAL` console candidate, or a
    /// `DERIVED` one with a private address, maps to the client's LOCAL candidate; anything else to the
    /// client's first OFFER candidate.
    public static func accepting(selected: PSNCandidate, clientLocal: PSNCandidate, clientFirstOffer: PSNCandidate)
        -> PSNCandidate
    {
        let viaLocal = selected.type == .local || (selected.type == .derived && isPrivateAddress(selected.address))
        let mapped = viaLocal ? clientLocal : clientFirstOffer
        return PSNCandidate(
            type: selected.type, address: selected.address, mappedAddress: mapped.address, port: selected.port,
            mappedPort: mapped.port)
    }

    private static func isPrivateAddress(_ address: String) -> Bool {
        if address.hasPrefix("10.") || address.hasPrefix("192.168.") { return true }
        if address.hasPrefix("172.") {
            let parts = address.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]) { return (16...31).contains(second) }
            return false
        }
        let lower = address.lowercased()
        return lower.hasPrefix("fc") || lower.hasPrefix("fd")
    }
}

/// `connRequest.localPeerAddr` (psn.md section 7.3).
public struct PSNPeerAddress: Sendable, Equatable {
    /// Decimal account ID.
    public var accountID: String
    /// `REMOTE_PLAY` for the client; `PROSPERO` (PS5) or `ORBIS` (PS4) for a console, per the reference's notes.
    public var platform: String

    public init(accountID: String, platform: String) {
        self.accountID = accountID
        self.platform = platform
    }
}

/// `connRequest` of an OFFER or ACCEPT (psn.md section 7.3).
public struct PSNConnRequest: Sendable, Equatable {
    public var sid: Int
    public var peerSid: Int
    /// 16 bytes (the client always sends zeros).
    public var skey: [UInt8]
    public var natType: Int
    public var candidates: [PSNCandidate]
    /// `xx:xx:xx:xx:xx:xx` lowercase, or empty.
    public var defaultRouteMACAddress: String
    /// Nil when a console's message had no value for it (psn.md section 7.5); the client always sends one.
    public var localPeerAddress: PSNPeerAddress?
    /// 20 bytes, or empty (`""` on the wire).
    public var localHashedID: [UInt8]

    public init(
        sid: Int, peerSid: Int, skey: [UInt8] = [UInt8](repeating: 0, count: 16), natType: Int,
        candidates: [PSNCandidate], defaultRouteMACAddress: String = "", localPeerAddress: PSNPeerAddress?,
        localHashedID: [UInt8]
    ) {
        self.sid = sid
        self.peerSid = peerSid
        self.skey = skey
        self.natType = natType
        self.candidates = candidates
        self.defaultRouteMACAddress = defaultRouteMACAddress
        self.localPeerAddress = localPeerAddress
        self.localHashedID = localHashedID
    }
}

/// `action` of a session message.
public enum PSNMessageAction: String, Sendable, Equatable {
    case offer = "OFFER"
    case accept = "ACCEPT"
    case result = "RESULT"
    case terminate = "TERMINATE"
}

/// A session message (psn.md section 7.2).
public struct PSNMessage: Sendable, Equatable {
    public var action: PSNMessageAction
    public var reqID: Int
    public var error: Int
    /// Nil for `{}` (always so for a RESULT).
    public var connRequest: PSNConnRequest?

    public init(action: PSNMessageAction, reqID: Int, error: Int = 0, connRequest: PSNConnRequest?) {
        self.action = action
        self.reqID = reqID
        self.error = error
        self.connRequest = connRequest
    }
}

/// A push notification, decoded (psn.md section 5.4). Fields are nil when the frame lacked them.
public enum PSNNotification: Sendable, Equatable {
    /// `remotePlaySession:created`; `/to/onlineId`.
    case sessionCreated(onlineID: String?)
    /// `rps:members:created`; `/body/data/members/0/deviceUniqueId`.
    case memberJoined(deviceUniqueID: String?)
    /// `rps:customData1:updated`; `/body/data/customData1` (still double base64).
    case customDataUpdated(customData1: String?)
    /// `rps:sessionMessage:created`; `/body/data/sessionMessage/payload`.
    case sessionMessage(payload: String?)
    /// `rps:members:deleted`.
    case memberLeft
    /// `remotePlaySession:deleted`; `/body/data/sessionId`.
    case sessionDeleted(sessionID: String?)
}
