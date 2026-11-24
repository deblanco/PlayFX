import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

/// The log a failed internet run prints: what STUN said, what was offered, what the probing saw and where it failed,
/// with addresses masked and nothing secret in it.
@Suite(.serialized) struct InternetDiagnosticsTests {
    // MARK: Masking

    @Test func addressesShowTheirKindAndFirstTwoOctetsOnly() {
        #expect(AddressMask.describe("203.0.113.5") == "public 203.0.x.x")
        #expect(AddressMask.describe("192.168.1.20") == "private 192.168.x.x")
        #expect(AddressMask.describe("10.1.2.3") == "private 10.1.x.x")
        #expect(AddressMask.describe("172.20.10.2") == "private 172.20.x.x")
        #expect(AddressMask.describe("172.32.0.1") == "public 172.32.x.x")
        #expect(AddressMask.describe("100.64.9.9") == "cgnat 100.64.x.x")
        #expect(AddressMask.describe("100.127.9.9") == "cgnat 100.127.x.x")
        #expect(AddressMask.describe("100.128.9.9") == "public 100.128.x.x")
        #expect(AddressMask.describe("127.0.0.1") == "loopback 127.0.x.x")
        #expect(AddressMask.describe("169.254.3.4") == "link-local 169.254.x.x")
        #expect(AddressMask.describe("0.0.0.0") == "unspecified 0.0.x.x")
        #expect(AddressMask.describe("239.1.1.1") == "reserved 239.1.x.x")
        #expect(AddressMask.describe("") == "none")
        #expect(AddressMask.describe("not an address") == "invalid")
        #expect(AddressMask.describe("198.51.100.7", port: 50123) == "public 198.51.x.x:50123")
        let shown = AddressMask.describe([
            PunchCandidate(type: .stun, address: "203.0.113.5", port: 40006),
            PunchCandidate(type: .staticAddress, address: "203.0.113.5", port: 50123),
            PunchCandidate(type: .local, address: "", port: 50123),
        ])
        #expect(shown == "STUN public 203.0.x.x port 40006; STATIC public 203.0.x.x port 50123; LOCAL none port 50123")
        #expect(!shown.contains("113"))
    }

    @Test func aLongRunOfGuessesIsShortened() {
        let guesses = PortGuess.guesses(around: 40000, count: 75).map { PunchCandidate(type: .stun, address: "203.0.113.5", port: $0) }
        let shown = AddressMask.describe(guesses)
        #expect(shown.hasPrefix("STUN public 203.0.x.x ports 40000,40001,39999,") && shown.hasSuffix(",... (75 ports)"))
    }

    // MARK: The prediction, in words

    static func answers(_ ports: [Int], address: String = "203.0.113.5") -> [StunAnswer] {
        ports.map { StunAnswer(address: address, port: UInt16($0)) }
    }

    @Test func thePredictionNamesItsCase() {
        func line(_ answers: [StunAnswer], local: UInt16) -> String {
            NATPrediction.explain(answers: answers, prediction: NATPrediction.predict(answers), localPort: local)
        }
        #expect(line([], local: 1).hasPrefix("no STUN answer"))
        #expect(line(Self.answers([50123, 50123, 50123, 50123]), local: 50123).contains("same port (the NAT keeps local port 50123)"))
        #expect(line(Self.answers([61000, 61000, 61000, 61000]), local: 50500)
            .contains("stable mapping, local port 50500 shows as 61000 to every server"))
        let increment = line(Self.answers([40000, 40002, 40004, 40006]), local: 50123)
        #expect(increment.contains("increment 2 (steps mod 65536 [2, 2, 2]), next port 40006"))
        let random = line(Self.answers([40000, 40007, 39990, 40100]), local: 50123)
        #expect(random.contains("4 answer(s), ports [40000, 40007, 39990, 40100], 1 public address(es)"))
        #expect(random.contains("random allocation (steps mod 65536 [7, 65519, 110] don't repeat), step 7"))
        #expect(line(Self.answers([40000]), local: 50123).contains("a single answer"))
        let mixed = [StunAnswer(address: "203.0.113.5", port: 40000), StunAnswer(address: "203.0.113.9", port: 40100)]
        #expect(line(mixed, local: 50123).contains("2 public address(es)") || line(mixed, local: 50123).contains("differs between servers"))
    }

    // MARK: STUN, one line per server

    @Test func eachStunServerIsLoggedWithItsAnswerOrWhyNot() throws {
        let server = try FakeSTUNServer()
        defer { server.stop() }
        let socket = try loopbackSocket()
        defer { socket.close() }
        let lines = Locked<[String]>([])
        let silent = try loopbackSocket()
        defer { silent.close() }
        var environment = StunEnvironment(resolve: { $0 == "gone.example" ? nil : "127.0.0.1" }, timeout: 0.2,
                                          log: { line in lines.with { $0.append(line) } })
        environment.isCancelled = { false }
        let servers = [
            StunServer(host: "gone.example", port: 3478), StunServer(host: "silent.example", port: silent.localPort),
            StunServer(host: "stun.example", port: server.socket.localPort),
        ]
        let answers = StunClient.collect(socket: socket, servers: servers, wanted: 4, environment: environment)
        #expect(answers.count == 1)
        let logged = lines.with { $0 }
        #expect(logged[0] == "STUN gone.example:3478: did not resolve")
        #expect(logged[1] == "STUN silent.example:\(silent.localPort): no answer in 0 s")
        #expect(logged[2] == "STUN stun.example:\(server.socket.localPort): mapped loopback 127.0.x.x:\(socket.localPort), "
            + "sent from local port \(socket.localPort)")
    }

    // MARK: Probing

    static func run(
        console: FakePunchConsole, random: Bool = false, extras: Int = 0, resends: Int = 2, probeWait: Double = 0.05,
        configure: (inout HolePunchOptions) -> Void = { _ in }, during: (LoopbackGuardedPunchSocket) throws -> Void = { _ in }
    ) throws -> (error: PunchError?, lines: [String], clientPort: UInt16) {
        let socket = try loopbackSocket()
        let signaling = FakeSignaling(consoleOffer: console.announced)
        signaling.onClientOffer.with { $0 = { console.start(clientOffer: $0) } }
        let lines = Locked<[String]>([])
        var options = HolePunchTests.options(extras: extras)
        options.resends = resends
        options.probeWait = probeWait
        options.log = { line in lines.with { $0.append(line) } }
        configure(&options)
        let finalOptions = options
        let client = try HolePunchTests.candidates(for: socket, random: random)
        let outcome = Locked<Result<PunchedHole, any Error>?>(nil)
        Thread {
            outcome.with { $0 = Result { try HolePunch.run(socket: socket, identity: HolePunchTests.identity, client: client,
                                                            peerSid: 0, signaling: signaling, options: finalOptions) } }
        }.start()
        #expect(eventually { signaling.offers.with { !$0.isEmpty } })
        try during(socket)
        #expect(eventually(15) { outcome.with { $0 != nil } })
        if case .failure(let error)? = outcome.with({ $0 }) { return (error as? PunchError, lines.with { $0 }, socket.localPort) }
        outcome.with { if case .success(let hole)? = $0 { hole.socket.close() } }
        return (nil, lines.with { $0 }, socket.localPort)
    }

    @Test func aSilentConsoleLeavesALogThatShowsWhereItFailed() throws {
        let console = try FakePunchConsole()
        defer { console.stop() }
        console.answers = false
        console.probes = false
        let (error, lines, clientPort) = try Self.run(console: console, random: true, extras: 3)
        #expect(error == .hostUnreachable)
        let text = lines.joined(separator: "\n")
        let port = console.main.localPort
        #expect(lines[0] == "console offered STATIC loopback 127.0.x.x port \(port); LOCAL loopback 127.0.x.x port \(port); "
            + "we offer STATIC loopback 127.0.x.x port \(clientPort); LOCAL loopback 127.0.x.x port \(clientPort)")
        let ended = try #require(lines.first { $0.hasPrefix("probing ended after ") })
        // 3 rounds of two candidates from the main socket, one STATIC candidate each from the 3 extra sockets.
        #expect(ended.contains("sent 6 from the main socket + 3 from 3 extra socket(s); received 0 datagram(s): 0 probe(s) "
            + "(0 request, 0 response, 0 response(s) with another request id), 0 not a probe, 0 identity mismatch(es); from no source"))
        #expect(lines.last == "failed while probing the console's candidates (up to 3 rounds of 0.05 s): hostUnreachable")
        #expect(!text.contains("127.0.0.1"))
    }

    @Test func whatComesBackIsCountedBySourceAndKind() throws {
        let console = try FakePunchConsole()
        defer { console.stop() }
        console.answers = false
        console.probes = false
        let stray = try loopbackSocket()
        defer { stray.close() }
        let forged = Self.forgedRequest()
        let good = ProbePacket.request(
            senderHashedID: FakePunchConsole.hashedID, receiverHashedID: HolePunchTests.identity.hashedID,
            senderSid: FakePunchConsole.sid, receiverSid: HolePunchTests.identity.sid, requestID: hex("0102030405"))
        let wrongID = ProbePacket.response(
            senderHashedID: FakePunchConsole.hashedID, receiverHashedID: HolePunchTests.identity.hashedID,
            senderSid: FakePunchConsole.sid, receiverSid: HolePunchTests.identity.sid, requestID: hex("0909090909"),
            source: ("127.0.0.1", 1))!
        let (error, lines, _) = try Self.run(console: console, resends: 6, probeWait: 0.1, during: { socket in
            for packet in [forged, forged, good, wrongID, [UInt8](repeating: 1, count: 30)] {
                try stray.send(packet, to: "127.0.0.1", port: socket.localPort)
            }
            sleepSeconds(0.2)
        })
        #expect(error == .hostUnreachable)
        let ended = try #require(lines.first { $0.hasPrefix("probing ended after ") })
        #expect(ended.contains("received 5 datagram(s): 4 probe(s) (3 request, 1 response, 1 response(s) with another request id), "
            + "1 not a probe, 2 identity mismatch(es); from loopback 127.0.x.x:\(stray.localPort) (3 req, 1 resp, 2 mismatch)"))
        // The first mismatch is named once, with the address masked and no ids.
        let mismatch = lines.filter { $0.contains("identity mismatch:") }
        #expect(mismatch.count == 1 && mismatch[0].hasPrefix("probe from loopback 127.0.x.x:\(stray.localPort) dropped, identity mismatch: "))
        #expect(!lines.joined().contains("127.0.0.1"))
    }

    static func forgedRequest() -> [UInt8] {
        ProbePacket.request(
            senderHashedID: hex("ffffffffffffffffffffffffffffffffffffffff"), receiverHashedID: HolePunchTests.identity.hashedID,
            senderSid: FakePunchConsole.sid, receiverSid: HolePunchTests.identity.sid, requestID: hex("0102030405"))
    }

    /// A send the system refuses (no route, a firewall) is counted and its first error shown: "no answer" isn't always
    /// the network's silence.
    @Test func sendErrorsAreCountedAndTheFirstIsShown() throws {
        let console = try FakePunchConsole()
        defer { console.stop() }
        console.answers = false
        console.probes = false
        let socket = try loopbackSocket()
        let signaling = FakeSignaling(consoleOffer: console.announced)
        let lines = Locked<[String]>([])
        var options = HolePunchTests.options()
        options.resends = 1
        options.log = { line in lines.with { $0.append(line) } }
        let failing = SendFailingSocket(socket)
        #expect(throws: PunchError.hostUnreachable) {
            try HolePunch.run(socket: failing, identity: HolePunchTests.identity,
                              client: try HolePunchTests.candidates(for: socket), peerSid: 0, signaling: signaling, options: options)
        }
        let ended = try #require(lines.with { $0 }.first { $0.hasPrefix("probing ended after ") })
        #expect(ended.contains("sent 4 from the main socket + 0 from 0 extra socket(s); received 0 datagram(s)"))
        #expect(ended.contains("; 4 send error(s), first: hostDown; from no source"))
    }

    @Test func aLongProbeLogsProgressEveryTwoSeconds() throws {
        let console = try FakePunchConsole()
        defer { console.stop() }
        console.answers = false
        console.probes = false
        let (error, lines, _) = try Self.run(console: console, resends: 6, probeWait: 0.5)
        #expect(error == .hostUnreachable)
        let progress = lines.filter { $0.hasPrefix("probing, round ") }
        #expect(progress.count == 1 && progress[0].hasPrefix("probing, round 4 of 7: sent "))
    }

    @Test func aSuccessfulPunchLogsTheSelectionAndAMissingProbeIsNamed() throws {
        let console = try FakePunchConsole()
        defer { console.stop() }
        console.probes = false  // answers, but never asks: the mutual check fails
        let (error, lines, _) = try Self.run(console: console, resends: 20)
        #expect(error == .consoleDidNotProbe)
        let selected = try #require(lines.first { $0.hasPrefix("probing selected loopback 127.0.x.x:\(console.main.localPort) (STATIC) after ") })
        #expect(selected.contains("1 response"))
        #expect(lines.contains { $0.hasPrefix("the console sent no probe of its own after the selection: ") })
        #expect(lines.last == "failed while answering the console's probes after the selection: consoleDidNotProbe")
    }

    @Test func aSignalingFailureNamesItsStage() throws {
        let console = try FakePunchConsole()
        defer { console.stop() }
        let socket = try loopbackSocket()
        let signaling = FakeSignaling(consoleOffer: console.announced)
        signaling.failure = .signalingFailed("no offer")
        let lines = Locked<[String]>([])
        var options = HolePunchTests.options()
        options.log = { line in lines.with { $0.append(line) } }
        #expect(throws: PunchError.signalingFailed("no offer")) {
            try HolePunch.run(socket: socket, identity: HolePunchTests.identity, client: try HolePunchTests.candidates(for: socket),
                              peerSid: 0, signaling: signaling, options: options)
        }
        #expect(lines.with { $0 } == ["failed while waiting for the console's OFFER: signalingFailed(\"no offer\")"])
    }
}

/// The whole log of a run that fails at the ctrl hole, through the rig (STUN, no router).
@Suite(.serialized) struct InternetRunLogTests {
    @Test func aFailedCtrlHoleLeavesALogOfEveryStep() async throws {
        let rig = try InternetRig()
        defer { rig.stop() }
        rig.mapper.failsMapping = true
        rig.console.ctrlEndpoint.answers = false
        rig.console.ctrlEndpoint.probes = false
        rig.environment.punch.resends = 2
        // Four servers whose answers differ by an irregular step: a carrier NAT.
        let stunPort = rig.stun.socket.localPort
        rig.environment.stunServers = { Array(repeating: StunServer(host: "127.0.0.1", port: stunPort), count: 4) }
        let error = await rig.startFailure()
        #expect(error == .holePunch(hole: .ctrl, .hostUnreachable))
        let lines = rig.logs.with { $0 }
        let text = lines.joined(separator: "\n")
        let port = rig.holeSockets.with { $0.first!.localPort }
        func has(_ prefix: String) -> Bool { lines.contains { $0.hasPrefix(prefix) } }
        #expect(has("stage linkingPSN"))
        #expect(has("UPnP: gateway found"))
        #expect(lines.filter { $0.hasPrefix("ctrl hole: STUN 127.0.0.1:\(stunPort): mapped loopback 127.0.x.x:\(port), sent from local port \(port)") }.count == 4)
        #expect(has("ctrl hole: prediction from 4 answer(s), ports [\(port), \(port), \(port), \(port)], 1 public address(es): same port"))
        #expect(has("ctrl hole: local port \(port), offering STATIC loopback 127.0.x.x port \(port); LOCAL loopback 127.0.x.x port \(port); no STUN candidates"))
        #expect(has("console offered STATIC loopback") || has("ctrl hole: console offered STATIC loopback"))
        #expect(lines.contains { $0.hasPrefix("ctrl hole: probing ended after ") && $0.contains("received 0 datagram(s)") })
        #expect(lines.last { $0.contains("failed while") }?.hasPrefix("ctrl hole: failed while probing the console's candidates") == true)
        // Nothing secret, and no raw address.
        for secret in [PSNVector.token, PSNVector.duid, Data(PSNVector.localHashedID).base64EncodedString(),
                       Data(InternetConsole.ctrlHashedID).base64EncodedString(), hexString(InternetConsole.ctrlHashedID),
                       hexString(PSNVector.data1), hexString(PSNVector.customData1), "43981", PSNVector.customData1Text] {
            #expect(!text.contains(secret), "\(secret)")
        }
        #expect(!text.contains("127.0.0.1:") || text.contains("STUN 127.0.0.1:"), "only the STUN server name may show an address")
        #expect(!text.replacingOccurrences(of: "STUN 127.0.0.1:", with: "").contains("127.0.0.1"))
    }

    static func printSample(_ lines: [String]) { for line in lines { print("LOG: \(line)") } }
}

private func hexString(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

/// Every send fails: the system says the host is down.
final class SendFailingSocket: UDPPunchSocket, @unchecked Sendable {
    let inner: any UDPPunchSocket
    init(_ inner: any UDPPunchSocket) { self.inner = inner }
    var localPort: UInt16 { inner.localPort }
    func send(_ bytes: [UInt8], to host: String, port: UInt16) throws { throw FailureKind.hostDown }
    func receive(timeout: Double) throws -> UDPPacket? { try inner.receive(timeout: timeout) }
    func connect(host: String, port: UInt16) throws { try inner.connect(host: host, port: port) }
    func setTimeToLive(_ ttl: Int) throws { try inner.setTimeToLive(ttl) }
    func close() { inner.close() }
}

/// The RUDP trace's lines (`PLAYFX_RUDP_TRACE`): what each datagram shows, and never more than 24 bytes of data.
@Suite struct RUDPTraceTests {
    @Test func theSpecsDatagramsAreDescribedMessageByMessage() {
        // R1: INIT.
        #expect(RUDPTrace.describe(hex("c016 244f244f 8030 1234 0b0101000100 89abcdef 0582"))
            == "22 bytes, 1 message(s): INIT seq=0x1234 data 14 bytes: 12340b010100010089abcdef0582")
        // R4: ACK with its ack field.
        #expect(RUDPTrace.describe(hex("c00e 244f244f 2430 1237 567a 0092"))
            == "14 bytes, 1 message(s): ACK seq=0x1237 ack=0x567a data 6 bytes: 1237567a0092")
        // R7: a console datagram of two messages (an ACK, then a ctrl heartbeat request).
        let r7 = RUDPTrace.describe(hex("c00e244f244f2430 567812390092 c012244f244f0230 56790000000000fe0000"))
        #expect(r7 == "32 bytes, 2 message(s): ACK seq=0x5678 ack=0x1239 data 6 bytes: 567812390092 | "
            + "DATA seq=0x5679 data 10 bytes: 56790000000000fe0000")
        // The console's variants and FINISH, and a type nobody knows (with its ack field read).
        #expect(RUDPTrace.describe(hex("c00c 244f244f 1230 5678 1234")).contains("DATA/12 seq=0x5678 ack=0x1234"))
        #expect(RUDPTrace.describe(hex("c008 244f244f c000")) == "8 bytes, 1 message(s): FINISH data 0 bytes")
        #expect(RUDPTrace.describe(hex("c00c 244f244f 7730 5678 1234")).contains("unknown 0x7730 seq=0x5678 ack=0x1234"))
        // Not RUDP at all (a late hole-punch probe).
        #expect(RUDPTrace.describe([UInt8](repeating: 7, count: 88)) == "88 bytes, not RUDP: 0707070707070707")
    }

    @Test func dataIsCutAt24BytesAndMarked() {
        let long = RUDPFraming.dataMessage(seq: 0x1236, payload: Array("GET /sie/ps5/rp/sess/init HTTP/1.1\r\nHost: x".utf8))
        let line = RUDPTrace.describe(long)
        // seq (2 bytes) and the first 22 characters of the request: no header after the request line's start.
        #expect(line.hasSuffix("data 45 bytes: 1236474554202f7369652f7073352f72702f736573732f696e697420...") || line.contains("..."))
        let hexPart = line.components(separatedBy: ": ").last!.replacingOccurrences(of: "...", with: "")
        #expect(hexPart.count == 48)
    }

    @Test func countersAreCounted() throws {
        let (a, b) = try loopbackPair()
        defer { b.close() }
        let lines = Locked<[String]>([])
        let client = RUDPConnection(socket: a, timings: RUDPConnectionTests.timings, initialSeq: 0x1234, tag: 1,
                                    trace: { line in lines.with { $0.append(line) } })
        defer { client.close() }
        try client.sendCtrlFrame(hex("00000000 01fe 0000"))
        try client.startCtrl { _ in }
        try b.send(hex("c00c 244f244f 7730 5678 1234"), to: "", port: 0)
        #expect(eventually { client.statistics.unknownTypes == 1 })
        let stats = client.statistics
        #expect(stats.datagramsOut >= 1 && stats.datagramsIn == 1)
        #expect(lines.with { $0 }.contains { $0.contains("rudp out: ") && $0.contains("DATA seq=0x1234") })
        #expect(lines.with { $0 }.contains { $0.contains("rudp in: ") && $0.contains("unknown 0x7730") })
        #expect(InternetLink.describe(stats).hasPrefix("rudp stats: "))
    }

    /// The frame check's drops are always logged with their data, so the layouts nobody has documented get captured.
    @Test func droppedMessagesAreLoggedWithTheirData() throws {
        let (a, b) = try loopbackPair()
        defer { b.close() }
        let always = Locked<[String]>([])
        let client = RUDPConnection(socket: a, timings: RUDPConnectionTests.timings, initialSeq: 0x1234, tag: 1,
                                    log: { line in always.with { $0.append(line) } })
        defer { client.close() }
        try client.startCtrl { _ in }
        // A 0x20 message with 4 data bytes (seq, then two more), twice, and a 0x36 with 20.
        let tiny = hex("c00c 244f244f 2030 6dea 1234")
        try b.send(tiny, to: "", port: 0)
        try b.send(tiny, to: "", port: 0)
        try b.send(hex("c01c 244f244f 3630 6de8 0001 0102030405060708090a0b0c0d0e0f10"), to: "", port: 0)
        #expect(eventually { client.statistics.malformed >= 2 })
        let lines = always.with { $0 }
        #expect(lines.contains("rudp: message 0x20 seq=0x6dea dropped by the frame check (data 4 bytes, frame offset 4): 6dea1234"))
        #expect(lines.contains("rudp: message 0x36 seq=0x6de8 dropped by the frame check (data 20 bytes, frame offset 2): "
            + "6de800010102030405060708090a0b0c0d0e0f10"))
        // The duplicate of the 0x20 message is acknowledged, not counted as another drop.
        #expect(client.statistics.duplicates == 1)
    }

    @Test func retransmissionsAreNamedAndTheCreditIsTraced() throws {
        let (a, b) = try loopbackPair()
        defer { b.close() }
        let lines = Locked<[String]>([])
        var timings = RUDPConnectionTests.timings
        timings.retransmitAfter = 0.05
        timings.retransmitCheck = 0.02
        let client = RUDPConnection(socket: a, timings: timings, initialSeq: 0x1234, tag: 1,
                                    trace: { line in lines.with { $0.append(line) } })
        defer { client.close() }
        try client.startCtrl { _ in }
        try client.sendCtrlFrame(hex("00000000 01fe 0000"))
        #expect(eventually { client.statistics.retransmissionsByKind["ctrl frame 0x01fe", default: 0] >= 2 })
        try b.send(hex("c00e 244f244f 2430 5678 1235 0092"), to: "", port: 0)
        #expect(eventually { lines.with { $0 }.contains { $0.contains("rudp: ack 0x1235 credits ctrl frame 0x01fe (key 0x1235, ") } })
        let trace = lines.with { $0 }
        #expect(trace.contains { $0.contains("rudp: retransmitting ctrl frame 0x01fe (key 0x1235), attempt 1, ") })
        #expect(trace.allSatisfy { $0.hasPrefix("[+") })
        #expect(InternetLink.describe(client.statistics).contains("; retransmitted: ctrl frame 0x01fe x"))
    }
}
