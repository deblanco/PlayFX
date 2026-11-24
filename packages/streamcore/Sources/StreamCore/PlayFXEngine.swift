import Foundation
import os
import PlayFXProtocol

/// The library's session, named apart from StreamCore's own `StreamSession`.
typealias PlayFXLibrarySession = PlayFXProtocol.StreamSession

/// The second `StreamEngine`: PlayFX's own protocol implementation (the PlayFXProtocol package) instead of
/// libchiaki. See the "PlayFX engine" section of the package README for what it supports and how the contract's
/// items map onto the library.
///
/// Threads. The library delivers video, game audio, haptics and the connected event on its Takion receive thread and
/// everything else on its private serial queue; each of those calls goes straight through to the sink (video, audio
/// and haptics never overlap each other, as the contract needs), inside `gate`, which is how `stop()` waits for them
/// and how nothing reaches the sink after it. Commands run on the caller's thread. The receive thread's own state
/// (`av`) is touched only there; what commands share sits behind `shared` (a condition, for `stop()`'s waits),
/// `input` and `mic`.
final class PlayFXEngine: StreamEngine, @unchecked Sendable {
    typealias Events = @Sendable (StreamEvent, PlayFXLibrarySession) -> Void
    /// Starts the library's session (tests start it against a fake console's environment).
    typealias Starter = @Sendable (
        _ address: String, _ target: RPTarget, _ registKey: [UInt8], _ rpKey: [UInt8], _ settings: StreamSettings,
        _ options: StreamSessionOptions, _ events: @escaping Events
    ) async throws -> PlayFXLibrarySession

    static let defaultStarter: Starter = { address, target, registKey, rpKey, settings, options, events in
        try await PlayFXLibrarySession.start(
            address: address, target: target, registKey: registKey, rpKey: rpKey, settings: settings, options: options,
            events: events)
    }

    /// Starts the library's internet session through PSN (tests start it against fakes of PSN, the router and the console).
    typealias RemoteStarter = @Sendable (
        _ remote: PSNRemote, _ settings: StreamSettings, _ options: StreamSessionOptions, _ internet: InternetOptions,
        _ events: @escaping Events
    ) async throws -> PlayFXLibrarySession

    static let defaultRemoteStarter: RemoteStarter = { remote, settings, options, internet, events in
        try await PlayFXLibrarySession.start(
            remote: remote, settings: settings, options: options, internet: internet, events: events)
    }

    /// The factory `StreamSession` uses for `Options.engine == "playfx"`.
    static let factory: StreamEngineFactory = { try PlayFXEngine(config: $0, sink: $1) }

    /// A factory that starts the library's session with `start`, and an internet one with `startRemote` (tests).
    static func factory(
        start: @escaping Starter, startRemote: @escaping RemoteStarter = PlayFXEngine.defaultRemoteStarter
    ) -> StreamEngineFactory {
        { try PlayFXEngine(config: $0, sink: $1, start: start, startRemote: startRemote) }
    }

    // MARK: State

    /// Unretained, as the contract asks: the session owns the engine.
    unowned(unsafe) let sink: any StreamEngineSink
    let gate = PlayFXSinkGate()
    let console: StreamConsoleName
    /// Reaching the console through PSN (`config.remote`): stopping then also leaves the PSN session.
    let isInternet: Bool
    /// The receive thread's state; only that thread touches it.
    let av = PlayFXReceiveState()

    struct Shared {
        var session: PlayFXLibrarySession?
        var stopCalled = false
        /// `start` returned (a session, or an error).
        var startFinished = false
        var sessionStarted = false
        /// The library delivered `ended` (or the start failed: no session to wait for).
        var libraryEnded = false
        var startTask: Task<Void, Never>?
        /// Internet play: the latest `RemoteStage` reported (its position in `RemoteStage.order`), so each goes out once.
        var remoteStage = -1
        var stats = StreamEngineStats()
        /// The console refused the last PIN: the next request is a retry.
        var pinWrong = false
    }
    private let condition = NSCondition()
    private var shared = Shared()

    func locked<T>(_ body: (inout Shared) -> T) -> T {
        condition.lock()
        defer { condition.unlock() }
        return body(&shared)
    }

    let input = OSAllocatedUnfairLock(initialState: PlayFXInput())

    struct Microphone {
        /// Frames are sent: the console was told the microphone is on.
        var on = false
        /// The console was told at least once (the microphone stream is set up).
        var connected = false
        /// Asked for before the stream was up: turned on once it is.
        var wanted = false
        var encoder: PlayFXOpusMicrophone?
    }
    let mic = OSAllocatedUnfairLock(initialState: Microphone())
    /// Orders `setMicrophone` calls (ctrl messages and `mic.on` stay in step) and `setController` calls (a state is mapped
    /// and sent under one lock, so concurrent calls can't reorder). Never taken on the library's threads.
    private let microphoneCommands = NSLock()
    private let controllerCommands = NSLock()

    // MARK: Starting

    /// Settings for the library from the session's config: resolution from the height (the largest preset at or below
    /// it, 360 at least), 60 fps from 60 up and 30 below, the codec as asked (H.264 for a PS4), the bitrate as given or,
    /// when 0, the library's preset for the resolution (360p 2000, 540p 6000, 720p 10000, 1080p 15000 kbit/s, at either
    /// frame rate). `autoDowngrade` goes to the library, which lowers a base PS4's 1080p to 720p with it.
    static func settings(for config: StreamEngineConfig) -> StreamSettings {
        let resolution: StreamResolution =
            config.height >= 1080 ? .p1080 : config.height >= 720 ? .p720 : config.height >= 540 ? .p540 : .p360
        let codec: StreamCodec
        switch config.codec {
        case _ where !config.ps5: codec = .h264
        case .h264: codec = .h264
        case .hevc: codec = .hevc
        case .hevcHDR: codec = .hevcHDR
        }
        return StreamSettings(
            resolution: resolution, frameRate: config.fps >= 60 ? .fps60 : .fps30,
            bitrate: config.bitrateKbps > 0 ? .kbps(config.bitrateKbps) : .preset, codec: codec,
            autoDowngrade: config.autoDowngrade)
    }

    /// Starts connecting in the background and returns. Throws only for internet play on a PS4 or without a 64-hex-character
    /// PSN device ID (a PS5's); the rest of an internet start (PSN, the holes, registration) runs in the background and
    /// reports as `.remoteProgress` events and, when it fails, `.quit`.
    ///
    /// The target is a PS5, or a PS4 on Remote Play version 10 (the config doesn't carry the PS4's version). The
    /// microphone is announced to the console at the start (`StreamSessionOptions.microphone`), so voice chat can be
    /// turned on later. The account ID isn't needed (the stream's keys are the registration and RP keys; over the
    /// internet the library registers first and uses the keys that registration returns).
    init(
        config: StreamEngineConfig, sink: any StreamEngineSink, start: @escaping Starter = PlayFXEngine.defaultStarter,
        startRemote: @escaping RemoteStarter = PlayFXEngine.defaultRemoteStarter,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        if let remote = config.remote {
            guard config.ps5, Self.isDeviceID(remote.duid) else {
                throw ConsoleError.message("Internet play needs a PS5 and its PSN device ID")
            }
        }
        self.sink = sink
        console = config.ps5 ? .ps5 : .ps4
        isInternet = config.remote != nil
        var options = StreamSessionOptions()
        options.microphone = true
        let settings = Self.settings(for: config)
        // Both closures hold the engine weakly: the library keeps the handler until the session ends.
        let events: Events = { [weak self] event, session in self?.handle(event, session) }
        let task: Task<Void, Never>
        if let remote = config.remote {
            let psn = PSNRemote(accessToken: remote.token, consoleDUID: remote.duid, platform: .ps5)
            let internet = Self.internetOptions(environment: environment) { [weak self] stage in self?.remoteProgress(stage) }
            task = Task { [weak self] in
                do {
                    let session = try await startRemote(psn, settings, options, internet, events)
                    if let self { self.startSucceeded(session) } else { session.stop() }
                } catch {
                    self?.startFailed(error)
                }
            }
        } else {
            let target: RPTarget = config.ps5 ? .ps5v1 : .ps4v10
            let (address, regist, rp) = (config.host, [UInt8](config.registKey), [UInt8](config.rpKey))
            task = Task { [weak self] in
                do {
                    let session = try await start(address, target, regist, rp, settings, options, events)
                    if let self { self.startSucceeded(session) } else { session.stop() }
                } catch {
                    self?.startFailed(error)
                }
            }
        }
        locked { $0.startTask = task }
    }

    deinit {
        // Normally `stop()` ran; if not, end the library's session quietly (the sink may be gone).
        let (task, session) = locked { s -> (Task<Void, Never>?, PlayFXLibrarySession?) in
            s.stopCalled ? (nil, nil) : (s.startTask, s.session)
        }
        task?.cancel()
        session?.stop()
    }

    private func startSucceeded(_ session: PlayFXLibrarySession) {
        let stopped = locked { s -> Bool in
            s.sessionStarted = true
            if !s.stopCalled && !s.libraryEnded { s.session = session }
            return s.stopCalled
        }
        if stopped { session.stop() }
        locked { $0.startFinished = true }
        condition.broadcast()
    }

    private func startFailed(_ error: Error) {
        locked { s in
            s.startFinished = true
            s.libraryEnded = true
        }
        condition.broadcast()
        guard gate.enterForQuit() else { return }
        defer { endCall() }
        let quit = Self.quit(forStartFailure: error, console: console)
        sink.deliver(.quit(reason: quit.reason, error: quit.error, kind: quit.kind))
    }

    // MARK: Quit

    struct Quit: Equatable {
        var reason: String
        var error: Bool
        var kind: StreamSession.QuitKind
    }

    /// How the library's end reason reads to the app: busy, dropped (lost connection or timeout) and stopped as
    /// themselves; everything else is final (the console ended it on purpose, refused it, or it never connected).
    static func quit(for end: StreamEndReason, console: StreamConsoleName) -> Quit {
        var reason = end.userMessage(console: console)
        if end.kind == .other, let text = end.remoteText, !text.isEmpty { reason += " (\(text))" }
        let kind: StreamSession.QuitKind
        switch end.retryClass {
        case .busy: kind = .busy
        case .dropped: kind = .dropped
        case .stopped: kind = .stopped
        case .final: kind = .final
        }
        return Quit(reason: reason, error: end.isError, kind: kind)
    }

    /// A start that failed: the console being busy is retried, anything else is final (a connection that was never
    /// made isn't "dropped").
    static func quit(forStartFailure error: Error, console: StreamConsoleName) -> Quit {
        if let failure = error as? InternetStartError {
            if case .cancelled = failure { return stopped }
            return Quit(
                reason: failure.userMessage(console: console), error: true,
                kind: failure.retryClass == .busy ? .busy : .final)
        }
        guard let failure = error as? StreamStartError else {
            return Quit(reason: "Couldn't start the stream: \(error.localizedDescription)", error: true, kind: .final)
        }
        if case .cancelled = failure { return stopped }
        let end = failure.endReason
        return Quit(
            reason: failure.userMessage(console: console), error: end?.isError ?? true,
            kind: end?.code == .consoleBusy ? .busy : .final)
    }

    private static let stopped = Quit(reason: "Stopped", error: false, kind: .stopped)

    // MARK: Commands

    var isStopped: Bool { locked { $0.stopCalled } }

    /// The library's session, unless stopped.
    var session: PlayFXLibrarySession? { locked { $0.stopCalled ? nil : $0.session } }

    func setController(_ state: ControllerState) {
        controllerCommands.lock()
        defer { controllerCommands.unlock() }
        guard !isStopped else { return }
        let mapped = input.withLock { $0.map(state) }
        session?.setControllerState(mapped)
    }

    func setLoginPin(_ pin: String) {
        guard let session else { return }
        do { try session.sendLoginPIN(pin) } catch { Log.warning(.session, "PlayFX engine: login PIN not sent (\(error))") }
    }

    /// Before the stream is up a request is kept and applied once it is. Turning it off before it was ever on does
    /// nothing (the console isn't told about a microphone it never had); on is recorded only once the console was told.
    func setMicrophone(_ on: Bool) {
        microphoneCommands.lock()
        defer { microphoneCommands.unlock() }
        guard !isStopped else { return }
        guard let session else {
            mic.withLock { $0.wanted = on }
            return
        }
        mic.withLock { $0.wanted = false }
        if !on {
            guard mic.withLock({ m -> Bool in
                m.on = false
                return m.connected
            }) else { return }
            do { try session.setMicrophone(on: false) } catch { Log.warning(.session, "PlayFX engine: microphone not switched off (\(error))") }
            return
        }
        guard mic.withLock({ m -> Bool in
            if m.encoder == nil { m.encoder = PlayFXOpusMicrophone() }
            return m.encoder != nil
        }) else { return Log.warning(.session, "PlayFX engine: no Opus encoder for the microphone") }
        do {
            try session.setMicrophone(on: true)
            mic.withLock { m in
                m.on = true
                m.connected = true
            }
        } catch {
            Log.warning(.session, "PlayFX engine: microphone not switched on (\(error))")
        }
    }

    func sendMicrophoneFrame(_ samples: UnsafeBufferPointer<Int16>) {
        guard let packet = mic.withLockUnchecked({ m in m.on ? m.encoder?.encode(samples) : nil }), let session else { return }
        session.sendMicrophoneFrame(packet)
    }

    func setKeyboardText(_ text: String) {
        try? session?.keyboardSetText(text)
    }

    func finishKeyboard(accept: Bool) {
        guard let session else { return }
        if accept { try? session.keyboardDone() } else { try? session.keyboardCancel() }
    }

    func requestKeyFrame() {
        session?.requestIDR()
    }

    func goToBed() {
        try? session?.goToBed()
    }

    /// The round trip the probe measured, the console's target bitrate, and the reorder queue's totals (the library
    /// reports those once a second). All zero before the stream is up and after `stop()`.
    func stats() -> StreamEngineStats { locked { $0.stopCalled ? StreamEngineStats() : $0.stats } }

    // MARK: Stopping

    /// Waits this long for the start to wind down and for the library's `ended` (they're prompt; this is a cap).
    static let stopTimeout = 5.0
    /// Waits this long for an internet session to leave PSN and remove its router mappings (the library bounds each of
    /// those by PSN's limits and the router's answers; this is the cap for all of it).
    static let internetStopTimeout = 8.0
    /// What `stop()` waits for the PSN session to be left (tests shorten it).
    var internetLeaveWait = PlayFXEngine.internetStopTimeout

    func stop() {
        let nested = gate.isInsideCall
        let (first, session, task) = locked { s -> (Bool, PlayFXLibrarySession?, Task<Void, Never>?) in
            guard !s.stopCalled else { return (false, nil, nil) }
            s.stopCalled = true
            return (true, s.session, s.startTask)
        }
        guard first else { return }
        gate.close()
        task?.cancel()
        // An internet session also leaves PSN and removes its mappings; that is waited for below, once the quit is out.
        var left: DispatchSemaphore?
        if isInternet, let session {
            let done = DispatchSemaphore(value: 0)
            left = done
            Task.detached {
                await session.stopAndWait()
                done.signal()
            }
        } else {
            session?.stop()
        }
        if !gate.waitForOtherCalls(timeout: Self.stopTimeout) {
            Log.warning(.session, "PlayFX engine: a sink call was still running after \(Self.stopTimeout) s; stopping anyway")
        }
        if nested {
            // The quit waits for this thread's own sink call to return (never delivered from inside `stop()`).
            _ = gate.claimQuitLater()
        } else if gate.claimQuit() {
            deliverStoppedQuit()
        }
        mic.withLock { $0 = Microphone() }
        // From inside a sink call the library can't finish (its `ended` waits for that call), so don't wait for it.
        guard !nested else { return }
        if !waitUntil({ $0.startFinished && ($0.libraryEnded || !$0.sessionStarted) }) {
            Log.warning(.session, "PlayFX engine: the library's session didn't end within \(Self.stopTimeout) s")
        }
        if let left, left.wait(timeout: .now() + internetLeaveWait) == .timedOut {
            Log.warning(.session, "PlayFX engine: the PSN session wasn't left within \(internetLeaveWait) s; it ends in the background")
        }
    }

    /// Called as a sink call returns: a quit that a nested `stop()` held goes out now, from this engine thread.
    func endCall() {
        gate.leave()
        if gate.takePendingQuit() {
            sink.deliver(Self.stoppedQuit)
            gate.quitDelivered()
        }
    }

    static let stoppedQuit = StreamSession.Event.quit(reason: "Stopped", error: false, kind: .stopped)

    /// `.quit(kind: .stopped)` from a thread of ours (never inside `stop()` itself), waited for up to `stopTimeout`.
    /// The thread holds the sink unretained: the sink may be the session in its `deinit`, and nothing of ours may
    /// retain it or touch it once `stop()` has returned.
    private func deliverStoppedQuit() {
        let unretained = Unmanaged.passUnretained(sink as AnyObject)
        let delivered = DispatchSemaphore(value: 0)
        let thread = Thread {
            do {
                // swiftlint:disable:next force_cast
                let sink = unretained.takeUnretainedValue() as! any StreamEngineSink
                sink.deliver(Self.stoppedQuit)
            }
            delivered.signal()
        }
        thread.name = "playfx.engine.quit"
        thread.start()
        if delivered.wait(timeout: .now() + Self.stopTimeout) == .timedOut {
            Log.warning(.session, "PlayFX engine: the quit event wasn't taken within \(Self.stopTimeout) s")
        }
    }

    private func waitUntil(_ done: (Shared) -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: Self.stopTimeout)
        condition.lock()
        defer { condition.unlock() }
        while !done(shared) && condition.wait(until: deadline) {}
        return done(shared)
    }

    /// The library's `ended` came: `stop()` can finish.
    func libraryDidEnd() {
        locked { s in
            s.libraryEnded = true
            s.session = nil
        }
        condition.broadcast()
    }
}
