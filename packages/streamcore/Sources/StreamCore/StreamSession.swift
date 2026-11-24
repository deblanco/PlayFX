import CoreVideo
import Foundation
import os

/// One Remote Play streaming session: the protocol engine (`StreamEngine`, libchiaki for now) → VideoToolbox
/// decode → frames, PCM → AudioPlayer, ControllerState → console.
public final class StreamSession: StreamEngineSink {
    public struct Options: Codable, Sendable {
        public var height: Int = 1080   // 360, 540, 720, 1080
        public var fps: Int = 60        // 30, 60
        public var hevc: Bool = true    // PS5 only; PS4 is always H.264
        public var bitrate: Int = 0     // kbps, 0 = preset default
        public var audio: Bool = true
        /// Let the console lower the resolution when the network can't keep up.
        public var autoDowngrade: Bool = true
        /// HDR10 (HEVC Main10, PQ, BT.2020) when the game and the console's HDR setting allow it. PS5 + HEVC only.
        public var hdr: Bool = false
        /// The protocol engine: "chiaki" (libchiaki, the default) or "playfx" (PlayFXProtocol, on the local network and
        /// over the internet through PSN). Anything else is "chiaki".
        public var engine: String = "chiaki"
        public init() {}

        /// Tests put an environment (`[String: String]`) in a decoder's `userInfo` under this key instead of the process's.
        static let environmentKey = CodingUserInfoKey(rawValue: "playfx.environment")!

        /// DEV ONLY, TEMPORARY (libchiaki is being removed): the engine for JSON that doesn't name one, from the
        /// `PLAYFX_ENGINE` variable ("playfx" or "chiaki"; anything else, or unset, is "chiaki").
        static func defaultEngine(environment: [String: String]) -> String {
            environment["PLAYFX_ENGINE"] == "playfx" ? "playfx" : "chiaki"
        }

        /// Missing keys keep their defaults, so older hosts' JSON still decodes.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Options()
            height = try c.decodeIfPresent(Int.self, forKey: .height) ?? d.height
            fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? d.fps
            hevc = try c.decodeIfPresent(Bool.self, forKey: .hevc) ?? d.hevc
            bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate) ?? d.bitrate
            audio = try c.decodeIfPresent(Bool.self, forKey: .audio) ?? d.audio
            autoDowngrade = try c.decodeIfPresent(Bool.self, forKey: .autoDowngrade) ?? d.autoDowngrade
            hdr = try c.decodeIfPresent(Bool.self, forKey: .hdr) ?? d.hdr
            engine = try c.decodeIfPresent(String.self, forKey: .engine) ??
                Self.defaultEngine(environment: decoder.userInfo[Self.environmentKey] as? [String: String]
                                    ?? ProcessInfo.processInfo.environment)
        }
    }

    /// What a quit means for reconnecting.
    public enum QuitKind: String, Sendable {
        /// Console asleep, disconnected on purpose, incompatible…: don't retry.
        case final
        /// Stopped by this client (e.g. replaced by a new session).
        case stopped
        /// Remote Play is still in use on the console (it is for ~9 s after a session ends): retry soon.
        case busy
        /// The connection was lost mid-stream: worth reconnecting.
        case dropped
    }

    /// Reaching the console over the internet (PS5): a valid PSN token and its PSN device ID.
    public struct Remote: Sendable {
        public var token: String
        public var duid: String
        public init(token: String, duid: String) {
            self.token = token
            self.duid = duid
        }
    }

    /// Steps of connecting over the internet, as they start.
    public enum RemoteStage: String, Sendable {
        /// PSN session and reaching the console (each step can take up to ~30 s).
        case linking
        /// Linked; opening the data connection.
        case data
        /// Data connection open.
        case connected
    }

    public enum Event: Sendable {
        case connected
        case remoteProgress(RemoteStage)
        case quit(reason: String, error: Bool, kind: QuitKind)
        case loginPinRequested(incorrect: Bool)
        /// The console's rumble: lasts until it says otherwise.
        case rumble(left: UInt8, right: UInt8)
        /// Rumble made from the DualSense haptics stream: repeated while it lasts, and over when it stops
        /// coming (the console sends nothing once an effect ends).
        case hapticRumble(left: UInt8, right: UInt8)
        /// DualSense adaptive-trigger effects for the left (L2) and right (R2) triggers.
        case triggerEffects(left: TriggerEffect, right: TriggerEffect)
        /// The DualSense light bar colour the game asks for.
        case light(red: UInt8, green: UInt8, blue: UInt8)
        /// The pad's player number as the console counts it (0 = player 1).
        case playerIndex(Int)
        case nickname(String)
        /// The console's text keyboard: a field was focused (with its text), its text changed, or the
        /// console closed it.
        case keyboard(KeyboardChange, text: String)
    }

    public enum KeyboardChange: String, Sendable {
        case open, change, close
    }

    public struct Stats: Codable, Sendable {
        public var framesDecoded = 0
        public var decodeErrors = 0
        public var framesLost = 0
        public var width = 0
        public var height = 0
        /// Compressed video bytes received; the host derives the live bitrate from it.
        public var bytesReceived = 0
        /// Round trip to the console, measured while connecting (0 until then).
        public var rttMs = 0.0
        /// The bitrate the console's encoder aims for now (kbps; 0 until it reports one).
        public var targetBitrateKbps = 0
        /// VideoToolbox decode time per frame, smoothed.
        public var decodeMs = 0.0
        /// How long a missing video packet is waited for before it's skipped, measured from the link (0 until
        /// the stream connects), and what libchiaki learned it from: holes that filled while waiting, packets
        /// that came after their hole was skipped, skipped holes nothing came for, and holes skipped because
        /// the reorder queue was full. Totals for the stream.
        public var reorderWaitMs = 0.0
        public var reorderHolesFilled = 0
        public var reorderLatePackets = 0
        public var reorderHolesLost = 0
        public var reorderQueueFull = 0

        /// Takes the engine's figures: the round trip and the reorder wait in µs as ms, the target bitrate in
        /// bit/s as kbps.
        mutating func setEngine(_ engine: StreamEngineStats) {
            rttMs = Double(engine.rttMicros) / 1000
            targetBitrateKbps = engine.targetBitrate / 1000
            reorderWaitMs = Double(engine.reorder.waitMicros) / 1000
            reorderHolesFilled = engine.reorder.holesFilled
            reorderLatePackets = engine.reorder.latePackets
            reorderHolesLost = engine.reorder.holesLost
            reorderQueueFull = engine.reorder.queueFullSkips
        }
    }

    /// Called from the engine's threads.
    /// Events that arrive before it's set (a session can report progress, or fail, right as it starts)
    /// are kept and delivered when it is.
    public var onEvent: ((Event) -> Void)? {
        get { events.withLock { $0.handler?.call } }
        set {
            let pending = events.withLock { state -> [Event] in
                state.handler = newValue.map(EventHandler.init)
                defer { state.pending = [] }
                return newValue == nil ? [] : state.pending
            }
            pending.forEach { newValue?($0) }
        }
    }

    /// The handler, boxed. A closure kept directly in the lock's state is re-wrapped in a conversion thunk
    /// every time that state goes through `withLock` as `inout`, so with one event at a time it grew by two
    /// calls per event, until a few thousand haptics events overflowed the receive thread's stack (seen on
    /// the PS5). A class reference passes through unchanged.
    private final class EventHandler: @unchecked Sendable {
        let call: (Event) -> Void
        init(_ call: @escaping (Event) -> Void) { self.call = call }
    }
    private let events = OSAllocatedUnfairLock(initialState: (handler: EventHandler?.none, pending: [Event]()))

    /// Delivers `event` now, or keeps it until `onEvent` is set.
    func deliver(_ event: Event) {
        let handler = events.withLock { state -> EventHandler? in
            if state.handler == nil { state.pending.append(event) }
            return state.handler
        }
        handler?.call(event)
    }
    /// Called from the video thread with every decoded frame.
    /// Each decoded frame with its place in the stream (counting frames lost on the way), for pacing.
    /// Set on the main thread after the engine has started (its video thread reads it): behind a lock, boxed
    /// like `onEvent`'s handler.
    public var onFrame: ((CVPixelBuffer, UInt64?) -> Void)? {
        get { frameHandler.withLock { $0?.call } }
        set { frameHandler.withLock { $0 = newValue.map(FrameHandler.init) } }
    }
    private final class FrameHandler: @unchecked Sendable {
        let call: (CVPixelBuffer, UInt64?) -> Void
        init(_ call: @escaping (CVPixelBuffer, UInt64?) -> Void) { self.call = call }
    }
    private let frameHandler = OSAllocatedUnfairLock<FrameHandler?>(initialState: nil)
    /// Each compressed frame as it reaches the decoder: its place in the stream and its size in bytes (for
    /// measuring, e.g. how small the console's repeats of a picture are). Set like `onFrame`.
    public var onVideoSample: ((UInt64, Int) -> Void)? {
        get { sampleHandler.withLock { $0?.call } }
        set { sampleHandler.withLock { $0 = newValue.map(SampleHandler.init) } }
    }
    private final class SampleHandler: @unchecked Sendable {
        let call: (UInt64, Int) -> Void
        init(_ call: @escaping (UInt64, Int) -> Void) { self.call = call }
    }
    private let sampleHandler = OSAllocatedUnfairLock<SampleHandler?>(initialState: nil)
    /// The index of the last frame handed to the decoder.
    private var frameIndex: UInt64 = 0

    public var stats: Stats {
        var s = lock.withLock { _stats }
        withEngine { s.setEngine($0.stats()) }
        s.decodeMs = decoder.decodeMilliseconds
        return s
    }
    public var latestFrame: CVPixelBuffer? { lock.withLock { _latestFrame } }
    /// The newest decoded frame with how many came so far: the count tells frames apart (the decoder's
    /// buffers are reused, so the buffer doesn't).
    public var latestNumberedFrame: (frame: CVPixelBuffer, number: Int)? {
        lock.withLock { _latestFrame.map { ($0, _stats.framesDecoded) } }
    }
    /// Waits for the frames VideoToolbox is still decoding (tests).
    func waitForDecodedFrames() { decoder.flush() }

    private var engine: (any StreamEngine)?
    /// Held while the engine is used, and by `stop()` while it takes the engine out: callers off the main thread (the
    /// latency test's presses, a stats poll) can't use a session being stopped.
    private let engineLock = NSRecursiveLock()

    /// Runs `body` with the session's engine unless it was stopped.
    private func withEngine(_ body: (any StreamEngine) -> Void) {
        engineLock.lock()
        defer { engineLock.unlock() }
        if let engine { body(engine) }
    }
    private let decoder: VideoDecoder
    private let audio: AudioPlayer?
    /// The DualSense haptics stream played on a pad connected by USB (otherwise it becomes rumble).
    private let padHaptics = DualSenseHaptics()
    private let lock = OSAllocatedUnfairLock()
    private var _stats = Stats()
    private var _latestFrame: CVPixelBuffer?

    /// Starts connecting to the console on the engine `options.engine` names (libchiaki unless it's "playfx");
    /// progress and the outcome arrive as events.
    public convenience init(credentials: ConsoleCredentials, options: Options = Options(), remote: Remote? = nil) throws {
        try self.init(credentials: credentials, options: options, remote: remote, engine: Self.engineFactory(for: options))
    }

    /// PlayFX's own engine runs the "playfx" choice, on the local network and over the internet.
    static func usesPlayFX(_ options: Options) -> Bool { options.engine == "playfx" }

    /// The factory for the engine `options.engine` names.
    static func engineFactory(for options: Options) -> StreamEngineFactory {
        if usesPlayFX(options) { return PlayFXEngine.factory }
        return { try ChiakiEngine(config: $0, sink: $1) }
    }

    /// Starts connecting through the engine `makeEngine` starts (tests: a stand-in).
    init(credentials: ConsoleCredentials, options: Options = Options(), remote: Remote? = nil,
         engine makeEngine: StreamEngineFactory) throws {
        guard let regist = Data(base64Encoded: credentials.registKey), regist.count == StreamEngineConfig.registKeySize,
              let rpKey = Data(base64Encoded: credentials.rpKey), rpKey.count == StreamEngineConfig.rpKeySize,
              let account = Data(base64Encoded: credentials.accountId), account.count == StreamEngineConfig.accountIDSize
        else { throw ConsoleError.message("Invalid console credentials") }

        let hevc = credentials.ps5 && options.hevc
        let hdr = hevc && options.hdr
        decoder = VideoDecoder(codec: hevc ? .hevc : .h264, tenBit: hdr)
        audio = options.audio ? AudioPlayer() : nil

        // Weak: VideoToolbox can still hand over a frame while the session is going away.
        decoder.onIndexedFrame = { [weak self] frame, index in
            guard let self else { return }
            lock.withLock {
                self._latestFrame = frame
                self._stats.framesDecoded += 1
                self._stats.width = CVPixelBufferGetWidth(frame)
                self._stats.height = CVPixelBufferGetHeight(frame)
            }
            frameHandler.withLock { $0 }?.call(frame, index)
        }

        let config = StreamEngineConfig(
            host: credentials.address, ps5: credentials.ps5, registKey: regist, rpKey: rpKey, accountID: account,
            height: options.height, fps: options.fps, codec: hdr ? .hevcHDR : hevc ? .hevc : .h264,
            bitrateKbps: options.bitrate, autoDowngrade: options.autoDowngrade, remote: remote)
        engine = try makeEngine(config, self)
    }

    deinit { stop() }

    /// The Mac's pointer used as a touchpad finger: where it touches (nil = lifted) and whether the
    /// touchpad is pressed. Merged into every controller state, so it works alongside a pad.
    public struct PointerTouch: Equatable, Sendable {
        public var touch: ControllerState.Touch?
        public var pressed: Bool
        public init(touch: ControllerState.Touch?, pressed: Bool) {
            self.touch = touch
            self.pressed = pressed
        }
        public static let none = PointerTouch(touch: nil, pressed: false)
    }

    private let input = OSAllocatedUnfairLock(initialState: (controller: ControllerState(), pointer: PointerTouch.none))

    public func setController(_ s: ControllerState) {
        send(input.withLock { $0.controller = s; return Self.merged(s, $0.pointer) })
    }

    public func setPointerTouch(_ pointer: PointerTouch) {
        send(input.withLock { $0.pointer = pointer; return Self.merged($0.controller, pointer) })
    }

    /// The controller state with the pointer's finger first (a pad's fingers after it, two at most) and
    /// its press as the touchpad button.
    static func merged(_ s: ControllerState, _ pointer: PointerTouch) -> ControllerState {
        var out = s
        if let touch = pointer.touch { out.touches = Array(([touch] + s.touches).prefix(2)) }
        if pointer.pressed { out.buttons |= ControllerState.touchpadButton }
        return out
    }

    private func send(_ s: ControllerState) { withEngine { $0.setController(s) } }

    public func setLoginPin(_ pin: String) { withEngine { $0.setLoginPin(pin) } }
    /// Where and how loud the sound plays (also kept in AudioOutput.current for later sessions).
    public func applyAudioOutput(_ output: AudioOutput) { audio?.apply(output) }

    private var microphone: Microphone?

    /// Turns the Mac's microphone on (asking for permission the first time) or off; `done` gets the
    /// resulting state, possibly later and on another queue.
    public func setMicrophone(_ on: Bool, done: @escaping @Sendable (Microphone.State) -> Void) {
        guard let engine else { return done(.off) }
        guard on else {
            microphone?.stop()
            microphone = nil
            engine.setMicrophone(false)
            return done(.off)
        }
        let mic = microphone ?? Microphone()
        microphone = mic
        mic.start(frames: { engine.sendMicrophoneFrame(UnsafeBufferPointer(start: $0, count: MicFramer.frameValues)) }) { state in
            if state == .on { engine.setMicrophone(true) }
            done(state)
        }
    }
    /// Replaces the text of the console's focused field, then `finishKeyboard` sends (true) or cancels it.
    public func setKeyboardText(_ text: String) { withEngine { $0.setKeyboardText(text) } }
    public func finishKeyboard(accept: Bool) { withEngine { $0.finishKeyboard(accept: accept) } }
    public func requestKeyframe() { withEngine { $0.requestKeyFrame() } }
    public func sleepConsole() { withEngine { $0.goToBed() } }

    /// Stops the stream and waits for the engine's threads to finish.
    public func stop() {
        // The engine comes out under the lock and is stopped outside it: stopping waits for the engine's sink calls,
        // and the app's handler may be inside one, calling a command (which takes this lock) or `stop()` itself.
        // Commands after this see no engine and do nothing.
        engineLock.lock()
        guard let engine else { engineLock.unlock(); return }
        microphone?.stop() // no more frames into the session we're about to stop
        microphone = nil
        self.engine = nil
        engineLock.unlock()
        engine.stop()
        decoder.flush() // no frame comes out after the session stopped
        audio?.stop()
        padHaptics.stop()
    }

    /// One frame of the DualSense haptics stream: played on a USB pad if there is one (returns true), else the
    /// engine makes rumble from it.
    func handleHaptics(_ samples: UnsafeBufferPointer<Int16>) -> Bool {
        padHaptics.push(samples)
    }

    func handleTriggerEffects(_ typeLeft: UInt8, _ left: [UInt8], _ typeRight: UInt8, _ right: [UInt8]) {
        deliver(.triggerEffects(left: TriggerEffect(mode: typeLeft, parameters: left),
                                 right: TriggerEffect(mode: typeRight, parameters: right)))
    }

    func handleAudioFormat(channels: Int, sampleRate: Int) {
        audio?.configure(channels: channels, sampleRate: Double(sampleRate))
    }

    func handleAudio(_ samples: UnsafePointer<Int16>, frames: Int) { audio?.push(samples, frames: frames) }

    func handleVideo(_ data: UnsafeRawBufferPointer, framesLost: Int) -> Bool {
        let bytes = data.count
        let index: UInt64 = lock.withLock {
            _stats.framesLost += framesLost
            _stats.bytesReceived += bytes
            frameIndex += 1 + UInt64(max(0, framesLost))
            return frameIndex
        }
        sampleHandler.withLock { $0 }?.call(index, bytes)
        let ok = decoder.decode(data, index: index)
        if !ok { lock.withLock { _stats.decodeErrors += 1 } }
        return ok
    }
}

extension StreamSession {
    /// How much decoded frame `b`'s picture changed from `a`'s, the measure `RepeatDetector` decides on,
    /// for tools measuring a stream; nil for frames of different sizes.
    public static func pictureDifference(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double? { InterpolationLane.difference(a, b) }
}
