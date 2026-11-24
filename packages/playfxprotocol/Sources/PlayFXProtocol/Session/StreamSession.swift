import Foundation

/// Why a `StreamSession` command was not carried out, beyond `ControlCommandError`.
public enum StreamCommandError: Error, Sendable, Equatable {
    /// `StreamSessionOptions.microphone` was off, so the microphone was never announced.
    case microphoneNotEnabled
}

/// A whole Remote Play stream: session init and ctrl (`ControlSession`), the network probe, the Takion stream
/// connection and its handshake, the AV layer, controller input and the end (stream.md, takion.md, av.md).
///
/// `start` runs everything up to a working stream and returns the session; it throws `StreamStartError` if any
/// step fails (no `ended` event follows a failed start). From then on every ending (the app's `stop()`, a
/// console Disconnect, a lost Takion connection, ctrl ending) becomes one `StreamEndReason`, delivered exactly
/// once as the last event; no event follows it. Events can arrive before `start` returns (a login PIN request,
/// `connected`), which is why the handler gets the session.
///
/// Threading, exactly:
/// - **Takion receive thread** (a dedicated user-interactive thread for `.bsd`, a dispatch queue for `.nw`):
///   `connected` and `audioHeader` (once, before any AV event), `videoAccessUnit`, `parameterSets`,
///   `audioPacket` and `haptics`. These calls make no allocation per packet. The handler **must be fast**
///   (hand off, don't decode or draw inside it) and must copy any bytes it keeps: the views are valid only
///   during the call. A slow handler delays packets and shows up as reorder wait and loss.
/// - **The session's private serial queue**: `rumble`, `triggerEffects`, `ledColor`, `playerIndex`,
///   `motionReset`, `connectionQuality`, `loginPINRequested`, `loginPINResult`, the keyboard events, `stats`
///   and `ended`.
/// The two threads can call the handler at the same time, so it must be thread safe. Commands can be called from
/// any thread, including the handler (`stop()` from inside it is fine; it only schedules the stop).
public final class StreamSession: @unchecked Sendable {
    private enum Phase { case starting, running, finished }

    private struct Shared {
        var phase = Phase.starting
        var startAbort: StreamStartError?
        var initDone = false
        var control: ControlSession?
        var link: StreamLink?
        var connection: TakionConnection?
        var transport: DatagramTransport?
        var probe = StreamProbeResult.fallback
        var probeSucceeded = false
        var goToBedRequested = false
        var microphoneConnected = false
        var endReason: StreamEndReason?
        /// `ended` has been delivered (or a failed start has been torn down): nothing more will happen.
        var over = false
        /// Kept past `finish`, so the `ended` handler can still read what was negotiated.
        var negotiated: StreamConnectedInfo?
    }

    // Fixed at creation.
    private let address: String
    private let target: RPTarget
    private let registKey: [UInt8]
    private let rpKey: [UInt8]
    private let settings: StreamSettings
    private let transportKind: StreamTransport
    private let options: StreamSessionOptions
    private let environment: StreamEnvironment
    /// Internet play: the PSN session, the RUDP channel and the data hole this stream runs on; nil on the LAN.
    private let internet: InternetLink?
    let gate: EventGate
    private let queue = DispatchQueue(label: "PlayFXProtocol.StreamSession")

    private let lock = NSLock()
    private var shared = Shared()

    // Confined to `queue`.
    private var finishing = false
    private var heartbeatTimer: DispatchSourceTimer?
    private var statsTimer: DispatchSourceTimer?
    private var startedAt = 0.0
    private var previousFrames = 0
    private var previousBytes = 0
    private var previousTime = 0.0

    init(
        address: String, target: RPTarget, registKey: [UInt8], rpKey: [UInt8], settings: StreamSettings,
        transport: StreamTransport, options: StreamSessionOptions, environment: StreamEnvironment,
        internet: InternetLink? = nil, events: @escaping @Sendable (StreamEvent, StreamSession) -> Void
    ) {
        self.internet = internet
        self.address = address
        self.target = target
        self.registKey = registKey
        self.rpKey = rpKey
        self.settings = settings
        transportKind = transport
        self.options = options
        self.environment = environment
        gate = EventGate(handler: events)
    }

    deinit { quietShutdown() }

    // MARK: Starting

    /// Runs session init, ctrl, the network probe and the stream handshake. `registKey` and `rpKey` are 16 bytes
    /// each. A login PIN request arrives as `loginPINRequested`: answer it with `sendLoginPIN` (the wait for the
    /// user is not limited). Cancelling the task, or calling `stop()`, before the stream is up ends the start
    /// promptly and throws `.cancelled`; once it returns, call `stop()` instead.
    public static func start(
        address: String, target: RPTarget, registKey: [UInt8], rpKey: [UInt8], settings: StreamSettings,
        transport: StreamTransport = .bsd, options: StreamSessionOptions = StreamSessionOptions(),
        events: @escaping @Sendable (StreamEvent, StreamSession) -> Void
    ) async throws -> StreamSession {
        try await start(
            environment: StreamEnvironment(), address: address, target: target, registKey: registKey, rpKey: rpKey,
            settings: settings, transport: transport, options: options, events: events)
    }

    static func start(
        environment: StreamEnvironment, address: String, target: RPTarget, registKey: [UInt8], rpKey: [UInt8],
        settings: StreamSettings, transport: StreamTransport, options: StreamSessionOptions,
        internet: InternetLink? = nil, events: @escaping @Sendable (StreamEvent, StreamSession) -> Void
    ) async throws -> StreamSession {
        let session = StreamSession(
            address: address, target: target, registKey: registKey, rpKey: rpKey, settings: settings,
            transport: transport, options: options, environment: environment, internet: internet, events: events)
        do {
            try await withTaskCancellationHandler {
                try await session.bootstrap()
            } onCancel: {
                session.abortStart(.cancelled)
            }
        } catch {
            session.tearDownAfterFailedStart()
            throw error as? StreamStartError ?? StreamStartError.cancelled
        }
        return session
    }

    /// Starts a stream with a console reached through PSN, from the access token and the console's device ID alone:
    /// no pairing record is needed, because every internet session registers first (registration.md section 8) and
    /// uses the keys that registration returns.
    ///
    /// It takes about 30 s on a real PS5. `internet.progress` reports each stage; `internet.log` has one line per step
    /// for diagnosing a first run. Everything after the stream is up is as for the LAN start: the same events, the
    /// same commands, the same end. Over the internet the stream runs on the BSD socket transport.
    ///
    /// Cancelling the task, or `stop()`, before the stream is up ends the start promptly and throws
    /// `InternetStartError.cancelled`. Whatever way it ends (a failure, a cancel, `stop()`, the console ending the
    /// stream), the PSN session is left and the UPnP mappings are removed. After a throw, wait about 10 s before the
    /// next start: the console can refuse a new session as busy for a few seconds (psn.md section 8).
    ///
    /// - Throws: `InternetStartError`.
    public static func start(
        remote: PSNRemote, settings: StreamSettings, options: StreamSessionOptions = StreamSessionOptions(),
        internet: InternetOptions = InternetOptions(),
        events: @escaping @Sendable (StreamEvent, StreamSession) -> Void
    ) async throws -> StreamSession {
        try await start(
            remote: remote, settings: settings, options: options, internet: internet,
            internetEnvironment: InternetEnvironment(), streamEnvironment: StreamEnvironment(), events: events)
    }

    private func bootstrap() async throws {
        var control = options.control
        control.streamingType = settings.codec.streamingType
        internet?.report(.sessionInit)
        let ctrl: ControlSession
        do {
            ctrl = try await ControlSession.start(
                environment: environment.control, address: address, target: target, registKey: registKey,
                rpKey: rpKey, options: control
            ) { [weak self] event, session in self?.controlEvent(event, session) }
        } catch let error as SessionError {
            if error == .cancelled { throw StreamStartError.cancelled }
            let stage: StreamStartError.Stage = lock.withLock { shared.initDone } ? .ctrl : .sessionInit
            throw StreamStartError.session(error, stage: stage)
        }
        adopt(ctrl)
        let handoff = try await waitForHandoff(ctrl)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let thread = Thread { [self] in
                continuation.resume(with: Result { try connectStream(handoff) })
            }
            thread.name = "playfx.stream.start"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    private func adopt(_ control: ControlSession) {
        lock.withLock { if shared.control == nil { shared.control = control } }
    }

    /// Waits for the session ID (ctrl `0x33`), which makes the hand-off. A login PIN request can come first;
    /// the user's answer is not timed.
    private func waitForHandoff(_ control: ControlSession) async throws -> StreamHandoff {
        while true {
            if let abort = startAbort { throw abort }
            if Task.isCancelled { throw StreamStartError.cancelled }
            if let handoff = control.handoff { return handoff }
            if let ended = control.endReason {
                throw StreamStartError.stream(StreamEndReason(code: .ctrlFailed), detail: "ctrl ended: \(ended)")
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private var startAbort: StreamStartError? { lock.withLock { shared.startAbort } }

    /// Records why the start must stop (the first reason wins). Only while the stream isn't up yet.
    private func abortStart(_ error: StreamStartError) {
        let aborted = lock.withLock { () -> Bool in
            guard shared.phase == .starting, shared.startAbort == nil else { return false }
            shared.startAbort = error
            return true
        }
        // An internet start may be inside the data hole's probes or a PSN wait: wake it.
        if aborted { internet?.cancel() }
    }

    /// The blocking part of the start, on its own thread: probe, Takion, Hello, HelloReply, StreamInfo.
    private func connectStream(_ handoff: StreamHandoff) throws {
        let abort: @Sendable () -> Bool = { [weak self] in self?.startAbort != nil }
        func checkAbort() throws { if let reason = startAbort { throw reason } }
        func failure(_ detail: String) -> StreamStartError {
            .stream(StreamEndReason(code: .streamFailed), detail: detail)
        }

        // 1. The probe (stream.md section 5); on failure the fallbacks, and the stream goes on.
        var probe = StreamProbeResult.fallback
        var probeSucceeded = false
        var probeFailure: String?
        let probeTransport: DatagramTransport
        if let internet {
            // Steps 11 and 12: the data hole, then the probe on its socket (takion.md section 18).
            do {
                try internet.punchDataHole()
                probeTransport = try internet.probeTransport()
            } catch {
                throw internetFailure(error, internet)
            }
        } else {
            let probePort = environment.probePort ?? handoff.probePort
            probeTransport = environment.makeTransport(transportKind, handoff.consoleAddress, probePort, true)
        }
        switch NetworkProbe.run(transport: probeTransport, timing: environment.probe, abort: abort) {
        case .success(let result):
            probe = result
            probeSucceeded = true
        case .failure(let reason):
            probeFailure = reason.description
        }
        try checkAbort()
        if let internet {
            switch internet.switchToStream() {
            case .acknowledged:
                break
            case .aborted:
                // Cancelled (or the connection closed under the wait): the start's own abort says why.
                try checkAbort()
                throw StreamStartError.cancelled
            case .ctrlEnded:
                try checkAbort()
                internet.record(.stream(StreamEndReason(code: .ctrlFailed), detail: "ctrl ended while waiting for 0x0034"))
                throw StreamStartError.stream(StreamEndReason(code: .ctrlFailed), detail: "ctrl ended during the switch")
            case .timedOut:
                try checkAbort()
                internet.record(.switchNotAcknowledged)
                throw failure("no ctrl 0x0034 within 5 s of the RUDP switch message")
            }
        }
        try checkAbort()

        // 2. The Hello (key pair, launch spec) and the stream connection.
        let handshake: StreamHandshake
        do {
            handshake = try StreamHandshake(
                handoff: handoff, settings: settings, probe: probe, keyPair: try environment.makeKeyPair())
        } catch {
            throw failure("couldn't build the Hello: \(error)")
        }
        let request = settings.launchRequest(target: handoff.negotiatedVersion, model: handoff.consoleModel)
        let codec: VideoCodec = request.codec == .h264 ? .h264 : .hevc
        let takionVersion = Int(StreamHandshake.takionVersion(for: handoff.negotiatedVersion))
        let rawTransport: DatagramTransport
        if let internet {
            do { rawTransport = try internet.streamTransport(dontFragment: probeSucceeded) } catch {
                throw internetFailure(error, internet)
            }
        } else {
            let streamPort = environment.streamPort ?? handoff.streamPort
            rawTransport = environment.makeTransport(transportKind, handoff.consoleAddress, streamPort, probeSucceeded)
        }
        let transport: DatagramTransport = options.simulatedReceiveLoss.map {
            LossyDatagramTransport(rawTransport, filter: LossFilter($0))
        } ?? rawTransport
        let template = StreamConnectedInfo(
            target: handoff.negotiatedVersion, consoleModel: handoff.consoleModel, probe: probe,
            probeSucceeded: probeSucceeded, probeFailure: probeFailure, requested: request, videoCodec: codec,
            profiles: [], audioHeader: AudioHeader(channels: 0, bitsPerSample: 0, sampleRate: 0, frameSize: 0),
            serverVersion: nil, serverVersionText: nil, consoleSignatureMatches: false, takionVersion: takionVersion,
            transport: transport.name)
        let link = StreamLink(
            session: self, gate: gate, handshake: handshake, handshakeKey: handoff.streamHandshakeKey,
            dualSense: handoff.dualSenseEnabled, ps5: handoff.negotiatedVersion.isPS5, microphone: options.microphone,
            videoCodec: codec, template: template,
            clock: environment.clock)
        var configuration = TakionConfiguration()
        configuration.version = takionVersion
        configuration.mtuIn = probe.mtuIn
        configuration.mtuOut = probe.mtuOut
        configuration.handshakeTimeout = environment.streamConnectTimeout
        configuration.stepTimeout = environment.streamStepTimeout
        let connection = TakionConnection(configuration: configuration, transport: transport, delegate: link)
        link.connection = connection
        connection.setCongestionSource(link)
        lock.withLock {
            shared.link = link
            shared.connection = connection
            shared.transport = transport
            shared.probe = probe
            shared.probeSucceeded = probeSucceeded
        }
        try checkAbort()

        /// Waits for a start-up event; a failure or a closed connection ends the wait with its error.
        func waitFor(_ seconds: Double, _ what: String, _ wanted: @escaping (StreamLink.StartEvent) -> Bool) throws {
            let event = link.startEvents.take(timeout: seconds, abort: abort) { event -> StreamLink.StartEvent? in
                switch event {
                case .failed, .closed: event
                default: wanted(event) ? event : nil
                }
            }
            // Once the link has committed (phase running) the start has succeeded, whatever happens next.
            if lock.withLock({ shared.phase == .running }) { return }
            try checkAbort()
            switch event {
            case .failed(let error)?: throw error
            case .closed(let reason)?: throw failure("the stream connection closed (\(reason)) before \(what)")
            case nil: throw failure("no \(what) in \(seconds) s")
            default: break
            }
        }

        do { try connection.connect() } catch { throw failure("couldn't open the stream socket: \(error)") }
        try waitFor(environment.streamConnectTimeout + 1, "Takion handshake") { if case .connected = $0 { true } else { false } }

        // 3. Hello, HelloReply (the bang), StreamInfo; the link answers them on the receive thread.
        guard connection.sendMessage(channel: 1, dataType: 0, handshake.helloBytes) != nil else {
            throw failure("couldn't send the Hello")
        }
        link.helloSent = true
        try waitFor(environment.helloReplyTimeout, "HelloReply") { if case .helloReplied = $0 { true } else { false } }
        try waitFor(environment.streamInfoTimeout, "StreamInfo") { if case .ready = $0 { true } else { false } }
        try checkAbort()
        queue.sync { startTimers() }
    }

    /// What a failed internet step becomes inside the start: the typed error is kept on the link (so `start(remote:)`
    /// can throw it), and the start fails as a stream failure, or as cancelled.
    private func internetFailure(_ error: any Error, _ internet: InternetLink) -> StreamStartError {
        if let abort = startAbort { return abort }
        let typed = (error as? InternetStartError) ?? .stream(StreamEndReason(code: .streamFailed), detail: "\(error)")
        internet.record(typed)
        if typed == .cancelled { return .cancelled }
        return .stream(StreamEndReason(code: .streamFailed), detail: "internet: \(typed)")
    }

    /// Called by the link on the receive thread when the StreamInfo is in: false if the start was abandoned.
    /// This is the commit point of `start`: once it returns true, `start` returns the session and every later
    /// failure is an `ended` event.
    func markRunning(_ info: StreamConnectedInfo) -> Bool {
        let (committed, transport) = lock.withLock { () -> (Bool, DatagramTransport?) in
            guard shared.phase == .starting, shared.startAbort == nil else { return (false, nil) }
            shared.phase = .running
            shared.negotiated = info
            return (true, shared.transport)
        }
        // The simulated loss (testing only) starts here, so the handshake itself is left alone.
        (transport as? LossyDatagramTransport)?.filter.arm()
        return committed
    }

    /// Closes what a start that failed (or was cancelled) left open. No `ended` event.
    private func tearDownAfterFailedStart() {
        let (link, connection, control) = lock.withLock { () -> (StreamLink?, TakionConnection?, ControlSession?) in
            shared.phase = .finished
            return (shared.link, shared.connection, shared.control)
        }
        // The Disconnect goes out when a handshake step failed after the Hello was sent (section 11.1).
        Farewell.close(connection, disconnect: link?.helloSent == true && connection?.isConnected == true, pause: transportKind == .nw)
        link?.detach()
        control?.stop()
        gate.close()
        internet?.shutdown()
        lock.withLock {
            shared.link = nil
            shared.connection = nil
            shared.transport = nil
            shared.control = nil
            shared.over = true
        }
    }

    // MARK: Ctrl

    private func controlEvent(_ event: ControlEvent, _ control: ControlSession) {
        adopt(control)
        switch event {
        case .sessionInitialized:
            lock.withLock { shared.initDone = true }
            internet?.report(.ctrl)
        case .loginPINRequested: postControl(.loginPINRequested)
        case .loginPINResult(let accepted): postControl(.loginPINResult(accepted: accepted))
        case .keyboardOpened(let text): postControl(.keyboardOpened(text: text))
        case .keyboardTextChanged(let sequence, let text): postControl(.keyboardTextChanged(sequence: sequence, text: text))
        case .keyboardClosed: postControl(.keyboardClosed)
        case .ended(let reason): controlEnded(reason)
        case .connected, .sessionID, .heartbeat, .displayNotice, .notice: break
        }
    }

    /// Ctrl ending is the end of the stream (the console drops the session without ctrl heartbeats), unless it
    /// is our own `stop()`.
    private func controlEnded(_ reason: ControlEndReason) {
        if reason == .stoppedByClient { return }
        let bed = lock.withLock { shared.goToBedRequested }
        let end = reason == .consoleClosed && bed
            ? StreamEndReason(code: .streamRemoteShutdown) : StreamEndReason(code: .ctrlFailed)
        abortStart(.stream(end, detail: "ctrl ended: \(reason)"))
        // The console's Takion Disconnect, which says why, often arrives a moment after ctrl closes: give it
        // that moment (`finish` takes whichever comes first).
        queue.asyncAfter(deadline: .now() + environment.ctrlEndGrace) { [self] in finish(end) }
    }

    // MARK: Events and ending

    /// Delivers a control-plane event on the private queue (never after `ended`).
    func postControl(_ event: StreamEvent) {
        queue.async { [self] in
            guard let handler = gate.enter() else { return }
            handler(event, self)
            gate.leave()
        }
    }

    /// The stream ended from the outside (the link, ctrl): schedules the one `ended` event.
    func linkEnded(_ reason: StreamEndReason) {
        queue.async { [self] in finish(reason) }
    }

    /// Ends the running stream: Disconnect, close everything, then `ended`, once.
    private func finish(_ reason: StreamEndReason) {
        let first = lock.withLock { () -> Bool in
            guard shared.phase == .running, !finishing else { return false }
            finishing = true
            shared.phase = .finished
            shared.endReason = reason
            return true
        }
        guard first else { return }
        heartbeatTimer?.cancel()
        statsTimer?.cancel()
        heartbeatTimer = nil
        statsTimer = nil
        let (link, connection, control) = lock.withLock { (shared.link, shared.connection, shared.control) }
        // Section 11.1: the client says goodbye (also when the console did) and closes at once.
        Farewell.close(connection, disconnect: true, pause: transportKind == .nw)
        link?.detach()
        control?.stop()
        let handler = gate.close()
        internet?.shutdown()
        lock.withLock { shared.link = nil; shared.connection = nil; shared.control = nil }
        handler?(.ended(reason), self)
        lock.withLock { shared.over = true }
    }

    /// Without events: the session was dropped.
    private func quietShutdown() {
        heartbeatTimer?.cancel()
        statsTimer?.cancel()
        let (link, connection, control) = lock.withLock { (shared.link, shared.connection, shared.control) }
        Farewell.close(connection, disconnect: link?.helloSent == true, pause: transportKind == .nw)
        link?.detach()
        control?.stop()
        gate.close()
        internet?.shutdown()
    }

    // MARK: Timers

    private func startTimers() {
        guard lock.withLock({ shared.phase == .running }), !finishing else { return }
        startedAt = monotonicSeconds()
        previousTime = startedAt
        let heartbeat = DispatchSource.makeTimerSource(queue: queue)
        heartbeat.schedule(deadline: .now() + environment.heartbeatInterval, repeating: environment.heartbeatInterval)
        heartbeat.setEventHandler { [weak self] in self?.link?.sendHeartbeat() }
        heartbeat.resume()
        heartbeatTimer = heartbeat
        let stats = DispatchSource.makeTimerSource(queue: queue)
        stats.schedule(deadline: .now() + environment.statsInterval, repeating: environment.statsInterval)
        stats.setEventHandler { [weak self] in self?.deliverStats() }
        stats.resume()
        statsTimer = stats
    }

    private func deliverStats() {
        guard let stats = makeStats(), let handler = gate.enter() else { return }
        handler(.stats(stats), self)
        gate.leave()
    }

    private func makeStats() -> StreamStats? {
        let (link, connection, transport, probe, probeOK) = lock.withLock {
            (shared.link, shared.connection, shared.transport, shared.probe, shared.probeSucceeded)
        }
        guard let link, let connection, let transport else { return nil }
        let counters = link.snapshot()
        let takion = connection.stats
        let audio = link.av.audio.statistics
        let now = monotonicSeconds()
        let interval = max(now - previousTime, 0.001)
        var stats = StreamStats()
        stats.seconds = now - startedAt
        stats.videoFrames = counters.frames - previousFrames
        stats.videoMbps = Double(counters.frameBytes - previousBytes) * 8 / 1_000_000 / interval
        previousFrames = counters.frames
        previousBytes = counters.frameBytes
        previousTime = now
        stats.videoFramesTotal = counters.frames
        stats.framesLost = counters.video.framesLost
        stats.framesRecovered = counters.video.framesRewritten
        stats.fecRecoveries = counters.video.framesRecoveredByFEC
        stats.fecFailures = counters.video.framesFECFailed
        stats.framesDropped = counters.video.framesDropped
        stats.decoderRejects = counters.decoderRejects
        stats.idrRequestsSent = counters.idrSent
        stats.corruptFrameReportsSent = counters.corruptSent
        stats.audioPackets = audio.packetsReceived
        stats.audioConcealed = audio.framesConcealed
        stats.audioSkipped = counters.audioSkipped
        stats.reorder = StreamReorderStats(
            waitMicros: takion.reorder.waitMicros, holesFilled: takion.reorder.holesFilled,
            latePackets: takion.reorder.latePackets, holesLost: takion.reorder.holesLost,
            queueFullSkips: takion.reorder.queueFullSkips, timeoutSkips: takion.reorder.timeoutSkips,
            duplicates: takion.reorder.duplicates)
        stats.lastCongestion = counters.lastCongestion
        stats.rttMicroseconds = probe.rttMicroseconds
        stats.mtuIn = probe.mtuIn
        stats.mtuOut = probe.mtuOut
        stats.probeSucceeded = probeOK
        stats.transport = transport.name
        stats.timestampSource = Self.timestampSource(of: transport, takion)
        stats.datagramsReceived = takion.datagramsReceived
        stats.droppedBadGMAC = takion.droppedBadGMAC
        stats.retransmissions = takion.retransmissions
        stats.simulatedDrops = (transport as? LossyDatagramTransport)?.filter.dropped ?? 0
        stats.videoCodecByte = counters.videoCodecByte
        stats.padInfoBodyLength = counters.padInfoLength
        return stats
    }

    /// Where the receive times come from: the socket's own setting for BSD; for Network.framework the
    /// `receiveTime` metadata, or the callback time when the packets carried none.
    static func timestampSource(of transport: DatagramTransport, _ takion: TakionStats) -> String {
        if let lossy = transport as? LossyDatagramTransport { return timestampSource(of: lossy.inner, takion) }
        if let bsd = transport as? BSDDatagramTransport { return bsd.timestampSource }
        guard takion.datagramsReceived > 0 else { return "none yet" }
        return takion.softwareTimestamps < takion.datagramsReceived ? "receiveTime metadata" : "callback time"
    }

    // MARK: Commands

    /// Why the stream ended, once it has.
    public var endReason: StreamEndReason? { lock.withLock { shared.endReason } }

    /// The negotiated stream, once `connected`.
    public var connectedInfo: StreamConnectedInfo? { lock.withLock { shared.negotiated } }

    var link: StreamLink? { lock.withLock { shared.link } }
    var connection: TakionConnection? { lock.withLock { shared.connection } }
    var streamTransport: DatagramTransport? { lock.withLock { shared.transport } }
    /// For tests: which command latches are set.
    var commandFlags: (goToBed: Bool, microphoneConnected: Bool) {
        lock.withLock { (shared.goToBedRequested, shared.microphoneConnected) }
    }

    /// Sets the controller's state: history events for button, trigger and touch changes go out at once, and a
    /// feedback state when sticks or motion changed (the transport repeats it every 200 ms otherwise). A state
    /// set before the stream is up goes out when it is. Returns false when it couldn't be sent yet.
    @discardableResult
    public func setControllerState(_ state: ControllerState) -> Bool { link?.setControllerState(state) ?? false }

    /// Asks the console for a key frame, at most once per second. Returns false when throttled or not connected.
    @discardableResult
    public func requestIDR() -> Bool { link?.requestIDR() ?? false }

    /// Call from inside the `videoAccessUnit` handler when the decoder rejected the frame: the receiver then
    /// doesn't count it as good, and keeps asking for a key frame after repeated rejections.
    public func rejectVideoFrame() { link?.rejectCurrentFrame() }

    /// Sends one 40-byte Opus frame of the microphone (stream.md section 9.10). False when it isn't 40 bytes, the
    /// microphone wasn't enabled, or the stream isn't up. There is no Opus encoder in the package yet, so
    /// nothing calls this by itself: the app encodes and feeds frames.
    @discardableResult
    public func sendMicrophoneFrame(_ opusFrame: [UInt8]) -> Bool { link?.sendMicrophoneFrame(opusFrame) ?? false }

    /// Turns the microphone on or off on ctrl (`0x0030` the first time, then `0x0036`). This is signalling only:
    /// the audio itself is sent with `sendMicrophoneFrame`. Throws `StreamCommandError.microphoneNotEnabled` when
    /// `StreamSessionOptions.microphone` is off, or `ControlCommandError`.
    public func setMicrophone(on: Bool) throws {
        guard options.microphone else { throw StreamCommandError.microphoneNotEnabled }
        let control = try runningControl()
        if !lock.withLock({ shared.microphoneConnected }) {
            try control.connectMicrophone()
            lock.withLock { shared.microphoneConnected = true }
        }
        try control.setMicrophone(on)
    }

    /// Answers a login PIN request (`ControlSession.sendLoginPIN`).
    public func sendLoginPIN(_ pin: String) throws { try runningControl().sendLoginPIN(pin) }
    public func keyboardSetText(_ text: String) throws { try runningControl().keyboardSetText(text) }
    public func keyboardDone() throws { try runningControl().keyboardDone() }
    public func keyboardCancel() throws { try runningControl().keyboardCancel() }
    /// A PS5 may end the stream when the keyboard is enabled (ctrl.md section 6.5).
    public func enableKeyboard() throws { try runningControl().enableKeyboard() }

    /// Puts the console into rest mode. The stream then ends with `streamRemoteShutdown` (not an error).
    public func goToBed() throws {
        let control = try runningControl()
        try control.goToBed()
        lock.withLock { shared.goToBedRequested = true }
    }

    private func runningControl() throws -> ControlSession {
        guard let control = lock.withLock({ shared.control }) else { throw ControlCommandError.notRunning }
        return control
    }

    /// `stop()`, then waits until the session has ended and, for an internet session, until the PSN session is left (the
    /// DELETE and the wait for its notification) and the UPnP mappings are removed. Use it where the process may exit
    /// right after (an app quitting): `stop()` alone leaves that to a background task that dies with the process. The
    /// wait is bounded by the PSN limits (psn.md section 10) and the router's answers, 13 s on a bad network.
    public func stopAndWait() async {
        stop()
        let deadline = monotonicSeconds() + 5
        while !lock.withLock({ shared.over }) && monotonicSeconds() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        await internet?.shutdownAndWait()
    }

    /// Ends the stream: the Disconnect, everything closed, then `ended(stoppedByClient)`. Safe at any time and
    /// from any thread, repeatedly; during `start` it makes `start` throw `.cancelled`.
    public func stop() {
        queue.async { [self] in
            let phase = lock.withLock { shared.phase }
            switch phase {
            case .starting: abortStart(.cancelled)
            case .running: finish(StreamEndReason(code: .stoppedByClient))
            case .finished: break
            }
        }
    }
}
