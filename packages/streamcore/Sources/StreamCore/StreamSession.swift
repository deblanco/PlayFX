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

    public enum Event: Sendable {
        case connected
        case quit(reason: String, error: Bool, kind: QuitKind)
        case loginPinRequested(incorrect: Bool)
        case rumble(left: UInt8, right: UInt8)
        case nickname(String)
    }

    public struct Stats: Codable, Sendable {
        public var framesDecoded = 0
        public var decodeErrors = 0
        public var framesLost = 0
        public var width = 0
        public var height = 0
        /// Compressed video bytes received; the host derives the live bitrate from it.
        public var bytesReceived = 0
    }

    /// Called from libchiaki's threads.
    public var onEvent: ((Event) -> Void)?
    /// Called from the video thread with every decoded frame.
    public var onFrame: ((CVPixelBuffer) -> Void)?

    public var stats: Stats { lock.withLock { _stats } }
    public var latestFrame: CVPixelBuffer? { lock.withLock { _latestFrame } }

    private var handle: OpaquePointer?
    private let decoder: VideoDecoder
    private let audio: AudioPlayer?
    private let lock = OSAllocatedUnfairLock()
    private var _stats = Stats()
    private var _latestFrame: CVPixelBuffer?

    public init(credentials: ConsoleCredentials, options: Options = Options()) throws {
        guard let regist = Data(base64Encoded: credentials.registKey), regist.count == Int(PSRP_REGIST_KEY_SIZE),
              let rpKey = Data(base64Encoded: credentials.rpKey), rpKey.count == Int(PSRP_RP_KEY_SIZE),
              let account = Data(base64Encoded: credentials.accountId), account.count == Int(PSRP_ACCOUNT_ID_SIZE)
        else { throw ConsoleError.message("Invalid console credentials") }

        let hevc = credentials.ps5 && options.hevc
        decoder = VideoDecoder(codec: hevc ? .hevc : .h264)
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
        config.codec = Int32(hevc ? PSRP_CODEC_H265.rawValue : PSRP_CODEC_H264.rawValue)
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
        callbacks.event = { user, type, a, b, message in
            let s = Unmanaged<StreamSession>.fromOpaque(user!).takeUnretainedValue()
            if let event = Event(type: type, a: a, b: b, message: message.map { String(cString: $0) } ?? "") {
                s.onEvent?(event)
            }
        }

        var error = [CChar](repeating: 0, count: 512)
        let handle = credentials.address.withCString { host -> OpaquePointer? in
            config.host = host
            return psrp_session_start(&config, &callbacks, &error, error.count)
        }
        guard let handle else { throw ConsoleError.message(String(cString: error)) }
        self.handle = handle
    }

    deinit { stop() }

    public func setController(_ s: ControllerState) {
        psrp_session_set_controller(handle, s.buttons, s.l2, s.r2, s.leftX, s.leftY, s.rightX, s.rightY)
    }

    public func setLoginPin(_ pin: String) { psrp_session_set_login_pin(handle, pin) }
    public func requestKeyframe() { psrp_session_request_idr(handle) }
    public func sleepConsole() { psrp_session_goto_bed(handle) }

    /// Stops the stream and waits for libchiaki's threads to finish.
    public func stop() {
        guard let handle else { return }
        self.handle = nil
        psrp_session_stop(handle)
        audio?.stop()
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
        default: return nil
        }
    }
}
