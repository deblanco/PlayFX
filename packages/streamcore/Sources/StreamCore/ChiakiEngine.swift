import CChiaki
import Foundation

/// The libchiaki engine: a `StreamEngine` over the C shim's `psrp_session_*` (Sources/CChiaki). Everything
/// libchiaki-specific about a stream lives here: the session config and callbacks, the shim's event codes, and
/// its controller and stats structs.
final class ChiakiEngine: StreamEngine {
    /// Unretained: the sink (the StreamSession) owns this engine and stops it before it goes away.
    private unowned(unsafe) let sink: any StreamEngineSink
    private var handle: OpaquePointer?
    /// Held while the handle is used, and by `stop()` while it frees it.
    private let lock = NSLock()

    /// Starts connecting in the background (`psrp_session_start`).
    init(config: StreamEngineConfig, sink: any StreamEngineSink) throws {
        self.sink = sink
        var c = PsrpSessionConfig()
        c.ps5 = config.ps5
        _ = withUnsafeMutableBytes(of: &c.regist_key) { config.registKey.copyBytes(to: $0) }
        _ = withUnsafeMutableBytes(of: &c.rp_key) { config.rpKey.copyBytes(to: $0) }
        _ = withUnsafeMutableBytes(of: &c.account_id) { config.accountID.copyBytes(to: $0) }
        c.height = Int32(config.height)
        c.fps = Int32(config.fps)
        let codec: PsrpCodec = switch config.codec {
        case .h264: PSRP_CODEC_H264
        case .hevc: PSRP_CODEC_H265
        case .hevcHDR: PSRP_CODEC_H265_HDR
        }
        c.codec = Int32(codec.rawValue)
        c.bitrate = Int32(config.bitrateKbps)
        c.auto_downgrade = config.autoDowngrade

        var callbacks = PsrpCallbacks()
        callbacks.user = Unmanaged.passUnretained(self).toOpaque()
        callbacks.video = { user, data, size, framesLost, _ in
            ChiakiEngine.sink(user).handleVideo(UnsafeRawBufferPointer(start: data, count: size), framesLost: Int(framesLost))
        }
        callbacks.audio_format = { user, channels, rate in
            ChiakiEngine.sink(user).handleAudioFormat(channels: Int(channels), sampleRate: Int(rate))
        }
        callbacks.audio = { user, pcm, frames in
            if let pcm { ChiakiEngine.sink(user).handleAudio(pcm, frames: frames) }
        }
        callbacks.trigger_effects = { user, typeLeft, left, typeRight, right in
            ChiakiEngine.sink(user).handleTriggerEffects(
                typeLeft, left.map { Array(UnsafeBufferPointer(start: $0, count: 10)) } ?? [],
                typeRight, right.map { Array(UnsafeBufferPointer(start: $0, count: 10)) } ?? [])
        }
        callbacks.haptics = { user, pcm, frames in
            guard let pcm else { return false }
            return ChiakiEngine.sink(user).handleHaptics(UnsafeBufferPointer(start: pcm, count: frames * 2))
        }
        callbacks.event = { user, type, a, b, message in
            if let event = StreamSession.Event(type: type, a: a, b: b, message: message.map { String(cString: $0) } ?? "") {
                ChiakiEngine.sink(user).deliver(event)
            }
        }

        var error = [CChar](repeating: 0, count: 512)
        // The C strings only need to live for this call; the shim copies what it keeps.
        let handle = config.host.withCString { host -> OpaquePointer? in
            c.host = host
            guard let remote = config.remote else { return psrp_session_start(&c, &callbacks, &error, error.count) }
            return remote.token.withCString { token in
                remote.duid.withCString { duid in
                    c.psn_token = token
                    c.psn_duid = duid
                    return psrp_session_start(&c, &callbacks, &error, error.count)
                }
            }
        }
        guard let handle else { throw ConsoleError.message(String(cString: error)) }
        self.handle = handle
    }

    deinit { stop() }

    /// The sink behind a callback's `user` pointer (this engine).
    private static func sink(_ user: UnsafeMutableRawPointer?) -> any StreamEngineSink {
        Unmanaged<ChiakiEngine>.fromOpaque(user!).takeUnretainedValue().sink
    }

    /// Runs `body` with the shim's session unless it was stopped.
    private func withHandle<T>(_ body: (OpaquePointer) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return handle.map(body)
    }

    func setController(_ state: ControllerState) {
        var s = state.psrp
        withHandle { psrp_session_set_controller_state($0, &s) }
    }

    func setLoginPin(_ pin: String) { withHandle { psrp_session_set_login_pin($0, pin) } }
    func setMicrophone(_ on: Bool) { withHandle { psrp_session_set_mic($0, on) } }
    func sendMicrophoneFrame(_ samples: UnsafeBufferPointer<Int16>) { withHandle { psrp_session_mic_frame($0, samples.baseAddress) } }
    func setKeyboardText(_ text: String) { withHandle { psrp_session_keyboard_set_text($0, text) } }
    func finishKeyboard(accept: Bool) { withHandle { psrp_session_keyboard_done($0, accept) } }
    func requestKeyFrame() { withHandle { psrp_session_request_idr($0) } }
    func goToBed() { withHandle { psrp_session_goto_bed($0) } }

    func stats() -> StreamEngineStats {
        withHandle { handle in
            var reorder = PsrpReorderStats()
            psrp_session_reorder_stats(handle, &reorder)
            return Self.stats(rttMicros: psrp_session_rtt_us(handle), targetBitrate: psrp_session_target_bitrate(handle),
                              reorder: reorder)
        } ?? StreamEngineStats()
    }

    /// The shim's figures as the engine's.
    static func stats(rttMicros: UInt64, targetBitrate: UInt32, reorder: PsrpReorderStats) -> StreamEngineStats {
        StreamEngineStats(
            rttMicros: Int(rttMicros), targetBitrate: Int(targetBitrate),
            reorder: StreamEngineStats.Reorder(
                waitMicros: Int(reorder.wait_us), holesFilled: Int(reorder.holes_filled),
                latePackets: Int(reorder.late_packets), holesLost: Int(reorder.holes_lost),
                queueFullSkips: Int(reorder.queue_full_skips)))
    }

    /// Stops the shim's session, which joins libchiaki's threads: no callback after this.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }
        self.handle = nil
        psrp_session_stop(handle)
    }
}

extension ControllerState {
    /// The C shim's form of this state.
    var psrp: PsrpControllerState {
        var c = PsrpControllerState()
        c.buttons = buttons
        c.l2 = l2
        c.r2 = r2
        c.left_x = leftX
        c.left_y = leftY
        c.right_x = rightX
        c.right_y = rightY
        func touch(_ i: Int) -> PsrpTouch {
            guard i < touches.count else { return PsrpTouch(id: -1, x: 0, y: 0) }
            let t = touches[i]
            func scale(_ v: Float, _ max: Int32) -> UInt16 { UInt16((min(1, Swift.max(0, v)) * Float(max)).rounded()) }
            return PsrpTouch(id: Int8(t.id & 0x7F), x: scale(t.x, PSRP_TOUCHPAD_WIDTH), y: scale(t.y, PSRP_TOUCHPAD_HEIGHT))
        }
        c.touches = (touch(0), touch(1))
        if let motion {
            c.motion = true
            (c.gyro_x, c.gyro_y, c.gyro_z) = (motion.gyro.x, motion.gyro.y, motion.gyro.z)
            (c.accel_x, c.accel_y, c.accel_z) = (motion.accel.x, motion.accel.y, motion.accel.z)
            c.motion_timestamp_us = motion.timestampMicros
        }
        return c
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
        case PSRP_EVENT_HAPTIC_RUMBLE.rawValue: self = .hapticRumble(left: UInt8(clamping: a), right: UInt8(clamping: b))
        case PSRP_EVENT_NICKNAME.rawValue: self = .nickname(text)
        case PSRP_EVENT_LIGHT.rawValue:
            self = .light(red: UInt8(truncatingIfNeeded: a >> 16), green: UInt8(truncatingIfNeeded: a >> 8),
                          blue: UInt8(truncatingIfNeeded: a))
        case PSRP_EVENT_PLAYER_INDEX.rawValue: self = .playerIndex(Int(a))
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
