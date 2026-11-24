import CommonCrypto
import CryptoKit
import Darwin
import Foundation

@testable import PlayFXProtocol

// Test-side Takion support, written independently of the implementation: a reference GKCrypt (byte-array
// arithmetic, CryptoKit's AES-GCM with a 16-byte nonce for the tag), a fake console that builds and parses
// packets by hand from takion.md, and in-memory and loopback links.

enum TakionVec {
    static let secret = hex("0c1fbe7f56ae330d92c6b86cd82e0879addd6822fe20f2419176352093908297")
    static let handshakeKey = hex("404142434445464748494a4b4c4d4e4f")
    static let clientTag: UInt32 = 0x1234abcd
    static let consoleTag: UInt32 = 0x5a5aa5a5
    static let cookie = (0xc0...0xdf).map { UInt8($0) }
}

/// An independent implementation of takion.md §6.
struct RefCrypto {
    let cipherKey: [UInt8]
    let ivBase: [UInt8]

    init(index: UInt8, secret: [UInt8] = TakionVec.secret, handshakeKey: [UInt8] = TakionVec.handshakeKey) {
        let message = Data([0x01, index, 0x00] + handshakeKey + [0x01, 0x00])
        let d = Array(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
        cipherKey = Array(d[0..<16])
        ivBase = Array(d[16..<32])
    }

    /// `a ⊕+ v`, one byte at a time with an explicit carry.
    static func add(_ a: [UInt8], _ v: UInt64) -> [UInt8] {
        var out = a
        var carry = 0
        for i in 0..<16 {
            let part = i < 8 ? Int((v >> UInt64(8 * i)) & 0xff) : 0
            let sum = Int(out[i]) + part + carry
            out[i] = UInt8(sum & 0xff)
            carry = sum >> 8
        }
        return out
    }

    static func aes(key: [UInt8], block: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), key, 16, nil,
                             block, 16, &out, 16, &moved)
        precondition(status == kCCSuccess)
        return out
    }

    func keystreamByte(_ position: UInt64) -> UInt8 {
        Self.aes(key: cipherKey, block: Self.add(ivBase, position / 16))[Int(position % 16)]
    }

    func keystream(from position: UInt64, count: Int) -> [UInt8] {
        (0..<count).map { keystreamByte(position + UInt64($0)) }
    }

    /// Encrypts or decrypts `data` as the payload of a packet with `keyPos`.
    func crypt(_ data: [UInt8], keyPos: UInt64) -> [UInt8] {
        zip(data, keystream(from: keyPos + 16, count: data.count)).map { $0 ^ $1 }
    }

    static func fold(_ digest: [UInt8]) -> [UInt8] { (0..<16).map { digest[$0] ^ digest[$0 + 16] } }

    func gmacKey(epoch: UInt64) -> [UInt8] {
        let g0 = Self.fold(Array(SHA256.hash(data: Data(cipherKey + ivBase))))
        if epoch == 0 { return g0 }
        return Self.fold(Array(SHA256.hash(data: Data(g0 + Self.add(ivBase, epoch * 44910)))))
    }

    func gmac(_ datagram: [UInt8], gmacAt: Int, keyPosAt: Int, zeroKeyPos: Bool, keyPos: UInt64) -> [UInt8] {
        var d = datagram
        for i in 0..<4 { d[gmacAt + i] = 0 }
        if zeroKeyPos { for i in 0..<4 { d[keyPosAt + i] = 0 } }
        let epoch: UInt64 = keyPos == 0 ? 0 : (keyPos - 1) / 45000
        let nonce = try! AES.GCM.Nonce(data: Self.add(ivBase, keyPos / 16))
        let sealed = try! AES.GCM.seal(Data(), using: SymmetricKey(data: gmacKey(epoch: epoch)), nonce: nonce, authenticating: Data(d))
        return Array(sealed.tag.prefix(4))
    }

    /// Fills the GMAC of a datagram (types per takion.md §2).
    func sealed(_ datagram: [UInt8], gmacAt: Int, keyPosAt: Int, zeroKeyPos: Bool, keyPos: UInt64) -> [UInt8] {
        var d = datagram
        let tag = gmac(d, gmacAt: gmacAt, keyPosAt: keyPosAt, zeroKeyPos: zeroKeyPos, keyPos: keyPos)
        d.replaceSubrange(gmacAt..<gmacAt + 4, with: tag)
        return d
    }
}

func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
func readBE32(_ d: [UInt8], _ at: Int) -> UInt32 { d[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) } }
func readBE16(_ d: [UInt8], _ at: Int) -> UInt16 { UInt16(d[at]) << 8 | UInt16(d[at + 1]) }

/// A client packet as the fake console saw it.
struct ClientPacket {
    var bytes: [UInt8]
    var type: UInt8 { bytes[0] & 0x0f }
    var gmacOK: Bool?
    var keyPos: UInt64
    /// Decrypted body of a feedback packet.
    var body: [UInt8] = []
    var chunkType: UInt8? { type == 0 && bytes.count >= 14 ? bytes[13] : nil }
}

/// The console side of a Takion connection, built by hand from takion.md. It never calls the implementation.
final class FakeTakionConsole: @unchecked Sendable {
    private let lock = NSLock()
    let consoleTag = TakionVec.consoleTag
    var expectedClientTag = TakionVec.clientTag
    /// Console → client packets are sent through this (set by the link).
    var emit: ([UInt8]) -> Void = { _ in }
    private var received: [ClientPacket] = []
    var ignoreInits = 0
    var ackData = true
    var ackSkip = 0
    var replyToHandshake = true
    private(set) var up: RefCrypto?
    private(set) var down: RefCrypto?
    private var nextConsoleTSN = TakionVec.consoleTag
    private var downKeyPos: UInt64 = 0
    private var lastClientKeyPos: UInt64 = 0
    private(set) var initCount = 0
    /// Answer with the tag the client chose in its INIT (the session's connections pick a random one).
    var adoptsClientTag = false
    /// Called with every client datagram after the console has handled it (acked, recorded).
    var onPacket: (([UInt8]) -> Void)?

    var packets: [ClientPacket] { lock.lock(); defer { lock.unlock() }; return received }

    func packets(ofType type: UInt8) -> [ClientPacket] { packets.filter { $0.type == type } }

    func dataChunks() -> [ClientPacket] { packets.filter { $0.chunkType == 0 } }

    func secure() {
        up = RefCrypto(index: 2)
        down = RefCrypto(index: 3)
    }

    // MARK: Console packets

    func initAck(initialTSN: UInt32? = nil) -> [UInt8] {
        [0] + be32(expectedClientTag) + be32(0) + be32(0) + [0x02, 0x00, 0x00, 0x34]
            + be32(consoleTag) + be32(0x19000) + be16(100) + be16(100) + be32(initialTSN ?? consoleTag) + TakionVec.cookie
    }

    func cookieAck() -> [UInt8] { [0] + be32(expectedClientTag) + be32(0) + be32(0) + [0x0b, 0x00, 0x00, 0x04] }

    /// A DATA chunk from the console. With keys, `keyPos` and the GMAC are filled (control packet rule).
    func dataChunk(tsn: UInt32? = nil, channel: UInt16 = 1, dataType: UInt8? = 0, flags: UInt8 = 1, message: [UInt8],
                   keyPos: UInt64? = nil) -> [UInt8] {
        let t: UInt32
        if let tsn { t = tsn } else { t = nextConsoleTSN; nextConsoleTSN &+= 1 }
        let payload = be32(t) + be16(channel) + [0, 0] + (dataType.map { [$0] } ?? []) + message
        var d = [0] + be32(expectedClientTag) + be32(0) + be32(0) + [0x00, flags] + be16(UInt16(payload.count + 4)) + payload
        if let down {
            let k = keyPos ?? downKeyPos
            d.replaceSubrange(9..<13, with: be32(UInt32(truncatingIfNeeded: k)))
            d = down.sealed(d, gmacAt: 5, keyPosAt: 9, zeroKeyPos: true, keyPos: k)
            if keyPos == nil { downKeyPos += UInt64(message.count + (message.count & 15)) }
        }
        return d
    }

    func dataAck(cumulative: UInt32, gaps: [(UInt16, UInt16)] = [], keyPos: UInt64? = nil) -> [UInt8] {
        let payload = be32(cumulative) + be32(0x19000) + be16(UInt16(gaps.count)) + be16(0) + gaps.flatMap { be16($0.0) + be16($0.1) }
        var d = [0] + be32(expectedClientTag) + be32(0) + be32(0) + [0x03, 0x00] + be16(UInt16(payload.count + 4)) + payload
        if let down {
            let k = keyPos ?? downKeyPos
            d.replaceSubrange(9..<13, with: be32(UInt32(truncatingIfNeeded: k)))
            d = down.sealed(d, gmacAt: 5, keyPosAt: 9, zeroKeyPos: true, keyPos: k)
            if keyPos == nil { downKeyPos += UInt64(d.count + (d.count & 15)) }
        }
        return d
    }

    /// An AV packet (types 2/3), version 9 or 12 layout, payload encrypted when keys exist.
    func av(video: Bool, version: Int = 12, packetIndex: UInt16, frameIndex: UInt16, word: UInt32, codec: UInt8 = 3,
            field18: UInt16 = 0x0367, byte20: UInt8 = 0x20, stream: UInt8 = 0, ext: Bool = false, payload: [UInt8],
            keyPos: UInt64? = nil, secure: Bool = true, goodGMAC: Bool = true) -> [UInt8] {
        let k = keyPos ?? downKeyPos
        let enc = (secure && down != nil) ? down!.crypt(payload, keyPos: k) : payload
        var d: [UInt8] = [(video ? 2 : 3) | (ext ? 0x10 : 0)] + be16(packetIndex) + be16(frameIndex) + be32(word) + [codec]
            + be32(0) + be32(UInt32(truncatingIfNeeded: k))
        if video {
            d += be16(field18) + [byte20]
            if ext { d += [9, 9, 9] }
        } else {
            d += [0]
            if ext { d += [9, 9, 9] }
            if version == 12 { d += [stream] }
        }
        d += enc
        if secure, let down {
            d = down.sealed(d, gmacAt: 10, keyPosAt: 14, zeroKeyPos: false, keyPos: k)
            if !goodGMAC { d[10] ^= 0xff }
            if keyPos == nil { downKeyPos += UInt64(16 + payload.count + ((16 + payload.count) & 15)) }
        }
        return d
    }

    /// A video packet with unit `unit` of `total` units (FEC `fec`).
    func video(index: UInt16, frame: UInt16 = 1, unit: Int = 0, total: Int = 1, fec: Int = 0, payload: [UInt8]? = nil,
               version: Int = 12) -> [UInt8] {
        let word = UInt32(unit) << 21 | UInt32(total - 1) << 10 | UInt32(fec)
        return av(video: true, version: version, packetIndex: index, frameIndex: frame, word: word,
                  payload: payload ?? [UInt8(index & 0xff), UInt8(index >> 8), 0xaa, 0xbb, 0xcc])
    }

    // MARK: Handling what the client sends

    /// Called for every client datagram. Replies through `emit`.
    func handle(_ d: [UInt8]) {
        guard !d.isEmpty else { return }
        var packet = ClientPacket(bytes: d, gmacOK: nil, keyPos: 0)
        switch d[0] & 0x0f {
        case 0:
            guard d.count >= 17 else { break }
            let keyPosLow = readBE32(d, 9)
            if let up {
                let k = UInt64(keyPosLow)
                packet.keyPos = k
                packet.gmacOK = up.gmac(d, gmacAt: 5, keyPosAt: 9, zeroKeyPos: true, keyPos: k) == Array(d[5..<9])
            }
            switch d[13] {
            case 0x01:
                if adoptsClientTag, d.count >= 21 { expectedClientTag = readBE32(d, 17) }
                lock.lock(); initCount += 1; let skip = ignoreInits > 0; if skip { ignoreInits -= 1 }; lock.unlock()
                if replyToHandshake && !skip { emit(initAck()) }
            case 0x0a:
                if replyToHandshake { emit(cookieAck()) }
            case 0x00:
                if ackData, d.count >= 26 {
                    let tsn = readBE32(d, 17)
                    lock.lock(); let skip = ackSkip > 0; if skip { ackSkip -= 1 }; lock.unlock()
                    if !skip { emit(dataAck(cumulative: tsn)) }
                }
            default: break
            }
        case 5:
            if let up, d.count >= 15 {
                let k = UInt64(readBE32(d, 11))
                packet.keyPos = k
                packet.gmacOK = up.gmac(d, gmacAt: 7, keyPosAt: 11, zeroKeyPos: true, keyPos: k) == Array(d[7..<11])
            }
        case 1, 6:
            if let up, d.count >= 12 {
                let k = UInt64(readBE32(d, 4))
                packet.keyPos = k
                packet.gmacOK = up.gmac(d, gmacAt: 8, keyPosAt: 4, zeroKeyPos: false, keyPos: k) == Array(d[8..<12])
                packet.body = up.crypt(Array(d[12...]), keyPos: k)
            }
        case 3:
            if let up, d.count >= 18 {
                let k = UInt64(readBE32(d, 14))
                packet.keyPos = k
                packet.gmacOK = up.gmac(d, gmacAt: 10, keyPosAt: 14, zeroKeyPos: false, keyPos: k) == Array(d[10..<14])
            }
        default: break
        }
        lock.lock()
        received.append(packet)
        lock.unlock()
        onPacket?(d)
    }
}

// MARK: Recording delegate

final class RecordingDelegate: TakionDelegate, @unchecked Sendable {
    struct AV {
        var header: TakionAVHeader
        var payload: [UInt8]
        var receivedAt: UInt64
    }
    struct Message: Equatable {
        var channel: UInt16
        var dataType: UInt8
        var bytes: [UInt8]
    }
    private let lock = NSLock()
    private var _connected = false
    private var _closed: [TakionCloseReason] = []
    private var _messages: [Message] = []
    private var _av: [AV] = []
    private var _acked: [UInt32] = []
    var onData: ((Message) -> Void)?

    var connected: Bool { lock.lock(); defer { lock.unlock() }; return _connected }
    var closed: [TakionCloseReason] { lock.lock(); defer { lock.unlock() }; return _closed }
    var messages: [Message] { lock.lock(); defer { lock.unlock() }; return _messages }
    var av: [AV] { lock.lock(); defer { lock.unlock() }; return _av }
    var acked: [UInt32] { lock.lock(); defer { lock.unlock() }; return _acked }

    func takionConnected() { lock.lock(); _connected = true; lock.unlock() }
    func takionClosed(_ reason: TakionCloseReason) { lock.lock(); _closed.append(reason); lock.unlock() }
    func takionData(channel: UInt16, dataType: UInt8, message: UnsafeRawBufferPointer) {
        let m = Message(channel: channel, dataType: dataType, bytes: Array(message))
        lock.lock(); _messages.append(m); lock.unlock()
        onData?(m)
    }
    func takionAV(_ header: TakionAVHeader, payload: UnsafeMutableRawBufferPointer, receivedAt: UInt64) {
        let a = AV(header: header, payload: Array(payload), receivedAt: receivedAt)
        lock.lock(); _av.append(a); lock.unlock()
    }
    func takionAcknowledged(through tsn: UInt32) { lock.lock(); _acked.append(tsn); lock.unlock() }
}

// MARK: Links

/// An in-memory transport: sends are logged, and the test feeds datagrams to the connection by hand.
final class MemoryTransport: DatagramTransport, @unchecked Sendable {
    let name = "memory"
    let localPort: UInt16 = 1
    private let lock = NSLock()
    private var _sent: [[UInt8]] = []
    private(set) var handler: TransportHandler?
    private(set) var stopped = false
    private(set) var reschedules = 0
    var failSend: FailureKind?

    var sent: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return _sent }
    func start(handler: TransportHandler) throws { self.handler = handler }
    func send(_ bytes: UnsafeRawBufferPointer) throws {
        if let failSend { throw failSend }
        lock.lock(); _sent.append(Array(bytes)); lock.unlock()
    }
    func reschedule() { lock.lock(); reschedules += 1; lock.unlock() }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
}

/// A connection over `MemoryTransport` wired to a `FakeTakionConsole`. `pump` runs the console on what the client sent.
final class MemoryHarness {
    let transport = MemoryTransport()
    let console = FakeTakionConsole()
    let delegate = RecordingDelegate()
    let connection: TakionConnection
    private var processed = 0
    private var outbox: [[UInt8]] = []
    var clock: UInt64 = 10_000_000_000

    init(version: Int = 12, tweak: (inout TakionConfiguration) -> Void = { _ in }) {
        var configuration = TakionConfiguration()
        configuration.version = version
        configuration.clientTag = TakionVec.clientTag
        tweak(&configuration)
        connection = TakionConnection(configuration: configuration, transport: transport, delegate: delegate)
        console.emit = { [unowned self] in outbox.append($0) }
    }

    /// Lets the console see everything sent so far and delivers its answers, until nothing is left.
    func pump() {
        var rounds = 0
        while rounds < 50 {
            rounds += 1
            let sent = transport.sent
            guard processed < sent.count || !outbox.isEmpty else { break }
            for d in sent[processed...] { console.handle(d) }
            processed = sent.count
            let toDeliver = outbox
            outbox = []
            for d in toDeliver { deliver(d) }
        }
    }

    func deliver(_ bytes: [UInt8], at time: UInt64? = nil) {
        var copy = bytes
        let stamp = time ?? takionNow()
        copy.withUnsafeMutableBytes { connection.transportDidReceive($0, at: stamp) }
    }

    func handshake(secure: Bool = false) throws {
        try connection.connect()
        pump()
        guard delegate.connected else { throw SupportError("the Takion handshake didn't complete") }
        if secure {
            console.secure()
        }
    }

    /// The client's datagrams sent after the first `n`.
    func sent(after n: Int) -> [[UInt8]] { Array(transport.sent.dropFirst(n)) }
}

/// A UDP socket on 127.0.0.1 that plays the console for the real transports.
final class UDPConsoleLink: @unchecked Sendable {
    let console: FakeTakionConsole
    private let fd: Int32
    let port: UInt16
    private let lock = NSLock()
    private var peer = sockaddr_in()
    private var havePeer = false
    private var running = true
    private var thread: Thread?
    private let done = DispatchSemaphore(value: 0)
    /// Datagrams to hold back from the client (tests drop by not sending; this just counts what was sent).
    private(set) var emitted = 0
    private var tasks: [() -> Void] = []
    /// Internet play: the punched socket this link shares with the other console of the pair (see `PunchedUDPEndpoint`).
    private let endpoint: PunchedUDPEndpoint?

    /// A link that talks through `endpoint`'s socket instead of one of its own; the endpoint's thread feeds it.
    init(console: FakeTakionConsole, endpoint: PunchedUDPEndpoint) {
        self.console = console
        self.endpoint = endpoint
        fd = -1
        port = endpoint.port
        console.emit = { [unowned self] in send($0) }
    }

    init(console: FakeTakionConsole) throws {
        endpoint = nil
        self.console = console
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { throw FailureKind(errno: errno) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw FailureKind(errno: errno) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &length) } }
        var timeout = timeval(tv_sec: 0, tv_usec: 20_000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        fd = s
        port = UInt16(bigEndian: addr.sin_port)
        console.emit = { [unowned self] in send($0) }
        let thread = Thread { [self] in loop() }
        thread.start()
        self.thread = thread
    }

    func send(_ bytes: [UInt8]) {
        if let endpoint {
            endpoint.send(bytes)
            lock.lock(); emitted += 1; lock.unlock()
            return
        }
        lock.lock()
        let target = peer
        let ok = havePeer
        lock.unlock()
        guard ok else { return }
        var to = target
        // Loopback only: the peer is whoever sent to our 127.0.0.1 socket.
        guard to.sin_addr.s_addr == inet_addr("127.0.0.1") else {
            loopbackViolation("fake console would send to a non-loopback address")
        }
        _ = withUnsafePointer(to: &to) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        lock.lock(); emitted += 1; lock.unlock()
    }

    /// Runs `block` on the link's own thread (where the console's state is otherwise only touched), within 20 ms.
    func perform(_ block: @escaping () -> Void) {
        if let endpoint { endpoint.perform(block); return }
        lock.lock(); tasks.append(block); lock.unlock()
    }

    private func loop() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            lock.lock(); let go = running; let due = tasks; tasks = []; lock.unlock()
            for task in due { task() }
            if !go { break }
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            if n < 0 { continue }
            lock.lock(); peer = from; havePeer = true; lock.unlock()
            console.handle(Array(buffer[0..<n]))
        }
        done.signal()
    }

    func stop() {
        if endpoint != nil { return }
        lock.lock(); running = false; lock.unlock()
        done.wait()
        close(fd)
    }
}

/// Polls `condition` for up to `seconds`.
func eventually(_ seconds: Double = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        usleep(2000)
    }
    return condition()
}

/// A congestion source that returns what the test sets.
final class FakeCongestionSource: CongestionSource, @unchecked Sendable {
    private let lock = NSLock()
    private var inputs = CongestionInputs()
    private(set) var calls = 0
    func set(_ new: CongestionInputs) { lock.lock(); inputs = new; lock.unlock() }
    func congestionInputs() -> CongestionInputs {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        let current = inputs
        inputs.videoReceived = 0
        inputs.videoLost = 0
        return current
    }
}
