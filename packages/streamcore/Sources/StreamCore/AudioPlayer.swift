import AVFoundation
import CoreAudio
import os

/// Plays interleaved Int16 PCM pushed from libchiaki's Opus decoder with low latency.
public final class AudioPlayer {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var lock = os_unfair_lock()
    private var ring = AudioRing()
    /// Engine changes come from libchiaki's audio thread (`configure`) and the host's command thread
    /// (`apply`); AVAudioEngine can't take them at once. Recursive: `configure` applies the output.
    private let control = NSRecursiveLock()
    /// While the output is the system default, the device macOS switches to is followed (setting the unit's
    /// device once would pin it to whatever was the default then).
    private var followingDefault = true
    private var defaultListener: AudioObjectPropertyListenerBlock?

    public init() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.defaultOutputChanged() }
        var address = Self.defaultOutputAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr {
            defaultListener = listener
        }
    }

    deinit {
        if let defaultListener {
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, defaultListener)
        }
        stop()
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// The user switched the Mac's output: follow it if that's what was chosen.
    private func defaultOutputChanged() {
        control.lock()
        defer { control.unlock() }
        guard followingDefault, source != nil else { return }
        setDevice(Self.systemDefaultOutput())
        Log.info(.session, "Sound output: following the system default to its new device")
    }

    public func configure(channels: Int, sampleRate: Double) {
        control.lock()
        defer { control.unlock() }
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
        apply(AudioOutput.current)
        do { try engine.start() } catch {
            FileHandle.standardError.write(Data("[audio] engine start failed: \(error)\n".utf8))
        }
    }

    /// The device set explicitly on the output (nil = the system default, followed automatically).
    private var appliedDevice: AudioDeviceID?

    /// Volume at once; a different output device restarts the engine briefly. A device that's no longer
    /// connected falls back to the system default.
    public func apply(_ output: AudioOutput) {
        control.lock()
        defer { control.unlock() }
        engine.mainMixerNode.outputVolume = output.volume
        let wanted = output.deviceUID.flatMap(AudioOutput.deviceID(uid:))
        followingDefault = wanted == nil
        guard wanted != appliedDevice else { return }
        let status = setDevice(wanted ?? Self.systemDefaultOutput())
        if status == noErr { appliedDevice = wanted }
        Log.info(.session, "Sound output: \(output.deviceUID == nil ? "system default" : "chosen device")\(status == noErr ? "" : " (failed: \(status))")")
    }

    /// Points the output unit at `device`, pausing the engine around it. Under `control`.
    @discardableResult
    private func setDevice(_ device: AudioDeviceID) -> OSStatus {
        guard let unit = engine.outputNode.audioUnit else { return kAudioUnitErr_Uninitialized }
        var device = device
        let running = engine.isRunning
        if running { engine.pause() }
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        if running { try? engine.start() }
        return status
    }

    private static func systemDefaultOutput() -> AudioDeviceID {
        var address = defaultOutputAddress
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    public func push(_ pcm: UnsafePointer<Int16>, frames: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        ring.push(pcm, frames: frames)
    }

    public func stop() {
        control.lock()
        defer { control.unlock() }
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
