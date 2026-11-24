import Foundation
import os

// The hole punch (holepunch.md sections 5 to 7): probes to every console candidate, answers to the console's,
// extra low-TTL sockets under random allocation, the selection rule, and the connected socket handed back.

/// The client's ids for one PSN session, shared by both holes (holepunch.md section 1).
public struct PunchIdentity: Sendable, Equatable {
    /// `localSid`: the low 16 bits of a random 32-bit number.
    public var sid: UInt16
    /// `localHashedId`: 20 random bytes.
    public var hashedID: [UInt8]

    public init(sid: UInt16, hashedID: [UInt8]) {
        precondition(hashedID.count == 20, "hashed id is 20 bytes")
        self.sid = sid
        self.hashedID = hashedID
    }

    /// New random ids.
    public static func random() -> PunchIdentity {
        PunchIdentity(sid: UInt16(truncatingIfNeeded: UInt32.random(in: 0...UInt32.max)),
                      hashedID: (0..<20).map { _ in UInt8.random(in: 0...255) })
    }
}

/// What a probe from the wrong party does (holepunch.md section 5.1: the reference checks only the type and the request id,
/// and the console's own perspective in its probes is assumed, not observed, section 10 question 1).
public enum ProbeIdentityCheck: Sendable, Equatable {
    /// A probe counts only if its sender is the console and its receiver is us (the default). Others are dropped.
    case strict
    /// Accepts every probe, like the reference, and logs the first mismatch of a hole. For a first hardware round, to tell
    /// a wrong assumption about the console's fields from a forgery.
    case logOnly
}

/// Timing, limits and seams of a hole punch. Defaults are the reference's values (holepunch.md section 9).
public struct HolePunchOptions: Sendable {
    /// Wait for the console's OFFER, for the RESULT of ours and for the console's ACCEPT: 30 s each.
    public var signalingWait: Double = 30
    /// Wait for a packet before resending: 0.5 s.
    public var probeWait: Double = 0.5
    /// Resends after the first round: 20.
    public var resends: Int = 20
    /// Extra low-TTL sockets under random allocation: 250.
    public var extraSocketCount: Int = 250
    /// Their IP time to live: 2.
    public var extraSocketTTL: Int = 2
    /// Derived candidates kept: 3.
    public var maxDerived: Int = 3
    /// The quiet time that ends the answering after selection and after the ACCEPT: 1 s.
    public var quietTime: Double = 1
    /// Five request-id bytes.
    public var makeRequestID: @Sendable () -> [UInt8] = { (0..<5).map { _ in UInt8.random(in: 0...255) } }
    /// Makes one extra socket (bound to an ephemeral port).
    public var makeExtraSocket: @Sendable () throws -> any UDPPunchSocket = { try POSIXPunchSocket() }
    /// Who may probe: see `ProbeIdentityCheck`.
    public var probeIdentity = ProbeIdentityCheck.strict
    /// Diagnostics: one line per hole when a probe doesn't match the identity expected. Never carries ids or keys; it does
    /// carry the address the probe came from, so the default writes it to the unified log as `.private`.
    public var log: @Sendable (String) -> Void = { message in
        Logger(subsystem: "PlayFXProtocol", category: "holepunch").notice("\(message, privacy: .private)")
    }
    /// Checked while waiting.
    public var isCancelled: @Sendable () -> Bool = { false }

    public init() {}
}

/// A hole that is open: one UDP socket connected to the console address and port that answered.
public struct PunchedHole: Sendable {
    /// The connected socket: RUDP for the ctrl hole, Takion for the data hole (holepunch.md section 7).
    public let socket: any UDPPunchSocket
    /// The selected console candidate (a derived one when the console answered from an address it never announced).
    public let selected: PunchCandidate
    /// The console's `sid` at the end (replaced by each new console OFFER).
    public let consoleSid: UInt16
    /// The console's hashed id from its OFFER.
    public let consoleHashedID: [UInt8]
    /// The candidate sent in the ACCEPT, with the client's side of the pair as `mapped*`.
    public let accepted: PunchCandidate

    /// `<addr>:<port>` of the selection: the `Host` header of session init and ctrl on the ctrl hole (section 6).
    public var hostHeaderValue: String { "\(selected.address):\(selected.port)" }
}

/// Opens a hole (holepunch.md section 5).
public enum HolePunch {
    /// Runs the whole sequence of holepunch.md section 5.2 for one hole, blocking the calling thread.
    ///
    /// - Parameters:
    ///   - socket: the hole's socket, the one STUN was asked from; closed on failure.
    ///   - identity: the client's sid and hashed id.
    ///   - client: the candidates already built from it (`CandidateBuilder`).
    ///   - peerSid: the OFFER's `peerSid`: 0 for the ctrl hole, the console's ctrl-hole `sid` for the data hole.
    ///   - signaling: the PSN side.
    public static func run(socket: any UDPPunchSocket, identity: PunchIdentity, client: ClientCandidates,
                           peerSid: UInt16, signaling: any PunchSignaling,
                           options: HolePunchOptions = HolePunchOptions()) throws -> PunchedHole {
        var sockets: [any UDPPunchSocket] = [socket]
        do {
            return try attempt(socket: socket, identity: identity, client: client, peerSid: peerSid,
                               signaling: signaling, options: options, sockets: &sockets)
        } catch {
            for s in sockets { s.close() }
            throw error
        }
    }

    private static func attempt(socket: any UDPPunchSocket, identity: PunchIdentity, client: ClientCandidates,
                                peerSid: UInt16, signaling: any PunchSignaling, options: HolePunchOptions,
                                sockets: inout [any UDPPunchSocket]) throws -> PunchedHole {
        let consoleOffer = try signaling.receiveConsoleOffer(timeout: options.signalingWait)
        guard consoleOffer.hashedID.count == 20, !consoleOffer.candidates.isEmpty else { throw PunchError.invalidOffer }
        try signaling.sendOffer(
            PunchOffer(sid: identity.sid, peerSid: peerSid, hashedID: identity.hashedID, candidates: client.candidates),
            timeout: options.signalingWait)

        let prober = Prober(identity: identity, console: consoleOffer, randomAllocation: client.randomAllocation,
                            options: options, main: socket)
        if client.randomAllocation {
            // GUI apps often start with a soft limit of 256 descriptors: raise it, and when sockets still run out
            // carry on with the ones made (the main socket alone can still win).
            FileLimit.raiseSoftLimit(toAtLeast: UInt64(options.extraSocketCount + 128))
            for _ in 0..<options.extraSocketCount {
                guard let extra = try? options.makeExtraSocket() else { break }
                sockets.append(extra)
                try? extra.setTimeToLive(options.extraSocketTTL)
                prober.addExtra(extra)
            }
        }
        let selection = try prober.probe()
        for s in sockets where s !== selection.socket { s.close() }
        sockets = [selection.socket]
        try selection.socket.connect(host: selection.candidate.address, port: selection.candidate.port)

        // Section 5.5: keep answering for as long as the console keeps asking; it must ask at least once.
        prober.answerUntilQuiet(on: selection.socket)
        if options.isCancelled() { throw PunchError.cancelled }
        guard prober.answered > 0 else { throw PunchError.consoleDidNotProbe }

        let accepted = CandidateBuilder.acceptCandidate(selected: selection.candidate, client: client)
        try signaling.sendAccept(PunchAccept(sid: identity.sid, peerSid: consoleOffer.sid, candidate: accepted))
        _ = try signaling.receiveConsoleAccept(timeout: options.signalingWait)
        prober.answerUntilQuiet(on: selection.socket)
        if options.isCancelled() { throw PunchError.cancelled }
        return PunchedHole(socket: selection.socket, selected: selection.candidate, consoleSid: consoleOffer.sid,
                           consoleHashedID: consoleOffer.hashedID, accepted: accepted)
    }

    /// The probe state of one hole.
    private final class Prober {
        struct Selection {
            var socket: any UDPPunchSocket
            var candidate: PunchCandidate
        }

        static let packetsPerSweep = 16
        let identity: PunchIdentity
        let console: PunchOffer
        let randomAllocation: Bool
        let options: HolePunchOptions
        let requestID: [UInt8]
        let request: [UInt8]
        var sockets: [any UDPPunchSocket]
        var candidates: [PunchCandidate]
        var derived = 0
        private var loggedMismatch = false
        var warmed = Set<Int>()
        private(set) var answered = 0

        init(identity: PunchIdentity, console: PunchOffer, randomAllocation: Bool, options: HolePunchOptions,
             main: any UDPPunchSocket) {
            self.identity = identity
            self.console = console
            self.randomAllocation = randomAllocation
            self.options = options
            requestID = options.makeRequestID()
            request = ProbePacket.request(senderHashedID: identity.hashedID, receiverHashedID: console.hashedID,
                                          senderSid: identity.sid, receiverSid: console.sid, requestID: requestID)
            sockets = [main]
            candidates = console.candidates
        }

        func addExtra(_ socket: any UDPPunchSocket) { sockets.append(socket) }

        /// True when the probe is in the console's voice and addressed to us (holepunch.md section 5.1: the sender is
        /// the console, by its hashed id and `sid` from its OFFER; the receiver is us). The spec calls the
        /// console's own perspective assumed, not observed, so a mismatch is logged once per hole, naming the fields
        /// that differed (never their values), to show on the first real run if the console fills one differently.
        /// With `probeIdentity == .logOnly` the probe is accepted all the same.
        func isAuthentic(_ probe: ProbePacket, from source: (address: String, port: UInt16)) -> Bool {
            var wrong: [String] = []
            if probe.senderHashedID != console.hashedID { wrong.append("sender hashed id") }
            if probe.senderSid != console.sid { wrong.append("sender sid") }
            if probe.receiverHashedID != identity.hashedID { wrong.append("receiver hashed id") }
            if probe.receiverSid != identity.sid { wrong.append("receiver sid") }
            if wrong.isEmpty { return true }
            let strict = options.probeIdentity == .strict
            if !loggedMismatch {
                loggedMismatch = true
                options.log("probe from \(source.address):\(source.port) \(strict ? "dropped" : "accepted anyway (log only)"), "
                    + "identity mismatch: " + wrong.joined(separator: ", ")
                    + " (further mismatches in this hole are not logged)")
            }
            return !strict
        }

        func sendRequest(from socketIndex: Int, to candidateIndex: Int) {
            let c = candidates[candidateIndex]
            try? sockets[socketIndex].send(request, to: c.address, port: c.port)
        }

        /// Sections 5.3 and 5.4.
        func probe() throws -> Selection {
            func sendRound() {
                for i in candidates.indices { sendRequest(from: 0, to: i) }
            }
            // The main socket's request goes first (holepunch.md section 5.3 step 1); then the low-TTL sockets open
            // mappings in the client's NAT towards each STATIC and STUN candidate (step 2).
            sendRound()
            for s in sockets.indices.dropFirst() {
                for i in candidates.indices where candidates[i].type == .staticAddress || candidates[i].type == .stun {
                    sendRequest(from: s, to: i)
                }
            }
            for round in 0...options.resends {
                let deadline = monotonicSeconds() + options.probeWait
                while monotonicSeconds() < deadline {
                    if options.isCancelled() { throw PunchError.cancelled }
                    if let selection = poll(waiting: min(0.005, max(0, deadline - monotonicSeconds()))) {
                        return selection
                    }
                }
                if round < options.resends { sendRound() }
            }
            throw PunchError.hostUnreachable
        }

        /// Reads whatever is queued on every socket; sleeps on the main one when nothing is.
        private func poll(waiting: Double) -> Selection? {
            var any = false
            for index in sockets.indices {
                // A bounded number per socket and sweep, so a flood can't hold the loop past its deadline.
                for _ in 0..<Self.packetsPerSweep {
                    guard let packet = try? sockets[index].receive(timeout: 0) else { break }
                    any = true
                    if let selection = handle(packet, on: index) { return selection }
                }
            }
            if !any {
                if let packet = try? sockets[0].receive(timeout: waiting), let selection = handle(packet, on: 0) {
                    return selection
                }
            }
            return nil
        }

        /// Section 5.4.
        private func handle(_ packet: UDPPacket, on index: Int) -> Selection? {
            // Not a probe at all (also a probe-sized datagram of another type), or not from the console to us:
            // nothing to learn from it, nothing to answer, and no derived candidate.
            guard let probe = ProbePacket.parse(packet.bytes),
                  isAuthentic(probe, from: (packet.host, packet.port)) else { return nil }
            if index > 0 && warmed.insert(index).inserted { try? sockets[index].setTimeToLive(64) }
            var candidateIndex = candidates.firstIndex { $0.address == packet.host && $0.port == packet.port }
            if candidateIndex == nil {
                guard derived < options.maxDerived else { return nil }
                derived += 1
                candidates.append(PunchCandidate(type: .derived, address: packet.host, port: packet.port))
                candidateIndex = candidates.count - 1
            }
            guard let candidateIndex else { return nil }
            switch probe.kind {
            case .request:
                respond(to: packet, on: index)
                // For every console request from a derived candidate (any candidate under random allocation), the
                // client's own request goes back to it from the same socket (holepunch.md section 5.4 step 3).
                if candidates[candidateIndex].type == .derived || randomAllocation {
                    sendRequest(from: index, to: candidateIndex)
                }
            case .response:
                if probe.requestID == requestID {
                    return Selection(socket: sockets[index], candidate: candidates[candidateIndex])
                }
            }
            return nil
        }

        private func respond(to packet: UDPPacket, on index: Int) {
            guard let response = ProbePacket.response(
                senderHashedID: identity.hashedID, receiverHashedID: console.hashedID, senderSid: identity.sid,
                receiverSid: console.sid, requestID: ProbePacket.parse(packet.bytes)?.requestID ?? [],
                source: (packet.host, packet.port)) else { return }
            try? sockets[index].send(response, to: packet.host, port: packet.port)
            answered += 1
        }

        /// Section 5.5 step 1: answers requests on the connected socket until `quietTime` passes without one.
        func answerUntilQuiet(on socket: any UDPPunchSocket) {
            var last = monotonicSeconds()
            while monotonicSeconds() - last < options.quietTime && !options.isCancelled() {
                let remaining = options.quietTime - (monotonicSeconds() - last)
                let received: UDPPacket?
                do {
                    received = try socket.receive(timeout: min(remaining, 0.05))
                } catch {
                    sleepSeconds(0.01)
                    continue
                }
                guard let packet = received else { continue }
                if let probe = ProbePacket.parse(packet.bytes), probe.kind == .request,
                   isAuthentic(probe, from: (packet.host, packet.port)) {
                    if let response = ProbePacket.response(
                        senderHashedID: identity.hashedID, receiverHashedID: console.hashedID,
                        senderSid: identity.sid, receiverSid: console.sid, requestID: probe.requestID,
                        source: (packet.host, packet.port)) {
                        try? socket.send(response, to: packet.host, port: packet.port)
                        answered += 1
                    }
                    last = monotonicSeconds()
                }
            }
        }
    }
}
