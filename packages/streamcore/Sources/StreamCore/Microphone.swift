import AVFoundation

/// Cuts a stream of interleaved stereo 16-bit samples into the console's 10 ms microphone frames.
struct MicFramer {
    /// The console's microphone audio: 48 kHz stereo, in 10 ms frames of 480 samples per channel.
    static let sampleRate = 48_000, frameSamples = 480
    static let frameValues = frameSamples * 2 // stereo
    private var pending: [Int16] = []

    /// Adds samples and calls `emit` with each complete frame (exactly `frameValues` values).
    mutating func append(_ samples: UnsafeBufferPointer<Int16>, emit: (UnsafePointer<Int16>) -> Void) {
        pending.append(contentsOf: samples)
        var start = 0
        while pending.count - start >= Self.frameValues {
            pending.withUnsafeBufferPointer { emit($0.baseAddress! + start) }
            start += Self.frameValues
        }
        pending.removeFirst(start)
    }
}

/// The Mac's microphone for voice chat: captures the default input, converts it to 48 kHz stereo 16-bit
/// and hands over 10 ms frames. Needs the user's permission (macOS asks the first time).
public final class Microphone: @unchecked Sendable {
    public enum State: String, Sendable {
        case on, off
        /// The user said no (System Settings → Privacy & Security → Microphone to change it).
        case denied
        /// No input device, or this build can't ask for the microphone (no usage description).
        case unavailable
    }

    /// The build declares why it wants the microphone; without it macOS would terminate the app on access.
    static var canAsk: Bool { Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil }

    private let engine = AVAudioEngine()
    private var framer = MicFramer()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(MicFramer.sampleRate),
                                       channels: 2, interleaved: true)!
    private var running = false
    /// Set by `stop()`, for good: a start still waiting for the permission prompt finds it and doesn't
    /// begin (the session it would feed may be gone by then). `gate` orders the two, which run on
    /// different threads.
    private var closed = false
    private let gate = NSLock()

    /// Asks for permission if needed, then starts; `done` gets the resulting state (on any queue).
    func start(frames: @escaping (UnsafePointer<Int16>) -> Void, done: @escaping (State) -> Void) {
        guard Self.canAsk else { return done(.unavailable) }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(begin(frames))
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                done(granted ? self.begin(frames) : .denied)
            }
        default: done(.denied)
        }
    }

    func begin(_ frames: @escaping (UnsafePointer<Int16>) -> Void) -> State {
        gate.lock()
        defer { gate.unlock() }
        guard !closed else { return .off }
        guard !running else { return .on }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let converter = AVAudioConverter(from: format, to: target) else { return .unavailable }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.convert(buffer, frames)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            Log.warning(.session, "Microphone couldn't start: \(error.localizedDescription)")
            return .unavailable
        }
        running = true
        Log.info(.session, "Microphone on (\(Int(format.sampleRate)) Hz, \(format.channelCount) ch)")
        return .on
    }

    private func convert(_ buffer: AVAudioPCMBuffer, _ frames: (UnsafePointer<Int16>) -> Void) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var given = false
        converter.convert(to: out, error: nil) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard let samples = out.int16ChannelData?[0] else { return }
        framer.append(UnsafeBufferPointer(start: samples, count: Int(out.frameLength) * 2), emit: frames)
    }

    func stop() {
        gate.lock()
        defer { gate.unlock() }
        closed = true
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        Log.info(.session, "Microphone off")
    }

    deinit { stop() }
}
