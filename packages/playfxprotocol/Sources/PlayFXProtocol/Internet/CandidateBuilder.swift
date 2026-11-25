// The client's candidate list for an OFFER (holepunch.md section 4), from injected inputs.

/// What UPnP gave one hole (holepunch.md section 3.1): the mapping worked and the gateway told its external address.
public struct UPnPMapping: Sendable, Equatable {
    /// The client's LAN address towards the gateway (`lanIp`).
    public var lanAddress: String
    /// The gateway's external address (`publicIp`).
    public var publicAddress: String

    public init(lanAddress: String, publicAddress: String) {
        self.lanAddress = lanAddress
        self.publicAddress = publicAddress
    }
}

/// Everything the list is built from, for one hole.
public struct CandidateInputs: Sendable, Equatable {
    /// The hole socket's local port.
    public var localPort: UInt16
    /// The first usable IPv4 address of this machine (`LocalInterfaces.firstUsableIPv4`), used when UPnP gave none;
    /// nil sends the LOCAL candidate with an empty address.
    public var interfaceAddress: String?
    /// The UPnP result, when the mapping and the external address both worked.
    public var upnp: UPnPMapping?
    /// The STUN prediction, when UPnP didn't give a public address.
    public var stun: NATPrediction?
    /// The user forced port guessing (holepunch.md section 4.2, sixth row).
    public var forcePortGuessing: Bool
    /// How many guesses to make under random allocation (75 by default).
    public var guessCount: Int

    public init(localPort: UInt16, interfaceAddress: String?, upnp: UPnPMapping? = nil, stun: NATPrediction? = nil,
                forcePortGuessing: Bool = false, guessCount: Int = 75) {
        self.localPort = localPort
        self.interfaceAddress = interfaceAddress
        self.upnp = upnp
        self.stun = stun
        self.forcePortGuessing = forcePortGuessing
        self.guessCount = guessCount
    }
}

/// The candidates of one OFFER and what they imply for the probes.
public struct ClientCandidates: Sendable, Equatable {
    /// The candidates in the order to send them: STUN guesses first, then STATIC, then LOCAL.
    public var candidates: [PunchCandidate]
    /// The client behaves as random-allocation for the probes: extra low-TTL sockets (holepunch.md section 5.3).
    public var randomAllocation: Bool

    /// The client's LOCAL candidate, if one was built (the ACCEPT's `mappedAddr` for a private console address).
    public var local: PunchCandidate? { candidates.first { $0.type == .local } }
    /// The first candidate of the OFFER (the ACCEPT's `mappedAddr` for any other console address).
    public var first: PunchCandidate? { candidates.first }
}

/// Builds the candidate list (holepunch.md sections 4.1 to 4.4).
public enum CandidateBuilder {
    /// - Throws: `PunchError.noPublicAddress` when neither UPnP nor STUN gave a public address.
    public static func build(_ inputs: CandidateInputs) throws -> ClientCandidates {
        let publicAddress: String
        var stunCandidates: [PunchCandidate] = []
        var random = false
        // An address that isn't dotted IPv4 never becomes a candidate (the STUN answer is used instead).
        let upnp = inputs.upnp.flatMap { IPv4Text.octets($0.publicAddress) == nil ? nil : $0 }
        if let upnp {
            publicAddress = upnp.publicAddress
        } else if let stun = inputs.stun {
            publicAddress = stun.publicAddress
            func stunCandidate(_ port: UInt16) -> PunchCandidate {
                PunchCandidate(type: .stun, address: stun.publicAddress, port: port)
            }
            let keepsPort = stun.basePort == inputs.localPort
            // A NAT whose answers differ in port, yet show no step, maps per destination: the console will see yet another
            // port, so the ports are guessed (a client choice; the spec's rule alone says "stable").
            random = stun.randomAllocation || stun.isPerDestination
                || (stun.increment == 0 && !keepsPort && inputs.forcePortGuessing)
            if random {
                stunCandidates = PortGuess.guesses(around: stun.basePort, count: inputs.guessCount).map(stunCandidate)
            } else if stun.increment != 0 {
                stunCandidates = PortGuess.steps(from: stun.basePort, increment: stun.increment, count: 8)
                    .map(stunCandidate)
            } else if !keepsPort {
                stunCandidates = [stunCandidate(stun.basePort)]
            }
        } else {
            throw PunchError.noPublicAddress
        }
        var list = stunCandidates
        list.append(PunchCandidate(type: .staticAddress, address: publicAddress, port: inputs.localPort))
        // No LAN address: the LOCAL candidate is still sent, with an empty address (holepunch.md section 4.1).
        list.append(PunchCandidate(type: .local, address: upnp?.lanAddress ?? inputs.interfaceAddress ?? "",
                                   port: inputs.localPort))
        return ClientCandidates(candidates: list, randomAllocation: random)
    }

    /// The candidate an ACCEPT carries (holepunch.md section 6): the selected console candidate with the client's
    /// side of the pair as `mappedAddress`/`mappedPort`: the client's LOCAL candidate for a `LOCAL` or private
    /// `DERIVED` console address, the first OFFER candidate for any other.
    public static func acceptCandidate(selected: PunchCandidate, client: ClientCandidates) -> PunchCandidate {
        let toLocal = selected.type == .local || (selected.type == .derived && selected.isPrivateAddress)
        let mapped = (toLocal ? client.local : nil) ?? client.first
        var result = selected
        result.mappedAddress = mapped?.address ?? "0.0.0.0"
        result.mappedPort = mapped?.port ?? 0
        return result
    }
}
