import Darwin
import Foundation

// One Takion connection (takion.md): handshake, reliable data with retransmission, secured AV packets with the
// reorder queue, congestion reports and feedback senders, over a `DatagramTransport`.
//
// Threads. Everything received runs on the transport's receive thread (or queue): the datagram handler, the
// timer wake-ups and the delegate callbacks. That state needs no lock. Everything the caller can touch from other
// threads (sending data and feedback, the send-side crypto context and counters, the retransmit list, deadlines,
// statistics) is behind `lock`, which is never held while calling the delegate.

/// A small `os_unfair_lock` wrapper.
final class UnfairLock: @unchecked Sendable {
    private let pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    init() { pointer.initialize(to: os_unfair_lock()) }
    deinit { pointer.deallocate() }
    @inline(__always) func withLock<R>(_ body: () -> R) -> R {
        os_unfair_lock_lock(pointer)
        defer { os_unfair_lock_unlock(pointer) }
        return body()
    }
}

enum TakionCloseReason: Sendable, Equatable {
    /// `close()` was called.
    case local
    /// The handshake did not finish in time (all tries used or the overall limit passed).
    case handshakeTimeout
    /// The socket failed (for example ICMP port unreachable).
    case socketError(Int32)
}

/// What the layer above implements. All calls come from the receive thread, with no lock held.
protocol TakionDelegate: AnyObject {
    /// The handshake finished.
    func takionConnected()
    func takionClosed(_ reason: TakionCloseReason)
    /// A reliable data message arrived, in order and complete (reassembled when the console fragmented it).
    /// `dataType` is 0 (protobuf stream message), 7, 9 or 0x0b. To switch the crypto on (after the bang), call
    /// `enableCrypto` from this callback: the ack that follows is then the first secured packet.
    func takionData(channel: UInt16, dataType: UInt8, message: UnsafeRawBufferPointer)
    /// An AV packet: header fields and the decrypted payload. Video comes out in packet-index order after the
    /// reorder wait; audio and haptics at once. `receivedAt` is the kernel receive time (`takionNow()` ns).
    func takionAV(_ header: TakionAVHeader, payload: UnsafeMutableRawBufferPointer, receivedAt: UInt64)
    /// The console acknowledged every chunk up to this TSN.
    func takionAcknowledged(through tsn: UInt32)
}

extension TakionDelegate {
    func takionConnected() {}
    func takionClosed(_ reason: TakionCloseReason) {}
    func takionAcknowledged(through tsn: UInt32) {}
}

struct TakionConfiguration: Sendable {
    /// 7 (probe), 9 (PS4) or 12 (PS5).
    var version = 12
    var mtuIn = 1454
    var mtuOut = 1454
    /// Overall limit for the handshake: 5 s on the stream, 30 s on the probe.
    var handshakeTimeout = 5.0
    var stepTimeout = 5.0
    var stepTries = 3
    var retransmitCheck = 0.1
    var retransmitAfter = 0.2
    var maxResends = 25
    var maxUnacked = 1024
    var congestionPeriod = 0.2
    var maxLoss = 0.05
    var feedbackStateInterval = 0.2
    /// Fixed `clientTag` (tests); nil picks a random non-zero one.
    var clientTag: UInt32?
    /// Whether to send congestion reports (the stream connection does, the probe does not).
    var sendsCongestionReports: Bool { version != 7 }
}

final class TakionConnection: TransportHandler, @unchecked Sendable {
    private enum Phase { case new, initSent, cookieSent, connected, closed }

    private struct Unacked {
        var tsn: UInt32
        var bytes: [UInt8]
        var lastSent: UInt64
        var resends: Int
    }

    let configuration: TakionConfiguration
    let clientTag: UInt32
    private let transport: DatagramTransport
    private var delegate: TakionDelegate?

    // MARK: Shared state (lock)
    private let lock = UnfairLock()
    private var phase = Phase.new
    private var consoleTag: UInt32 = 0
    private var cookie: [UInt8] = []
    private var handshakePacket: [UInt8] = []
    private var handshakeDeadline: UInt64 = 0
    private var stepDeadline: UInt64 = 0
    private var stepTriesDone = 0
    private var nextTSN: UInt32
    private var upContext: GKCryptContext?
    private var upKeyPos: UInt64 = 0
    private var pendingDown: GKCryptContext?
    private var unacked: [Unacked] = []
    private var retransmitDue: UInt64 = 0
    private var ackedThrough: UInt32?
    private var congestionDue: UInt64 = 0
    private var stateSequence: UInt16 = 0
    private var lastStateBody: [UInt8]?
    private var stateRepeatDue: UInt64 = 0
    private var eventNumber: UInt16 = 0
    private var recentEvents: [[UInt8]] = []
    private var lastHistory: (sequence: UInt16, byte3: UInt8, body: [UInt8])?
    private var historyBase: UInt64 = 0
    private var historyRepeatsDone = 4
    private static let historyRepeatOffsets: [UInt64] = [20_000_000, 50_000_000, 100_000_000, 200_000_000]
    private var fatalSendError: Int32?
    private var published = TakionStats()
    private var sendStats = TakionStats()

    // MARK: Receive-thread state
    private var downContext: GKCryptContext?
    private var keyPosReference: UInt64 = 0
    private var rx = TakionStats()
    private var rxNext: UInt32 = 0
    private let windowBytes: UnsafeMutableRawPointer
    private let windowLengths: UnsafeMutablePointer<Int>
    private let windowFilled: UnsafeMutablePointer<Bool>
    private var assembling = false
    private var assemblyType: UInt8 = 0
    private var assemblyChannel: UInt16 = 0
    private var assembly: [UInt8] = []
    private static let maxAssembly = 4 << 20
    private static let heldSlots = 32
    private let heldBytes: UnsafeMutableRawPointer
    private let heldLengths: UnsafeMutablePointer<Int>
    private let heldTimes: UnsafeMutablePointer<UInt64>
    private var heldCount = 0
    private let reorder = VideoReorderQueue()
    private var congestionReporter = CongestionReporter()
    private var congestionSource: CongestionSource?

    init(configuration: TakionConfiguration, transport: DatagramTransport, delegate: TakionDelegate) {
        self.configuration = configuration
        self.transport = transport
        self.delegate = delegate
        var tag = configuration.clientTag ?? UInt32.random(in: 1...UInt32.max)
        if tag == 0 { tag = 1 }
        clientTag = tag
        nextTSN = tag
        let window = TakionConstants.receiveWindow
        windowBytes = .allocate(byteCount: window * TakionConstants.maxDatagram, alignment: 16)
        windowLengths = .allocate(capacity: window)
        windowLengths.initialize(repeating: 0, count: window)
        windowFilled = .allocate(capacity: window)
        windowFilled.initialize(repeating: false, count: window)
        heldBytes = .allocate(byteCount: Self.heldSlots * TakionConstants.maxDatagram, alignment: 16)
        heldLengths = .allocate(capacity: Self.heldSlots)
        heldLengths.initialize(repeating: 0, count: Self.heldSlots)
        heldTimes = .allocate(capacity: Self.heldSlots)
        heldTimes.initialize(repeating: 0, count: Self.heldSlots)
    }

    deinit {
        windowBytes.deallocate()
        windowLengths.deallocate()
        windowFilled.deallocate()
        heldBytes.deallocate()
        heldLengths.deallocate()
        heldTimes.deallocate()
    }

    // MARK: Public API

    /// Opens the socket and starts the handshake. The delegate hears `takionConnected` or `takionClosed`.
    func connect() throws {
        defer { checkSendFailure() }
        let now = takionNow()
        lock.withLock {
            phase = .initSent
            handshakeDeadline = now + Self.nanos(configuration.handshakeTimeout)
            stepDeadline = now + Self.nanos(configuration.stepTimeout)
            stepTriesDone = 1
            if configuration.sendsCongestionReports { congestionDue = now + Self.nanos(configuration.congestionPeriod) }
            handshakePacket = TakionWire.initiate(clientTag: clientTag)
        }
        try transport.start(handler: self)
        lock.withLock { transmitLocked(handshakePacket) }
        transport.reschedule()
    }

    /// Ends the connection: no goodbye at the Takion level (§13). The stream layer sends its own disconnect
    /// message first, as an ordinary data message.
    func close() { finish(.local) }

    /// The stream keys exist (§6.7). Call from `takionData` while processing the bang, or from any thread later.
    func enableCrypto(ecdhSecret: [UInt8], handshakeKey: [UInt8]) {
        let up = GKCryptContext(ecdhSecret: ecdhSecret, handshakeKey: handshakeKey, index: 2)
        let down = GKCryptContext(ecdhSecret: ecdhSecret, handshakeKey: handshakeKey, index: 3, prefetch: true)
        lock.withLock {
            upContext = up
            upKeyPos = 0
            pendingDown = down
        }
        transport.reschedule()
    }

    var isConnected: Bool { lock.withLock { phase == .connected } }

    var stats: TakionStats {
        lock.withLock {
            var s = published
            s.datagramsSent = sendStats.datagramsSent
            s.bytesSent = sendStats.bytesSent
            s.retransmissions = sendStats.retransmissions
            s.chunksGivenUp = sendStats.chunksGivenUp
            s.congestionReports = sendStats.congestionReports
            s.sendErrors = sendStats.sendErrors
            return s
        }
    }

    /// Where the congestion reports take their numbers from (the AV layer); without one, reports say 0 and 0.
    func setCongestionSource(_ source: CongestionSource?) { lock.withLock { congestionSource = source } }

    /// Tests: blocks until the receive context's next GMAC epoch key is ready. Receive thread only.
    func waitForPrefetch() { downContext?.waitForPrefetch() }

    /// Chunks sent and not yet acknowledged.
    var unackedCount: Int { lock.withLock { unacked.count } }

    /// Whether the console has acknowledged `tsn` (cumulatively).
    func isAcknowledged(_ tsn: UInt32) -> Bool {
        lock.withLock { ackedThrough.map { Serial.isBeforeOrEqual(tsn, $0) } ?? false }
    }

    /// Sends a reliable data message (§5), fragmenting it when it doesn't fit the MTU (§5.3). Returns the TSN of
    /// its last chunk, or nil when the connection isn't up.
    @discardableResult
    func sendMessage(channel: UInt16, dataType: UInt8 = 0, _ message: [UInt8]) -> UInt32? {
        defer { checkSendFailure() }
        let now = takionNow()
        let m = max(min(configuration.mtuIn, configuration.mtuOut) - 50, 40)
        var last: UInt32?
        let sent = lock.withLock { () -> Bool in
            guard phase == .connected else { return false }
            var offset = 0
            var first = true
            while true {
                let capacity = first ? m - 26 : m - 25
                let remaining = message.count - offset
                let isLast = remaining <= capacity
                let count = isLast ? remaining : capacity
                let tsn = nextTSN
                nextTSN &+= 1
                var packet = TakionWire.data(tag: consoleTag, tsn: tsn, channel: channel, dataType: first ? dataType : nil,
                                             flags: isLast ? 1 : 0, message: message[offset..<offset + count])
                sealLocked(&packet, layout: .control, cost: count)
                if unacked.count < configuration.maxUnacked {
                    if unacked.isEmpty { retransmitDue = now + Self.nanos(configuration.retransmitCheck) }
                    unacked.append(Unacked(tsn: tsn, bytes: packet, lastSent: now, resends: 0))
                }
                transmitLocked(packet)
                last = tsn
                if isLast { return true }
                offset += count
                first = false
            }
        }
        if sent { transport.reschedule() }
        return sent ? last : nil
    }

    /// Sends a raw datagram as is (the probe's pings, takion.md §10).
    @discardableResult
    func sendRaw(_ datagram: [UInt8]) -> Bool {
        defer { checkSendFailure() }
        return lock.withLock {
            guard phase != .closed else { return false }
            transmitLocked(datagram)
            return true
        }
    }

    /// Sends a feedback state packet (§9.2) with the 25- (v9) or 28-byte (v12) body, and repeats the same body
    /// every 200 ms until a new one replaces it (client choice, observed). False when the keys aren't up.
    @discardableResult
    func sendFeedbackState(body: [UInt8]) -> Bool {
        defer { checkSendFailure() }
        let now = takionNow()
        let expected = configuration.version == 12 ? 28 : 25
        let ok = lock.withLock { () -> Bool in
            guard phase == .connected, upContext != nil, body.count == expected else { return false }
            sendStateLocked(body, now: now)
            return true
        }
        if ok { transport.reschedule() }
        return ok
    }

    /// Sends one controller event (§9.4) in a packet of its own: the event followed by up to 8 earlier ones, and
    /// repeats that packet unchanged 20, 50, 100 and 200 ms later unless a newer event replaces it. `event` is
    /// the encoded event (2, 3 or 5 bytes). False when the keys aren't up.
    @discardableResult
    func sendFeedbackEvent(_ event: [UInt8]) -> Bool {
        defer { checkSendFailure() }
        let now = takionNow()
        let ok = lock.withLock { () -> Bool in
            guard phase == .connected, upContext != nil, !event.isEmpty else { return false }
            recentEvents.insert(event, at: 0)
            if recentEvents.count > 9 { recentEvents.removeLast(recentEvents.count - 9) }
            let body = recentEvents.flatMap { $0 }
            let packet = (sequence: eventNumber, byte3: UInt8(recentEvents.count - 1), body: body)
            eventNumber &+= 1
            lastHistory = packet
            historyBase = now
            historyRepeatsDone = 0
            sendHistoryLocked(packet)
            return true
        }
        if ok { transport.reschedule() }
        return ok
    }

    /// Sends one client microphone packet (§7.5). `payload` is the 120 bytes. False when the keys aren't up.
    @discardableResult
    func sendMicrophone(packetIndex: UInt16, payload: [UInt8]) -> Bool {
        defer { checkSendFailure() }
        return lock.withLock {
            guard phase == .connected, let up = upContext else { return false }
            var packet = TakionWire.microphone(packetIndex: packetIndex, version: configuration.version, payload: payload)
            let bodyAt = packet.count - payload.count
            let k = upKeyPos
            packet.withUnsafeMutableBytes { buffer in
                up.apply(to: UnsafeMutableRawBufferPointer(rebasing: buffer[bodyAt...]), keyPos: k)
                buffer.putBE32(UInt32(truncatingIfNeeded: k), at: TakionAV.keyPosOffset)
                up.seal(buffer, layout: .av, keyPos: k)
            }
            upKeyPos &+= keyPosAdvance(16 + payload.count)
            transmitLocked(packet)
            return true
        }
    }

    /// Test hook: puts the send-side counters at known values (the known-answer vectors start mid-stream).
    func overrideSendState(keyPos: UInt64? = nil, stateSequence: UInt16? = nil, eventNumber: UInt16? = nil) {
        lock.withLock {
            if let keyPos { upKeyPos = keyPos }
            if let stateSequence { self.stateSequence = stateSequence }
            if let eventNumber {
                self.eventNumber = eventNumber
                recentEvents = []
            }
        }
    }

    /// The next send-side `keyPos` (diagnostics and tests).
    var nextKeyPos: UInt64 { lock.withLock { upKeyPos } }

    // MARK: Send side (lock held)

    private static func nanos(_ seconds: Double) -> UInt64 { UInt64(seconds * 1_000_000_000) }

    private static func errnoValue(of error: Error) -> Int32 {
        guard let kind = error as? FailureKind else { return EIO }
        switch kind {
        case .connectionRefused: return ECONNREFUSED
        case .networkUnreachable: return ENETUNREACH
        case .hostDown: return EHOSTUNREACH
        case .disconnected: return EPIPE
        case .permissionDenied: return EPERM
        case .badAddress: return EINVAL
        case .timeout: return ETIMEDOUT
        case .other(let code): return code
        default: return EIO
        }
    }

    /// Ends the connection if a send hit a non-transient error. Called with no lock held.
    private func checkSendFailure() {
        let code = lock.withLock { () -> Int32? in
            defer { fatalSendError = nil }
            return fatalSendError
        }
        if let code { finish(.socketError(code)) }
    }

    private func transmitLocked(_ bytes: [UInt8]) {
        do {
            try transport.send(bytes)
            sendStats.datagramsSent += 1
            sendStats.bytesSent += bytes.count
        } catch {
            sendStats.sendErrors += 1
            // A full send queue (ENOBUFS, EAGAIN) loses this datagram as UDP does; any other error means the path
            // is gone (§13: socket errors end the connection).
            let code = Self.errnoValue(of: error)
            if code != ENOBUFS && code != EAGAIN && fatalSendError == nil { fatalSendError = code }
        }
    }

    /// Writes `keyPos` and the GMAC into a control or congestion packet when the keys exist; `cost` is the `s` of
    /// §6.6 the counter advances by.
    private func sealLocked(_ packet: inout [UInt8], layout: GMACLayout, cost: Int) {
        guard let up = upContext else { return }
        let k = upKeyPos
        packet.withUnsafeMutableBytes { buffer in
            buffer.putBE32(UInt32(truncatingIfNeeded: k), at: layout.keyPosOffset)
            up.seal(buffer, layout: layout, keyPos: k)
        }
        upKeyPos &+= keyPosAdvance(cost)
    }

    private func sendFeedbackLocked(type: TakionPacketType, sequence: UInt16, byte3: UInt8, body: [UInt8]) {
        guard let up = upContext else { return }
        var packet = TakionWire.feedback(type: type, sequence: sequence, byte3: byte3, body: body)
        let k = upKeyPos
        packet.withUnsafeMutableBytes { buffer in
            up.apply(to: UnsafeMutableRawBufferPointer(rebasing: buffer[12...]), keyPos: k)
            buffer.putBE32(UInt32(truncatingIfNeeded: k), at: GMACLayout.feedback.keyPosOffset)
            up.seal(buffer, layout: .feedback, keyPos: k)
        }
        upKeyPos &+= keyPosAdvance(16 + body.count)
        transmitLocked(packet)
    }

    private func sendStateLocked(_ body: [UInt8], now: UInt64) {
        sendFeedbackLocked(type: .feedbackState, sequence: stateSequence, byte3: 0, body: body)
        stateSequence &+= 1
        lastStateBody = body
        stateRepeatDue = now + Self.nanos(configuration.feedbackStateInterval)
    }

    private func sendHistoryLocked(_ h: (sequence: UInt16, byte3: UInt8, body: [UInt8])) {
        sendFeedbackLocked(type: .feedbackHistory, sequence: h.sequence, byte3: h.byte3, body: h.body)
    }

    private func sendAckLocked(cumulative: UInt32) {
        var packet = TakionWire.dataAck(tag: consoleTag, cumulativeTSN: cumulative)
        sealLocked(&packet, layout: .control, cost: TakionConstants.dataAckSize)
        transmitLocked(packet)
    }

    // MARK: TransportHandler

    @_optimize(speed) func transportDidReceive(_ datagram: UnsafeMutableRawBufferPointer, at timestamp: UInt64, kernelTimestamp: Bool) {
        defer { checkSendFailure() }
        let pending = lock.withLock { () -> GKCryptContext? in
            defer { pendingDown = nil }
            return pendingDown
        }
        if let pending { adopt(pending, at: timestamp) }
        rx.datagramsReceived += 1
        if !kernelTimestamp { rx.softwareTimestamps += 1 }
        rx.bytesReceived += datagram.count
        if datagram.count == 0 {
            rx.droppedTruncated += 1
        } else {
            switch datagram[0] & 0x0f {
            case TakionPacketType.control.rawValue: handleControl(datagram, at: timestamp)
            case TakionPacketType.video.rawValue, TakionPacketType.audio.rawValue: handleAV(datagram, at: timestamp)
            default: rx.droppedUnknownType += 1
            }
        }
        publish()
    }

    func transportNextWake() -> UInt64? {
        var next: UInt64?
        func consider(_ t: UInt64?) { if let t, t != 0 { next = min(next ?? t, t) } }
        lock.withLock {
            switch phase {
            case .initSent, .cookieSent:
                consider(handshakeDeadline)
                consider(stepDeadline)
            case .connected:
                if !unacked.isEmpty { consider(retransmitDue) }
                if lastStateBody != nil { consider(stateRepeatDue) }
                if historyRepeatsDone < Self.historyRepeatOffsets.count {
                    consider(historyBase + Self.historyRepeatOffsets[historyRepeatsDone])
                }
            default: break
            }
            if phase != .new && phase != .closed && configuration.sendsCongestionReports { consider(congestionDue) }
        }
        consider(reorder.nextDeadline)
        return next
    }

    func transportWake(now: UInt64) {
        defer { checkSendFailure() }
        var failed = false
        var report = false
        lock.withLock {
            switch phase {
            case .initSent, .cookieSent:
                if now >= handshakeDeadline {
                    failed = true
                } else if now >= stepDeadline {
                    if stepTriesDone < configuration.stepTries {
                        stepTriesDone += 1
                        stepDeadline = now + Self.nanos(configuration.stepTimeout)
                        transmitLocked(handshakePacket)
                    } else {
                        failed = true
                    }
                }
            case .connected:
                retransmitLocked(now)
                if lastStateBody != nil && now >= stateRepeatDue, let body = lastStateBody { sendStateLocked(body, now: now) }
                if historyRepeatsDone < Self.historyRepeatOffsets.count,
                   now >= historyBase + Self.historyRepeatOffsets[historyRepeatsDone], let h = lastHistory {
                    historyRepeatsDone += 1
                    sendHistoryLocked(h)
                }
            default: break
            }
            if phase != .new && phase != .closed && configuration.sendsCongestionReports && now >= congestionDue {
                congestionDue = now + Self.nanos(configuration.congestionPeriod)
                report = true
            }
        }
        if failed {
            finish(.handshakeTimeout)
            return
        }
        if report {
            let source = lock.withLock { congestionSource }
            let counts = congestionReporter.report(source?.congestionInputs() ?? CongestionInputs(), maxLoss: configuration.maxLoss)
            lock.withLock {
                var packet = TakionWire.congestion(received: counts.received, lost: counts.lost)
                sealLocked(&packet, layout: .congestion, cost: TakionConstants.congestionSize)
                transmitLocked(packet)
                sendStats.congestionReports += 1
            }
        }
        reorder.wake(at: now) { [unowned self] header, payload, at in deliverVideo(header, payload, at) }
        publish()
    }

    func transportFailed(errno code: Int32) { finish(.socketError(code)) }

    private func retransmitLocked(_ now: UInt64) {
        guard !unacked.isEmpty, now >= retransmitDue else { return }
        retransmitDue = now + Self.nanos(configuration.retransmitCheck)
        let after = Self.nanos(configuration.retransmitAfter)
        var i = 0
        while i < unacked.count {
            if now &- unacked[i].lastSent > after {
                if unacked[i].resends >= configuration.maxResends {
                    unacked.remove(at: i)
                    sendStats.chunksGivenUp += 1
                    continue
                }
                unacked[i].resends += 1
                unacked[i].lastSent = now
                sendStats.retransmissions += 1
                transmitLocked(unacked[i].bytes)
            }
            i += 1
        }
    }

    private func finish(_ reason: TakionCloseReason) {
        let wasOpen = lock.withLock { () -> Bool in
            let open = phase != .closed
            phase = .closed
            return open
        }
        guard wasOpen else { return }
        transport.stop()
        let d = delegate
        delegate = nil
        d?.takionClosed(reason)
    }

    @_optimize(speed) private func publish() {
        rx.reorder = reorder.snapshot
        lock.withLock { published = rx }
    }

    // MARK: Receive: crypto switch

    private func adopt(_ down: GKCryptContext, at now: UInt64) {
        downContext = down
        keyPosReference = 0
        // Chunks queued before the keys existed are checked now and dropped if they fail (§6.7).
        for step in 0..<TakionConstants.receiveWindow {
            let slot = Int((rxNext &+ UInt32(step)) & 15)
            guard windowFilled[slot] else { continue }
            let buffer = UnsafeMutableRawBufferPointer(start: windowBytes + slot * TakionConstants.maxDatagram,
                                                       count: windowLengths[slot])
            if !authenticateControl(buffer) {
                windowFilled[slot] = false
                rx.droppedBadGMAC += 1
            }
        }
        let held = heldCount
        heldCount = 0
        for i in 0..<held {
            let buffer = UnsafeMutableRawBufferPointer(start: heldBytes + i * TakionConstants.maxDatagram, count: heldLengths[i])
            processAV(buffer, at: heldTimes[i], down)
        }
    }

    /// Checks a control packet's GMAC with `ctxDown`; updates the key-position reference only on success.
    @_optimize(speed) private func authenticateControl(_ d: UnsafeMutableRawBufferPointer) -> Bool {
        guard let down = downContext else { return true }
        let k = reconstructKeyPos(low: d.be32(9), reference: keyPosReference)
        guard down.verify(d, layout: .control, keyPos: k) else { return false }
        keyPosReference = k
        return true
    }

    // MARK: Receive: control

    @_optimize(speed) private func handleControl(_ d: UnsafeMutableRawBufferPointer, at now: UInt64) {
        guard let header = TakionControlHeader.parse(d.readOnly) else {
            rx.droppedMalformed += 1
            return
        }
        guard header.tag == clientTag else {
            rx.droppedMalformed += 1
            return
        }
        guard authenticateControl(d) else {
            rx.droppedBadGMAC += 1
            return
        }
        rx.controlPackets += 1
        let phase = lock.withLock { self.phase }
        switch (TakionChunkType(rawValue: header.chunkType), phase) {
        case (.initAck?, .initSent):
            handleInitAck(d)
        case (.cookieAck?, .cookieSent):
            if header.chunkLength == 4 { connected() } else { rx.droppedMalformed += 1 }
        case (.data?, .connected):
            handleData(d)
        case (.dataAck?, .connected):
            handleDataAck(d)
        case (.initAck?, .cookieSent):
            break  // the console repeated its INIT_ACK (§4.4): ignore it
        default:
            rx.droppedUnknownType += 1
        }
    }

    private func handleInitAck(_ d: UnsafeMutableRawBufferPointer) {
        guard let ack = TakionInitAck.parse(d.readOnly, clientTag: clientTag) else {
            rx.droppedMalformed += 1
            return
        }
        let now = takionNow()
        rxNext = ack.consoleTag
        lock.withLock {
            consoleTag = ack.consoleTag
            cookie = ack.cookie
            phase = .cookieSent
            stepTriesDone = 1
            stepDeadline = now + Self.nanos(configuration.stepTimeout)
            handshakePacket = TakionWire.cookie(consoleTag: ack.consoleTag, cookie: ack.cookie)
            transmitLocked(handshakePacket)
        }
    }

    private func connected() {
        let now = takionNow()
        lock.withLock {
            phase = .connected
            handshakeDeadline = 0
            stepDeadline = 0
            if configuration.sendsCongestionReports && congestionDue == 0 { congestionDue = now + Self.nanos(configuration.congestionPeriod) }
        }
        delegate?.takionConnected()
    }

    private func handleDataAck(_ d: UnsafeMutableRawBufferPointer) {
        guard let ack = TakionDataAck.parse(d.readOnly) else {
            rx.droppedMalformed += 1
            return
        }
        rx.dataAcksReceived += 1
        lock.withLock {
            var done = 0
            while done < unacked.count && Serial.isBeforeOrEqual(unacked[done].tsn, ack.cumulativeTSN) { done += 1 }
            if done > 0 { unacked.removeFirst(done) }
            if ackedThrough == nil || Serial.isAfter(ack.cumulativeTSN, ackedThrough!) { ackedThrough = ack.cumulativeTSN }
        }
        delegate?.takionAcknowledged(through: ack.cumulativeTSN)
    }

    // MARK: Receive: reliable data (§12.1)

    @_optimize(speed) private func handleData(_ d: UnsafeMutableRawBufferPointer) {
        guard let chunk = TakionDataChunk.parse(d.readOnly) else {
            rx.droppedMalformed += 1
            return
        }
        if Serial.isBefore(chunk.tsn, rxNext) {
            // Already delivered: the ack was probably lost; repeat it (recommended in §5.5).
            rx.duplicateChunks += 1
            let cumulative = rxNext &- 1
            lock.withLock { sendAckLocked(cumulative: cumulative) }
            return
        }
        let distance = chunk.tsn &- rxNext
        guard distance < UInt32(TakionConstants.receiveWindow) else {
            rx.droppedWindow += 1
            return
        }
        let slot = Int(chunk.tsn & 15)
        guard !windowFilled[slot] else {
            rx.duplicateChunks += 1
            return
        }
        guard d.count <= TakionConstants.maxDatagram, let source = d.baseAddress else {
            rx.droppedMalformed += 1
            return
        }
        (windowBytes + slot * TakionConstants.maxDatagram).copyMemory(from: source, byteCount: d.count)
        windowLengths[slot] = d.count
        windowFilled[slot] = true
        var delivered = false
        while windowFilled[Int(rxNext & 15)] {
            let at = Int(rxNext & 15)
            windowFilled[at] = false
            rxNext &+= 1
            delivered = true
            deliverChunk(UnsafeRawBufferPointer(start: windowBytes + at * TakionConstants.maxDatagram, count: windowLengths[at]))
            rx.dataChunksDelivered += 1
            let pending = lock.withLock { () -> GKCryptContext? in
                defer { pendingDown = nil }
                return pendingDown
            }
            if let pending { adopt(pending, at: takionNow()) }
        }
        if delivered {
            let cumulative = rxNext &- 1
            lock.withLock { sendAckLocked(cumulative: cumulative) }
        }
    }

    /// Hands a delivered chunk up: whole messages straight from the window slot, fragments through `assembly`.
    @_optimize(speed) private func deliverChunk(_ d: UnsafeRawBufferPointer) {
        let flags = d[14]
        let last = flags & 1 != 0
        let channel = d.be16(21)
        if assembling {
            assembly.append(contentsOf: UnsafeRawBufferPointer(rebasing: d[TakionDataChunk.continuationOffset...]))
            if assembly.count > Self.maxAssembly {
                assembling = false
                assembly = []
                rx.droppedMalformed += 1
            } else if last {
                assembling = false
                let message = assembly
                assembly = []
                message.withUnsafeBytes { emit(channel: assemblyChannel, dataType: assemblyType, $0) }
            }
            return
        }
        let dataType = d[25]
        let message = UnsafeRawBufferPointer(rebasing: d[TakionDataChunk.firstMessageOffset...])
        if last {
            emit(channel: channel, dataType: dataType, message)
        } else {
            assembling = true
            assemblyType = dataType
            assemblyChannel = channel
            assembly = Array(message)
        }
    }

    @_optimize(speed) private func emit(channel: UInt16, dataType: UInt8, _ message: UnsafeRawBufferPointer) {
        switch dataType {
        case 0x00, 0x07, 0x09, 0x0b: delegate?.takionData(channel: channel, dataType: dataType, message: message)
        default: break
        }
    }

    // MARK: Receive: AV

    @_optimize(speed) private func handleAV(_ d: UnsafeMutableRawBufferPointer, at now: UInt64) {
        if configuration.version == 7 {
            // The probe: no crypto and no reordering; the stream layer reads pongs and MTU test packets.
            guard let parsed = TakionAV.parse(d.readOnly, version: 7) else {
                rx.droppedTruncated += 1
                return
            }
            if parsed.header.isVideo { rx.videoPackets += 1 } else { rx.audioPackets += 1 }
            delegate?.takionAV(parsed.header, payload: UnsafeMutableRawBufferPointer(rebasing: d[parsed.payloadOffset...]), receivedAt: now)
            return
        }
        guard let down = downContext else {
            // Keys not ready: hold up to 32 packets (§6.7).
            guard heldCount < Self.heldSlots, d.count <= TakionConstants.maxDatagram else {
                rx.avHeldOverflow += 1
                return
            }
            (heldBytes + heldCount * TakionConstants.maxDatagram).copyMemory(from: d.baseAddress!, byteCount: d.count)
            heldLengths[heldCount] = d.count
            heldTimes[heldCount] = now
            heldCount += 1
            rx.avHeld += 1
            return
        }
        processAV(d, at: now, down)
    }

    @_optimize(speed) private func processAV(_ d: UnsafeMutableRawBufferPointer, at now: UInt64, _ down: GKCryptContext) {
        guard d.count >= 18 else {
            rx.droppedTruncated += 1
            return
        }
        let k = reconstructKeyPos(low: d.be32(TakionAV.keyPosOffset), reference: keyPosReference)
        guard down.verify(d, layout: .av, keyPos: k) else {
            rx.droppedBadGMAC += 1
            return
        }
        keyPosReference = k
        guard let parsed = TakionAV.parse(d.readOnly, version: configuration.version) else {
            rx.droppedTruncated += 1
            return
        }
        let payload = UnsafeMutableRawBufferPointer(rebasing: d[parsed.payloadOffset...])
        down.apply(to: payload, keyPos: k)
        if parsed.header.isVideo {
            rx.videoPackets += 1
            reorder.insert(parsed.header, payload: payload, at: now) { [unowned self] header, payload, at in
                deliverVideo(header, payload, at)
            }
        } else {
            rx.audioPackets += 1
            delegate?.takionAV(parsed.header, payload: payload, receivedAt: now)
        }
    }

    @_optimize(speed) private func deliverVideo(_ header: TakionAVHeader, _ payload: UnsafeMutableRawBufferPointer, _ at: UInt64) {
        delegate?.takionAV(header, payload: payload, receivedAt: at)
    }
}
