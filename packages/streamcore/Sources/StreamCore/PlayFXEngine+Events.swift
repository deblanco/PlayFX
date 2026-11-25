import Foundation
import PlayFXProtocol

/// What only the library's receive thread touches: the audio decoder, the parameter sets of the current resolution
/// (to put in front of key frames), the buffer that joins them to a key frame, whether a key frame has been asked
/// for, and the haptics-to-rumble state.
final class PlayFXReceiveState {
    var playback: PlayFXOpusPlayback?
    var parameterSets: [UInt8] = []
    /// The next frame must carry the parameter sets (the first one, and the first after a resolution switch).
    var parameterSetsDue = false
    var keyFrameRequested = false
    var rumble = PlayFXHapticRumble()
    private var joined: UnsafeMutableRawPointer?
    private var joinedCapacity = 0

    deinit { joined?.deallocate() }

    /// `parameterSets` followed by `unit`, in a buffer that is reused (it grows only when a frame outgrows it).
    func joinedUnit(_ unit: UnsafeRawBufferPointer) -> UnsafeRawBufferPointer {
        let count = parameterSets.count + unit.count
        if count > joinedCapacity {
            joined?.deallocate()
            joinedCapacity = max(count, joinedCapacity * 2)
            joined = .allocate(byteCount: joinedCapacity, alignment: 16)
        }
        guard let joined else { return unit }
        parameterSets.withUnsafeBytes { joined.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        if let base = unit.baseAddress { (joined + parameterSets.count).copyMemory(from: base, byteCount: unit.count) }
        return UnsafeRawBufferPointer(start: joined, count: count)
    }
}

extension PlayFXEngine {
    /// The library's events, on its two threads (see the class comment).
    func handle(_ event: StreamEvent, _ session: PlayFXLibrarySession) {
        switch event {
        case .videoAccessUnit(let unit, let info): video(unit, info, session)
        case .parameterSets(_, let profile, _):
            av.parameterSets = profile.header
            av.parameterSetsDue = !profile.header.isEmpty
        case .audioHeader(let header): audioHeader(header)
        case .audioPacket(let audio): audioPacket(audio)
        case .haptics(_, let samples): haptics(samples)
        case .connected(let info): connected(info, session)
        case .ended(let reason): ended(reason)
        default: control(event, session)
        }
    }

    /// Runs `body` as a sink call, unless the engine is stopping or has quit.
    @inline(__always)
    private func toSink(_ body: (any StreamEngineSink) -> Void) {
        guard gate.enter() else { return }
        body(sink)
        endCall()
    }

    // MARK: Video

    /// A key frame (or the first frame of a resolution) goes with the parameter sets in front, as the contract has it.
    /// A frame the app couldn't decode is passed back to the library as rejected and a key frame is asked for, once
    /// until one arrives.
    private func video(_ unit: UnsafeRawBufferPointer, _ info: VideoFrameInfo, _ session: PlayFXLibrarySession) {
        guard gate.enter() else { return }
        defer { endCall() }
        var data = unit
        if info.isKeyFrame == true || av.parameterSetsDue, !av.parameterSets.isEmpty {
            data = av.joinedUnit(unit)
            av.parameterSetsDue = false
        }
        let decoded = sink.handleVideo(data, framesLost: info.framesLost)
        if info.isKeyFrame == true { av.keyFrameRequested = false }
        guard !decoded else { return }
        // The decoder may have to start again: the next unit, whatever the library made of its slices, carries them.
        av.parameterSetsDue = !av.parameterSets.isEmpty
        session.rejectVideoFrame()
        if !av.keyFrameRequested, session.requestIDR() { av.keyFrameRequested = true }
    }

    // MARK: Audio

    /// Announces the format and makes the decoder; a header libopus can't decode leaves the audio silent.
    private func audioHeader(_ header: AudioHeader) {
        guard let playback = PlayFXOpusPlayback(header) else {
            av.playback = nil
            return Log.warning(.session, "PlayFX engine: can't decode the console's audio (\(header.channels) ch, \(header.sampleRate) Hz)")
        }
        av.playback = playback
        toSink { $0.handleAudioFormat(channels: playback.channels, sampleRate: playback.sampleRate) }
    }

    /// A packet is decoded; a lost frame is concealed by the decoder (av.md section 6.4); a gap too long to conceal
    /// resets it.
    private func audioPacket(_ event: AudioEvent) {
        guard let playback = av.playback else { return }
        let decoded: (samples: UnsafePointer<Int16>, frames: Int)?
        switch event {
        case .packet(_, let opus): decoded = playback.decode(opus)
        case .lost: decoded = playback.conceal()
        case .skipped:
            playback.reset()
            return
        }
        guard let decoded else { return }
        toSink { $0.handleAudio(decoded.samples, frames: decoded.frames) }
    }

    // MARK: Haptics

    /// Played on a DualSense by USB when the sink can; else turned into rumble (see `PlayFXHapticRumble`).
    private func haptics(_ samples: UnsafeBufferPointer<Int16>) {
        guard gate.enter() else { return }
        defer { endCall() }
        if sink.handleHaptics(samples) {
            av.rumble.reset()
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds / 1000
        if let strength = av.rumble.process(samples, nowMicros: now) {
            sink.deliver(.hapticRumble(left: strength.left, right: strength.right))
        }
    }

    // MARK: Control

    private func connected(_ info: StreamConnectedInfo, _ session: PlayFXLibrarySession) {
        locked { s in
            if s.session == nil && !s.stopCalled { s.session = session }
            s.stats.rttMicros = info.probeSucceeded ? info.probe.rttMicroseconds : 0
        }
        toSink { $0.deliver(.connected) }
        // A pad state set before the stream was up.
        if let latest = input.withLock({ $0.latest }) { session.setControllerState(latest) }
        // Voice chat asked for before the stream was up.
        if mic.withLock({ $0.wanted }) { setMicrophone(true) }
    }

    private func ended(_ reason: StreamEndReason) {
        defer { libraryDidEnd() }
        guard gate.enterForQuit() else { return }
        defer { endCall() }
        let quit = Self.quit(for: reason, console: console)
        sink.deliver(.quit(reason: quit.reason, error: quit.error, kind: quit.kind))
    }

    /// Everything the library delivers on its serial queue.
    private func control(_ event: StreamEvent, _ session: PlayFXLibrarySession) {
        locked { s in if s.session == nil && !s.stopCalled && !s.libraryEnded { s.session = session } }
        switch event {
        case .rumble(let levels): toSink { $0.deliver(.rumble(left: levels.left, right: levels.right)) }
        case .triggerEffects(let effects):
            toSink { $0.handleTriggerEffects(effects.leftMode, effects.leftParameters, effects.rightMode, effects.rightParameters) }
        case .ledColor(let red, let green, let blue): toSink { $0.deliver(.light(red: red, green: green, blue: blue)) }
        case .playerIndex(let index): toSink { $0.deliver(.playerIndex(Int(index))) }
        case .motionReset: input.withLock { $0.resetMotion() }
        case .connectionQuality(let quality):
            locked { s in if let bitrate = quality.targetBitrate { s.stats.targetBitrate = Int(bitrate) } }
        case .loginPINRequested:
            let incorrect = locked { s -> Bool in
                defer { s.pinWrong = false }
                return s.pinWrong
            }
            toSink { $0.deliver(.loginPinRequested(incorrect: incorrect)) }
        case .loginPINResult(let accepted): locked { $0.pinWrong = !accepted }
        case .keyboardOpened(let text): toSink { $0.deliver(.keyboard(.open, text: text)) }
        case .keyboardTextChanged(_, let text): toSink { $0.deliver(.keyboard(.change, text: text)) }
        case .keyboardClosed: toSink { $0.deliver(.keyboard(.close, text: "")) }
        case .stats(let stats):
            locked { s in
                s.stats.reorder = StreamEngineStats.Reorder(
                    waitMicros: stats.reorder.waitMicros, holesFilled: stats.reorder.holesFilled,
                    latePackets: stats.reorder.latePackets, holesLost: stats.reorder.holesLost,
                    queueFullSkips: stats.reorder.queueFullSkips)
            }
        default: break
        }
    }
}
