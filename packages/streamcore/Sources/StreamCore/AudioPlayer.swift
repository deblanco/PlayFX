import AVFoundation
import os

/// Plays interleaved Int16 PCM pushed from libchiaki's Opus decoder with low latency.
public final class AudioPlayer {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var lock = os_unfair_lock()
    private var ring = AudioRing()

    public init() {}

    deinit { stop() }

    public func configure(channels: Int, sampleRate: Double) {
        stop()
        os_unfair_lock_lock(&lock)
        ring = AudioRing(channels: channels, sampleRate: sampleRate)
        os_unfair_lock_unlock(&lock)

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                          channels: AVAudioChannelCount(ring.channels), interleaved: false) else { return }
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, bufferList in
            self?.render(frames: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(bufferList))
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch {
            FileHandle.standardError.write(Data("[audio] engine start failed: \(error)\n".utf8))
        }
    }

    public func push(_ pcm: UnsafePointer<Int16>, frames: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        ring.push(pcm, frames: frames)
    }

    public func stop() {
        if let source {
            engine.stop()
            engine.detach(source)
            self.source = nil
        }
    }

    func render(frames: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        ring.render(frames: frames, into: buffers.lazy.map { $0.mData?.assumingMemoryBound(to: Float.self) })
    }
}

/// Interleaved Float ring buffer behind AudioPlayer: prebuffers before starting, bounds latency by
/// dropping the oldest audio, and rebuffers after an underrun. Not thread-safe (AudioPlayer locks).
struct AudioRing {
    let channels: Int
    /// Frames (samples per channel) to accumulate before starting, and the cap before dropping old audio.
    let prebuffer: Int
    let maxBuffered: Int
    private(set) var storage: [Float]
    private(set) var readIndex = 0
    /// Buffered samples (all channels).
    private(set) var count = 0
    private(set) var started = false

    init() {
        channels = 2
        prebuffer = 0
        maxBuffered = 0
        storage = []
    }

    init(channels: Int, sampleRate: Double) {
        self.channels = max(1, channels)
        prebuffer = Int(sampleRate * 0.03)   // 30 ms
        maxBuffered = Int(sampleRate * 0.12) // 120 ms
        storage = [Float](repeating: 0, count: Int(sampleRate) * self.channels) // 1 s capacity
    }

    mutating func push(_ pcm: UnsafePointer<Int16>, frames: Int) {
        let samples = frames * channels
        guard !storage.isEmpty else { return }
        let cap = storage.count
        for i in 0..<samples {
            if count == cap { readIndex = (readIndex + 1) % cap; count -= 1 }
            storage[(readIndex + count) % cap] = Float(pcm[i]) / 32768
            count += 1
        }
        // Keep latency bounded: drop the oldest audio if we fell behind.
        let maxSamples = maxBuffered * channels
        if count > maxSamples {
            let drop = count - maxSamples
            readIndex = (readIndex + drop) % cap
            count -= drop
        }
    }

    /// Writes `frames` frames into one non-interleaved buffer per channel (silence when not started
    /// or underrunning) and consumes what was played.
    mutating func render<Outputs: Sequence>(frames: Int, into outputs: Outputs)
    where Outputs.Element == UnsafeMutablePointer<Float>? {
        if !started, count >= prebuffer * channels { started = true }
        let available = started ? min(frames, count / channels) : 0
        let cap = storage.count
        for (ch, out) in outputs.enumerated() {
            guard let out else { continue }
            for f in 0..<frames {
                out[f] = f < available && ch < channels ? storage[(readIndex + f * channels + ch) % cap] : 0
            }
        }
        readIndex = (readIndex + available * channels) % max(cap, 1)
        count -= available * channels
        if available < frames { started = false } // underrun: rebuffer
    }
}
