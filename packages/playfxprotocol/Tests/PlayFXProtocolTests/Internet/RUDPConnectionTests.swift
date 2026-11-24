import Dispatch
import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

/// The console end of an RUDP link on loopback: answers the handshake and one HTTP exchange, acknowledges ctrl data
/// and answers the switch message. Tests make it misbehave through the flags.
final class FakeRUDPConsole: @unchecked Sendable {
    static let cookie = hex("c0c1c2c3c4c5c6c7c8c9cacbcccdcecf")
    let socket: any UDPPunchSocket
    /// Every datagram the client sent.
    let datagrams = Locked<[[UInt8]]>([])
    /// The payloads (after `seq`) of the bare DATA messages the client sent: ctrl frames and the switch message.
    let frames = Locked<[[UInt8]]>([])
    /// Messages to ignore, by kind: "init", "cookie", "request", "finish".
    let skip = Locked<[String: Int]>([:])
    var response = Array("HTTP/1.1 200 OK\r\nRP-Nonce: AAAA\r\n\r\n".utf8)
    var cookieAckSeq: UInt16 = 0x5678
    /// Sends FINISH after the client's ACK of an exchange (registration and session init); off for ctrl.
    var finishAfterAck = false
    var acknowledgesData = true
    var answersSwitch = true
    /// The next client `seq` the console expects, for cumulative ACKs (nil: acknowledge what arrived).
    let expectedClientSeq = Locked<UInt16?>(nil)
    private let arrived = Locked(Set<UInt16>())
    private let consoleSeq = Locked<UInt16>(0)
    private let stopped = Locked(false)
    private let ended = DispatchSemaphore(value: 0)

    init(socket: any UDPPunchSocket) { self.socket = socket }

    func start() {
        Thread { [self] in
            while !stopped.with({ $0 }) {
                guard let packet = try? socket.receive(timeout: 0.02) else { continue }
                datagrams.with { $0.append(packet.bytes) }
                react(RUDPFraming.parse(packet.bytes))
            }
            ended.signal()
        }.start()
    }

    func stop() {
        stopped.with { $0 = true }
        _ = ended.wait(timeout: .now() + 2)
        socket.close()
    }

    private func take(_ kind: String) -> Bool {
        skip.with { counts in
            guard let n = counts[kind], n > 0 else { return false }
            counts[kind] = n - 1
            return true
        }
    }

    func push(_ bytes: [UInt8]) { try? socket.send(bytes, to: "", port: 0) }

    /// A console DATA message carrying `frame` under `seq`, as flags-`type` message with the given layout bytes.
    static func message(type: UInt16 = RUDPType.data, seq: UInt16, middle: [UInt8] = [], frame: [UInt8]) -> [UInt8] {
        RUDPFraming.encode(type: type, data: RUDPFraming.be16(seq) + middle + frame)
    }

    func nextSeq() -> UInt16 { consoleSeq.with { seq in defer { seq &+= 1 }; return seq } }

    /// Notes a client `seq` and returns the cumulative ack: the next value in order that hasn't arrived.
    private func cumulativeAck(after seq: UInt16) -> UInt16 {
        guard expectedClientSeq.with({ $0 }) != nil else { return seq &+ 1 }
        _ = arrived.with { $0.insert(seq) }
        return expectedClientSeq.with { expected in
            while arrived.with({ $0.remove(expected!) != nil }) { expected = expected! &+ 1 }
            return expected!
        }
    }

    private func react(_ messages: [RUDPMessage]) {
        guard let first = messages.first else { return }
        if [0x80, 0x90, 0x20].contains(first.flags), let seq = first.peerSeq { _ = cumulativeAck(after: seq) }
        switch first.flags {
        case 0x80:
            if !take("init") { push(RUDPFraming.encode(type: RUDPType.initiateAck, data: [UInt8](repeating: 0, count: 8) + Self.cookie)) }
        case 0x90:
            if !take("cookie"), Array(first.data.dropFirst(14)) == Self.cookie {
                consoleSeq.with { $0 = cookieAckSeq &+ 1 }
                push(RUDPFraming.encode(type: RUDPType.cookieAck, data: RUDPFraming.be16(cookieAckSeq)))
            }
        case 0x20:
            if !take("request") {
                push(RUDPFraming.dataMessage(seq: nextSeq(), payload: response))
            }
        case 0x24:
            if finishAfterAck && !take("finish") { push(RUDPFraming.encode(type: RUDPType.finish, data: [])) }
        case 0x02:
            guard let seq = first.peerSeq else { return }
            let payload = Array(first.data.dropFirst(2))
            frames.with { $0.append(payload) }
            if acknowledgesData { push(RUDPFraming.ackMessage(seq: consoleSeq.with { $0 }, ack: cumulativeAck(after: seq))) }
            if answersSwitch && payload.starts(with: hex("00000010 000d")) {
                push(Self.message(seq: nextSeq(), frame: hex("00000000 0034 0000")))
            }
        default: break
        }
    }
}

final class RUDPEventLog: @unchecked Sendable {
    private let events = Locked<[RUDPEvent]>([])
    var all: [RUDPEvent] { events.with { $0 } }
    var frames: [[UInt8]] { all.compactMap { if case .ctrlFrame(let f) = $0 { f } else { nil } } }
    func append(_ event: RUDPEvent) { events.with { $0.append(event) } }
    var handler: @Sendable (RUDPEvent) -> Void { { [self] in append($0) } }
}

@Suite(.serialized) struct RUDPConnectionTests {
    static var timings: RUDPTimings {
        var t = RUDPTimings()
        t.stepWait = 0.15
        t.retransmitAfter = 0.05
        t.retransmitCheck = 0.02
        t.switchWait = 0.3
        t.receiveFailureLimit = 0.2
        return t
    }

    static let heartbeat = hex("00000000 01fe 0000")

    /// A client connection and its fake console on a loopback pair; `wrap` can make the client's side lossy.
    func link(wrap: (LoopbackGuardedPunchSocket) -> any UDPPunchSocket = { $0 }, initialSeq: UInt16 = 0x1234,
              timings: RUDPTimings = RUDPConnectionTests.timings)
        throws -> (client: RUDPConnection, console: FakeRUDPConsole) {
        let (a, b) = try loopbackPair()
        let console = FakeRUDPConsole(socket: b)
        console.expectedClientSeq.with { $0 = initialSeq }
        console.start()
        return (RUDPConnection(socket: wrap(a), timings: timings, initialSeq: initialSeq, tag: 0x89ab_cdef,
                               random: { _ in hex("404142434445464748494a4b4c4d4e4f") }), console)
    }

    /// Everything in R1 to R6, in the order a session sends it.
    @Test func vectorsEndToEnd() throws {
        let (client, console) = try link()
        defer { client.close(); console.stop() }
        console.finishAfterAck = true
        let response = try client.exchange(request: RUDPFramingTests.sessionInit, expectFinish: true)
        #expect(response == console.response)

        let sent = console.datagrams.with { $0 }
        #expect(sent.count == 4)
        #expect(sent[0] == hex("c016 244f244f 8030 1234 0b0101000100 89abcdef 0582"))
        #expect(sent[1] == hex("c026 244f244f 9030 1235 0b0101000100 89abcdef 0582 c0c1c2c3c4c5c6c7c8c9cacbcccdcecf"))
        #expect(sent[2] == RUDPFraming.requestDatagram(seq: 0x1236, ack: 0x5679, request: RUDPFramingTests.sessionInit))
        #expect(sent[3] == hex("c00e 244f244f 2430 1237 567a 0092"))  // R4

        let log = RUDPEventLog()
        try client.startCtrl(handler: log.handler)
        try client.sendCtrlFrame(Self.heartbeat)
        try client.sendSwitch()
        #expect(eventually { console.datagrams.with { $0.count } >= 6 })
        let ctrl = console.datagrams.with { $0 }
        #expect(ctrl[4] == hex("c012 244f244f 0230 1237 0000000001fe0000"))  // R5
        #expect(ctrl[5] == hex("c022 244f244f 0230 1238 00000010000d0000 404142434445464748494a4b4c4d4e4f"))  // R6
        // The console answers the switch with ctrl 0x0034, which is delivered like any frame.
        #expect(client.waitForSwitchAcknowledgement(timeout: 2))
        #expect(log.frames == [hex("00000000 0034 0000")])
    }

    /// R7: the console's two-message datagram releases the kept messages and gets a heartbeat ACK.
    @Test func r7ConsoleDatagram() throws {
        let (a, b) = try loopbackPair()
        defer { b.close() }
        let client = RUDPConnection(socket: a, timings: Self.timings, initialSeq: 0x1237, tag: 1)
        defer { client.close() }
        let log = RUDPEventLog()
        try client.sendCtrlFrame(Self.heartbeat)
        try client.sendSwitch(random: hex("404142434445464748494a4b4c4d4e4f"))
        try client.startCtrl(handler: log.handler)
        #expect(try b.receive(timeout: 1)?.bytes == hex("c012 244f244f 0230 1237 0000000001fe0000"))
        #expect(try b.receive(timeout: 1)?.bytes == hex("c022 244f244f 0230 1238 00000010000d0000 404142434445464748494a4b4c4d4e4f"))
        try b.send(hex("c00e244f244f2430 567812390092 c012244f244f0230 56790000000000fe0000"), to: "", port: 0)
        #expect(eventually { log.frames.count == 1 })
        #expect(log.frames == [hex("00000000 00fe 0000")])
        // Its ACK acknowledges the DATA message's own seq + 1, with the client's current seq (0x1239).
        var ack: [UInt8]?
        while let packet = try b.receive(timeout: 0.3) {
            if packet.bytes.count == 14 { ack = packet.bytes }
        }
        #expect(ack == hex("c00e 244f244f 2430 1239 567a 0092"))
        // Both kept messages were released: nothing is resent.
        sleepSeconds(0.2)
        #expect(client.statistics.retransmissions == 0)
    }

    @Test func handshakeRetries() throws {
        let (client, console) = try link()
        defer { client.close(); console.stop() }
        console.finishAfterAck = true
        console.skip.with { $0 = ["init": 1, "cookie": 1, "request": 1] }
        let response = try client.exchange(request: Array("GET / HTTP/1.1\r\n\r\n".utf8), expectFinish: true)
        #expect(response == console.response)
        let sent = console.datagrams.with { $0 }
        // INIT twice (new seq each time), COOKIE twice with the same cookie, the request twice as a new pair.
        #expect(sent.map { RUDPFraming.parse($0).first?.flags } == [0x80, 0x80, 0x90, 0x90, 0x20, 0x20, 0x24])
        let seqs = sent.map { RUDPFraming.parse($0).first?.peerSeq }
        #expect(seqs == [0x1234, 0x1235, 0x1236, 0x1237, 0x1238, 0x1239, 0x123a])
        #expect(RUDPFraming.parse(sent[1])[0].data.suffix(4) == RUDPFraming.parse(sent[0])[0].data.suffix(4))
        #expect(RUDPFraming.parse(sent[2])[0].data.suffix(16) == RUDPFraming.parse(sent[3])[0].data.suffix(16))
    }

    @Test func exchangeTimeouts() throws {
        let request = Array("GET / HTTP/1.1\r\n\r\n".utf8)
        for (kind, step) in [("init", RUDPStep.initAck), ("cookie", .cookieAck), ("request", .response)] {
            let (client, console) = try link()
            defer { client.close(); console.stop() }
            console.skip.with { $0[kind] = 99 }
            #expect(throws: RUDPError.timeout(step)) { try client.exchange(request: request, expectFinish: false) }
            // Three tries each.
            #expect(console.datagrams.with { $0.count } >= 3)
        }
    }

    /// Three tries of 1 s, the identical ACK resent between them: the ACK goes out three times in all (the original and
    /// two resends), and the exchange carries on without FINISH (rudp.md section 10).
    @Test func aMissingFinishIsIgnored() throws {
        let (client, console) = try link()
        defer { client.close(); console.stop() }
        console.finishAfterAck = true
        console.skip.with { $0["finish"] = 99 }
        _ = try client.exchange(request: [1], expectFinish: true)
        #expect(eventually { console.datagrams.with { $0.filter { RUDPFraming.parse($0).first?.flags == 0x24 }.count } == 3 })
        sleepSeconds(0.2)
        let acks = console.datagrams.with { $0.filter { RUDPFraming.parse($0).first?.flags == 0x24 } }
        #expect(acks.count == 3 && Set(acks).count == 1)
    }

    @Test func exchangeRefusals() throws {
        let (client, console) = try link()
        defer { console.stop() }
        #expect(throws: RUDPError.messageTooLarge) {
            try client.exchange(request: [UInt8](repeating: 0, count: 4086), expectFinish: false)
        }
        #expect(throws: RUDPError.messageTooLarge) { try client.sendCtrlFrame([UInt8](repeating: 0, count: 4086)) }
        _ = try client.exchange(request: [UInt8](repeating: 0, count: 4085), expectFinish: false)
        try client.startCtrl(handler: { _ in })
        #expect(throws: RUDPError.wrongState) { try client.startCtrl(handler: { _ in }) }
        #expect(throws: RUDPError.wrongState) { try client.exchange(request: [1], expectFinish: false) }
        try client.sendCtrlFrame([UInt8](repeating: 0, count: 4085))
        client.close()
        client.close()
        #expect(throws: RUDPError.closed) { try client.sendCtrlFrame(Self.heartbeat) }
        #expect(throws: RUDPError.closed) { try client.sendSwitch() }
        #expect(throws: RUDPError.closed) { try client.exchange(request: [1], expectFinish: false) }
        #expect(throws: RUDPError.closed) { try client.startCtrl(handler: { _ in }) }
    }

    /// Frames after the response in its datagram, and a response in one of the data variants.
    @Test func ctrlFramesThatArriveWithTheResponse() throws {
        let (client, console) = try link()
        defer { client.close(); console.stop() }
        console.finishAfterAck = false
        let log = RUDPEventLog()
        // The console doesn't answer by itself: the response and a first ctrl frame arrive in one datagram by hand.
        console.skip.with { $0["request"] = 99 }
        let done = DispatchSemaphore(value: 0)
        let result = Locked<[UInt8]?>(nil)
        Thread {
            result.with { $0 = try? client.exchange(request: [1], expectFinish: false) }
            done.signal()
        }.start()
        #expect(eventually { console.datagrams.with { $0.count } >= 3 })
        let seq = console.cookieAckSeq &+ 1
        let datagram = RUDPFraming.encode(type: 0x1230, data: RUDPFraming.be16(seq) + RUDPFraming.be16(0x1236) + [0, 0, 0, 0]
            + Array("HTTP/1.1 200 OK\r\n\r\n".utf8))
        console.push(datagram + FakeRUDPConsole.message(seq: seq &+ 1, frame: Self.heartbeat))
        // flags 0x12: the whole HTTP text is data bytes 2... "whatever the variant", the 0x12 extras included.
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(result.with { $0 }?.suffix(19) == Array("HTTP/1.1 200 OK\r\n\r\n".utf8)[...])
        try client.startCtrl(handler: log.handler)
        #expect(eventually { log.frames == [Self.heartbeat] })
    }

    /// Every layout of rudp.md section 7.3, each carrying one frame.
    @Test func consoleDataVariants() throws {
        let (client, console) = try link()
        defer { client.close(); console.stop() }
        let log = RUDPEventLog()
        try client.startCtrl(handler: log.handler)
        let frame = hex("00000002 0016 0000 01ff")
        let cases: [(name: String, bytes: [UInt8])] = [
            ("0x02", FakeRUDPConsole.message(type: 0x0230, seq: 100, frame: frame)),
            ("0x12", FakeRUDPConsole.message(type: 0x1230, seq: 101, middle: hex("0001 aabbccdd"), frame: frame)),
            ("0x26", FakeRUDPConsole.message(type: 0x2630, seq: 102, middle: hex("0001 aabb"), frame: frame)),
            ("0x36", FakeRUDPConsole.message(type: 0x3630, seq: 103, frame: frame)),
            ("other", FakeRUDPConsole.message(type: 0x4230, seq: 104, middle: hex("aabb"), frame: frame)),
        ]
        for (index, entry) in cases.enumerated() {
            console.push(entry.bytes)
            #expect(eventually { log.frames.count == index + 1 }, "\(entry.name)")
        }
        #expect(log.frames.allSatisfy { $0 == frame })
        // Each was acknowledged with its own seq + 1.
        #expect(eventually { console.datagrams.with { $0.filter { $0.count == 14 }.count } == 5 })
        let acks = console.datagrams.with { $0.compactMap { RUDPFraming.parse($0).first }.filter { $0.flags == 0x24 } }
        #expect(acks.map { UInt16($0.data[2]) << 8 | UInt16($0.data[3]) } == [101, 102, 103, 104, 105])
    }

    @Test func malformedAndTinyMessages() throws {
        let (client, console) = try link()
        defer { client.close(); console.stop() }
        let log = RUDPEventLog()
        try client.startCtrl(handler: log.handler)
        // A payload length that doesn't match the message: dropped, but acknowledged.
        console.push(FakeRUDPConsole.message(seq: 10, frame: hex("00000009 0016 0000 01")))
        // Too short for a frame: dropped, acknowledged.
        console.push(FakeRUDPConsole.message(seq: 11, frame: hex("0000")))
        // Fewer than 4 data bytes: skipped without an ACK.
        console.push(RUDPFraming.encode(type: RUDPType.data, data: hex("000c 00")))
        // A late hole-punch probe on the same socket: not RUDP at all.
        console.push([UInt8](repeating: 7, count: 88))
        console.push(FakeRUDPConsole.message(seq: 12, frame: Self.heartbeat))
        #expect(eventually { log.frames == [Self.heartbeat] })
        let acks = console.datagrams.with { $0.compactMap { RUDPFraming.parse($0).first }.filter { $0.flags == 0x24 } }
        #expect(acks.count == 3)
        #expect(client.statistics.malformed == 2)
    }

    @Test func duplicatesAreIgnoredButAcknowledged() throws {
        let (client, console) = try link()
        defer { client.close(); console.stop() }
        let log = RUDPEventLog()
        try client.startCtrl(handler: log.handler)
        let message = FakeRUDPConsole.message(seq: 50, frame: Self.heartbeat)
        console.push(message)
        console.push(message)
        console.push(FakeRUDPConsole.message(seq: 51, frame: Self.heartbeat))
        #expect(eventually { log.frames.count == 2 })
        sleepSeconds(0.1)
        #expect(log.frames.count == 2 && client.statistics.duplicates == 1)
        #expect(eventually { console.datagrams.with { $0.filter { $0.count == 14 }.count } == 3 })
    }

    /// The client's data is lost and duplicated on the way out; it is resent until the console acknowledges it.
    @Test func lostAndDuplicatedClientData() throws {
        let (client, console) = try link(wrap: {
            LossyPunchSocket($0, send: { index, _ in index == 0 ? .drop : (index == 1 ? .duplicate : .deliver) })
        })
        defer { client.close(); console.stop() }
        try client.startCtrl(handler: { _ in })
        let first = hex("00000001 0001 0000 aa")
        let second = hex("00000001 0002 0000 bb")
        try client.sendCtrlFrame(first)  // dropped: retransmitted until acknowledged
        try client.sendCtrlFrame(second)  // duplicated on the wire
        #expect(eventually { Set(console.frames.with { $0 }) == [first, second] })
        #expect(eventually { client.statistics.retransmissions >= 1 })
        // Once acknowledged nothing more is resent.
        sleepSeconds(0.2)
        let settled = client.statistics.retransmissions
        sleepSeconds(0.2)
        #expect(client.statistics.retransmissions == settled && client.statistics.abandoned == 0)
    }

    /// The console's data arrives reordered and duplicated: each frame once, in arrival order.
    @Test func reorderedAndDuplicatedConsoleData() throws {
        let (client, console) = try link(wrap: {
            LossyPunchSocket($0, receive: { index, _ in index == 0 ? .hold : (index == 2 ? .duplicate : .deliver) })
        })
        defer { client.close(); console.stop() }
        let log = RUDPEventLog()
        try client.startCtrl(handler: log.handler)
        let frames = (1...3).map { hex("00000001 0010 0000 0\($0)") }
        for (i, frame) in frames.enumerated() { console.push(FakeRUDPConsole.message(seq: UInt16(200 + i), frame: frame)) }
        #expect(eventually { log.frames.count == 3 })
        #expect(log.frames == [frames[1], frames[0], frames[2]])  // arrival order, as the spec has it
        sleepSeconds(0.1)
        #expect(log.frames.count == 3 && client.statistics.duplicates == 1)
    }

    @Test func retransmissionLimits() throws {
        var timings = Self.timings
        timings.maxRetransmissions = 3
        timings.maxKept = 2
        let (client, console) = try link(timings: timings)
        defer { client.close(); console.stop() }
        console.acknowledgesData = false
        try client.startCtrl(handler: { _ in })
        for i in 0..<3 { try client.sendCtrlFrame(hex("00000001 0001 0000 0\(i)")) }
        // The 3rd was sent once and not kept; the 2 kept are resent 3 times each, then dropped silently.
        #expect(eventually { client.statistics.abandoned == 2 })
        let stats = client.statistics
        #expect(stats.unkept == 1 && stats.retransmissions == 6)
        #expect(console.frames.with { $0.count } == 3 + 6)
    }

    @Test func acksReleaseByRFC1982Comparison() throws {
        // Sequence values wrap: seq 0xffff is kept under key 0, released by ack 0 (and by ack 1), not by ack 0xfffe.
        let (a, b) = try loopbackPair()
        defer { b.close() }
        let client = RUDPConnection(socket: a, timings: Self.timings, initialSeq: 0xffff, tag: 1)
        defer { client.close() }
        try client.startCtrl(handler: { _ in })
        try client.sendCtrlFrame(Self.heartbeat)
        try b.send(RUDPFraming.ackMessage(seq: 1, ack: 0xfffe), to: "", port: 0)
        #expect(eventually { client.statistics.retransmissions >= 1 })
        try b.send(RUDPFraming.ackMessage(seq: 1, ack: 0), to: "", port: 0)
        sleepSeconds(0.1)
        let settled = client.statistics.retransmissions
        sleepSeconds(0.2)
        #expect(client.statistics.retransmissions == settled)
        #expect(client.statistics.abandoned == 0)
    }

    @Test func consoleFinishEndsCtrl() throws {
        let (client, console) = try link()
        defer { client.close(); console.stop() }
        let log = RUDPEventLog()
        try client.startCtrl(handler: log.handler)
        console.push(RUDPFraming.encode(type: RUDPType.finish, data: []))
        #expect(eventually { log.all == [.finished] })
        client.close()
    }

    @Test func receiveFailuresEndCtrl() throws {
        final class Broken: UDPPunchSocket, @unchecked Sendable {
            var localPort: UInt16 { 0 }
            func send(_ bytes: [UInt8], to host: String, port: UInt16) throws { throw FailureKind.networkUnreachable }
            func receive(timeout: Double) throws -> UDPPacket? { throw FailureKind.connectionRefused }
            func connect(host: String, port: UInt16) throws {}
            func setTimeToLive(_ ttl: Int) throws {}
            func close() {}
        }
        let client = RUDPConnection(socket: Broken(), timings: Self.timings, initialSeq: 1, tag: 1)
        let log = RUDPEventLog()
        try client.startCtrl(handler: log.handler)
        // A send that fails is a lost datagram, not an error.
        try client.sendCtrlFrame(Self.heartbeat)
        #expect(eventually { log.all == [.failed(.receiveFailed)] })
        client.close()
    }

    @Test func switchWithoutAnAnswer() throws {
        let (client, console) = try link()
        defer { client.close(); console.stop() }
        console.answersSwitch = false
        try client.startCtrl(handler: { _ in })
        try client.sendSwitch()
        #expect(!client.waitForSwitchAcknowledgement(timeout: 0.1))
        #expect(!client.waitForSwitchAcknowledgement())
        // Random bytes come from the injected source: 16 of them.
        #expect(eventually { console.frames.with { $0.first?.count } == 24 })
        #expect(console.frames.with { $0[0].suffix(16) } == hex("404142434445464748494a4b4c4d4e4f")[...])
    }

    @Test func defaultStartingValues() throws {
        for _ in 0..<50 {
            let (a, b) = try loopbackPair()
            let client = RUDPConnection(socket: a)
            try client.sendCtrlFrame(Self.heartbeat)
            let packet = try #require(try b.receive(timeout: 1))
            let message = try #require(RUDPFraming.parse(packet.bytes).first)
            let seq = try #require(message.peerSeq)
            #expect((0x01FF...0x5FFE).contains(seq))
            client.close()
            b.close()
        }
    }

    // MARK: Closing, ending and hostile input

    /// Item 7: close() ends an exchange in flight at once, with .closed rather than a timeout.
    @Test func closeDuringAnExchange() throws {
        var slow = Self.timings
        slow.stepWait = 1
        let (client, console) = try link(timings: slow)
        defer { console.stop() }
        console.skip.with { $0["init"] = 99 }
        let result = Locked<Result<[UInt8], any Error>?>(nil)
        let start = monotonicSeconds()
        let ended = DispatchSemaphore(value: 0)
        Thread {
            result.with { $0 = Result { try client.exchange(request: [1], expectFinish: false) } }
            ended.signal()
        }.start()
        sleepSeconds(0.1)
        client.close()
        #expect(ended.wait(timeout: .now() + 2) == .success)
        #expect(monotonicSeconds() - start < 1)
        if case .failure(let error)? = result.with({ $0 }) { #expect(error as? RUDPError == .closed) } else { Issue.record("expected .closed") }
    }

    /// Item 8: close() from the handler doesn't wait for its own thread, and the connection is closed afterwards.
    @Test func closeFromTheHandler() throws {
        let (client, console) = try link()
        defer { console.stop() }
        let box = Locked<RUDPConnection?>(nil)
        box.with { $0 = client }
        let tookMs = Locked<Double>(-1)
        try client.startCtrl(handler: { _ in
            let start = monotonicSeconds()
            box.with { $0 }?.close()
            tookMs.with { $0 = (monotonicSeconds() - start) * 1000 }
        })
        console.push(FakeRUDPConsole.message(seq: 1, frame: Self.heartbeat))
        #expect(eventually { tookMs.with { $0 } >= 0 })
        #expect(tookMs.with { $0 } < 500)
        #expect(throws: RUDPError.closed) { try client.sendCtrlFrame(Self.heartbeat) }
        box.with { $0 = nil }
    }

    /// Item 8: a connection dropped without close() releases its thread and socket.
    @Test func aDroppedConnectionIsReleased() throws {
        let (a, b) = try loopbackPair()
        defer { b.close() }
        weak var weakClient: RUDPConnection?
        do {
            let client = RUDPConnection(socket: a, timings: Self.timings, initialSeq: 1, tag: 1)
            weakClient = client
            try client.startCtrl(handler: { _ in })
            try client.sendCtrlFrame(Self.heartbeat)
        }
        #expect(eventually { weakClient == nil })
        // Its socket was closed with it.
        #expect(eventually { (try? a.send([1], to: "", port: 0)) == nil })
    }

    /// The console's FINISH ends ctrl: sending afterwards throws instead of silently queuing.
    @Test func sendingAfterFinishThrows() throws {
        let (client, console) = try link()
        defer { client.close(); console.stop() }
        let log = RUDPEventLog()
        try client.startCtrl(handler: log.handler)
        try client.sendCtrlFrame(Self.heartbeat)
        console.push(RUDPFraming.encode(type: RUDPType.finish, data: []))
        #expect(eventually { log.all == [.finished] })
        #expect(throws: RUDPError.closed) { try client.sendCtrlFrame(Self.heartbeat) }
        #expect(throws: RUDPError.closed) { try client.sendSwitch() }
        // A failure ends it the same way.
        #expect(client.statistics.frames == 0)
    }

    @Test func invalidSwitchBytesThrow() throws {
        let (client, console) = try link()
        defer { client.close(); console.stop() }
        for count in [0, 15, 17, 100] {
            #expect(throws: RUDPError.invalidArgument) { try client.sendSwitch(random: [UInt8](repeating: 1, count: count)) }
        }
        #expect(console.frames.with { $0.isEmpty })
    }

    /// Item 15: an INIT_ACK whose cookie couldn't be sent back is not used (and nothing traps).
    @Test func anOversizedCookieIsIgnored() throws {
        let (client, console) = try link()
        defer { client.close(); console.stop() }
        console.skip.with { $0["init"] = 99 }
        let result = Locked<Result<[UInt8], any Error>?>(nil)
        let ended = DispatchSemaphore(value: 0)
        Thread {
            result.with { $0 = Result { try client.exchange(request: [1], expectFinish: false) } }
            ended.signal()
        }.start()
        #expect(eventually { console.datagrams.with { !$0.isEmpty } })
        // 8 data bytes plus the cookie must fit one message: the biggest INIT_ACK the console can send has a cookie of
        // 4079 bytes, which is over the 4073 we could return.
        console.push(RUDPFraming.encode(type: RUDPType.initiateAck, data: [UInt8](repeating: 0, count: 8)
            + [UInt8](repeating: 7, count: 4079)))
        #expect(ended.wait(timeout: .now() + 3) == .success)
        if case .failure(let error)? = result.with({ $0 }) { #expect(error as? RUDPError == .timeout(.initAck)) } else { Issue.record("expected a timeout") }
    }

    /// Item 10: the duplicate window starts afresh with each exchange.
    @Test func theDuplicateWindowIsResetPerExchange() throws {
        let (client, console) = try link()
        defer { client.close(); console.stop() }
        _ = try client.exchange(request: [1], expectFinish: false)  // the response had seq 0x5679
        console.cookieAckSeq = 0x6000
        let response = try client.exchange(request: [2], expectFinish: false)
        #expect(response == console.response)
        let log = RUDPEventLog()
        try client.startCtrl(handler: log.handler)
        // 0x5679 was taken in the first exchange; after the reset it is a new message again.
        console.push(FakeRUDPConsole.message(seq: 0x5679, frame: Self.heartbeat))
        #expect(eventually { log.frames == [Self.heartbeat] })
        console.push(FakeRUDPConsole.message(seq: 0x5679, frame: Self.heartbeat))
        sleepSeconds(0.1)
        #expect(log.frames.count == 1 && client.statistics.duplicates == 1)
    }
}
