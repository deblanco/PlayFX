import Foundation

/// The stream connection's side of a `StreamSession`: it is the Takion delegate (so everything here runs on the
/// receive thread), runs the Hello to StreamInfo handshake of stream.md section 6, feeds the AV layer and turns
/// its callbacks into messages and events.
///
/// Threads. Receive-thread state needs no lock. What other threads touch (the controller state, the counters,
/// the manual IDR throttle, the microphone packetiser) has its own lock. The hot path (video, audio, haptics)
/// calls the app's handler through the `EventGate` and allocates nothing per packet; control messages (rumble,
/// pad info, quality) are parsed on this thread and handed to the session's control queue.
final class StreamLink: TakionDelegate, CongestionSource, @unchecked Sendable {
    enum Stage { case awaitingHelloReply, awaitingStreamInfo, running, finished }

    /// What the start-up thread waits for.
    enum StartEvent {
        case connected
        case closed(TakionCloseReason)
        case helloReplied
        case ready
        case failed(StreamStartError)
    }

    struct Counters {
        var frames = 0
        var frameBytes = 0
        var decoderRejects = 0
        var idrSent = 0
        var corruptSent = 0
        var audioSkipped = 0
        var video = VideoStatistics()
        var lastCongestion: StreamCongestionReport?
        var congestionReports = 0
    }

    let startEvents = Mailbox<StartEvent>()
    private weak var session: StreamSession?
    private let gate: EventGate
    private let handshake: StreamHandshake
    private let handshakeKey: [UInt8]
    private let dualSense: Bool
    private let ps5: Bool
    private let microphone: Bool
    private let videoCodec: VideoCodec
    private var template: StreamConnectedInfo

    /// Set before `connect`, cleared by `detach` (any thread may read it).
    private let connectionLock = UnfairLock()
    private var held: TakionConnection?
    var connection: TakionConnection? {
        get { connectionLock.withLock { held } }
        set { connectionLock.withLock { held = newValue } }
    }
    private(set) var av: AVReceiver!

    /// The stage can be ended from any thread that sees the connection close (a sender's fatal error calls
    /// `takionClosed` on that thread), so it has a lock; the receive thread reads it for every packet.
    private let stageLock = UnfairLock()
    private var currentStage = Stage.awaitingHelloReply
    private var stage: Stage {
        get { stageLock.withLock { currentStage } }
        set { stageLock.withLock { currentStage = newValue } }
    }

    // Receive thread only.
    private var reporter = CongestionReporter()
    private var rejectRequested = false
    private var lastColor: [UInt8]?
    private var lastPlayer: UInt8?

    // Shared (statsLock).
    private let statsLock = UnfairLock()
    private var counters = Counters()
    private var lastManualIDR = -Double.infinity
    private var helloWasSent = false
    private let clock: @Sendable () -> Double

    // Controller input (feedbackLock).
    private let feedbackLock = UnfairLock()
    private var feedbackReady = false
    private var pending = ControllerState.idle
    private var sent = ControllerState.idle
    private var stateSent = false
    /// Batches of sends in order, drained by one thread at a time outside the lock.
    private var feedbackBatches: [[FeedbackSend]] = []
    private var feedbackDraining = false

    private enum FeedbackSend {
        case event([UInt8])
        case state([UInt8])
    }

    private let microphoneLock = UnfairLock()
    private var packetizer = MicrophonePacketizer()
    private var microphonePacketIndex: UInt16 = 0

    init(
        session: StreamSession, gate: EventGate, handshake: StreamHandshake, handshakeKey: [UInt8], dualSense: Bool,
        ps5: Bool, microphone: Bool, videoCodec: VideoCodec, template: StreamConnectedInfo,
        clock: @escaping @Sendable () -> Double = monotonicSeconds
    ) {
        self.session = session
        self.gate = gate
        self.handshake = handshake
        self.handshakeKey = handshakeKey
        self.dualSense = dualSense
        self.ps5 = ps5
        self.microphone = microphone
        self.videoCodec = videoCodec
        self.template = template
        self.clock = clock
        av = AVReceiver(
            video: VideoCallbacks(
                accessUnit: { [unowned self] bytes, info in deliverAccessUnit(bytes, info) },
                parameterSets: { [unowned self] index, profile, codec in
                    emit { .parameterSets(profileIndex: index, profile: profile, codec: codec) }
                },
                corruptFrames: { [unowned self] first, last in sendCorruptFrame(first, last) },
                needsIDR: { [unowned self] _ in sendIDR() },
                decoderRejecting: { [unowned self] _ in requestIDR() }),
            audio: { [unowned self] event in deliverAudio(event) },
            haptics: { [unowned self] frame, samples in emit { .haptics(frameIndex: frame, samples: samples) } })
    }

    // MARK: Emitting

    /// The hot path: calls the handler on this thread, never after the gate closed.
    @inline(__always) private func emit(_ make: () -> StreamEvent) {
        guard let handler = gate.enter() else { return }
        // The strong reference to the session outlives `leave`: if the app dropped its last one meanwhile, the
        // session's deinit (which closes the gate and waits for calls in flight) must not run inside this call.
        let target = session
        if let target { handler(make(), target) }
        withExtendedLifetime(target) { gate.leave() }
    }

    private func post(_ event: StreamEvent) { session?.postControl(event) }

    // MARK: Sending

    @discardableResult
    func send(_ message: OutgoingStreamMessage) -> Bool {
        connection?.sendMessage(channel: message.channel, dataType: message.dataType, message.bytes) != nil
    }

    func sendHeartbeat() { send(.heartbeat) }

    @discardableResult
    func sendDisconnect() -> Bool { send(.disconnect) }

    private func sendIDR() {
        if send(.idrRequest) { statsLock.withLock { counters.idrSent += 1 } }
        snapshotVideo()
    }

    private func sendCorruptFrame(_ first: UInt16, _ last: UInt16) {
        if send(.corruptFrame(first: first, last: last)) { statsLock.withLock { counters.corruptSent += 1 } }
        snapshotVideo()
    }

    /// An IDR request the app (or its decoder) asked for: at most one per second (stream.md section 9.3 doesn't
    /// limit these; the video receiver's own repeat limit is one per second, and this matches it).
    @discardableResult
    func requestIDR() -> Bool {
        let now = clock()
        let allowed = statsLock.withLock { () -> Bool in
            guard now - lastManualIDR >= VideoReceiver.idrRepeatInterval else { return false }
            lastManualIDR = now
            return true
        }
        guard allowed, send(.idrRequest) else { return false }
        statsLock.withLock { counters.idrSent += 1 }
        return true
    }

    /// The app rejected the frame it is being handed (call from inside the video handler).
    func rejectCurrentFrame() { rejectRequested = true }

    private func snapshotVideo() {
        let video = av.video.statistics
        statsLock.withLock { counters.video = video }
    }

    func snapshot() -> Counters { statsLock.withLock { counters } }

    /// The Hello went out: the Disconnect of section 11.1 is owed from here on.
    var helloSent: Bool {
        get { statsLock.withLock { helloWasSent } }
        set { statsLock.withLock { helloWasSent = newValue } }
    }

    /// Lets go of everything that points back (the connection, the handshake's key pair) once the connection is
    /// closed or abandoned, so nothing stays alive through a cycle.
    func detach() {
        stage = .finished
        handshake.abort()
        connection = nil
    }

    // MARK: Controller input

    /// Sends the history events and, when sticks or motion changed, a feedback state. The TakionConnection
    /// numbers the packets and repeats the state every 200 ms (takion.md section 9.3). The sends happen outside
    /// the lock, in order, by whichever thread finds nobody draining: a fatal send ends the connection, which
    /// joins the receive thread, and that thread must never wait for a lock a sender holds.
    @discardableResult
    func setControllerState(_ state: ControllerState) -> Bool {
        let ready = feedbackLock.withLock { () -> Bool in
            pending = state
            guard feedbackReady else { return false }
            enqueueFeedbackLocked(state)
            return true
        }
        if ready { drainFeedback() }
        return ready
    }

    private func enqueueFeedbackLocked(_ state: ControllerState) {
        var batch: [FeedbackSend] = ControllerEvent.events(from: sent, to: state).map { .event($0.bytes) }
        if !stateSent || FeedbackState.needsSend(old: sent, new: state) {
            batch.append(.state(FeedbackState.body(state, ps5: ps5)))
            stateSent = true
        }
        sent = state
        if !batch.isEmpty { feedbackBatches.append(batch) }
    }

    private func drainFeedback() {
        let mine = feedbackLock.withLock { () -> Bool in
            guard !feedbackDraining else { return false }
            feedbackDraining = true
            return true
        }
        guard mine else { return }
        while true {
            let batch = feedbackLock.withLock { () -> [FeedbackSend]? in
                if feedbackBatches.isEmpty {
                    feedbackDraining = false
                    return nil
                }
                return feedbackBatches.removeFirst()
            }
            guard let batch else { return }
            for item in batch {
                switch item {
                case .event(let bytes): _ = connection?.sendFeedbackEvent(bytes)
                case .state(let body): _ = connection?.sendFeedbackState(body: body)
                }
            }
        }
    }

    private func startFeedback() {
        feedbackLock.withLock {
            feedbackReady = true
            enqueueFeedbackLocked(pending)
        }
        drainFeedback()
    }

    // MARK: Microphone

    /// One 40-byte Opus frame of the microphone (stream.md section 9.10). False when it isn't 40 bytes, the
    /// microphone wasn't announced, or the stream isn't up.
    @discardableResult
    func sendMicrophoneFrame(_ opusFrame: [UInt8]) -> Bool {
        guard microphone, let connection else { return false }
        return microphoneLock.withLock {
            guard let packet = packetizer.packet(opusFrame: opusFrame) else { return false }
            return connection.sendMicrophone(packetIndex: packet.packetIndex, payload: packet.payload)
        }
    }

    // MARK: TakionDelegate

    func takionConnected() { startEvents.post(.connected) }

    func takionClosed(_ reason: TakionCloseReason) {
        guard reason != .local else { return }
        let wasRunning = stageLock.withLock { () -> Bool in
            defer { currentStage = .finished }
            return currentStage == .running
        }
        startEvents.post(.closed(reason))
        if wasRunning { session?.linkEnded(StreamEndReason(code: .streamFailed)) }
    }

    func takionData(channel: UInt16, dataType: UInt8, message: UnsafeRawBufferPointer) {
        switch stage {
        case .awaitingHelloReply:
            guard dataType == StreamInbound.DataType.protobuf else { return }
            handleHandshake(Array(message))
        case .awaitingStreamInfo:
            guard let inbound = try? StreamInbound.parse(dataType: dataType, body: Array(message)) else { return }
            switch inbound {
            case .message(.streamInfo(let info)): applyStreamInfo(info)
            case .message(.disconnect(let disconnect)): failStart(remoteDisconnect: disconnect.reason)
            default: break
            }
        case .running:
            guard let inbound = try? StreamInbound.parse(dataType: dataType, body: Array(message)) else { return }
            handleRunning(inbound)
        case .finished:
            break
        }
    }

    func takionAV(_ header: TakionAVHeader, payload: UnsafeMutableRawBufferPointer, receivedAt: UInt64) {
        guard stage == .running else { return }
        let word: UInt32
        var streamByte: UInt8?
        if header.isVideo {
            word = UInt32(truncatingIfNeeded: header.unitIndex) << 21
                | UInt32(truncatingIfNeeded: header.totalUnits - 1) << 10 | UInt32(truncatingIfNeeded: header.fecUnits)
        } else {
            word = UInt32(truncatingIfNeeded: header.unitIndex) << 24
                | UInt32(truncatingIfNeeded: header.totalUnits - 1) << 16
                | UInt32(truncatingIfNeeded: header.unitSize) << 8 | UInt32(truncatingIfNeeded: header.fecUnits) << 4
                | UInt32(truncatingIfNeeded: header.sourceUnits)
            if ps5 { streamByte = header.kind == .haptics ? AVUnit.hapticsStreamByte : 0 }
        }
        av.receive(
            AVUnit(
                kind: header.isVideo ? .video : .audio, packetIndex: header.packetIndex, frameIndex: header.frameIndex,
                unitWord: word, codec: header.codec, extensionFlag: header.extensionFlag,
                adaptiveStreamIndex: header.adaptiveStreamIndex, streamByte: streamByte, offset18: header.field18,
                payload: UnsafeRawBufferPointer(payload)))
    }

    // MARK: Congestion

    func congestionInputs() -> CongestionInputs {
        let video = av.video.takeCongestionCounters()
        let audio = av.audio.statistics
        let inputs = CongestionInputs(
            videoReceived: video.received, videoLost: video.lost, audioPacketsReceived: audio.packetsReceived,
            audioHighestFrameIndex: audio.highestFrameIndex)
        // The same arithmetic the connection runs on these inputs, to know what it reported.
        let counts = reporter.report(inputs, maxLoss: connection?.configuration.maxLoss ?? 0.05)
        statsLock.withLock {
            counters.congestionReports += 1
            counters.lastCongestion = StreamCongestionReport(
                received: Int(counts.received), lost: Int(counts.lost), count: counters.congestionReports)
        }
        return inputs
    }

    // MARK: Handshake (stream.md section 6)

    private func failStart(_ error: StreamStartError) {
        stage = .finished
        startEvents.post(.failed(error))
    }

    private func failStart(remoteDisconnect reason: String?) {
        failStart(.stream(StreamEndReason(consoleDisconnect: reason), detail: "the console sent a Disconnect"))
    }

    private func handleHandshake(_ bytes: [UInt8]) {
        let event: StreamHandshakeEvent
        do { event = try handshake.receive(bytes) } catch {
            failStart(.stream(StreamEndReason(code: .streamFailed), detail: "HelloReply rejected: \(error)"))
            return
        }
        switch event {
        case .ignored, .earlyStreamInfo:
            break
        case .remoteDisconnect(let reason):
            failStart(remoteDisconnect: reason)
        case .completed(let result):
            // Inside the bang's callback, so the ack that follows is the first secured packet (takion.md 6.7).
            connection?.enableCrypto(ecdhSecret: result.ecdhSecret, handshakeKey: handshakeKey)
            template.serverVersion = result.reply.serverVersion
            template.serverVersionText = result.reply.serverVersionText
            template.consoleSignatureMatches = result.consoleSignatureMatches
            stage = .awaitingStreamInfo
            startEvents.post(.helloReplied)
            if let early = handshake.earlyStreamInfo { applyStreamInfo(early) }
        }
    }

    /// Section 6.6 and 6.7: the profiles and audio header to the AV layer, then the three answers.
    private func applyStreamInfo(_ info: StreamInfoMessage) {
        guard let audioHeader = info.parsedAudioHeader else {
            failStart(.stream(StreamEndReason(code: .streamFailed), detail: "the audio header is not 14 bytes"))
            return
        }
        let profiles = info.usableProfiles
        av.setStreamInfo(profiles: profiles, audioHeader: info.audioHeader, codec: videoCodec)
        template.profiles = profiles
        template.audioHeader = audioHeader
        let connected = template
        // The commit point: from here the start succeeds, and any failure is an `ended` event.
        guard session?.markRunning(connected) == true else {
            stage = .finished
            return
        }
        stage = .running
        // The answers first (section 6.7), so a slow handler can't delay them.
        send(.streamInfoAck)
        send(.controllerConnection(dualSense: dualSense))
        if microphone { send(.microphoneStreamInfo) }
        emit { .connected(connected) }
        emit { .audioHeader(audioHeader) }
        startFeedback()
        startEvents.post(.ready)
    }

    // MARK: During the stream

    private func handleRunning(_ inbound: StreamInbound) {
        switch inbound {
        case .message(.disconnect(let disconnect)):
            stage = .finished
            session?.linkEnded(StreamEndReason(consoleDisconnect: disconnect.reason))
        case .message(.connectionQuality(let quality)):
            post(.connectionQuality(quality))
        case .rumble(let rumble):
            post(.rumble(rumble))
        case .triggerEffects(let effects):
            post(.triggerEffects(effects))
        case .padInfo(let info):
            let color = [info.red, info.green, info.blue]
            if lastColor != color {
                lastColor = color
                post(.ledColor(red: info.red, green: info.green, blue: info.blue))
            }
            if lastPlayer != info.playerIndex {
                lastPlayer = info.playerIndex
                post(.playerIndex(info.playerIndex))
            }
            if info.motionReset { post(.motionReset) }
        default:
            break
        }
    }

    // MARK: AV callbacks

    private func deliverAccessUnit(_ bytes: UnsafeRawBufferPointer, _ info: VideoFrameInfo) -> Bool {
        rejectRequested = false
        emit { .videoAccessUnit(bytes, info) }
        let rejected = rejectRequested
        let video = av.video.statistics
        statsLock.withLock {
            counters.frames += 1
            counters.frameBytes += bytes.count
            counters.video = video
            if rejected { counters.decoderRejects += 1 }
        }
        return !rejected
    }

    private func deliverAudio(_ event: AudioEvent) {
        if case .skipped(_, let count) = event { statsLock.withLock { counters.audioSkipped += count } }
        emit { .audioPacket(event) }
    }
}
