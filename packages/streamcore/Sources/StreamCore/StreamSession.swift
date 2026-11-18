import CChiaki
import CoreVideo
import Foundation
import os

/// One Remote Play streaming session: libchiaki protocol → VideoToolbox decode → frames,
/// Opus → AudioPlayer, ControllerState → console.
public final class StreamSession {
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
        public init() {}

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
        case rumble(left: UInt8, right: UInt8)
        /// DualSense adaptive-trigger effects for the left (L2) and right (R2) triggers.
        case triggerEffects(left: TriggerEffect, right: TriggerEffect)
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
    }

    /// Called from libchiaki's threads.
    /// Events that arrive before it's set (a session can report progress, or fail, right as it starts)
    /// are kept and delivered when it is.
    public var onEvent: ((Event) -> Void)? {
        get { events.withLock { $0.handler } }
        set {
            let pending = events.withLock { state -> [Event] in
                state.handler = newValue
                defer { state.pending = [] }
                return newValue == nil ? [] : state.pending
            }
            pending.forEach { newValue?($0) }
        }
    }
    private let events = OSAllocatedUnfairLock(initialState: (handler: ((Event) -> Void)?.none, pending: [Event]()))

    /// Delivers `event` now, or keeps it until `onEvent` is set.
    func deliver(_ event: Event) {
        let handler = events.withLock { state -> ((Event) -> Void)? in
            if state.handler == nil { state.pending.append(event) }
            return state.handler
        }
        handler?(event)
    }
    /// Called from the video thread with every decoded frame.
    public var onFrame: ((CVPixelBuffer) -> Void)?

    public var stats: Stats {
        var s = lock.withLock { _stats }
        if let handle { s.rttMs = Double(psrp_session_rtt_us(handle)) / 1000 }
        return s
    }
    public var latestFrame: CVPixelBuffer? { lock.withLock { _latestFrame } }

    private var handle: OpaquePointer?
    private let decoder: VideoDecoder
    private let audio: AudioPlayer?
    private let lock = OSAllocatedUnfairLock()
    private var _stats = Stats()
    private var _latestFrame: CVPixelBuffer?

    public init(credentials: ConsoleCredentials, options: Options = Options(), remote: Remote? = nil) throws {
        guard let regist = Data(base64Encoded: credentials.registKey), regist.count == Int(PSRP_REGIST_KEY_SIZE),
              let rpKey = Data(base64Encoded: credentials.rpKey), rpKey.count == Int(PSRP_RP_KEY_SIZE),
              let account = Data(base64Encoded: credentials.accountId), account.count == Int(PSRP_ACCOUNT_ID_SIZE)
        else { throw ConsoleError.message("Invalid console credentials") }

        let hevc = credentials.ps5 && options.hevc
        let hdr = hevc && options.hdr
        decoder = VideoDecoder(codec: hevc ? .hevc : .h264, tenBit: hdr)
        audio = options.audio ? AudioPlayer() : nil

        decoder.onFrame = { [unowned self] frame in
            lock.withLock {
                _latestFrame = frame
                _stats.framesDecoded += 1
                _stats.width = CVPixelBufferGetWidth(frame)
                _stats.height = CVPixelBufferGetHeight(frame)
            }
            onFrame?(frame)
        }

        var config = PsrpSessionConfig()
        config.ps5 = credentials.ps5
        _ = withUnsafeMutableBytes(of: &config.regist_key) { regist.copyBytes(to: $0) }
        _ = withUnsafeMutableBytes(of: &config.rp_key) { rpKey.copyBytes(to: $0) }
        _ = withUnsafeMutableBytes(of: &config.account_id) { account.copyBytes(to: $0) }
        config.height = Int32(options.height)
        config.fps = Int32(options.fps)
        config.codec = Int32(hdr ? PSRP_CODEC_H265_HDR.rawValue : hevc ? PSRP_CODEC_H265.rawValue : PSRP_CODEC_H264.rawValue)
        config.bitrate = Int32(options.bitrate)
        config.auto_downgrade = options.autoDowngrade

        var callbacks = PsrpCallbacks()
        callbacks.user = Unmanaged.passUnretained(self).toOpaque()
        callbacks.video = { user, data, size, framesLost, _ in
            let s = Unmanaged<StreamSession>.fromOpaque(user!).takeUnretainedValue()
            return s.handleVideo(UnsafeRawBufferPointer(start: data, count: size), framesLost: Int(framesLost))
        }
        callbacks.audio_format = { user, channels, rate in
            let s = Unmanaged<StreamSession>.fromOpaque(user!).takeUnretainedValue()
            s.audio?.configure(channels: Int(channels), sampleRate: Double(rate))
        }
        callbacks.audio = { user, pcm, frames in
            let s = Unmanaged<StreamSession>.fromOpaque(user!).takeUnretainedValue()
            if let pcm { s.audio?.push(pcm, frames: frames) }
        }
        callbacks.trigger_effects = { user, typeLeft, left, typeRight, right in
            let s = Unmanaged<StreamSession>.fromOpaque(user!).takeUnretainedValue()
            s.handleTriggerEffects(typeLeft, left.map { Array(UnsafeBufferPointer(start: $0, count: 10)) } ?? [],
                                   typeRight, right.map { Array(UnsafeBufferPointer(start: $0, count: 10)) } ?? [])
        }
        callbacks.event = { user, type, a, b, message in
            let s = Unmanaged<StreamSession>.fromOpaque(user!).takeUnretainedValue()
            if let event = Event(type: type, a: a, b: b, message: message.map { String(cString: $0) } ?? "") {
                s.deliver(event)
            }
        }

        var error = [CChar](repeating: 0, count: 512)
        // The C strings only need to live for this call; the shim copies what it keeps.
        let handle = credentials.address.withCString { host -> OpaquePointer? in
            config.host = host
            guard let remote else { return psrp_session_start(&config, &callbacks, &error, error.count) }
            return remote.token.withCString { token in
                remote.duid.withCString { duid in
                    config.psn_token = token
                    config.psn_duid = duid
                    return psrp_session_start(&config, &callbacks, &error, error.count)
                }
            }
        }
        guard let handle else { throw ConsoleError.message(String(cString: error)) }
        self.handle = handle
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
        if pointer.pressed { out.buttons |= UInt32(PSRP_BTN_TOUCHPAD.rawValue) }
        return out
    }

    private func send(_ s: ControllerState) {
        var state = s.psrp
        psrp_session_set_controller_state(handle, &state)
    }

    public func setLoginPin(_ pin: String) { psrp_session_set_login_pin(handle, pin) }

    private var microphone: Microphone?

    /// Turns the Mac's microphone on (asking for permission the first time) or off; `done` gets the
    /// resulting state, possibly later and on another queue.
    public func setMicrophone(_ on: Bool, done: @escaping @Sendable (Microphone.State) -> Void) {
        guard let handle else { return done(.off) }
        guard on else {
            microphone?.stop()
            microphone = nil
            psrp_session_set_mic(handle, false)
            return done(.off)
        }
        let mic = microphone ?? Microphone()
        microphone = mic
        mic.start(frames: { psrp_session_mic_frame(handle, $0) }) { state in
            if state == .on { psrp_session_set_mic(handle, true) }
            done(state)
        }
    }
    /// Replaces the text of the console's focused field, then `finishKeyboard` sends (true) or cancels it.
    public func setKeyboardText(_ text: String) { psrp_session_keyboard_set_text(handle, text) }
    public func finishKeyboard(accept: Bool) { psrp_session_keyboard_done(handle, accept) }
    public func requestKeyframe() { psrp_session_request_idr(handle) }
    public func sleepConsole() { psrp_session_goto_bed(handle) }

    /// Stops the stream and waits for libchiaki's threads to finish.
    public func stop() {
        guard let handle else { return }
        microphone?.stop() // no more frames into the session we're about to free
        microphone = nil
        self.handle = nil
        psrp_session_stop(handle)
        audio?.stop()
    }

    func handleTriggerEffects(_ typeLeft: UInt8, _ left: [UInt8], _ typeRight: UInt8, _ right: [UInt8]) {
        deliver(.triggerEffects(left: TriggerEffect(mode: typeLeft, parameters: left),
                                 right: TriggerEffect(mode: typeRight, parameters: right)))
    }

    func handleVideo(_ data: UnsafeRawBufferPointer, framesLost: Int) -> Bool {
        let bytes = data.count
        lock.withLock {
            _stats.framesLost += framesLost
            _stats.bytesReceived += bytes
        }
        let ok = decoder.decode(data)
        if !ok { lock.withLock { _stats.decodeErrors += 1 } }
        return ok
    }
}

extension StreamSession.QuitKind {
    /// From a PsrpQuitKind code.
    init(code: Int32) {
        switch UInt32(code) {
        case PSRP_QUIT_BUSY.rawValue: self = .busy
        case PSRP_QUIT_DROPPED.rawValue: self = .dropped
        case PSRP_QUIT_STOPPED.rawValue: self = .stopped
        default: self = .final
        }
    }
}

extension StreamSession.Event {
    /// Maps a PsrpEventType callback to an Event (nil for unknown types).
    init?(type: Int32, a: Int32, b: Int32, message text: String) {
        switch UInt32(type) {
        case PSRP_EVENT_CONNECTED.rawValue: self = .connected
        case PSRP_EVENT_QUIT.rawValue: self = .quit(reason: text, error: a != 0, kind: StreamSession.QuitKind(code: b))
        case PSRP_EVENT_LOGIN_PIN_REQUEST.rawValue: self = .loginPinRequested(incorrect: a != 0)
        case PSRP_EVENT_RUMBLE.rawValue: self = .rumble(left: UInt8(clamping: a), right: UInt8(clamping: b))
        case PSRP_EVENT_NICKNAME.rawValue: self = .nickname(text)
        case PSRP_EVENT_KEYBOARD.rawValue:
            let change: StreamSession.KeyboardChange = switch UInt32(a) {
            case PSRP_KEYBOARD_OPEN.rawValue: .open
            case PSRP_KEYBOARD_CHANGE.rawValue: .change
            default: .close
            }
            self = .keyboard(change, text: text)
        case PSRP_EVENT_REMOTE_PROGRESS.rawValue:
            switch UInt32(a) {
            case PSRP_REMOTE_DATA.rawValue: self = .remoteProgress(.data)
            case PSRP_REMOTE_CONNECTED.rawValue: self = .remoteProgress(.connected)
            default: self = .remoteProgress(.linking)
            }
        default: return nil
        }
    }
}
