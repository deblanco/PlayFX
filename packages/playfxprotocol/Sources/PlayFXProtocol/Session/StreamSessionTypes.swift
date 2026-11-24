import Foundation

/// The public types of `StreamSession`: options, the events it delivers, the once-per-second statistics and the
/// errors `start` throws. See `StreamSession` for which thread each event arrives on.

/// Which receive transport carries the stream (DESIGN.md "Stream transport, the open question").
public enum StreamTransport: Sendable, Equatable {
    /// A BSD socket read by a dedicated user-interactive thread.
    case bsd
    /// Network.framework UDP.
    case nw

    /// The name shown in statistics and by `pfxp`.
    public var name: String { self == .bsd ? "bsd" : "nw" }
}

/// Client choices beyond the stream settings.
public struct StreamSessionOptions: Sendable, Equatable {
    /// Ctrl options. `streamingType` is always replaced by the one that matches `StreamSettings.codec`.
    public var control = ControlOptions()
    /// Whether to announce the microphone (stream.md section 6.7 step 3). Off: the mic StreamInfo isn't sent.
    /// Sending the mic audio itself isn't implemented yet (it needs an Opus encoder); see `setMicrophone`.
    public var microphone = false
    /// TESTING ONLY, off by default: drops a share of the datagrams the stream connection receives, from the
    /// moment the stream is up (see `SimulatedLoss`). `pfxp stream --drop`.
    public var simulatedReceiveLoss: SimulatedLoss?

    public init() {}
}

/// What the stream negotiated, delivered with `StreamEvent.connected`.
public struct StreamConnectedInfo: Sendable, Equatable {
    public var target: RPTarget
    public var consoleModel: ConsoleModel?
    /// The probe's results, or the fallback when it failed (`probeSucceeded` false).
    public var probe: StreamProbeResult
    public var probeSucceeded: Bool
    /// Why the probe failed, when it did (no secrets in it).
    public var probeFailure: String?
    /// What the launch spec asked for, after the console-kind rules (stream.md section 7.2).
    public var requested: StreamLaunchRequest
    /// The codec the AV layer was told (from the launch spec; the video header's `codec` byte is not used, but
    /// `StreamStats.videoCodecByte` shows what the console sent).
    public var videoCodec: VideoCodec
    /// The resolutions the console may stream, in list order (index 0, 1, ...), with their parameter sets.
    public var profiles: [VideoProfile]
    public var audioHeader: AudioHeader
    /// The HelloReply's `serverVersion` and `serverVersionText` (meaning unknown, stream.md section 4.1).
    public var serverVersion: UInt32?
    public var serverVersionText: String?
    /// Whether the console's signature equalled HMAC-SHA256(streamHandshakeKey, its key): open question 1.
    public var consoleSignatureMatches: Bool
    /// The Takion version of the stream connection (12 for a PS5, 9 for a PS4).
    public var takionVersion: Int
    /// `bsd` or `nw`.
    public var transport: String
}

/// The reorder queue's counters (takion.md section 12).
public struct StreamReorderStats: Sendable, Equatable {
    /// The current reorder wait, microseconds.
    public var waitMicros = 0
    /// Holes that filled while being waited for.
    public var holesFilled = 0
    /// Packets that arrived after their hole was skipped.
    public var latePackets = 0
    /// Skipped holes that never filled (real loss).
    public var holesLost = 0
    /// Skips forced because the queue was full.
    public var queueFullSkips = 0
    /// Holes skipped after the wait ran out.
    public var timeoutSkips = 0
    public var duplicates = 0
}

/// The last congestion report the transport sent (takion.md section 8).
public struct StreamCongestionReport: Sendable, Equatable {
    public var received: Int
    public var lost: Int
    /// Reports sent so far.
    public var count: Int
}

/// Delivered once per second (`StreamEvent.stats`). Counters are totals since `connected` unless the name says
/// otherwise. The video numbers are read from the receive thread's counters when it last handed over a frame or
/// reported a loss, so they can lag a stalled stream by the stall.
public struct StreamStats: Sendable, Equatable {
    /// Seconds since `connected`.
    public var seconds = 0.0
    /// Access units handed to the app during the last interval, and the video bit rate over it (Mbit/s).
    public var videoFrames = 0
    public var videoMbps = 0.0
    public var videoFramesTotal = 0
    /// Frames skipped between the frames handed over (whatever the reason).
    public var framesLost = 0
    /// Frames whose HEVC reference was rewritten to an older one (decodable, maybe with artefacts).
    public var framesRecovered = 0
    /// Frames rebuilt with the erasure code, and frames it could not rebuild.
    public var fecRecoveries = 0
    public var fecFailures = 0
    /// Frames dropped while waiting for a key frame or for a missing reference.
    public var framesDropped = 0
    /// Frames the app rejected (`StreamSession.rejectVideoFrame`).
    public var decoderRejects = 0
    public var idrRequestsSent = 0
    public var corruptFrameReportsSent = 0
    public var audioPackets = 0
    public var audioConcealed = 0
    /// Frames of audio skipped without concealment (a gap longer than the cap).
    public var audioSkipped = 0
    public var reorder = StreamReorderStats()
    public var lastCongestion: StreamCongestionReport?
    public var rttMicroseconds = 0
    public var mtuIn = 0
    public var mtuOut = 0
    public var probeSucceeded = false
    /// `bsd` or `nw`, and where the receive times come from (`SO_TIMESTAMP_MONOTONIC`, `SO_TIMESTAMP`,
    /// `receiveTime` metadata, or `callback time` when the kernel gave none).
    public var transport = ""
    public var timestampSource = ""
    public var datagramsReceived = 0
    public var droppedBadGMAC = 0
    public var retransmissions = 0
    /// Datagrams dropped on purpose by `StreamSessionOptions.simulatedReceiveLoss` (0 when it is off).
    public var simulatedDrops = 0
    /// The `codec` byte of the video packet header as the console sent it (the last value seen), nil before the
    /// first video packet (takion.md section 7, av.md open question 2).
    public var videoCodecByte: UInt8?
    /// The body length of the last pad-info message, 17 or 25 (stream.md section 9.8, open question 7), nil if
    /// none has arrived.
    public var padInfoBodyLength: Int?
}

/// Everything `StreamSession` delivers. Not `Sendable`: the video, audio and haptics cases carry views into
/// buffers that are valid only during the handler call.
public enum StreamEvent {
    /// The stream is up: delivered once, before any AV event (receive thread).
    case connected(StreamConnectedInfo)
    /// The console's audio header (receive thread, right after `connected`).
    case audioHeader(AudioHeader)
    /// One complete Annex-B access unit. The bytes are valid only during the call: copy what you keep. To
    /// reject the frame (the decoder failed), call `StreamSession.rejectVideoFrame()` before returning.
    case videoAccessUnit(UnsafeRawBufferPointer, VideoFrameInfo)
    /// The parameter sets to give the decoder as their own sample before the next frame (the first frame, and
    /// whenever the console switches resolution).
    case parameterSets(profileIndex: Int, profile: VideoProfile, codec: VideoCodec?)
    /// An Opus packet, a lost frame to conceal, or a skipped gap (valid only during the call).
    case audioPacket(AudioEvent)
    /// DualSense haptics: interleaved signed 16-bit left/right samples at 3000 Hz (valid only during the call).
    case haptics(frameIndex: UInt16, samples: UnsafeBufferPointer<Int16>)
    case rumble(RumbleLevels)
    case triggerEffects(TriggerEffects)
    /// The light-bar colour, when pad info changes it.
    case ledColor(red: UInt8, green: UInt8, blue: UInt8)
    /// The player index (0 = player 1), when pad info changes it.
    case playerIndex(UInt8)
    /// Pad info asked for a motion reset: take the pad's current orientation as the new origin.
    case motionReset
    case connectionQuality(ConnectionQualityMessage)
    case loginPINRequested
    case loginPINResult(accepted: Bool)
    case keyboardOpened(text: String)
    case keyboardTextChanged(sequence: UInt32, text: String)
    case keyboardClosed
    case stats(StreamStats)
    /// Always the last event, delivered exactly once.
    case ended(StreamEndReason)
}

/// Why `StreamSession.start` failed. No `ended` event follows a failed start.
public enum StreamStartError: Error, Sendable, Equatable {
    /// Which part of the session set-up a `SessionError` came from.
    public enum Stage: Sendable, Equatable {
        case sessionInit
        case ctrl
    }

    /// The task was cancelled, or `stop()` was called, before the stream was up.
    case cancelled
    /// Session init or ctrl was refused or failed.
    case session(SessionError, stage: Stage)
    /// The ctrl channel ended, or the probe-to-StreamInfo stage failed, before the stream was up. `detail` has
    /// no secrets in it.
    case stream(StreamEndReason, detail: String)

    /// The end reason of section 11.2 this failure corresponds to (nil when cancelled).
    public var endReason: StreamEndReason? {
        switch self {
        case .cancelled: nil
        case .session(let error, let stage): Self.reason(for: error, stage: stage)
        case .stream(let reason, _): reason
        }
    }

    /// A message for the user (empty when cancelled).
    public func userMessage(console: StreamConsoleName) -> String {
        switch self {
        case .cancelled: ""
        case .session(let error, _): error.userMessage(ps5: console == .ps5)
        case .stream(let reason, _): reason.userMessage(console: console)
        }
    }

    static func reason(for error: SessionError, stage: Stage) -> StreamEndReason {
        let init_ = stage == .sessionInit
        switch error {
        case .consoleBusy: return StreamEndReason(code: .consoleBusy)
        case .remotePlayCrashed: return StreamEndReason(code: .remotePlayCrashed)
        case .versionMismatch: return StreamEndReason(code: .versionMismatch)
        case .noAnswer(.connectionRefused):
            return StreamEndReason(code: init_ ? .sessionInitRefused : .ctrlRefused)
        case .noAnswer, .network:
            return StreamEndReason(code: init_ ? .sessionInitUnknown : .ctrlConnectFailed)
        case .ctrlRejected, .ctrlResetRepeatedly, .invalidResponse, .refused:
            return StreamEndReason(code: init_ ? .sessionInitUnknown : .ctrlFailed)
        case .invalidInput, .cryptoFailure, .cancelled:
            return StreamEndReason(code: .sessionInitUnknown)
        }
    }
}

// The video, audio and haptics cases carry views into buffers that are valid only during the handler call, and
// the session never moves those across threads. Only the control-plane cases (all plain values) cross queues.
extension StreamEvent: @unchecked Sendable {}
