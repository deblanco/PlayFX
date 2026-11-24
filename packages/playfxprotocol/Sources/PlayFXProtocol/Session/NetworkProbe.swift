import Foundation

/// The network probe on port 9297 (stream.md section 5): Takion version 7, the version request, the empty Hello,
/// the RTT pings, both MTU bisections and the Disconnect. Control-plane code: it blocks the calling thread, which
/// is the session's start-up thread, and is told what arrived by the Takion receive thread through a mailbox.
struct ProbeFailure: Error, Sendable, Equatable, CustomStringConvertible {
    var description: String
}

final class NetworkProbe: TakionDelegate, @unchecked Sendable {
    enum Event {
        case connected
        case closed(TakionCloseReason)
        /// A console message: its wrapper `type` when readable, and the decoded message when it decodes.
        case message(type: UInt64?, StreamMessage?)
        /// An audio-type AV packet (a pong candidate).
        case pong(unit: Int, frame: UInt16, tag: UInt32?, at: UInt64)
        /// A video-type AV packet (an inbound MTU test packet).
        case video(frame: UInt16)
    }

    private let mailbox = Mailbox<Event>()
    private let timing: ProbeTiming
    private let abort: @Sendable () -> Bool
    private var connection: TakionConnection?

    private init(timing: ProbeTiming, abort: @escaping @Sendable () -> Bool) {
        self.timing = timing
        self.abort = abort
    }

    /// Runs the whole probe over `transport` (which should have Don't-Fragment set). Never throws: a failure of
    /// any step is the result's `.failure`, and the caller then uses `StreamProbeResult.fallback`.
    static func run(
        transport: DatagramTransport, timing: ProbeTiming, abort: @escaping @Sendable () -> Bool
    ) -> Result<StreamProbeResult, ProbeFailure> {
        let probe = NetworkProbe(timing: timing, abort: abort)
        var configuration = TakionConfiguration()
        configuration.version = 7
        configuration.handshakeTimeout = timing.connectTimeout
        configuration.stepTimeout = timing.stepTimeout
        let connection = TakionConnection(configuration: configuration, transport: transport, delegate: probe)
        probe.connection = connection
        do {
            let result = try probe.execute(connection)
            // Section 5.6: Disconnect, then close without waiting.
            Farewell.close(connection, disconnect: true, pause: transport.name == "nw")
            return .success(result)
        } catch let failure as ProbeFailure {
            connection.close()
            return .failure(failure)
        } catch {
            connection.close()
            return .failure(ProbeFailure(description: "\(error)"))
        }
    }

    // MARK: TakionDelegate (receive thread)

    func takionConnected() { mailbox.post(.connected) }

    func takionClosed(_ reason: TakionCloseReason) { mailbox.post(.closed(reason)) }

    func takionData(channel: UInt16, dataType: UInt8, message: UnsafeRawBufferPointer) {
        guard dataType == 0 else { return }
        let bytes = Array(message)
        // The probe's HelloReply isn't checked, so a body that doesn't decode still counts by its type.
        let type = (try? ProtobufReader.fields(of: bytes))?.optionalVarint(1)
        mailbox.post(.message(type: type, try? StreamMessage.decode(bytes)))
    }

    func takionAV(_ header: TakionAVHeader, payload: UnsafeMutableRawBufferPointer, receivedAt: UInt64) {
        if header.isVideo {
            mailbox.post(.video(frame: header.frameIndex))
        } else {
            let tag = payload.count >= 8 ? payload.be32(4) : nil
            mailbox.post(.pong(unit: header.unitIndex, frame: header.frameIndex, tag: tag, at: receivedAt))
        }
    }

    // MARK: Steps

    @discardableResult
    private func send(_ message: OutgoingStreamMessage) -> UInt32? {
        connection?.sendMessage(channel: message.channel, dataType: message.dataType, message.bytes)
    }

    private func sendOrThrow(_ message: OutgoingStreamMessage, _ step: String) throws -> UInt32 {
        guard let tsn = send(message) else { throw ProbeFailure(description: "\(step): not connected") }
        return tsn
    }

    private func waitAcknowledged(_ tsn: UInt32, _ step: String) throws {
        let deadline = monotonicSeconds() + timing.answerTimeout
        while !(connection?.isAcknowledged(tsn) ?? false) {
            if abort() { throw ProbeFailure(description: "aborted") }
            if monotonicSeconds() >= deadline { throw ProbeFailure(description: "\(step): no acknowledgement") }
            usleep(2000)
        }
    }

    private func waitForMessage(_ step: String, _ match: @escaping (UInt64?, StreamMessage?) -> Bool) throws {
        let found: Bool? = mailbox.take(timeout: timing.answerTimeout, abort: abort) { event in
            if case .message(let type, let message) = event, match(type, message) { return true }
            if case .closed = event { return false }
            return nil
        }
        guard found == true else {
            throw ProbeFailure(description: abort() ? "aborted" : found == false ? "\(step): the connection closed" : "\(step): no answer")
        }
    }

    private func execute(_ connection: TakionConnection) throws -> StreamProbeResult {
        do { try connection.connect() } catch { throw ProbeFailure(description: "connect: \(error)") }
        let up: Bool? = mailbox.take(timeout: timing.connectTimeout + 1, abort: abort) { event in
            switch event {
            case .connected: return true
            case .closed: return false
            default: return nil
            }
        }
        guard up == true else {
            throw ProbeFailure(description: abort() ? "aborted" : "Takion handshake on the probe port failed")
        }

        // 5.2 and 5.3: the version request, then the empty Hello; neither answer is checked, only awaited.
        _ = try sendOrThrow(.probeVersionRequest, "version request")
        try waitForMessage("version request") { type, _ in type == StreamMessageType.transportVersionAck.rawValue }
        _ = try sendOrThrow(.probeHello, "probe Hello")
        try waitForMessage("probe Hello") { type, _ in type == StreamMessageType.helloReply.rawValue }

        let rtt = try measureRTT(connection)
        let wait = min(max(5 * Double(rtt) / 1_000_000, timing.mtuWaitMinimum), timing.mtuWaitMaximum)
        let mtuIn = try measureInboundMTU(wait: wait)
        let mtuOut = try measureOutboundMTU(mtuIn: mtuIn, wait: wait, connection)
        return StreamProbeResult(rttMicroseconds: rtt, mtuIn: mtuIn, mtuOut: mtuOut)
    }

    /// 5.4: the mean round-trip time of the pongs, in microseconds.
    private func measureRTT(_ connection: TakionConnection) throws -> Int {
        let on = try sendOrThrow(.probe(.echo(enabled: true)), "echo on")
        try waitAcknowledged(on, "echo on")
        var samples: [UInt64] = []
        for unit in 0..<timing.pings {
            let tag = UInt32.random(in: 0...UInt32.max)
            let sentAt = takionNow()
            guard connection.sendRaw(TakionProbe.ping(unit: unit, tag: tag)) else {
                throw ProbeFailure(description: "ping: not connected")
            }
            if let at = awaitPong(unit: unit, tag: tag, timeout: timing.pongTimeout) { samples.append(at &- min(sentAt, at)) }
            if abort() { throw ProbeFailure(description: "aborted") }
        }
        let off = try sendOrThrow(.probe(.echo(enabled: false)), "echo off")
        try waitAcknowledged(off, "echo off")
        guard !samples.isEmpty else { throw ProbeFailure(description: "no pong to any ping") }
        return Int(samples.reduce(0, +) / UInt64(samples.count) / 1000)
    }

    /// A pong of §5.4: frame index 0, this unit index, and the tag in data bytes 4..7. Returns its receive time.
    private func awaitPong(unit: Int, tag: UInt32, timeout: Double) -> UInt64? {
        mailbox.take(timeout: timeout, abort: abort) { event in
            if case .pong(let u, let frame, let t, let at) = event, frame == 0, u == unit, t == tag { return at }
            return nil
        }
    }

    /// 5.5, console to client: bisection over [576, 1454] with up to three attempts per size.
    private func measureInboundMTU(wait: Double) throws -> Int {
        var lo = 576, hi = 1454, size = 1454
        var id: UInt32 = 0
        while hi - lo > 1 {
            var seen = false
            for _ in 0..<3 where !seen {
                id += 1
                _ = try sendOrThrow(.probe(.mtu(id: id, requestedMtu: UInt32(size))), "MTU test")
                let wanted = UInt16(truncatingIfNeeded: id)
                let got: Bool? = mailbox.take(timeout: wait, abort: abort) { event in
                    if case .video(let frame) = event, frame == wanted { return true }
                    return nil
                }
                seen = got != nil
                if abort() { throw ProbeFailure(description: "aborted") }
            }
            if seen { lo = size } else { hi = size }
            size = lo + (hi - lo) / 2
        }
        return lo
    }

    /// 5.5, client to console.
    private func measureOutboundMTU(mtuIn: Int, wait: Double, _ connection: TakionConnection) throws -> Int {
        let announce = ProbeMessage.clientMtu(id: 1, requestedMtu: UInt32(mtuIn), active: true, downstreamMtu: UInt32(mtuIn))
        _ = try sendOrThrow(.probe(announce), "client MTU")
        try waitForMessage("client MTU") { _, message in
            if case .probe(let probe)? = message, probe.command == .clientMtu, probe.clientMtu?.id == 1 { return true }
            return false
        }
        var lo = 576, hi = 1454, size = mtuIn
        while hi - lo > 1 {
            var seen = false
            for attempt in 0..<3 where !seen {
                let tag = UInt32.random(in: 0...UInt32.max)
                // `size` is an IP packet size; 28 bytes of it are the IPv4 and UDP headers.
                guard connection.sendRaw(TakionProbe.ping(unit: attempt, tag: tag, size: size - 28)) else {
                    throw ProbeFailure(description: "MTU ping: not connected")
                }
                seen = awaitPong(unit: attempt, tag: tag, timeout: wait) != nil
                if abort() { throw ProbeFailure(description: "aborted") }
            }
            if seen { lo = size } else { hi = size }
            size = lo + (hi - lo) / 2
        }
        let done = ProbeMessage.clientMtu(id: 2, requestedMtu: UInt32(hi), active: false, downstreamMtu: UInt32(mtuIn))
        try waitAcknowledged(try sendOrThrow(.probe(done), "client MTU end"), "client MTU end")
        return lo
    }
}

/// "Disconnect, then close" (stream.md section 11.1): one place for the stream, the probe and a dropped session.
enum Farewell {
    /// Sends the Disconnect when `disconnect` is true and the connection is up, then closes at once. Network.framework
    /// sends asynchronously, so `pause` gives the datagram a moment before the connection is cancelled.
    static func close(_ connection: TakionConnection?, disconnect: Bool, pause: Bool) {
        if disconnect, let connection {
            let message = OutgoingStreamMessage.disconnect
            if connection.sendMessage(channel: message.channel, dataType: message.dataType, message.bytes) != nil, pause {
                usleep(20_000)
            }
        }
        connection?.close()
    }
}
