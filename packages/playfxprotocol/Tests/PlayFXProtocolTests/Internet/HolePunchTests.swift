import Dispatch
import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

/// A fake PSN side: hands the client the console's OFFER and ACCEPT, records what the client sends.
final class FakeSignaling: PunchSignaling, @unchecked Sendable {
    let consoleOffer: PunchOffer
    let offers = Locked<[PunchOffer]>([])
    let accepts = Locked<[PunchAccept]>([])
    let onClientOffer = Locked<(@Sendable (PunchOffer) -> Void)?>(nil)
    var failure: PunchError?
    var failAccept: PunchError?
    var onAccept: (@Sendable () -> Void)?

    init(consoleOffer: PunchOffer) { self.consoleOffer = consoleOffer }

    func receiveConsoleOffer(timeout: Double) throws -> PunchOffer {
        if let failure { throw failure }
        return consoleOffer
    }

    func sendOffer(_ offer: PunchOffer, timeout: Double) throws {
        offers.with { $0.append(offer) }
        onClientOffer.with { $0 }?(offer)
    }

    func sendAccept(_ accept: PunchAccept) throws {
        accepts.with { $0.append(accept) }
        onAccept?()
    }

    func receiveConsoleAccept(timeout: Double) throws -> PunchAccept {
        if let failAccept { throw failAccept }
        return PunchAccept(sid: consoleOffer.sid, peerSid: 0, candidate: consoleOffer.candidates[0])
    }
}

/// A fake console peer on loopback: probes the client's candidates and answers its probes.
final class FakePunchConsole: @unchecked Sendable {
    static let hashedID = hex("a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3")
    static let sid: UInt16 = 0xabcd
    let main: LoopbackGuardedPunchSocket
    let alt: LoopbackGuardedPunchSocket
    /// Answers requests (the client's responses come from this).
    var answers = true
    /// Sends its own requests (the mutual check).
    var probes = true
    /// Answers and probes from `alt`, a port it never announced.
    var viaAlt = false
    /// Ignores requests from this client port (so only another socket of the client can win).
    var ignoreClientPort: UInt16?
    let clientRequests = Locked<[ProbePacket]>([])
    let clientResponses = Locked<[[UInt8]]>([])
    private let target = Locked<[PunchCandidate]>([])
    private let stopped = Locked(false)
    private let clientHashedID = Locked<[UInt8]>([])
    private let clientSid = Locked<UInt16>(0)
    private let loopEnded = DispatchSemaphore(value: 0)
    private let started = Locked(false)

    init() throws {
        main = try loopbackSocket()
        alt = try loopbackSocket()
    }

    var announced: PunchOffer {
        PunchOffer(sid: Self.sid, peerSid: 0, hashedID: Self.hashedID, candidates: [
            PunchCandidate(type: .staticAddress, address: "127.0.0.1", port: main.localPort),
            PunchCandidate(type: .local, address: "127.0.0.1", port: main.localPort),
        ])
    }

    /// Starts once the client's OFFER is known.
    func start(clientOffer: PunchOffer) {
        target.with { $0 = clientOffer.candidates }
        clientHashedID.with { $0 = clientOffer.hashedID }
        clientSid.with { $0 = clientOffer.sid }
        started.with { $0 = true }
        Thread { [self] in
            loop()
            loopEnded.signal()
        }.start()
    }

    /// Stops the console's thread (so a test can read its sockets) without closing them.
    func freeze() {
        stopped.with { $0 = true }
        // The thread signals once; only the first freeze waits for it.
        if started.with({ let was = $0; $0 = false; return was }) { _ = loopEnded.wait(timeout: .now() + 2) }
    }

    func stop() {
        freeze()
        main.close()
        alt.close()
    }

    private var speaker: LoopbackGuardedPunchSocket { viaAlt ? alt : main }

    private func loop() {
        var lastSend = 0.0
        let requestID = hex("c1c2c3c4c5")
        while !stopped.with({ $0 }) {
            // Like a console: asks until the client has answered once.
            if probes && clientResponses.with({ $0.isEmpty }) && monotonicSeconds() - lastSend >= 0.03 {
                lastSend = monotonicSeconds()
                let request = ProbePacket.request(
                    senderHashedID: Self.hashedID, receiverHashedID: clientHashedID.with { $0 },
                    senderSid: Self.sid, receiverSid: clientSid.with { $0 }, requestID: requestID)
                for c in target.with({ $0 }) { try? speaker.send(request, to: c.address, port: c.port) }
            }
            for socket in [main, alt] {
                guard let packet = try? socket.receive(timeout: socket === main ? 0.01 : 0) else { continue }
                guard let probe = ProbePacket.parse(packet.bytes) else { continue }
                if probe.kind == .response {
                    clientResponses.with { $0.append(packet.bytes) }
                } else if answers && packet.port != ignoreClientPort {
                    clientRequests.with { $0.append(probe) }
                    if let response = ProbePacket.response(
                        senderHashedID: Self.hashedID, receiverHashedID: probe.senderHashedID, senderSid: Self.sid,
                        receiverSid: probe.senderSid, requestID: probe.requestID, source: (packet.host, packet.port)) {
                        try? speaker.send(response, to: packet.host, port: packet.port)
                    }
                }
            }
        }
    }
}

@Suite(.serialized) struct HolePunchTests {
    static let identity = PunchIdentity(sid: 0x1234, hashedID: hex("000102030405060708090a0b0c0d0e0f10111213"))

    static func options(extras: Int = 0, made: Locked<[LoopbackGuardedPunchSocket]>? = nil) -> HolePunchOptions {
        var options = HolePunchOptions()
        options.signalingWait = 2
        options.probeWait = 0.05
        options.resends = 6
        options.quietTime = 0.25
        options.extraSocketCount = extras
        options.makeRequestID = { hex("5152535455") }
        options.makeExtraSocket = {
            let socket = try loopbackSocket()
            made?.with { $0.append(socket) }
            return socket
        }
        return options
    }

    /// The client's candidates for a socket on loopback (UPnP-style: STATIC and LOCAL on the socket's port).
    static func candidates(for socket: any UDPPunchSocket, random: Bool = false) throws -> ClientCandidates {
        var built = try CandidateBuilder.build(CandidateInputs(
            localPort: socket.localPort, interfaceAddress: "127.0.0.1",
            upnp: UPnPMapping(lanAddress: "127.0.0.1", publicAddress: "127.0.0.1")))
        built.randomAllocation = random
        return built
    }

    /// Runs one punch against a fake console configured by `configure`.
    func punch(extras: Int = 0, random: Bool = false, peerSid: UInt16 = 0,
               configure: (FakePunchConsole, LoopbackGuardedPunchSocket) -> Void = { _, _ in }, signalingFailure: PunchError? = nil,
               options: HolePunchOptions? = nil, made: Locked<[LoopbackGuardedPunchSocket]>? = nil,
               check: (FakePunchConsole, FakeSignaling, LoopbackGuardedPunchSocket, Result<PunchedHole, any Error>) throws -> Void)
        throws {
        let console = try FakePunchConsole()
        defer { console.stop() }
        let socket = try loopbackSocket()
        configure(console, socket)
        let signaling = FakeSignaling(consoleOffer: console.announced)
        signaling.failure = signalingFailure
        signaling.onClientOffer.with { $0 = { console.start(clientOffer: $0) } }
        let result = Result { try HolePunch.run(
            socket: socket, identity: Self.identity, client: try Self.candidates(for: socket, random: random),
            peerSid: peerSid, signaling: signaling, options: options ?? Self.options(extras: extras, made: made)) }
        try check(console, signaling, socket, result)
    }

    @Test func basicPunch() throws {
        try punch(peerSid: 0) { console, signaling, socket, result in
            let hole = try result.get()
            #expect(hole.selected == PunchCandidate(type: .staticAddress, address: "127.0.0.1", port: console.main.localPort))
            #expect(hole.consoleSid == 0xabcd && hole.consoleHashedID == FakePunchConsole.hashedID)
            #expect(hole.hostHeaderValue == "127.0.0.1:\(console.main.localPort)")
            #expect(hole.socket === socket)

            // The OFFER and ACCEPT the integration was handed.
            let offer = try #require(signaling.offers.with { $0.first })
            #expect(offer.sid == 0x1234 && offer.peerSid == 0 && offer.hashedID == Self.identity.hashedID)
            #expect(offer.candidates.map(\.type) == [.staticAddress, .local])
            let accept = try #require(signaling.accepts.with { $0.first })
            #expect(accept.sid == 0x1234 && accept.peerSid == 0xabcd)
            #expect(accept.candidate == PunchCandidate(
                type: .staticAddress, address: "127.0.0.1", port: console.main.localPort,
                mappedAddress: "127.0.0.1", mappedPort: socket.localPort))
            #expect(signaling.accepts.with { $0.count } == 1)

            // The client's first request, byte for byte: its ids, the console's, the request id.
            let first = try #require(console.clientRequests.with { $0.first })
            #expect(first == ProbePacket(kind: .request, senderHashedID: Self.identity.hashedID,
                                         receiverHashedID: FakePunchConsole.hashedID, senderSid: 0x1234,
                                         receiverSid: 0xabcd, requestID: hex("5152535455")))
            // Its responses to the console's requests tell the console where they came from, masked by the sids.
            let response = try #require(console.clientResponses.with { $0.first })
            let expected = try #require(ProbePacket.response(
                senderHashedID: Self.identity.hashedID, receiverHashedID: FakePunchConsole.hashedID, senderSid: 0x1234,
                receiverSid: 0xabcd, requestID: hex("c1c2c3c4c5"), source: ("127.0.0.1", console.main.localPort)))
            #expect(response == expected)

            // The socket is connected to the console: both directions work, and only the console is heard.
            console.freeze()
            try hole.socket.send([1, 2, 3], to: "", port: 0)
            #expect(try console.main.receive(timeout: 1)?.bytes == [1, 2, 3])
            try console.main.send([4, 5], to: "127.0.0.1", port: socket.localPort)
            #expect(try hole.socket.receive(timeout: 1)?.bytes == [4, 5])
            hole.socket.close()
        }
    }

    @Test func dataHoleOfferCarriesTheConsolesCtrlSid() throws {
        try punch(peerSid: 0xabcd) { _, signaling, _, result in
            let hole = try result.get()
            #expect(signaling.offers.with { $0.first?.peerSid } == 0xabcd)
            hole.socket.close()
        }
    }

    @Test func aConsoleAnsweringFromAnotherPortIsADerivedCandidate() throws {
        try punch(configure: { c, _ in c.viaAlt = true }) { console, signaling, socket, result in
            let hole = try result.get()
            #expect(hole.selected == PunchCandidate(type: .derived, address: "127.0.0.1", port: console.alt.localPort))
            // A derived address that is private (127.x isn't) maps to the first OFFER candidate.
            #expect(hole.accepted.mappedPort == socket.localPort)
            // The client also sent its request to the derived candidate.
            #expect(console.clientRequests.with { $0.count } >= 1)
            console.freeze()
            try hole.socket.send([9], to: "", port: 0)
            #expect(try console.alt.receive(timeout: 1)?.bytes == [9])
            #expect(signaling.accepts.with { $0.first?.candidate.type } == .derived)
            hole.socket.close()
        }
    }

    @Test func randomAllocationUsesLowTTLExtraSockets() throws {
        let made = Locked<[LoopbackGuardedPunchSocket]>([])
        try punch(extras: 4, random: true, made: made) { console, _, socket, result in
            let hole = try result.get()
            let extras = made.with { $0 }
            #expect(extras.count == 4)
            // Every extra got TTL 2 first; one that received something went back to 64.
            #expect(extras.allSatisfy { $0.ttls.with { $0.first } == 2 })
            // Each extra sent its request to the console's STATIC and LOCAL candidates on loopback only.
            #expect(extras.allSatisfy { $0.destinations.with { Set($0) } == ["127.0.0.1"] })
            // The hole works whichever socket won, and the others are closed.
            console.freeze()
            try hole.socket.send([7], to: "", port: 0)
            #expect(try console.main.receive(timeout: 1)?.bytes == [7])
            for other in [socket] + extras where other !== hole.socket {
                #expect(throws: (any Error).self) { try other.send([1], to: "127.0.0.1", port: 1) }
            }
            hole.socket.close()
        }
    }

    /// holepunch.md section 5.3: the request goes out from the main socket first, then from the extras.
    @Test func theMainSocketSendsBeforeTheExtras() throws {
        let console = try FakePunchConsole()
        defer { console.stop() }
        let order = Locked<[String]>([])
        let socket = OrderedSocket(try loopbackSocket(), name: "main", order: order)
        let signaling = FakeSignaling(consoleOffer: console.announced)
        signaling.onClientOffer.with { $0 = { console.start(clientOffer: $0) } }
        var options = Self.options(extras: 3)
        options.makeExtraSocket = { OrderedSocket(try loopbackSocket(), name: "extra", order: order) }
        let hole = try HolePunch.run(
            socket: socket, identity: Self.identity, client: try Self.candidates(for: socket, random: true), peerSid: 0,
            signaling: signaling, options: options)
        hole.socket.close()
        let sends = order.with { $0 }
        let firstExtra = try #require(sends.firstIndex(of: "extra"))
        let firstMain = try #require(sends.firstIndex(of: "main"))
        #expect(firstMain < firstExtra)
    }

    /// The console ignores the main socket's port, so only an extra socket's request is answered and it wins.
    @Test func anExtraSocketCanWin() throws {
        let made = Locked<[LoopbackGuardedPunchSocket]>([])
        var options = Self.options(extras: 3, made: made)
        options.resends = 20
        try punch(random: true, configure: { console, socket in console.ignoreClientPort = socket.localPort },
                  options: options) { console, _, socket, result in
            let hole = try result.get()
            #expect(hole.socket !== socket)
            let winner = try #require(made.with { $0 }.first { $0 === hole.socket })
            #expect(winner.ttls.with { $0 } == [2, 64])
            #expect(winner.localPort != socket.localPort)
            #expect(throws: (any Error).self) { try socket.send([1], to: "127.0.0.1", port: 1) }
            console.freeze()
            try hole.socket.send([8], to: "", port: 0)
            #expect(try console.main.receive(timeout: 1)?.bytes == [8])
            hole.socket.close()
        }
    }

    /// Item 6: running out of descriptors (EMFILE) stops the extras, it doesn't abort the hole.
    @Test func makingExtraSocketsMayFail() throws {
        let made = Locked<[LoopbackGuardedPunchSocket]>([])
        let attempts = Locked(0)
        var options = Self.options(extras: 6)
        options.makeExtraSocket = {
            let n = attempts.with { $0 += 1; return $0 }
            if n > 2 { throw FailureKind.other(errno: EMFILE) }
            let socket = try loopbackSocket()
            made.with { $0.append(socket) }
            return socket
        }
        try punch(random: true, options: options) { console, _, socket, result in
            let hole = try result.get()
            // Two extras were made; it stopped at the first failure; the hole opened with what it had.
            #expect(attempts.with { $0 } == 3 && made.with { $0.count } == 2)
            console.freeze()
            try hole.socket.send([3], to: "", port: 0)
            #expect(try console.main.receive(timeout: 1)?.bytes == [3])
            for other in [socket] + made.with({ $0 }) where other !== hole.socket {
                #expect(throws: (any Error).self) { try other.send([1], to: "127.0.0.1", port: 1) }  // closed
            }
            hole.socket.close()
        }
        // The factory failing at once leaves the main socket to do the work.
        var none = Self.options(extras: 5)
        none.makeExtraSocket = { throw FailureKind.other(errno: EMFILE) }
        try punch(random: true, options: none) { _, _, _, result in
            try result.get().socket.close()
        }
    }

    /// Item 13: cancelling after the hole is selected stops the sequence before the ACCEPT's answer is used.
    @Test func cancellingAfterSelection() throws {
        let cancelled = Locked(false)
        var options = Self.options()
        options.isCancelled = { cancelled.with { $0 } }
        let console = try FakePunchConsole()
        defer { console.stop() }
        let socket = try loopbackSocket()
        let signaling = FakeSignaling(consoleOffer: console.announced)
        signaling.onClientOffer.with { $0 = { console.start(clientOffer: $0) } }
        signaling.onAccept = { cancelled.with { $0 = true } }  // set once the ACCEPT is out, i.e. after selection
        #expect(throws: PunchError.cancelled) {
            try HolePunch.run(socket: socket, identity: Self.identity, client: try Self.candidates(for: socket),
                              peerSid: 0, signaling: signaling, options: options)
        }
        #expect(signaling.accepts.with { $0.count } == 1)
        #expect(throws: (any Error).self) { try socket.send([1], to: "127.0.0.1", port: 1) }  // closed on failure
        // Cancelled before the first answer period ends: also .cancelled, not consoleDidNotProbe.
        let early = Locked(false)
        var options2 = Self.options()
        options2.isCancelled = { early.with { $0 } }
        let silent = try FakePunchConsole()
        defer { silent.stop() }
        silent.probes = false
        let socket2 = try loopbackSocket()
        let signaling2 = FakeSignaling(consoleOffer: silent.announced)
        signaling2.onClientOffer.with { $0 = { silent.start(clientOffer: $0) } }
        // The console answers our request, so the client selects it; then the flag flips during the quiet time.
        Thread {
            _ = eventually { silent.clientRequests.with { !$0.isEmpty } }
            early.with { $0 = true }
        }.start()
        #expect(throws: PunchError.cancelled) {
            try HolePunch.run(socket: socket2, identity: Self.identity, client: try Self.candidates(for: socket2),
                              peerSid: 0, signaling: signaling2, options: options2)
        }
    }

    /// holepunch.md section 5.4 step 3: each console request from a derived candidate is answered, and our own
    /// request goes back to it every time (not once).
    @Test func everyRequestFromADerivedCandidateGetsOurRequestBack() throws {
        let console = try FakePunchConsole()
        defer { console.stop() }
        console.answers = false
        console.probes = false
        let socket = try loopbackSocket()
        let signaling = FakeSignaling(consoleOffer: console.announced)
        let stray = try loopbackSocket()
        let outcome = Locked<Result<PunchedHole, any Error>?>(nil)
        var options = Self.options()
        options.resends = 2
        let finalOptions = options
        let client = try Self.candidates(for: socket)
        Thread {
            outcome.with { $0 = Result { try HolePunch.run(socket: socket, identity: Self.identity, client: client,
                                                            peerSid: 0, signaling: signaling, options: finalOptions) } }
        }.start()
        #expect(eventually { signaling.offers.with { !$0.isEmpty } })
        let request = ProbePacket.request(senderHashedID: FakePunchConsole.hashedID, receiverHashedID: Self.identity.hashedID,
                                          senderSid: 0xabcd, receiverSid: 0x1234, requestID: hex("0102030405"))
        for _ in 0..<3 {
            try stray.send(request, to: "127.0.0.1", port: socket.localPort)
            sleepSeconds(0.01)
        }
        var responses = 0
        var requests = 0
        while let packet = try stray.receive(timeout: 0.4) {
            switch ProbePacket.parse(packet.bytes)?.kind {
            case .response?: responses += 1
            case .request?: requests += 1
            case nil: break
            }
        }
        #expect(responses == 3)
        #expect(requests >= 3)  // one per console request, plus the derived candidate's share of each resend
        #expect(eventually(5) { outcome.with { $0 != nil } })
    }

    @Test func nobodyAnswering() throws {
        try punch(configure: { c, _ in c.answers = false; c.probes = false }) { _, _, socket, result in
            #expect(throws: PunchError.hostUnreachable) { try result.get() }
            // The socket was closed on failure.
            #expect(throws: (any Error).self) { try socket.send([1], to: "127.0.0.1", port: 1) }
        }
    }

    @Test func aConsoleThatNeverProbes() throws {
        try punch(configure: { c, _ in c.probes = false }) { _, signaling, _, result in
            #expect(throws: PunchError.consoleDidNotProbe) { try result.get() }
            #expect(signaling.accepts.with { $0.isEmpty })
        }
    }

    @Test func unusableOffers() throws {
        let socket = try loopbackSocket()
        let client = try Self.candidates(for: socket)
        let badID = FakeSignaling(consoleOffer: PunchOffer(
            sid: 1, peerSid: 0, hashedID: [1, 2, 3], candidates: [PunchCandidate(type: .local, address: "127.0.0.1", port: 9)]))
        #expect(throws: PunchError.invalidOffer) {
            try HolePunch.run(socket: socket, identity: Self.identity, client: client, peerSid: 0, signaling: badID)
        }
        let none = FakeSignaling(consoleOffer: PunchOffer(sid: 1, peerSid: 0, hashedID: FakePunchConsole.hashedID, candidates: []))
        #expect(throws: PunchError.invalidOffer) {
            try HolePunch.run(socket: try loopbackSocket(), identity: Self.identity, client: client, peerSid: 0, signaling: none)
        }
    }

    @Test func signalingFailuresPropagateAndCloseTheSocket() throws {
        try punch(signalingFailure: .signalingFailed("timeout")) { _, _, socket, result in
            #expect(throws: PunchError.signalingFailed("timeout")) { try result.get() }
            #expect(throws: (any Error).self) { try socket.send([1], to: "127.0.0.1", port: 1) }
        }
        let console = try FakePunchConsole()
        defer { console.stop() }
        let signaling = FakeSignaling(consoleOffer: console.announced)
        signaling.failAccept = .signalingFailed("no ACCEPT")
        signaling.onClientOffer.with { $0 = { console.start(clientOffer: $0) } }
        let socket = try loopbackSocket()
        #expect(throws: PunchError.signalingFailed("no ACCEPT")) {
            try HolePunch.run(socket: socket, identity: Self.identity, client: try Self.candidates(for: socket), peerSid: 0,
                              signaling: signaling, options: Self.options())
        }
    }

    @Test func cancelling() throws {
        var options = Self.options()
        options.resends = 1000
        let start = monotonicSeconds()
        options.isCancelled = { monotonicSeconds() - start > 0.15 }
        try punch(configure: { c, _ in c.answers = false; c.probes = false }, options: options) { _, _, _, result in
            #expect(throws: PunchError.cancelled) { try result.get() }
            #expect(monotonicSeconds() - start < 3)
        }
    }

    /// Only three derived candidates are kept; other datagrams are ignored.
    @Test func derivedCandidatesAreCapped() throws {
        let console = try FakePunchConsole()
        defer { console.stop() }
        console.answers = false
        console.probes = false
        let socket = try loopbackSocket()
        let signaling = FakeSignaling(consoleOffer: console.announced)
        let strays = try (0..<5).map { _ in try loopbackSocket() }
        let noise = try loopbackSocket()
        let outcome = Locked<Result<PunchedHole, any Error>?>(nil)
        var options = Self.options()
        options.resends = 8
        let finalOptions = options
        let client = try Self.candidates(for: socket)
        Thread {
            outcome.with { $0 = Result { try HolePunch.run(socket: socket, identity: Self.identity, client: client,
                                                            peerSid: 0, signaling: signaling, options: finalOptions) } }
        }.start()
        #expect(eventually { signaling.offers.with { !$0.isEmpty } })
        let request = ProbePacket.request(senderHashedID: FakePunchConsole.hashedID, receiverHashedID: Self.identity.hashedID,
                                          senderSid: 0xabcd, receiverSid: 0x1234, requestID: hex("0102030405"))
        for stray in strays { try stray.send(request, to: "127.0.0.1", port: socket.localPort) }
        try noise.send(Array(repeating: 7, count: 100), to: "127.0.0.1", port: socket.localPort)
        try noise.send(Array(repeating: 6, count: 88), to: "127.0.0.1", port: socket.localPort)
        var answered = 0
        for stray in strays {
            while let packet = try stray.receive(timeout: 0.3) {
                if ProbePacket.parse(packet.bytes)?.kind == .response { answered += 1; break }
            }
        }
        #expect(answered == 3)
        #expect(eventually(5) { outcome.with { $0 != nil } })
        if case .failure(let error)? = outcome.with({ $0 }) { #expect(error as? PunchError == .hostUnreachable) } else { Issue.record("should fail") }
    }

    // MARK: Forged probes (an attacker who can reach the punched port)

    /// Probes with one identity field wrong each, as requests and (with our request id) as responses.
    private static func forgeries() -> [(name: String, request: [UInt8], response: [UInt8])] {
        let good = (sender: FakePunchConsole.hashedID, receiver: identity.hashedID, senderSid: FakePunchConsole.sid,
                    receiverSid: identity.sid)
        let other = hex("ffffffffffffffffffffffffffffffffffffffff")
        let variants: [(String, [UInt8], [UInt8], UInt16, UInt16)] = [
            ("wrong sender hashed id", other, good.receiver, good.senderSid, good.receiverSid),
            ("wrong sender sid", good.sender, good.receiver, 0x9999, good.receiverSid),
            ("wrong receiver hashed id", good.sender, other, good.senderSid, good.receiverSid),
            ("wrong receiver sid", good.sender, good.receiver, good.senderSid, 0x7777),
        ]
        return variants.map { name, sender, receiver, senderSid, receiverSid in
            (name,
             ProbePacket.request(senderHashedID: sender, receiverHashedID: receiver, senderSid: senderSid,
                                 receiverSid: receiverSid, requestID: hex("0102030405")),
             ProbePacket.response(senderHashedID: sender, receiverHashedID: receiver, senderSid: senderSid,
                                  receiverSid: receiverSid, requestID: hex("5152535455"),
                                  source: ("127.0.0.1", 1))!)
        }
    }

    /// Forged probes neither create candidates, nor get answered or answered with a request of ours, nor select a pair,
    /// and the first drop is logged once without ids.
    @Test func forgedProbesAreDroppedAndLoggedOnce() throws {
        let console = try FakePunchConsole()
        defer { console.stop() }
        console.answers = false
        console.probes = false
        let socket = try loopbackSocket()
        let signaling = FakeSignaling(consoleOffer: console.announced)
        let forger = try loopbackSocket()
        let lines = Locked<[String]>([])
        var options = Self.options()
        options.resends = 3
        options.log = { line in lines.with { $0.append(line) } }
        let finalOptions = options
        let client = try Self.candidates(for: socket)
        let outcome = Locked<Result<PunchedHole, any Error>?>(nil)
        Thread {
            outcome.with { $0 = Result { try HolePunch.run(socket: socket, identity: Self.identity, client: client,
                                                            peerSid: 0, signaling: signaling, options: finalOptions) } }
        }.start()
        #expect(eventually { signaling.offers.with { !$0.isEmpty } })
        for forged in Self.forgeries() {
            try forger.send(forged.request, to: "127.0.0.1", port: socket.localPort)
            try forger.send(forged.response, to: "127.0.0.1", port: socket.localPort)
        }
        var heard: [ProbePacket.Kind] = []
        while let packet = try forger.receive(timeout: 0.3) {
            if let probe = ProbePacket.parse(packet.bytes) { heard.append(probe.kind) }
        }
        #expect(heard.isEmpty, "no answer and no request of ours goes to a forger")
        #expect(eventually(5) { outcome.with { $0 != nil } })
        if case .failure(let error)? = outcome.with({ $0 }) { #expect(error as? PunchError == .hostUnreachable) } else {
            Issue.record("a forged response must not select a pair")
        }
        let logged = lines.with { $0 }
        #expect(logged.count == 1)
        #expect(logged.first?.contains("identity mismatch") == true)
        #expect(logged.first?.contains("sender hashed id") == true)
        #expect(logged.first?.contains("ffffffff") == false)
    }

    /// `logOnly`: the first hardware round's tool. A probe with another identity is accepted as before the check existed
    /// (answered, a derived candidate), and the first one of the hole is logged, once.
    @Test func logOnlyAcceptsMismatchedProbesAndSaysSo() throws {
        let console = try FakePunchConsole()
        defer { console.stop() }
        console.answers = false
        console.probes = false
        let socket = try loopbackSocket()
        let signaling = FakeSignaling(consoleOffer: console.announced)
        let stray = try loopbackSocket()
        let lines = Locked<[String]>([])
        var options = Self.options()
        options.resends = 3
        options.probeIdentity = .logOnly
        options.log = { line in lines.with { $0.append(line) } }
        let finalOptions = options
        let client = try Self.candidates(for: socket)
        let outcome = Locked<Result<PunchedHole, any Error>?>(nil)
        Thread {
            outcome.with { $0 = Result { try HolePunch.run(socket: socket, identity: Self.identity, client: client,
                                                            peerSid: 0, signaling: signaling, options: finalOptions) } }
        }.start()
        #expect(eventually { signaling.offers.with { !$0.isEmpty } })
        for forged in Self.forgeries() { try stray.send(forged.request, to: "127.0.0.1", port: socket.localPort) }
        var responses = 0
        while let packet = try stray.receive(timeout: 0.3) {
            if ProbePacket.parse(packet.bytes)?.kind == .response { responses += 1 }
        }
        #expect(responses == 4, "every mismatched request was answered")
        #expect(eventually(5) { outcome.with { $0 != nil } })
        let logged = lines.with { $0 }
        #expect(logged.count == 1 && logged[0].contains("identity mismatch") && logged[0].contains("accepted"))
    }

    /// holepunch.md section 5.5 step 2 needs a request from the console after selection. One with another identity
    /// from the selected peer is not the console's: the hole fails as `consoleDidNotProbe` (without the check in
    /// `answerUntilQuiet` it would count).
    @Test func aMismatchedRequestFromTheSelectedPeerIsNotTheConsolesProbe() throws {
        let console = try FakePunchConsole()
        defer { console.stop() }
        console.probes = false
        let socket = try loopbackSocket()
        let signaling = FakeSignaling(consoleOffer: console.announced)
        let forged = ProbePacket.request(
            senderHashedID: FakePunchConsole.hashedID, receiverHashedID: hex("ffffffffffffffffffffffffffffffffffffffff"),
            senderSid: FakePunchConsole.sid, receiverSid: Self.identity.sid, requestID: hex("0102030405"))
        let stop = Locked(false)
        signaling.onClientOffer.with { $0 = { offer in
            console.start(clientOffer: offer)
            // From the console's own socket (the selected peer), for the whole window after selection.
            Thread {
                // Bounded, so that a punch that counted these (the check removed) ends instead of waiting for quiet.
                let end = monotonicSeconds() + 1
                while !stop.with({ $0 }) && monotonicSeconds() < end {
                    try? console.main.send(forged, to: "127.0.0.1", port: socket.localPort)
                    sleepSeconds(0.01)
                }
            }.start()
        } }
        let result = Result { try HolePunch.run(
            socket: socket, identity: Self.identity, client: try Self.candidates(for: socket), peerSid: 0,
            signaling: signaling, options: Self.options()) }
        stop.with { $0 = true }
        #expect(throws: PunchError.consoleDidNotProbe) { try result.get() }
    }

    /// A forger spraying forged responses (right request id, wrong identity) doesn't stop the console winning.
    @Test func aLegitimateConsoleStillPunchesThroughForgeries() throws {
        let forger = try loopbackSocket()
        let lines = Locked<[String]>([])
        var options = Self.options()
        options.log = { line in lines.with { $0.append(line) } }
        let finalOptions = options
        try punch(configure: { _, socket in
            let port = socket.localPort
            Thread {
                for _ in 0..<30 {
                    for forged in Self.forgeries() {
                        try? forger.send(forged.response, to: "127.0.0.1", port: port)
                        try? forger.send(forged.request, to: "127.0.0.1", port: port)
                    }
                    sleepSeconds(0.005)
                }
            }.start()
        }, options: finalOptions) { console, _, _, result in
            let hole = try result.get()
            #expect(hole.selected == PunchCandidate(type: .staticAddress, address: "127.0.0.1", port: console.main.localPort))
            #expect(lines.with { $0.count } <= 1)
            hole.socket.close()
        }
        forger.close()
    }

    @Test func nothingLeavesTheLoopback() throws {
        try punch { console, _, socket, result in
            let hole = try result.get()
            #expect(socket.destinations.with { Set($0) }.isSubset(of: ["127.0.0.1", ""]))
            #expect(console.main.destinations.with { Set($0) }.isSubset(of: ["127.0.0.1"]))
            hole.socket.close()
        }
    }
}

/// Records which socket sends, in order.
final class OrderedSocket: UDPPunchSocket, @unchecked Sendable {
    let inner: LoopbackGuardedPunchSocket
    let name: String
    let order: Locked<[String]>
    init(_ inner: LoopbackGuardedPunchSocket, name: String, order: Locked<[String]>) {
        self.inner = inner
        self.name = name
        self.order = order
    }
    var localPort: UInt16 { inner.localPort }
    func send(_ bytes: [UInt8], to host: String, port: UInt16) throws {
        order.with { $0.append(name) }
        try inner.send(bytes, to: host, port: port)
    }
    func receive(timeout: Double) throws -> UDPPacket? { try inner.receive(timeout: timeout) }
    func connect(host: String, port: UInt16) throws { try inner.connect(host: host, port: port) }
    func setTimeToLive(_ ttl: Int) throws { try inner.setTimeToLive(ttl) }
    func close() { inner.close() }
}
