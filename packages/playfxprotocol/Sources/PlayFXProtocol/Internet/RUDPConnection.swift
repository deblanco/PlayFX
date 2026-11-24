import Dispatch
import Foundation

// The RUDP connection over the ctrl hole's connected UDP socket (rudp.md): the handshake before each HTTP-style
// exchange, then ctrl data with retransmission, the switch to the stream, and the end.
//
// Threading (DESIGN.md: control plane, no actors in a packet path): `exchange` runs on the caller's thread and reads
// the socket itself. `startCtrl` starts one receive thread (user-initiated) that reads, acknowledges, delivers
// frames to the handler and retransmits every 200 ms. Sending is safe from any thread.

/// The step that ran out of tries (rudp.md section 10).
public enum RUDPStep: String, Sendable, Equatable {
    case initAck = "INIT_ACK"
    case cookieAck = "COOKIE_ACK"
    case response = "response"
}

/// Why an RUDP operation failed.
public enum RUDPError: Error, Sendable, Equatable {
    /// A step got no answer in its tries.
    case timeout(RUDPStep)
    /// The request or frame doesn't fit one message (4095 bytes with the header).
    case messageTooLarge
    /// The connection was closed, by `close()` or because the console ended ctrl with FINISH.
    case closed
    /// `exchange` was called while ctrl is running, or `startCtrl` twice.
    case wrongState
    /// Receiving failed continuously for 10 s.
    case receiveFailed
    /// An argument that can't be sent (the switch message needs exactly 16 random bytes).
    case invalidArgument
}

/// What the connection reports once ctrl runs.
public enum RUDPEvent: Sendable, Equatable {
    /// One whole ctrl frame (8-byte header and payload) from the console, in arrival order.
    case ctrlFrame([UInt8])
    /// The console sent FINISH: it ended ctrl (rudp.md section 9). No more events follow.
    case finished
    /// The connection gave up. No more events follow.
    case failed(RUDPError)
}

/// How the wait after the switch message ended (rudp.md section 8).
public enum RUDPSwitchOutcome: Sendable, Equatable {
    /// The console's ctrl `0x0034` came.
    case acknowledged
    /// 5 s (or the given time) passed without it.
    case timedOut
    /// The console sent FINISH: it ended ctrl while the client waited.
    case consoleFinished
    /// The connection was closed (a cancel) or gave up receiving.
    case closed
}

/// Timings and limits (rudp.md sections 7.2 and 10), all client choices; tests shorten them.
public struct RUDPTimings: Sendable {
    /// Wait per try for INIT_ACK, COOKIE_ACK, the response and FINISH: 1 s.
    public var stepWait: Double = 1
    /// Tries per step: 3.
    public var tries: Int = 3
    /// A kept message is resent when last sent more than this long ago: 0.4 s.
    public var retransmitAfter: Double = 0.4
    /// How often kept messages are checked: 0.2 s.
    public var retransmitCheck: Double = 0.2
    /// A message is dropped after this many retransmissions: 25.
    public var maxRetransmissions: Int = 25
    /// Messages kept at most: 16.
    public var maxKept: Int = 16
    /// The wait for ctrl `0x0034` after the switch message: 5 s.
    public var switchWait: Double = 5
    /// Continuous receive failure that ends ctrl: 10 s.
    public var receiveFailureLimit: Double = 10

    public init() {}
}

/// Counters for diagnostics.
public struct RUDPStatistics: Sendable, Equatable {
    /// Messages resent.
    public var retransmissions = 0
    /// Messages dropped after the last retransmission.
    public var abandoned = 0
    /// Messages sent but not kept because 16 were kept already.
    public var unkept = 0
    /// Console data messages ignored because their `seq` had been taken.
    public var duplicates = 0
    /// Console data messages dropped by the frame check.
    public var malformed = 0
    /// Ctrl frames delivered.
    public var frames = 0
    /// Datagrams sent and received on the socket, and console messages of a type this client has no meaning for
    /// (rudp.md section 2), for the trace.
    public var datagramsOut = 0
    public var datagramsIn = 0
    public var unknownTypes = 0
    /// Retransmissions by what was resent (`ctrl frame 0x01fe`, `switch message`), to see which kinds the console
    /// doesn't acknowledge, or acknowledges late.
    public var retransmissionsByKind: [String: Int] = [:]
}

/// One datagram as a line of the RUDP trace (`PLAYFX_RUDP_TRACE`): each message in it with its type, `seq` and `ack`
/// where the type has them, its length, and the first 24 bytes of its data in hex, and nothing past that. Nothing here
/// reads a key: the data of a request or response starts with `seq` and the first characters of an HTTP line, and
/// frames are encrypted.
enum RUDPTrace {
    static let dataLimit = 24
    /// A message the frame check dropped is logged with up to this many bytes of data (it is ctrl-encrypted or tiny).
    static let droppedLimit = 64

    static func name(_ flags: UInt8) -> String? {
        switch flags {
        case 0x80: "INIT"
        case 0xD0: "INIT_ACK"
        case 0x90: "COOKIE"
        case 0xA0: "COOKIE_ACK"
        case 0x20: "REQUEST"
        case 0x02: "DATA"
        case 0x24: "ACK"
        case 0x12: "DATA/12"
        case 0x26: "DATA/26"
        case 0x36: "DATA/36"
        case 0xC0: "FINISH"
        default: nil
        }
    }

    static func hex(_ bytes: ArraySlice<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func describe(_ datagram: [UInt8]) -> String {
        let messages = RUDPFraming.parse(datagram)
        guard !messages.isEmpty else {
            return "\(datagram.count) bytes, not RUDP: \(hex(datagram.prefix(8)))"
        }
        let parts = messages.map { message -> String in
            let flags = message.flags
            var text = name(flags) ?? String(format: "unknown 0x%04x", message.type)
            if let seq = message.peerSeq { text += String(format: " seq=0x%04x", seq) }
            if message.data.count >= 4, [0x20, 0x24, 0x12, 0x26, 0x36].contains(flags) || name(flags) == nil {
                text += String(format: " ack=0x%04x", UInt16(message.data[2]) << 8 | UInt16(message.data[3]))
            }
            let data = message.data
            text += " data \(data.count) bytes"
            if !data.isEmpty { text += ": " + hex(data.prefix(dataLimit)) + (data.count > dataLimit ? "..." : "") }
            return text
        }
        return "\(datagram.count) bytes, \(messages.count) message(s): " + parts.joined(separator: " | ")
    }
}

/// RUDP over one connected UDP socket.
public final class RUDPConnection: @unchecked Sendable {
    private struct Kept {
        var key: UInt16
        var bytes: [UInt8]
        var lastSent: Double
        var retransmissions: Int
        /// What it is, for the trace and the statistics.
        var label: String
    }

    private let socket: any UDPPunchSocket
    private let timings: RUDPTimings
    private let tag: UInt32
    private let random: @Sendable (Int) -> [UInt8]
    private let traceSink: (@Sendable (String) -> Void)?
    private let log: (@Sendable (String) -> Void)?
    private let created = monotonicSeconds()
    private var droppedLogged = 0
    private let lock = NSLock()
    private var localSeq: UInt16
    private var kept: [Kept] = []
    private var backlog: [RUDPMessage] = []
    private var seen = Set<UInt16>()
    private var seenOrder: [UInt16] = []
    private var counters = RUDPStatistics()
    private var closed = false
    /// The console's FINISH or a failure ended ctrl: nothing more can be sent.
    private var finished = false
    private var ctrlRunning = false
    private var receiveThread: Thread?
    private var receiveThreadExited = false
    private var awaitingSwitch = false
    private var switchAcknowledged = false
    private var switchEnd: RUDPSwitchOutcome?
    private let switchSignal = DispatchSemaphore(value: 0)
    private let exited = DispatchSemaphore(value: 0)
    private var handler: (@Sendable (RUDPEvent) -> Void)?

    /// - Parameters:
    ///   - socket: the ctrl hole's connected socket. Closed by `close()`.
    ///   - initialSeq: the first sequence value; random in `0x01FF...0x5FFE` by default (rudp.md section 4.1).
    ///   - tag: the 32-bit tag; random plus `0x8000` by default (section 4.2).
    ///   - random: secure random bytes for the switch message.
    ///   - log: lines that are always wanted, few: a console message the frame check dropped, with its data.
    ///   - trace: one line per datagram in and out, per ctrl frame and per message the frame check drops (`RUDPTrace`).
    public init(socket: any UDPPunchSocket, timings: RUDPTimings = RUDPTimings(), initialSeq: UInt16? = nil,
                tag: UInt32? = nil,
                random: @escaping @Sendable (Int) -> [UInt8] = { n in (0..<n).map { _ in UInt8.random(in: 0...255) } },
                trace: (@Sendable (String) -> Void)? = nil, log: (@Sendable (String) -> Void)? = nil) {
        self.traceSink = trace
        self.log = log
        self.socket = socket
        self.timings = timings
        self.random = random
        localSeq = initialSeq ?? UInt16(UInt32.random(in: 0...UInt32.max) % 0x5E00 + 0x01FF)
        self.tag = tag ?? UInt32.random(in: 0...UInt32.max) &+ 0x8000
    }

    deinit { socket.close() }

    /// A trace line, with the seconds since this connection was made.
    private func trace(_ line: @autoclosure () -> String) {
        guard let traceSink else { return }
        traceSink(String(format: "[+%.3f] ", monotonicSeconds() - created) + line())
    }

    /// Whether the ctrl receive thread is running (false before `startCtrl` and after it has ended).
    var isReceiveThreadRunning: Bool { lock.withLock { ctrlRunning && !receiveThreadExited } }

    /// Diagnostics counters.
    public var statistics: RUDPStatistics { lock.withLock { counters } }

    // MARK: HTTP-style exchange (rudp.md sections 5 and 6)

    /// One exchange: the handshake, the request, the response, the ACK and, with `expectFinish`, the console's FINISH
    /// (registration and session init). For the ctrl start request pass `expectFinish: false`: the channel then goes
    /// on, and `startCtrl` continues it.
    ///
    /// - Returns: the response: data bytes 2... of the console's DATA message (the HTTP header and body; for ctrl, any
    ///   bytes after the header are already binary ctrl frames).
    public func exchange(request: [UInt8], expectFinish: Bool) throws -> [UInt8] {
        guard request.count + 2 <= RUDPFraming.maxDataLength else { throw RUDPError.messageTooLarge }
        try lock.withLock {
            guard !closed else { throw RUDPError.closed }
            guard !ctrlRunning else { throw RUDPError.wrongState }
            // A new handshake starts the console's numbering afresh as far as is known: forget the old seqs.
            seen = []
            seenOrder = []
        }
        let cookie = try handshakeInit()
        let peerNext = try handshakeCookie(cookie)
        var response: (seq: UInt16, body: [UInt8])?
        for _ in 0..<timings.tries where response == nil {
            let seq = takeSeq()
            send(RUDPFraming.requestDatagram(seq: seq, ack: peerNext, request: request))
            response = awaitMessage(timings.stepWait) { m in
                guard m.flags & 0x0f == 0x2 || m.flags & 0x0f == 0x6, m.data.count >= 2 else { return nil }
                return (m.peerSeq ?? 0, Array(m.data[2...]))
            }
        }
        guard let response else {
            try ensureOpen()
            throw RUDPError.timeout(.response)
        }
        markSeen(response.seq)
        let ack = lock.withLock { RUDPFraming.ackMessage(seq: localSeq, ack: response.seq &+ 1) }
        send(ack)
        if expectFinish {
            // Up to three waits of 1 s, the identical ACK resent between them (rudp.md section 10).
            for attempt in 0..<timings.tries {
                if awaitMessage(timings.stepWait, { $0.flags == 0xC0 ? true : nil }) != nil { break }
                try ensureOpen()
                if attempt < timings.tries - 1 { send(ack) }
            }
        }
        return response.body
    }

    private func ensureOpen() throws {
        if lock.withLock({ closed }) { throw RUDPError.closed }
    }

    private func handshakeInit() throws -> [UInt8] {
        for _ in 0..<timings.tries {
            send(RUDPFraming.initMessage(seq: takeSeq(), tag: tag))
            // A cookie too long to send back is no INIT_ACK we can use.
            if let cookie = awaitMessage(timings.stepWait, { m in
                m.flags == 0xD0 && m.data.count >= 8 && m.data.count - 8 <= RUDPFraming.maxCookieLength
                    ? Array(m.data[8...]) : nil
            }) { return cookie }
            try ensureOpen()
        }
        throw RUDPError.timeout(.initAck)
    }

    private func handshakeCookie(_ cookie: [UInt8]) throws -> UInt16 {
        for _ in 0..<timings.tries {
            guard let message = RUDPFraming.cookieMessage(seq: takeSeq(), tag: tag, cookie: cookie) else {
                throw RUDPError.messageTooLarge
            }
            send(message)
            if let peerSeq = awaitMessage(timings.stepWait, { m in m.flags == 0xA0 ? m.peerSeq : nil }) {
                return peerSeq &+ 1
            }
            try ensureOpen()
        }
        throw RUDPError.timeout(.cookieAck)
    }

    /// Reads datagrams until `pick` accepts a message or `timeout` passes. Messages that follow the accepted one in
    /// its datagram are kept for ctrl; messages of another kind are dropped (a tolerant receiver, rudp.md section 10).
    private func awaitMessage<T>(_ timeout: Double, _ pick: (RUDPMessage) -> T?) -> T? {
        let deadline = monotonicSeconds() + timeout
        var pending = lock.withLock { () -> [RUDPMessage] in
            defer { backlog = [] }
            return backlog
        }
        while true {
            for (index, message) in pending.enumerated() {
                if let value = pick(message) {
                    lock.withLock { backlog = Array(pending[(index + 1)...]) + backlog }
                    return value
                }
            }
            let remaining = deadline - monotonicSeconds()
            // Short slices, so that close() ends the wait at once.
            if remaining <= 0 || lock.withLock({ closed }) { return nil }
            do {
                guard let packet = try socket.receive(timeout: min(remaining, 0.05)) else {
                    pending = []
                    continue
                }
                received(packet.bytes)
                pending = RUDPFraming.parse(packet.bytes)
            } catch {
                pending = []
                sleepSeconds(0.01)
            }
        }
    }

    // MARK: Ctrl (rudp.md section 7)

    /// Starts the receive thread: from now on every ctrl frame, the console's FINISH and a failure go to `handler`
    /// on that thread (so it must be quick), after the `exchange` that sent the ctrl start request.
    public func startCtrl(handler: @escaping @Sendable (RUDPEvent) -> Void) throws {
        let initial = try lock.withLock { () -> [RUDPMessage] in
            guard !closed else { throw RUDPError.closed }
            guard !ctrlRunning else { throw RUDPError.wrongState }
            ctrlRunning = true
            self.handler = handler
            defer { backlog = [] }
            return backlog
        }
        // The thread holds the connection only while it runs one step, so a connection that is dropped without
        // `close()` ends the thread (and `deinit` closes the socket).
        let state = LoopState(initial: initial, now: monotonicSeconds())
        let exited = exited
        let thread = Thread { [weak self] in
            while let connection = self, connection.step(state) {}
            self?.lock.withLock { self?.receiveThreadExited = true }
            exited.signal()
        }
        thread.name = "PlayFXProtocol.rudp"
        thread.qualityOfService = .userInitiated
        lock.withLock { receiveThread = thread }
        thread.start()
    }

    /// Sends one ctrl frame (rudp.md section 7.1): one DATA message, kept for retransmission until acknowledged.
    /// A 17th message while 16 are kept is sent once and not kept. Throws `.closed` after `close()` and after the
    /// console's FINISH. Callers serialise their frames: the `seq` is assigned under a lock but the datagram is sent
    /// after it, so two threads could put two frames on the wire in the other order.
    public func sendCtrlFrame(_ frame: [UInt8]) throws {
        guard frame.count + 2 <= RUDPFraming.maxDataLength else { throw RUDPError.messageTooLarge }
        let label = frame.count >= 6 ? String(format: "ctrl frame 0x%02x%02x", frame[4], frame[5]) : "ctrl frame"
        try sendKept(label: label) { RUDPFraming.dataMessage(seq: $0, payload: frame) }
    }

    /// Sends the switch-to-stream message (rudp.md section 8) with 16 random bytes (or `random`). The console's ctrl
    /// `0x0034` answer is awaited with `waitForSwitchAcknowledgement`.
    public func sendSwitch(random bytes: [UInt8]? = nil) throws {
        let payload = bytes ?? random(16)
        guard payload.count == 16 else { throw RUDPError.invalidArgument }
        lock.withLock { awaitingSwitch = true }
        try sendKept(label: "switch message") { RUDPFraming.switchMessage(seq: $0, random: payload) ?? [] }
    }

    /// Waits for the console's ctrl frame of type `0x0034` after `sendSwitch` (5 s by default); false on timeout.
    public func waitForSwitchAcknowledgement(timeout: Double? = nil) -> Bool {
        waitForSwitch(timeout: timeout) == .acknowledged
    }

    /// Like `waitForSwitchAcknowledgement`, but says why it ended: a closed connection, a failed receive or the
    /// console's FINISH end the wait at once instead of at the timeout.
    public func waitForSwitch(timeout: Double? = nil) -> RUDPSwitchOutcome {
        let deadline = monotonicSeconds() + (timeout ?? timings.switchWait)
        while true {
            let (acknowledged, end) = lock.withLock { (switchAcknowledged, switchEnd) }
            if acknowledged { return .acknowledged }
            if let end { return end }
            let remaining = deadline - monotonicSeconds()
            if remaining <= 0 { return .timedOut }
            _ = switchSignal.wait(timeout: .now() + remaining)
        }
    }

    /// Records why the switch wait must stop and wakes it.
    private func endSwitchWait(_ outcome: RUDPSwitchOutcome) {
        lock.withLock { if switchEnd == nil { switchEnd = outcome } }
        switchSignal.signal()
    }

    private func sendKept(label: String, _ build: (UInt16) -> [UInt8]) throws {
        let bytes: [UInt8] = try lock.withLock {
            guard !closed, !finished else { throw RUDPError.closed }
            let seq = localSeq
            localSeq &+= 1
            let bytes = build(seq)
            if kept.count < timings.maxKept {
                kept.append(Kept(key: seq &+ 1, bytes: bytes, lastSent: monotonicSeconds(), retransmissions: 0, label: label))
            } else {
                counters.unkept += 1
            }
            return bytes
        }
        send(bytes)
    }

    /// What the receive thread keeps between steps.
    private final class LoopState: @unchecked Sendable {
        var initial: [RUDPMessage]
        var lastCheck: Double
        var failingSince: Double?
        init(initial: [RUDPMessage], now: Double) {
            self.initial = initial
            lastCheck = now
        }
    }

    /// One turn of the receive thread: false when it should end.
    private func step(_ state: LoopState) -> Bool {
        if lock.withLock({ closed }) { return false }
        if !state.initial.isEmpty {
            let messages = state.initial
            state.initial = []
            for message in messages where !handle(message) { return false }
        }
        do {
            if let packet = try socket.receive(timeout: 0.05) {
                received(packet.bytes)
                for message in RUDPFraming.parse(packet.bytes) where !handle(message) { return false }
            }
            state.failingSince = nil
        } catch {
            let now = monotonicSeconds()
            state.failingSince = state.failingSince ?? now
            if now - (state.failingSince ?? now) >= timings.receiveFailureLimit {
                lock.withLock { finished = true }
                endSwitchWait(.closed)
                emit(.failed(.receiveFailed))
                return false
            }
            sleepSeconds(0.05)
        }
        let now = monotonicSeconds()
        if now - state.lastCheck >= timings.retransmitCheck {
            state.lastCheck = now
            retransmit(now: now)
        }
        return true
    }

    /// Rudp.md section 7.2: resend what is older than 400 ms, drop what has been resent 25 times.
    private func retransmit(now: Double) {
        let due: [(bytes: [UInt8], note: String)] = lock.withLock {
            var resend: [(bytes: [UInt8], note: String)] = []
            var remaining: [Kept] = []
            for var item in kept {
                if now - item.lastSent > timings.retransmitAfter {
                    if item.retransmissions >= timings.maxRetransmissions {
                        counters.abandoned += 1
                        resend.append(([], "gave up on \(item.label), key 0x\(String(item.key, radix: 16)), after \(item.retransmissions) retransmission(s)"))
                        continue
                    }
                    item.retransmissions += 1
                    counters.retransmissions += 1
                    counters.retransmissionsByKind[item.label, default: 0] += 1
                    resend.append((item.bytes, String(format: "retransmitting %@ (key 0x%04x), attempt %d, %.2f s since it was last sent",
                                                    item.label, item.key, item.retransmissions, now - item.lastSent)))
                    item.lastSent = now
                }
                remaining.append(item)
            }
            kept = remaining
            return resend
        }
        for item in due {
            trace("rudp: " + item.note)
            if !item.bytes.isEmpty { send(item.bytes) }
        }
    }

    /// One received message (rudp.md section 7.3). False when ctrl has ended.
    private func handle(_ message: RUDPMessage) -> Bool {
        let flags = message.flags
        if flags == 0xC0 {
            lock.withLock { finished = true }
            endSwitchWait(.consoleFinished)
            emit(.finished)
            return false
        }
        let data = message.data
        guard data.count >= 4, let peerSeq = message.peerSeq else { return true }
        let ackField = UInt16(data[2]) << 8 | UInt16(data[3])
        let offset: Int
        switch flags {
        case 0x24:
            release(upTo: ackField)
            return true
        case 0x02: offset = 2
        case 0x12:
            release(upTo: ackField)
            offset = 8
        case 0x26:
            release(upTo: ackField)
            offset = 6
        case 0x36:
            release(upTo: ackField)
            offset = 2
        default: offset = 4
        }
        // Every data message is acknowledged with its own `seq + 1`, duplicates included (the first ACK may be lost).
        let ack = lock.withLock { RUDPFraming.ackMessage(seq: localSeq, ack: peerSeq &+ 1) }
        send(ack)
        guard markSeen(peerSeq) else {
            lock.withLock { counters.duplicates += 1 }
            trace(String(format: "rudp: duplicate data message seq=0x%04x ignored (acknowledged again)", peerSeq))
            return true
        }
        guard data.count >= offset + 8,
              Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
                  == data.count - offset - 8 else {
            lock.withLock { counters.malformed += 1 }
            let line = String(format: "rudp: message 0x%02x seq=0x%04x dropped by the frame check (data %d bytes, frame offset %d): ",
                              flags, peerSeq, data.count, offset) + RUDPTrace.hex(data.prefix(RUDPTrace.droppedLimit))
                + (data.count > RUDPTrace.droppedLimit ? "... (+\(data.count - RUDPTrace.droppedLimit) bytes)" : "")
            trace(line)
            // Always logged (a few times): the layouts of these messages are unknown, and the next run should capture them.
            let first = lock.withLock { () -> Bool in
                droppedLogged += 1
                return droppedLogged <= 20
            }
            if first { log?(line) }
            return true
        }
        let frame = Array(data[offset...])
        let isSwitchAnswer = lock.withLock { () -> Bool in
            counters.frames += 1
            let answer = awaitingSwitch && frame[4] == 0x00 && frame[5] == 0x34
            if answer {
                awaitingSwitch = false
                switchAcknowledged = true
            }
            return answer
        }
        trace(String(format: "rudp: ctrl frame type 0x%02x%02x, payload %d bytes", frame[4], frame[5], frame.count - 8))
        emit(.ctrlFrame(frame))
        if isSwitchAnswer { switchSignal.signal() }
        return true
    }

    private func emit(_ event: RUDPEvent) {
        let target = lock.withLock { handler }
        target?(event)
    }

    /// Releases kept messages whose key is at or below `ack` (16-bit serial-number comparison, RFC 1982).
    private func release(upTo ack: UInt16) {
        let released = lock.withLock { () -> [String] in
            var names: [String] = []
            kept.removeAll { item in
                let credited = item.key == ack || (1...32767).contains(ack &- item.key)
                if credited { names.append(String(format: "%@ (key 0x%04x, %d retransmission(s))", item.label, item.key, item.retransmissions)) }
                return credited
            }
            return names
        }
        if !released.isEmpty { trace(String(format: "rudp: ack 0x%04x credits ", ack) + released.joined(separator: ", ")) }
    }

    /// Records a console `seq`; false if it was already taken (the last 256 are remembered).
    @discardableResult
    private func markSeen(_ seq: UInt16) -> Bool {
        lock.withLock {
            guard seen.insert(seq).inserted else { return false }
            seenOrder.append(seq)
            if seenOrder.count > 256 { seen.remove(seenOrder.removeFirst()) }
            return true
        }
    }

    private func takeSeq() -> UInt16 {
        lock.withLock {
            defer { localSeq &+= 1 }
            return localSeq
        }
    }

    private func send(_ bytes: [UInt8]) {
        lock.withLock { counters.datagramsOut += 1 }
        trace("rudp out: " + RUDPTrace.describe(bytes))
        try? socket.send(bytes, to: "", port: 0)
    }

    /// A datagram came in: counted, traced, and its messages of a type we don't know counted.
    private func received(_ bytes: [UInt8]) {
        let unknown = RUDPFraming.parse(bytes).filter { RUDPTrace.name($0.flags) == nil }.count
        lock.withLock {
            counters.datagramsIn += 1
            counters.unknownTypes += unknown
        }
        trace("rudp in: " + RUDPTrace.describe(bytes))
    }

    /// Stops the receive thread and closes the socket; an `exchange` in progress ends with `.closed`. There is no RUDP
    /// close message (rudp.md section 9). Safe from the handler too (it doesn't wait for its own thread).
    public func close() {
        let (wasRunning, thread) = lock.withLock { () -> (Bool, Thread?) in
            guard !closed else { return (false, nil) }
            closed = true
            return (ctrlRunning, receiveThread)
        }
        endSwitchWait(.closed)
        if wasRunning && thread !== Thread.current { _ = exited.wait(timeout: .now() + 1) }
        socket.close()
    }
}
