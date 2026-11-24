// Candidates and the hole-punch messages exchanged through PSN (holepunch.md sections 1, 4, 6; psn.md section 7).
// The PSN JSON is someone else's: these are our own value types an adapter maps to and from it.

/// The type of a candidate (psn.md section 7.4).
public enum PunchCandidateType: String, Sendable, Equatable {
    /// The public address with the local port.
    case staticAddress = "STATIC"
    /// The LAN address.
    case local = "LOCAL"
    /// A public address and port as a STUN server saw (or a guess of the next one).
    case stun = "STUN"
    /// A source address we learned from an incoming probe (holepunch.md section 5.4).
    case derived = "DERIVED"
}

/// One address a peer can be reached at.
public struct PunchCandidate: Sendable, Equatable {
    /// The type.
    public var type: PunchCandidateType
    /// The IPv4 address (dotted text).
    public var address: String
    /// The UDP port.
    public var port: UInt16
    /// `mappedAddr`: `0.0.0.0` except in an ACCEPT (holepunch.md section 6).
    public var mappedAddress: String
    /// `mappedPort`: 0 except in an ACCEPT.
    public var mappedPort: UInt16

    public init(type: PunchCandidateType, address: String, port: UInt16, mappedAddress: String = "0.0.0.0",
                mappedPort: UInt16 = 0) {
        self.type = type
        self.address = address
        self.port = port
        self.mappedAddress = mappedAddress
        self.mappedPort = mappedPort
    }

    /// True for `10.`, `192.168.` and `172.16.`-`172.31.` (and IPv6 `fc`/`fd`) addresses (holepunch.md section 6).
    public var isPrivateAddress: Bool {
        let parts = address.split(separator: ".")
        if parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]) {
            return a == 10 || (a == 192 && b == 168) || (a == 172 && (16...31).contains(b))
        }
        let lower = address.lowercased()
        return lower.hasPrefix("fc") || lower.hasPrefix("fd")
    }
}

/// An OFFER (either side): the sender's ids and candidates (psn.md sections 7.3, 7.6).
///
/// Constants the adapter writes for the client (holepunch.md section 4.5): `skey` 16 zero bytes, `natType` 2,
/// `defaultRouteMacAddr` empty, `localPeerAddr` `{"accountId":...,"platform":"REMOTE_PLAY"}`, `localHashedId` base64.
public struct PunchOffer: Sendable, Equatable {
    /// The sender's `sid`.
    public var sid: UInt16
    /// `peerSid`: for the client, 0 on the ctrl hole and the console's ctrl-hole `sid` on the data hole.
    public var peerSid: UInt16
    /// The sender's 20-byte hashed id.
    public var hashedID: [UInt8]
    /// The candidates in the order to probe them.
    public var candidates: [PunchCandidate]

    public init(sid: UInt16, peerSid: UInt16, hashedID: [UInt8], candidates: [PunchCandidate]) {
        self.sid = sid
        self.peerSid = peerSid
        self.hashedID = hashedID
        self.candidates = candidates
    }
}

/// An ACCEPT (either side): the selected pair (holepunch.md section 6).
///
/// Constants for the client's ACCEPT: `natType` 0, `localHashedId` empty, `skey` zeros, `defaultRouteMacAddr` empty.
public struct PunchAccept: Sendable, Equatable {
    /// The sender's `sid`.
    public var sid: UInt16
    /// The other side's current `sid`.
    public var peerSid: UInt16
    /// The selected console candidate, with `mappedAddress`/`mappedPort` set to the client's side of the pair.
    public var candidate: PunchCandidate

    public init(sid: UInt16, peerSid: UInt16, candidate: PunchCandidate) {
        self.sid = sid
        self.peerSid = peerSid
        self.candidate = candidate
    }
}

/// The PSN side of a hole punch, supplied by the integration (psn.md section 7). Every call blocks.
///
/// The implementation owns the `reqId`s and the RESULT messages (holepunch.md section 5.2): it answers the
/// console's OFFER and ACCEPT with a RESULT, and returns from `sendOffer` once the console's RESULT for it is in.
public protocol PunchSignaling: Sendable {
    /// The console's OFFER for this hole (answered with a RESULT before returning). Waits up to `timeout` seconds.
    func receiveConsoleOffer(timeout: Double) throws -> PunchOffer
    /// Sends the client's OFFER and waits up to `timeout` seconds for the console's RESULT for it.
    func sendOffer(_ offer: PunchOffer, timeout: Double) throws
    /// Sends the client's ACCEPT.
    func sendAccept(_ accept: PunchAccept) throws
    /// The console's ACCEPT (answered with a RESULT before returning). Waits up to `timeout` seconds.
    func receiveConsoleAccept(timeout: Double) throws -> PunchAccept
}

/// Why hole punching or the work around it failed.
public enum PunchError: Error, Sendable, Equatable {
    /// No public address from UPnP or STUN (holepunch.md section 4.2, last row).
    case noPublicAddress
    /// The console's OFFER was unusable (a hashed id that isn't 20 bytes, or no candidates).
    case invalidOffer
    /// No console candidate answered in 20 resends (holepunch.md section 5.3 step 3).
    case hostUnreachable
    /// A response arrived but the console never sent a request of its own (holepunch.md section 5.5 step 2).
    case consoleDidNotProbe
    /// The caller cancelled.
    case cancelled
    /// The PSN side gave up (a timeout, TERMINATE, a failed send).
    case signalingFailed(String)
}
