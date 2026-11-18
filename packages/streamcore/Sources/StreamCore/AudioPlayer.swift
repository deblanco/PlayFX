import AVFoundation
import os

/// Plays interleaved Int16 PCM pushed from libchiaki's Opus decoder with low latency.
public final class AudioPlayer {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var lock = os_unfair_lock()
    private var ring: [Float] = []
    private var readIndex = 0
    private var count = 0
    private var channels = 2
    private var started = false
    /// Samples (per channel) to accumulate before starting, and the cap before dropping old audio.
    private var prebuffer = 0
    private var maxBuffered = 0

    public init() {}

    deinit { stop() }

    public func configure(channels: Int, sampleRate: Double) {
        stop()
        self.channels = max(1, channels)
        prebuffer = Int(sampleRate * 0.03)   // 30 ms
        maxBuffered = Int(sampleRate * 0.12) // 120 ms
        ring = [Float](repeating: 0, count: Int(sampleRate) * self.channels) // 1 s capacity
        readIndex = 0
        count = 0
        started = false

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                          channels: AVAudioChannelCount(self.channels), interleaved: false) else { return }
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
        let samples = frames * channels
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard !ring.isEmpty else { return }
        let cap = ring.count
        for i in 0..<samples {
            if count == cap { readIndex = (readIndex + 1) % cap; count -= 1 }
            ring[(readIndex + count) % cap] = Float(pcm[i]) / 32768
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

    public func stop() {
        if let source {
            engine.stop()
            engine.detach(source)
            self.source = nil
        }
    }

    private func render(frames: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if !started, count >= prebuffer * channels { started = true }
        let available = started ? min(frames, count / channels) : 0
        let cap = ring.count
        for (ch, buffer) in buffers.enumerated() {
            guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for f in 0..<frames {
                out[f] = f < available && ch < channels ? ring[(readIndex + f * channels + ch) % cap] : 0
            }
        }
        readIndex = (readIndex + available * channels) % max(cap, 1)
        count -= available * channels
        if available < frames { started = false } // underrun: rebuffer
    }
}
