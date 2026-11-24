import CommonCrypto
import CryptoKit
import Darwin
import Foundation

@testable import PlayFXProtocol

// A console for internet play, on loopback only, written from docs/protocol (holepunch.md, rudp.md, registration.md
// section 8): UDP sockets that answer the hole-punch probes and then speak RUDP (registration, session init, ctrl,
// the switch) or Takion. PSN is faked separately (the tests' `FakePSN`); these classes are what the "console" does
// once the candidates are exchanged.

/// One UDP socket on 127.0.0.1 that plays the console's side of a hole: it probes the client's candidates until the
/// client has answered, answers the client's probes, and hands every other datagram to `onDatagram`. One thread runs
/// it all, so whatever `onDatagram` and `perform` touch is only ever touched there.
final class PunchedUDPEndpoint: @unchecked Sendable {
    let port: UInt16
    let hashedID: [UInt8]
    let sid: UInt16
    /// Answers the client's requests (off: a console behind a NAT that drops them).
    var answers = true
    /// Sends its own requests (the mutual check of holepunch.md section 5.5).
    var probes = true
    /// Every probe request of the client, as parsed.
    let clientRequests = Locked<[ProbePacket]>([])
    /// Datagrams that aren't probes.
    var onDatagram: (([UInt8]) -> Void)?

    private let fd: Int32
    private let lock = NSLock()
    private var peer = sockaddr_in()
    private var havePeer = false
    private var running = true
    private var tasks: [() -> Void] = []
    private var clientOffer: PunchOffer?
    private var clientAnswered = false
    private let done = DispatchSemaphore(value: 0)

    init(hashedID: [UInt8], sid: UInt16) throws {
        self.hashedID = hashedID
        self.sid = sid
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { throw FailureKind(errno: errno) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw FailureKind(errno: errno) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &length) }
        }
        var timeout = timeval(tv_sec: 0, tv_usec: 10_000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        fd = s
        port = UInt16(bigEndian: addr.sin_port)
        Thread { [self] in loop() }.start()
    }

    /// The console's OFFER for this hole: its candidates are this socket.
    var announced: PunchOffer {
        PunchOffer(sid: sid, peerSid: 0, hashedID: hashedID, candidates: [
            PunchCandidate(type: .staticAddress, address: "127.0.0.1", port: port),
            PunchCandidate(type: .local, address: "127.0.0.1", port: port),
        ])
    }

    /// Starts probing the client's candidates once its OFFER is known.
    func startProbing(clientOffer offer: PunchOffer) {
        lock.lock(); clientOffer = offer; lock.unlock()
    }

    /// Sends to whoever last sent here (loopback only).
    func send(_ bytes: [UInt8]) {
        lock.lock()
        var target = peer
        let ok = havePeer
        lock.unlock()
        guard ok else { return }
        guard target.sin_addr.s_addr == inet_addr("127.0.0.1") else {
            loopbackViolation("fake console would send to a non-loopback address")
        }
        _ = withUnsafePointer(to: &target) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    /// Runs `block` on the endpoint's thread, within 10 ms.
    func perform(_ block: @escaping () -> Void) {
        lock.lock(); tasks.append(block); lock.unlock()
    }

    private func sendTo(_ bytes: [UInt8], host: String, port: UInt16) {
        guard host == "127.0.0.1" else { loopbackViolation("fake console would send to \(host)") }
        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_addr.s_addr = inet_addr(host)
        target.sin_port = port.bigEndian
        _ = withUnsafePointer(to: &target) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private func loop() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var lastRequest = 0.0
        let requestID = hex("c1c2c3c4c5")
        while true {
            lock.lock()
            let go = running
            let due = tasks
            tasks = []
            let offer = clientOffer
            let answered = clientAnswered
            lock.unlock()
            for task in due { task() }
            if !go { break }
            if probes, let offer, !answered, monotonicSeconds() - lastRequest >= 0.03 {
                lastRequest = monotonicSeconds()
                let request = ProbePacket.request(
                    senderHashedID: hashedID, receiverHashedID: offer.hashedID, senderSid: sid, receiverSid: offer.sid,
                    requestID: requestID)
                for candidate in offer.candidates { sendTo(request, host: candidate.address, port: candidate.port) }
            }
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            if n < 0 { continue }
            lock.lock(); peer = from; havePeer = true; lock.unlock()
            let bytes = Array(buffer[0..<n])
            guard let probe = ProbePacket.parse(bytes) else {
                onDatagram?(bytes)
                continue
            }
            switch probe.kind {
            case .response:
                lock.lock(); clientAnswered = true; lock.unlock()
            case .request:
                clientRequests.with { $0.append(probe) }
                if answers, let response = ProbePacket.response(
                    senderHashedID: hashedID, receiverHashedID: probe.senderHashedID, senderSid: sid,
                    receiverSid: probe.senderSid, requestID: probe.requestID,
                    source: ("127.0.0.1", UInt16(bigEndian: from.sin_port))) {
                    send(response)
                }
            }
        }
        done.signal()
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
        done.wait()
        close(fd)
    }
}

/// The console's RUDP, on the ctrl hole's endpoint (rudp.md): the handshake before each exchange, then the HTTP-style
/// requests of registration through PSN, session init and the ctrl start, ctrl frames both ways (through a
/// `CtrlPeer`, the same console-side ctrl as the LAN tests use), and the switch message.
final class RUDPConsole: @unchecked Sendable {
    enum RegistrationReply { case accept, refuse(reason: String), silent }

    /// What the console knows of the PSN session: the secrets of registration.md section 8.2 and the account.
    struct Secrets {
        var data1: [UInt8]
        var data2: [UInt8]
        var customData1: [UInt8]
        var accountID: [UInt8]
    }

    let endpoint: PunchedUDPEndpoint
    let secrets: Secrets
    /// INIT gets no INIT_ACK.
    var answersHandshake = true
    var registrationReply = RegistrationReply.accept
    var initReplies: @Sendable (Int) -> FakeSessionConsole.InitReply = { _ in .nonce }
    /// The console's ctrl conversation once the ctrl request is in (default: head, session ID, then read).
    var ctrlScript: @Sendable (CtrlPeer) -> Void = { peer in
        peer.sendHead()
        peer.send(0x33, sessionIDPlain)
        peer.pump(limit: 30)
    }
    /// Runs when the switch message arrives, before the console's `0x0034`.
    var onSwitch: () -> Void = {}
    /// Answers the switch message with `0x0034` (off: it never comes).
    var acknowledgesSwitch = true

    /// What each exchange carried, in order.
    let registrations = Locked<[(header: String, inner: String)]>([])
    let initRequests = Locked<[String]>([])
    let ctrlRequests = Locked<[String]>([])
    let switchMessages = Locked<[[UInt8]]>([])
    /// Datagrams of each RUDP type the client sent.
    let clientMessages = Locked<[RUDPMessage]>([])
    let peers = Locked<[CtrlPeer]>([])

    private var seq: UInt16 = 0x5678
    private var bridge: Int32 = -1
    private var peerFD: Int32 = -1
    private var finishAfterAck = false
    private let bridgeRunning = Locked(false)

    init(endpoint: PunchedUDPEndpoint, secrets: Secrets) {
        self.endpoint = endpoint
        self.secrets = secrets
        endpoint.onDatagram = { [unowned self] in handle($0) }
    }

    private func nextSeq() -> UInt16 {
        defer { seq &+= 1 }
        return seq
    }

    private func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }

    private func sendData(_ payload: [UInt8]) {
        endpoint.send(RUDPFraming.dataMessage(seq: nextSeq(), payload: payload))
    }

    private func handle(_ datagram: [UInt8]) {
        for message in RUDPFraming.parse(datagram) {
            clientMessages.with { $0.append(message) }
            switch message.flags {
            case 0x80:
                guard answersHandshake else { continue }
                endpoint.send(RUDPFraming.encode(type: 0xD000, data: [UInt8](repeating: 0, count: 8) + hex("c0c1c2c3c4c5c6c7c8c9cacbcccdcecf")))
            case 0x90:
                guard answersHandshake else { continue }
                endpoint.send(RUDPFraming.encode(type: 0xA030, data: be16(nextSeq())))
            case 0x02:
                guard let clientSeq = message.peerSeq, message.data.count >= 2 else { continue }
                endpoint.send(RUDPFraming.ackMessage(seq: seq, ack: clientSeq &+ 1))
                dataMessage(Array(message.data[2...]))
            case 0x24:
                if finishAfterAck {
                    finishAfterAck = false
                    endpoint.send(RUDPFraming.encode(type: 0xC000, data: []))
                }
            default:
                break
            }
        }
    }

    private func dataMessage(_ payload: [UInt8]) {
        if bridge >= 0 {
            if payload.count >= 8, Array(payload[0..<8]) == RUDPFraming.switchHeader {
                switchMessages.with { $0.append(payload) }
                onSwitch()
                if acknowledgesSwitch { _ = sendToCtrl(0x34) }
            } else {
                _ = payload.withUnsafeBytes { write(bridge, $0.baseAddress, $0.count) }
            }
            return
        }
        let text = String(decoding: payload, as: UTF8.self)
        if text.contains("/rp/sess/rgst") {
            registration(payload)
        } else if text.contains("/rp/sess/init") {
            let index = initRequests.with { $0.append(text); return $0.count - 1 }
            switch initReplies(index) {
            case .nonce:
                respond(Array(("HTTP/1.1 200 OK\r\nContent-Length:        0\r\nRP-Server-Type: ignored\r\n"
                    + "RP-Nonce: AAECAwQFBgcICQoLDA0ODw==\r\n\r\n").utf8), then: true)
            case .refuse(let status, let reason, let version):
                var head = "HTTP/1.1 \(status)\r\nContent-Length:        0\r\n"
                if let reason { head += "RP-Application-Reason: \(reason)\r\n" }
                if let version { head += "RP-Version: \(version)\r\n" }
                respond(Array((head + "\r\n").utf8), then: true)
            case .raw(let bytes): respond(bytes, then: true)
            case .close, .hang: break
            }
        } else if text.contains("/rp/sess/ctrl") {
            ctrlRequests.with { $0.append(text) }
            startCtrl(text)
        }
    }

    private func respond(_ bytes: [UInt8], then finish: Bool) {
        sendData(bytes)
        finishAfterAck = finish
    }

    private func sendToCtrl(_ type: UInt16) -> Bool {
        guard let peer = peers.with({ $0.first }) else { return false }
        peer.send(type)
        return true
    }

    // MARK: Registration (registration.md section 8, rpcrypt.md section 7 from the console's side)

    private func registration(_ request: [UInt8]) {
        guard let end = FakeConsole.indexOf([13, 10, 13, 10], in: request) else { return }
        let header = String(decoding: request[0..<end + 4], as: UTF8.self)
        let body = Array(request[(end + 4)...])
        guard body.count > 0x1e0 else { return }
        let ps5 = header.contains("/ps5/")
        let (rk, rm) = ps5 ? (RPTables.registKeyPs5, RPTables.registMaskPs5) : (RPTables.registKeyPs4, RPTables.registMaskPs4)
        let hmac = ps5 ? RPTables.ivHmacKeyPs5 : RPTables.ivHmacKeyPs4
        let add: UInt8 = ps5 ? 0x2b : 0xd7
        let m = Array(body[0x191..<0x199]) + Array(body[0x0c7..<0x0cf])
        let keyColumn = Int(body[0x18d] & 0x1f), maskColumn = Int(body[0] >> 3)
        var seed = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { seed[i] = ((m[i] ^ rm[i * 0x20 + maskColumn]) &+ UInt8(i)) &- add }
        let e = FakeConsole.cfb((key: secrets.data1, seed: secrets.data2, hmac: hmac), secrets.customData1, encrypt: true)
        var key = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { key[i] = rk[i * 0x20 + keyColumn] ^ e[i] }
        let context = (key: key, seed: seed, hmac: hmac)
        let inner = String(decoding: FakeConsole.cfb(context, Array(body[0x1e0...]), encrypt: false), as: UTF8.self)
        registrations.with { $0.append((header, inner)) }
        switch registrationReply {
        case .silent: return
        case .refuse(let reason):
            respond(Array("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nRP-Application-Reason: \(reason)\r\n\r\n".utf8), then: true)
        case .accept:
            let plaintext = "\(ps5 ? "PS5" : "PS4")-RegistKey: 3031323361626364\r\nRP-KeyType: 2\r\n"
                + "RP-Key: a0a1a2a3a4a5a6a7a8a9aaabacadaeaf\r\n\(ps5 ? "PS5" : "PS4")-Mac: 0a1b2c3d4e5f\r\n"
                + "\(ps5 ? "PS5" : "PS4")-Nickname: PS5-TEST\r\n"
            let encrypted = FakeConsole.cfb(context, Array(plaintext.utf8), encrypt: true)
            let head = "HTTP/1.1 200 OK\r\nConnection: close\r\nRP-Feature: 3\r\nContent-Length: \(encrypted.count)\r\n\r\n"
            respond(Array(head.utf8) + encrypted, then: true)
        }
    }

    // MARK: Ctrl

    private func startCtrl(_ request: String) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else { return }
        peerFD = fds[0]
        bridge = fds[1]
        let version = CtrlPeer.header("RP-Version", in: request) ?? "1.0"
        let peer = CtrlPeer(fd: fds[0], cipher: .forVersion(version), requestText: request, leftover: [])
        if version == "1.0" { peer.skipClientCounter() }
        peers.with { $0.append(peer) }
        bridgeRunning.with { $0 = true }
        let bridgeFD = fds[1]
        // Console frames written to the CtrlPeer come out here, one datagram each, and go to the client.
        Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while bridgeRunning.with({ $0 }) {
                var pfd = pollfd(fd: bridgeFD, events: Int16(POLLIN), revents: 0)
                guard poll(&pfd, 1, 20) > 0 else { continue }
                let n = buffer.withUnsafeMutableBytes { read(bridgeFD, $0.baseAddress, 4096) }
                if n <= 0 { break }
                let payload = Array(buffer[0..<n])
                endpoint.perform { [self] in sendData(payload) }
            }
        }.start()
        Thread { [self] in
            ctrlScript(peer)
            _ = self
        }.start()
    }

    /// Ends the console's ctrl: a FINISH to the client (rudp.md section 9).
    func finishCtrl() {
        endpoint.perform { [self] in endpoint.send(RUDPFraming.encode(type: 0xC000, data: [])) }
    }

    func stop() {
        bridgeRunning.with { $0 = false }
        if peerFD >= 0 { close(peerFD) }
        if bridge >= 0 { close(bridge) }
    }
}

/// A whole console for internet play: the ctrl hole's RUDP console and the data hole's Takion consoles, on loopback.
final class InternetConsole: @unchecked Sendable {
    static let ctrlHashedID = hex("a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3")
    static let dataHashedID = hex("c0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3")
    static let ctrlSid: UInt16 = 0xabcd
    static let dataSid: UInt16 = 0xabce

    let ctrlEndpoint: PunchedUDPEndpoint
    let dataEndpoint: PunchedUDPEndpoint
    let rudp: RUDPConsole
    let stream: StreamConsole

    init(secrets: RUDPConsole.Secrets, serverType: UInt8 = 2) throws {
        ctrlEndpoint = try PunchedUDPEndpoint(hashedID: Self.ctrlHashedID, sid: Self.ctrlSid)
        dataEndpoint = try PunchedUDPEndpoint(hashedID: Self.dataHashedID, sid: Self.dataSid)
        rudp = RUDPConsole(endpoint: ctrlEndpoint, secrets: secrets)
        stream = try StreamConsole(serverType: serverType, internet: dataEndpoint)
        let stream = stream
        rudp.onSwitch = { stream.activateStream() }
    }

    func endpoint(_ hole: InternetHole) -> PunchedUDPEndpoint { hole == .ctrl ? ctrlEndpoint : dataEndpoint }

    func stop() {
        rudp.stop()
        stream.stop()
        ctrlEndpoint.stop()
        dataEndpoint.stop()
    }
}
