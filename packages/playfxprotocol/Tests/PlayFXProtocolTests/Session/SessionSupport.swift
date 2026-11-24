import Foundation
import Testing

@testable import PlayFXProtocol

// Test-side support for StreamSession: a whole fake console on 127.0.0.1 (session init and ctrl over TCP, the
// probe port and the stream port over UDP), written from the spec bytes, and a recorder for the session's events.

/// The session tests open real sockets and threads; running them one after the other (rather than alongside each
/// other and the rest of the suite) keeps the timing-sensitive tests elsewhere steady.
@Suite(.serialized) enum StreamSessionSuites {}

// MARK: Spec bytes

enum SessionBytes {
    /// V-ST6: a StreamInfo with two profiles and the console's 14-byte audio header.
    static let streamInfo = hex("""
        080d 7a35
        0a11 08800f 10b808 1a09 000000014201010160
        0a10 08800a 10d005 1a08 0000000142010101
        120e 02 10 0000bb80 000001e0 00000001
        """)
    static let streamInfoBadAudio = hex("080d 7a21 0a11 08800f 10b808 1a09 000000014201010160 120c 02 10 0000bb80 000001e0 0000")
    static let dummyProfile0Header = hex("000000014201010160")

    /// V-ST5, with the accepted flags chosen.
    static func helloReply(versionAccepted: Bool = true, keyAccepted: Bool = true, key: Bool = true) -> [UInt8] {
        let flags = hex(keyAccepted ? "1801" : "1800") + hex(versionAccepted ? "2001" : "2000")
        var tail = hex("2a00")
        if key { tail += hex("4241") + StreamInputs.publicB + hex("4a20") + StreamInputs.signatureB }
        let payload = hex("080c 10f8acd19101") + flags + tail
        return hex("0801 1a") + [UInt8(payload.count)] + payload
    }

    static func disconnect(_ text: String) -> [UInt8] {
        let inner = [UInt8(0x0a), UInt8(text.utf8.count)] + Array(text.utf8)
        return [0x08, 0x08, 0x52, UInt8(inner.count)] + inner
    }

    static let serverShuttingDown = hex("080852160a14536572766572207368757474696e6720646f776e")
    static let transportVersionAck = hex("08 20 82 02 02 08 09")
    static let probeHelloReply = hex("08 01 1a 0a 08 0c 10 00 18 01 20 01 2a 00")
    static let clientMtuAnswer = hex("080c720e08042a0a080110ae0b180120ae0b")
    static let rumble = hex("008040")
    static let triggers = hex("00 25 26 0000 0102030405060708090a 1112131415161718191a")
    static let pad25 = hex("0102 0000 00000007 01 ff74a6 01 00000000000000 02 03 000000")
    static let pad17 = hex("02 0000ff 00 00000000000000 03 00 000000")
    /// The idle feedback-state body of a PS5 (V-ST9).
    static let idleState = hex("a0 ff7f ff7f ff7f ff7f 9999 ff7f fef7ef1f 0000 0000 0000 0000 000001")
    static let heartbeat = hex("0803")
    static let streamInfoAck = hex("080e")
    static let controllerConnectionDualSense = hex("0815b2010410011806")
    static let micStreamInfo = hex("080d7a10120e01100000bb80000001e000000001")
    static let clientDisconnect = hex("080852160a14436c69656e7420446973636f6e6e656374696e67")
}

// MARK: The real capture

struct CaptureUnit {
    var packetIndex: UInt16
    var frame: UInt16
    var index: Int
    var total: Int
    var fec: Int
    var payload: [UInt8]
}

/// The 20 units of av.md V-AV7, in order.
func loadCapture() throws -> [CaptureUnit] {
    let url = try #require(Bundle.module.url(forResource: "av-capture-h264", withExtension: "txt", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").filter { !$0.hasPrefix("#") }.map { line in
        let f = line.split(separator: " ")
        return CaptureUnit(
            packetIndex: UInt16(f[1])!, frame: UInt16(f[2])!, index: Int(f[3])!, total: Int(f[4])!, fec: Int(f[5])!,
            payload: hex(String(f[6])))
    }
}

/// av.md V-AV7's access units.
let captureExpected: [UInt16: (length: Int, head: String, sha: String)] = [
    1: (103, "00000001658880867f002fc803ff087e", "7cfcb4169c975d5ff1f6120c2239b9564b5530811c76fe31be79c0fc99fb2982"),
    2: (15995, "00000001419a04422f9fe004a404fffc", "02b08cbe0820d13393ea93d17c551a8291bcdbefaf8a76d4c209129306ae5dc6"),
]

// MARK: Reassembling what the client sends

/// A client data message put back together from its chunks (flags 0 = more follows, 1 = last).
struct ClientMessage: Equatable {
    var channel: UInt16
    var dataType: UInt8
    var bytes: [UInt8]
    /// Chunks it took.
    var chunks: [(length: Int, flags: UInt8, continuation: Bool)]

    static func == (a: ClientMessage, b: ClientMessage) -> Bool {
        a.channel == b.channel && a.dataType == b.dataType && a.bytes == b.bytes
    }
}

struct ClientMessageAssembler {
    private var open: ClientMessage?
    /// TSNs seen: a retransmitted chunk (its ack was late) is not a new message.
    private var seen = Set<UInt32>()

    /// Feeds one client datagram; returns the message when its last chunk arrives.
    mutating func feed(_ d: [UInt8]) -> ClientMessage? {
        guard d.count >= 26, d[0] & 0x0f == 0, d[13] == 0x00, seen.insert(readBE32(d, 17)).inserted else { return nil }
        let flags = d[14]
        if var message = open {
            message.bytes += d[25...]
            message.chunks.append((d.count - 25, flags, true))
            open = flags & 1 == 1 ? nil : message
            return flags & 1 == 1 ? message : nil
        }
        let message = ClientMessage(
            channel: readBE16(d, 21), dataType: d[25], bytes: Array(d[26...]), chunks: [(d.count - 26, flags, false)])
        if flags & 1 == 1 { return message }
        open = message
        return nil
    }
}

/// Reads a protobuf varint (the probe messages are small enough to parse by hand).
func readVarint(_ d: [UInt8], _ at: inout Int) -> Int {
    var value = 0
    var shift = 0
    while at < d.count {
        let b = Int(d[at])
        at += 1
        value |= (b & 0x7f) << shift
        if b & 0x80 == 0 { break }
        shift += 7
    }
    return value
}

/// The fields of a protobuf message: number to (varint value or bytes).
func protoFields(_ d: [UInt8]) -> [(number: Int, varint: Int?, bytes: [UInt8]?)] {
    var out: [(Int, Int?, [UInt8]?)] = []
    var at = 0
    while at < d.count {
        let tag = readVarint(d, &at)
        if tag & 7 == 0 {
            out.append((tag >> 3, readVarint(d, &at), nil))
        } else {
            let length = readVarint(d, &at)
            out.append((tag >> 3, nil, Array(d[at..<min(at + length, d.count)])))
            at += length
        }
    }
    return out
}

// MARK: The console

/// How the probe port behaves.
enum ProbeScript {
    /// Answers everything; MTU tests pass up to these IP packet sizes.
    case answers(inLimit: Int, outLimit: Int)
    /// Takion handshake works, then no pong ever comes.
    case noPongs
    /// The socket exists but never answers.
    case silent
}

enum ReplyScript { case accept, versionRejected, keyRejected, noKey, silent, disconnect(String) }
enum InfoScript { case afterReply, beforeReply, never, badAudio, afterHelloAck }

/// A console on 127.0.0.1 for the whole flow.
final class StreamConsole: @unchecked Sendable {
    let ctrl: FakeSessionConsole
    let probeConsole = FakeTakionConsole()
    let streamConsole = FakeTakionConsole()
    let probeLink: UDPConsoleLink
    let streamLink: UDPConsoleLink

    var probeScript = ProbeScript.answers(inLimit: 1400, outLimit: 1300)
    var replyScript = ReplyScript.accept
    var infoScript = InfoScript.afterReply
    /// Indices of units of capture frame 2 never to send.
    var dropUnits: Set<Int> = []
    /// Called just before the StreamInfo goes out with `.afterHelloAck` (the client's ack of the HelloReply is in).
    var beforeStreamInfo: (() -> Void)?
    private var infoPending = false
    /// Send the capture, audio and haptics once the StreamInfoAck arrives.
    var streams = true

    /// What the client sent on the stream connection, in order.
    let messages = Locked<[ClientMessage]>([])
    let probeMessages = Locked<[ClientMessage]>([])
    private var streamAssembler = ClientMessageAssembler()
    private var probeAssembler = ClientMessageAssembler()
    /// Probe pings seen: (unit, datagram length).
    let pings = Locked<[(unit: Int, length: Int)]>([])
    let capture: [CaptureUnit]

    /// Set when the default ctrl script saw the client close the connection.
    let ctrlClosed: Locked<Bool>

    /// `ctrl` replaces the default ctrl conversation (head, session ID, then reading until the client closes).
    init(
        serverType: UInt8 = 2, ctrl custom: (@Sendable (CtrlPeer) -> Void)? = nil,
        initReplies: @escaping @Sendable (Int) -> FakeSessionConsole.InitReply = { _ in .nonce }
    ) throws {
        capture = try loadCapture()
        let closed = Locked(false)
        ctrlClosed = closed
        ctrl = FakeSessionConsole(
            ctrl: { peer, _ in
                if let custom {
                    custom(peer)
                    closed.with { $0 = true }
                    return
                }
                peer.sendHead(serverType: serverType)
                peer.send(0x33, sessionIDPlain)
                peer.pump(limit: 30)
                closed.with { $0 = true }
            }, initReplies: initReplies)
        probeLink = try UDPConsoleLink(console: probeConsole)
        streamLink = try UDPConsoleLink(console: streamConsole)
        probeConsole.adoptsClientTag = true
        streamConsole.adoptsClientTag = true
        probeConsole.onPacket = { [unowned self] in handleProbe($0) }
        streamConsole.onPacket = { [unowned self] in handleStream($0) }
    }

    private let streamLinkStopped = Locked(false)

    /// Stops the stream port's socket (the console "goes away"); `stop` doesn't stop it again.
    func stopStreamLink() {
        if streamLinkStopped.with({ let was = $0; $0 = true; return was }) { return }
        streamLink.stop()
    }

    private let probeLinkStopped = Locked(false)

    /// Stops the probe port's socket; call from a thread other than the link's own.
    func stopProbeLink() {
        if probeLinkStopped.with({ let was = $0; $0 = true; return was }) { return }
        probeLink.stop()
    }

    func stop() {
        ctrl.stop()
        stopProbeLink()
        stopStreamLink()
    }

    var ctrlPeer: CtrlPeer? { ctrl.peers.with { $0.first } }

    // MARK: Probe port

    private func probeSend(dataType: UInt8 = 0, channel: UInt16 = 1, _ message: [UInt8]) {
        probeLink.send(probeConsole.dataChunk(channel: channel, dataType: dataType, message: message))
    }

    private func handleProbe(_ d: [UInt8]) {
        if d[0] & 0x0f == 3, d.count >= 26 {
            pings.with { $0.append((Int(readBE32(d, 5) >> 21), d.count)) }
            guard case .answers(_, let outLimit) = probeScript, d.count + 28 <= outLimit else { return }  // `.noPongs`: never
            let unit = Int(readBE32(d, 5) >> 21)
            let pong = [0x03] + be16(0) + be16(0) + be32(UInt32(unit) << 21 | 0x7ff << 10) + [0xff] + [UInt8](repeating: 0, count: 8)
                + [0, 0, 0, 0] + be32(readBE32(d, 22)) + [0, 0, 0, 0]
            probeLink.send(pong)
            return
        }
        guard let message = probeAssembler.feed(d) else { return }
        probeMessages.with { $0.append(message) }
        var inLimit = 1400
        switch probeScript {
        case .silent: return
        case .noPongs: break
        case .answers(let limit, _): inLimit = limit
        }
        guard message.dataType == 0 else { return }
        let wrapper = protoFields(message.bytes)
        switch wrapper.first(where: { $0.number == 1 })?.varint {
        case 31: probeSend(SessionBytes.transportVersionAck)
        case 0: probeSend(SessionBytes.probeHelloReply)
        case 12:
            guard let probe = wrapper.first(where: { $0.number == 14 })?.bytes else { return }
            let fields = protoFields(probe)
            switch fields.first(where: { $0.number == 1 })?.varint {
            case 1:
                let mtu = protoFields(fields.first(where: { $0.number == 3 })?.bytes ?? [])
                let id = mtu.first(where: { $0.number == 1 })?.varint ?? 0
                let requested = mtu.first(where: { $0.number == 2 })?.varint ?? 0
                if requested <= inLimit {
                    probeLink.send([0x02] + be16(0) + be16(UInt16(id)) + be32(0) + [0] + be32(0) + be32(0) + be16(0) + [0])
                }
            case 4:
                let client = protoFields(fields.first(where: { $0.number == 5 })?.bytes ?? [])
                if client.first(where: { $0.number == 1 })?.varint == 1 { probeSend(SessionBytes.clientMtuAnswer) }
            default: break
            }
        default: break
        }
    }

    // MARK: Stream port

    /// Sends a data message to the client from the link's own thread.
    func send(dataType: UInt8 = 0, channel: UInt16 = 1, _ message: [UInt8]) {
        streamLink.perform { [self] in
            streamLink.send(streamConsole.dataChunk(channel: channel, dataType: dataType, message: message))
        }
    }

    private func handleStream(_ d: [UInt8]) {
        if infoPending, d.count >= 17, d[0] & 0x0f == 0, d[13] == 0x03 {
            infoPending = false
            beforeStreamInfo?()
            streamLink.send(streamConsole.dataChunk(message: SessionBytes.streamInfo))
        }
        guard let message = streamAssembler.feed(d) else { return }
        messages.with { $0.append(message) }
        let wrapper = message.dataType == 0 ? protoFields(message.bytes) : []
        switch wrapper.first(where: { $0.number == 1 })?.varint {
        case 0: answerHello()
        case 14: if streams { stream() }
        default: break
        }
    }

    private func answerHello() {
        func emit(_ bytes: [UInt8]) { streamLink.send(streamConsole.dataChunk(message: bytes)) }
        if infoScript == .beforeReply { emit(SessionBytes.streamInfo) }
        switch replyScript {
        case .silent: return
        case .accept: emit(SessionBytes.helloReply())
        case .versionRejected: emit(SessionBytes.helloReply(versionAccepted: false))
        case .keyRejected: emit(SessionBytes.helloReply(keyAccepted: false))
        case .noKey: emit(SessionBytes.helloReply(key: false))
        case .disconnect(let text): emit(SessionBytes.disconnect(text))
        }
        // The HelloReply is the bang: everything after it is secured.
        if case .accept = replyScript { streamConsole.secure() }
        switch infoScript {
        case .afterReply: emit(SessionBytes.streamInfo)
        case .badAudio: emit(SessionBytes.streamInfoBadAudio)
        case .afterHelloAck: infoPending = true
        case .beforeReply, .never: break
        }
    }

    /// The capture as encrypted, GMAC'd video packets, then audio and haptics, all from the link thread.
    private func stream() {
        for unit in capture where !(unit.frame == 2 && dropUnits.contains(unit.index)) {
            streamLink.send(streamConsole.av(
                video: true, packetIndex: unit.packetIndex, frameIndex: unit.frame,
                word: videoWord(index: unit.index, total: unit.total, fec: unit.fec), field18: 0x0367, byte20: 0x00,
                payload: unit.payload))
        }
        // Six audio packets (one source and two redundant units of 40 bytes each) and one haptics packet.
        for n in 0..<6 {
            let frame = UInt16(100 + n)
            let payload = (0..<3).flatMap { u in [UInt8](repeating: UInt8(n * 3 + u), count: 40) }
            streamLink.send(streamConsole.av(
                video: false, packetIndex: UInt16(n), frameIndex: frame,
                word: audioWord(total: 3, unitSize: 40, redundant: 2, source: 1), codec: 5, stream: 0, payload: payload))
        }
        streamLink.send(streamConsole.av(
            video: false, packetIndex: 6, frameIndex: 7, word: audioWord(total: 1, unitSize: 12, redundant: 0, source: 1),
            codec: 5, stream: 2, payload: [1, 0, 2, 0, 3, 0, 0xff, 0xff, 0, 0x80, 0x34, 0x12]))
    }

    /// Sends `count` more one-unit video frames (numbered from `first`) from the link's thread, after the capture.
    func sendExtraFrames(first: Int, count: Int) {
        streamLink.perform { [self] in
            for n in 0..<count {
                streamLink.send(streamConsole.av(
                    video: true, packetIndex: UInt16(20 + n), frameIndex: UInt16(first + n),
                    word: videoWord(index: 0, total: 1, fec: 0), field18: 0x0367, byte20: 0,
                    payload: [0, 0, 0, 0, 0, 1, 0x41, 9, 9]))
            }
        }
    }

    /// The two source units of a frame sent by `sendFECFrames` (each starts with its two pad bytes) and the
    /// access unit they make.
    static let fecSourceUnits: [[UInt8]] = [[0, 0, 0, 0, 0, 1, 0x41, 9, 9, 9, 9], [0, 0, 9, 9, 9, 9, 9, 9, 9, 9, 9]]
    static let fecAccessUnit = Array(fecSourceUnits[0].dropFirst(2)) + Array(fecSourceUnits[1].dropFirst(2))

    /// Sends `count` video frames numbered from `first` from the link's thread, each of two source units and
    /// `parity` parity units made with the package's erasure code (`ReferenceFEC`, written separately from the
    /// decoder), after the capture. Packet indices continue from one call to the next.
    func sendFECFrames(first: Int, count: Int, parity: Int = 4) {
        let units = Self.fecSourceUnits + ReferenceFEC.encode(source: Self.fecSourceUnits, m: parity)
        streamLink.perform { [self] in
            for n in 0..<count {
                for (u, payload) in units.enumerated() {
                    streamLink.send(streamConsole.av(
                        video: true, packetIndex: nextFECPacket, frameIndex: UInt16(first + n),
                        word: videoWord(index: u, total: units.count, fec: parity), field18: 0x0367, byte20: 0,
                        payload: payload))
                    nextFECPacket &+= 1
                }
            }
        }
    }

    private var nextFECPacket: UInt16 = 0

    // MARK: Looking at what arrived

    /// The feedback-history packets, each sequence number once (the transport repeats the last one at 20, 50, 100
    /// and 200 ms).
    func historyPackets() -> [ClientPacket] {
        var seen = Set<UInt16>()
        return streamConsole.packets(ofType: 1).filter { seen.insert(readBE16($0.bytes, 1)).inserted }
    }

    /// Client messages on the stream connection with this channel, in order.
    func received(channel: UInt16) -> [[UInt8]] { messages.with { $0.filter { $0.channel == channel }.map(\.bytes) } }

    func count(_ bytes: [UInt8], channel: UInt16 = 1) -> Int { received(channel: channel).filter { $0 == bytes }.count }

    /// The Hello as one message.
    var hello: ClientMessage? { messages.with { $0.first } }
}

// MARK: Recording events

/// One event as the test sees it: copies of what is only valid during the call, and where it was delivered.
enum Recorded: Equatable {
    case connected(StreamConnectedInfo)
    case audioHeader(AudioHeader)
    case video(bytes: [UInt8], info: VideoFrameInfo)
    case parameterSets(Int, [UInt8])
    case audioPacket(frame: UInt16, bytes: [UInt8])
    case audioLost(UInt16)
    case audioSkipped(UInt16, Int)
    case haptics(UInt16, [Int16])
    case rumble(left: UInt8, right: UInt8)
    case triggers(left: UInt8, right: UInt8)
    case led(UInt8, UInt8, UInt8)
    case playerIndex(UInt8)
    case motionReset
    case quality
    case loginPINRequested
    case loginPINResult(Bool)
    case keyboardOpened(String)
    case keyboardTextChanged(UInt32, String)
    case keyboardClosed
    case stats(StreamStats)
    case ended(StreamEndReason)
}

final class EventRecorder: @unchecked Sendable {
    struct Entry {
        var event: Recorded
        var thread: String
    }

    let entries = Locked<[Entry]>([])
    let session = Locked<StreamSession?>(nil)
    /// Runs for each event after it is recorded, on the thread it was delivered on.
    nonisolated(unsafe) var onEvent: (@Sendable (StreamEvent, StreamSession) -> Void)?

    var handler: @Sendable (StreamEvent, StreamSession) -> Void {
        { [self] event, session in
            let thread = Thread.current.name ?? ""
            let recorded: Recorded
            switch event {
            case .connected(let info): recorded = .connected(info)
            case .audioHeader(let header): recorded = .audioHeader(header)
            case .videoAccessUnit(let bytes, let info): recorded = .video(bytes: Array(bytes), info: info)
            case .parameterSets(let index, let profile, _): recorded = .parameterSets(index, profile.header)
            case .audioPacket(.packet(let frame, let opus)): recorded = .audioPacket(frame: frame, bytes: Array(opus))
            case .audioPacket(.lost(let frame)): recorded = .audioLost(frame)
            case .audioPacket(.skipped(let first, let count)): recorded = .audioSkipped(first, count)
            case .haptics(let frame, let samples): recorded = .haptics(frame, Array(samples))
            case .rumble(let r): recorded = .rumble(left: r.left, right: r.right)
            case .triggerEffects(let t): recorded = .triggers(left: t.leftMode, right: t.rightMode)
            case .ledColor(let r, let g, let b): recorded = .led(r, g, b)
            case .playerIndex(let p): recorded = .playerIndex(p)
            case .motionReset: recorded = .motionReset
            case .connectionQuality: recorded = .quality
            case .loginPINRequested: recorded = .loginPINRequested
            case .loginPINResult(let ok): recorded = .loginPINResult(ok)
            case .keyboardOpened(let text): recorded = .keyboardOpened(text)
            case .keyboardTextChanged(let sequence, let text): recorded = .keyboardTextChanged(sequence, text)
            case .keyboardClosed: recorded = .keyboardClosed
            case .stats(let stats): recorded = .stats(stats)
            case .ended(let reason): recorded = .ended(reason)
            }
            entries.with { $0.append(Entry(event: recorded, thread: thread)) }
            onEvent?(event, session)
        }
    }

    var all: [Recorded] { entries.with { $0.map(\.event) } }

    var ended: [StreamEndReason] { all.compactMap { if case .ended(let r) = $0 { r } else { nil } } }

    var videoFrames: [(bytes: [UInt8], info: VideoFrameInfo)] {
        all.compactMap { if case .video(let b, let i) = $0 { (b, i) } else { nil } }
    }

    var stats: [StreamStats] { all.compactMap { if case .stats(let s) = $0 { s } else { nil } } }

    func wait(timeout: Double = 5, _ condition: ([Recorded]) -> Bool) async -> Bool {
        await waitUntil(timeout: timeout) { condition(all) }
    }

    func waitForEnd(timeout: Double = 5) async -> StreamEndReason? {
        _ = await wait(timeout: timeout) { $0.contains { if case .ended = $0 { true } else { false } } }
        return ended.first
    }
}

// MARK: Starting a session against the console

/// Settings of the vectors: PS5, 1080p, 60 fps, 15000 kbit/s.
let hevcSettings = StreamSettings(resolution: .p1080, frameRate: .fps60, bitrate: .preset, codec: .hevc, autoDowngrade: false)
let avcSettings = StreamSettings(resolution: .p1080, frameRate: .fps60, bitrate: .preset, codec: .h264, autoDowngrade: false)

/// An environment with real sockets to the fake console only, fast timers and the vector key material.
func loopbackStreamEnvironment(_ console: StreamConsole, tweak: (inout StreamEnvironment) -> Void = { _ in }) -> StreamEnvironment {
    var environment = StreamEnvironment()
    environment.control = .loopback(initPort: console.ctrl.port)
    environment.control.randomBytes = { count in count == 16 ? StreamInputs.handshakeKey : secureRandomBytes(count) }
    environment.probePort = console.probeLink.port
    environment.streamPort = console.streamLink.port
    environment.probe = ProbeTiming(
        connectTimeout: 1, stepTimeout: 0.25, answerTimeout: 1, pongTimeout: 0.3, pings: 3, mtuWaitMinimum: 0.005,
        mtuWaitMaximum: 0.02)
    environment.streamConnectTimeout = 1
    environment.streamStepTimeout = 0.25
    environment.helloReplyTimeout = 1
    environment.streamInfoTimeout = 1
    environment.heartbeatInterval = 0.1
    environment.statsInterval = 0.2
    environment.makeKeyPair = { try vectorKeyPair() }
    environment.makeTransport = { kind, host, port, dontFragment in
        guard isLoopback(host) else {
            Issue.record("test tried to open a transport to non-loopback address \(host)")
            return BSDDatagramTransport(host: "127.0.0.1", port: 9, dontFragment: dontFragment)
        }
        switch kind {
        case .bsd: return BSDDatagramTransport(host: host, port: port, dontFragment: dontFragment)
        case .nw: return NWDatagramTransport(host: host, port: port, dontFragment: dontFragment)
        }
    }
    tweak(&environment)
    return environment
}

func startSession(
    _ console: StreamConsole, recorder: EventRecorder, settings: StreamSettings = avcSettings,
    transport: StreamTransport = .bsd, options: StreamSessionOptions = StreamSessionOptions(),
    tweak: (inout StreamEnvironment) -> Void = { _ in }
) async throws -> StreamSession {
    let session = try await StreamSession.start(
        environment: loopbackStreamEnvironment(console, tweak: tweak), address: "127.0.0.1", target: .ps5v1,
        registKey: SessionVector.registKey, rpKey: SessionVector.rpKey, settings: settings, transport: transport,
        options: options, events: recorder.handler)
    recorder.session.with { $0 = session }
    return session
}

/// The error `start` throws.
func startFailure(
    _ console: StreamConsole, recorder: EventRecorder = EventRecorder(), settings: StreamSettings = avcSettings,
    transport: StreamTransport = .bsd, tweak: (inout StreamEnvironment) -> Void = { _ in }
) async -> StreamStartError? {
    do {
        let session = try await startSession(console, recorder: recorder, settings: settings, transport: transport, tweak: tweak)
        session.stop()
        return nil
    } catch let error as StreamStartError {
        return error
    } catch {
        Issue.record("unexpected error \(error)")
        return nil
    }
}

// MARK: Transport wrappers

/// Fails every send with `FailureKind.disconnected` while `failing` is set.
final class FlakyTransport: DatagramTransport, @unchecked Sendable {
    let inner: DatagramTransport
    let failing: Locked<Bool>
    init(_ inner: DatagramTransport, failing: Locked<Bool>) {
        self.inner = inner
        self.failing = failing
    }
    var name: String { inner.name }
    var localPort: UInt16 { inner.localPort }
    func start(handler: TransportHandler) throws { try inner.start(handler: handler) }
    func send(_ bytes: UnsafeRawBufferPointer) throws {
        if failing.with({ $0 }) { throw FailureKind.disconnected }
        try inner.send(bytes)
    }
    func reschedule() { inner.reschedule() }
    func stop() { inner.stop() }
}

/// Refuses datagrams over `limit` bytes with EMSGSIZE, as a socket with Don't-Fragment does above the local MTU.
final class SizeLimitedTransport: DatagramTransport, @unchecked Sendable {
    let inner: DatagramTransport
    let limit: Int
    init(_ inner: DatagramTransport, limit: Int) {
        self.inner = inner
        self.limit = limit
    }
    var name: String { inner.name }
    var localPort: UInt16 { inner.localPort }
    func start(handler: TransportHandler) throws { try inner.start(handler: handler) }
    func send(_ bytes: UnsafeRawBufferPointer) throws {
        if bytes.count > limit { throw FailureKind.other(errno: EMSGSIZE) }
        try inner.send(bytes)
    }
    func reschedule() { inner.reschedule() }
    func stop() { inner.stop() }
}

/// An environment tweak that wraps the transport made for one port.
func wrapTransport(
    _ env: inout StreamEnvironment, port: UInt16, _ wrap: @escaping @Sendable (DatagramTransport) -> DatagramTransport
) {
    let base = env.makeTransport
    env.makeTransport = { kind, host, p, df in
        let transport = base(kind, host, p, df)
        return p == port ? wrap(transport) : transport
    }
}
