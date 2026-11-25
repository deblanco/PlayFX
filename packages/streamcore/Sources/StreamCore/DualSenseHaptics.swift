import AudioToolbox
import CoreAudio
import Foundation
import os

/// Real DualSense haptics. The console drives the DualSense's two voice-coil motors with an audio stream
/// (stereo, 3 kHz). On USB the pad is also a 4-channel sound device whose channels 3 and 4 are those motors,
/// so the stream is played there as it is (needs the pad's sound set to 4 channels, "Quadraphonic" in Audio
/// MIDI Setup), with the pad switched into audio-haptics mode while it plays (see USBHapticsMode). On
/// Bluetooth it goes to the pad in HID reports (see BluetoothHaptics.swift). Without either, the caller plays
/// it as rumble.
final class DualSenseHaptics: @unchecked Sendable {
    struct Device: Equatable {
        let id: AudioDeviceID
        let name: String
        let outputChannels: Int
    }

    enum Choice: Equatable {
        case play(Device)
        /// No USB pad to play on, but a DualSense on Bluetooth.
        case bluetooth(BluetoothPad)
        /// A DualSense whose sound is set to 2 channels: the motors aren't reachable until it's set to 4.
        case stereoOnly(Device)
        case none
    }

    /// A DualSense's sound device, if one is plugged in with the motors' channels available; else a pad on
    /// Bluetooth (a USB pad set to 2 channels comes first: it can be fixed, and is what the player plugged in).
    static func choose(_ devices: [Device], bluetooth: BluetoothPad? = nil) -> Choice {
        let pads = devices.filter { $0.name.localizedCaseInsensitiveContains("DualSense") }
        if let pad = pads.first(where: { $0.outputChannels >= 4 }) { return .play(pad) }
        if let pad = pads.first { return .stereoOnly(pad) }
        return bluetooth.map(Choice.bluetooth) ?? .none
    }

    /// Where the stream goes now.
    enum Route: Equatable {
        case usb(Device)
        case bluetooth(BluetoothPad)
    }

    /// Something playing the buffer on a device (the CoreAudio output; stand-ins in tests).
    protocol Output: AnyObject { func stop() }

    /// The Mac's sound output devices (replaced in tests; none in a test run, see `PadHardware`).
    nonisolated(unsafe) static var devices: () -> [Device] = { PadHardware.allowed ? HapticsDevices.all() : [] }
    /// Opens an output playing `buffer` on the device (replaced in tests).
    nonisolated(unsafe) static var open: (Device, HapticsBuffer) -> Output? = { device, buffer in
        HapticsOutputUnit(device: device, buffer: buffer)
    }
    /// A DualSense on Bluetooth, and a sender of the queue's audio to it (replaced in tests).
    nonisolated(unsafe) static var bluetoothPad: () -> BluetoothPad? = { PadHardware.allowed ? BluetoothPad.find() : nil }
    nonisolated(unsafe) static var openBluetooth: (BluetoothPad, BluetoothHapticsQueue) -> Output? = { pad, queue in
        BluetoothHapticsSender(pad: pad, queue: queue)
    }
    /// How often the devices are looked at again: a pad plugged in, or unplugged, mid-stream.
    static let recheckInterval: TimeInterval = 2

    private struct State {
        var output: Output?
        var route: Route?
        var checkedAt = -TimeInterval.infinity
        var warnedStereo = false
        /// A Bluetooth pad that wouldn't open is said once, not every check.
        var warnedBluetooth = false
        /// No pad at all is said once a session, with the Mac's outputs.
        var loggedNoPad = false
        /// When the audio-haptics report last went to the USB pad.
        var enabledAt = -TimeInterval.infinity
        /// `USBHapticsMode.padOutputCount` as last seen.
        var padOutputs: UInt64 = 0
    }
    /// Only `push` uses it, always from the engine's one haptics thread.
    private var upsampler = HapticsUpsampler()
    private let state = OSAllocatedUnfairLock(initialState: State())
    let buffer = HapticsBuffer()
    /// The 3 kHz audio as it comes, for a pad on Bluetooth.
    let bluetoothQueue = BluetoothHapticsQueue()
    /// Looking at the devices and opening one takes milliseconds: not on the engine's receive thread.
    private let queue = DispatchQueue(label: "streamcore.haptics", qos: .userInitiated)
    /// Keeps a USB pad in audio-haptics mode. On `queue`.
    private let mode = USBHapticsMode()

    init() { PadQuiet.register(self) }

    /// Waits for a device check under way (tests).
    func waitUntilIdle() { queue.sync {} }

    deinit { stop() }

    /// Whether the haptics are being played on a pad.
    var isPlaying: Bool { state.withLock { $0.output != nil } }

    /// One frame of the haptics stream (interleaved stereo at 3 kHz), from the engine's thread. Returns whether
    /// it was played on a pad; if not, the caller makes rumble from it.
    func push(_ samples: UnsafeBufferPointer<Int16>, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        let padOutputs = USBHapticsMode.padOutputCount
        let (route, due, resend) = state.withLock { state -> (Route?, Bool, Bool) in
            let due = now - state.checkedAt >= Self.recheckInterval
            if due { state.checkedAt = now }
            let route = state.output == nil ? nil : state.route
            let padOutput = padOutputs != state.padOutputs
            state.padOutputs = padOutputs
            guard case .usb? = route else { return (route, due, false) }
            // The app's own output to the pad may have switched it back to rumble emulation: again shortly after.
            if padOutput {
                state.enabledAt = min(state.enabledAt, now - USBHapticsMode.resendInterval + USBHapticsMode.afterPadOutput)
            }
            let resend = now - state.enabledAt >= USBHapticsMode.resendInterval
            if resend { state.enabledAt = now }
            return (route, due, resend)
        }
        if due || resend {
            queue.async { [weak self] in
                if due { self?.refresh(now: now) }
                if resend { self?.enableAudioHaptics() }
            }
        }
        switch route {
        case .usb: buffer.append(upsampler.upsample(samples))
        case .bluetooth: bluetoothQueue.append(samples, now: now)
        case nil: break
        }
        return route != nil
    }

    /// Stops playing (the session ended).
    func stop() {
        let output = state.withLock { state -> Output? in
            defer {
                state.output = nil
                state.route = nil
                state.checkedAt = .infinity // and no more checks
            }
            return state.output
        }
        output?.stop()
        queue.async { [mode] in mode.reset() }
    }

    /// Starts playing on a pad that was plugged in, or stops when it's gone. On `queue`; the device is opened
    /// outside the lock, so the receive thread never waits for it.
    private func refresh(now: TimeInterval) {
        let devices = Self.devices()
        // Only looked for when no USB pad can play: listing HID devices isn't free.
        let choice = Self.choose(devices, bluetooth: Self.choose(devices) == .none ? Self.bluetoothPad() : nil)
        guard let current = state.withLock({ $0.checkedAt == .infinity ? nil : Optional($0.route) }) else { return }
        let opened: Output? = switch choice {
        case .play(let device) where current != .usb(device): Self.open(device, buffer)
        case .bluetooth(let pad) where current != .bluetooth(pad): Self.openBluetooth(pad, bluetoothQueue)
        default: nil
        }
        let previous = state.withLock { state -> Output? in
            guard state.checkedAt != .infinity else { return opened } // stopped meanwhile: close what was opened
            return apply(choice, opened: opened, to: &state, devices: devices)
        }
        previous?.stop()
        let route = state.withLock { state -> Route? in
            guard case .usb? = state.route, state.output != nil else { return nil }
            if opened != nil { state.enabledAt = now }
            return state.route
        }
        if route == nil {
            mode.reset()
        } else if opened != nil { // just started on USB (or on another USB pad)
            mode.reset()
            enableAudioHaptics()
        }
    }

    /// Sends the USB pad playing the haptics the report that has it play them. On `queue`.
    private func enableAudioHaptics() {
        guard case .usb(let device)? = state.withLock({ $0.output == nil ? nil : $0.route }) else { return }
        mode.enable(device.name)
    }

    /// Returns the output to stop, if any.
    private func apply(_ choice: Choice, opened: Output?, to state: inout State, devices: [Device]) -> Output? {
        let previous = state.output
        switch choice {
        case .play(let device) where state.route == .usb(device):
            return nil
        case .bluetooth(let pad) where state.route == .bluetooth(pad):
            return nil
        case .play(let device):
            state.output = opened
            state.route = opened == nil ? nil : .usb(device)
            Log.info(.input, opened == nil ? "DualSense haptics: couldn't open \(device.name)"
                                           : "DualSense haptics: playing on \(device.name) (USB)")
        case .bluetooth(let pad):
            state.output = opened
            state.route = opened == nil ? nil : .bluetooth(pad)
            if opened != nil {
                Log.info(.input, "DualSense haptics: playing on \(pad.name) (Bluetooth)")
            } else if !state.warnedBluetooth {
                state.warnedBluetooth = true
                Log.warning(.input, "DualSense haptics: couldn't open \(pad.name) on Bluetooth; playing them as rumble")
            }
        case .stereoOnly(let device):
            if previous != nil { Log.info(.input, "DualSense haptics: back to rumble") }
            state.output = nil
            state.route = nil
            if !state.warnedStereo {
                state.warnedStereo = true
                Log.warning(.input, "\(device.name) is on USB with 2-channel sound: set it to 4 channels (Quadraphonic) in "
                    + "Audio MIDI Setup for its real haptics. Playing them as rumble meanwhile.")
            }
        case .none:
            if previous != nil { Log.info(.input, "DualSense haptics: pad gone, back to rumble") }
            state.output = nil
            state.route = nil
            if !state.loggedNoPad {
                state.loggedNoPad = true
                Log.info(.input, "DualSense haptics: no DualSense sound device on USB and no DualSense on Bluetooth; playing "
                    + "them as rumble. The Mac's sound outputs: \(Self.describe(devices))")
            }
        }
        return previous
    }
}

extension DualSenseHaptics {
    /// The outputs' names and channel counts, for the log.
    static func describe(_ devices: [Device]) -> String {
        devices.isEmpty ? "none" : devices.map { "\($0.name) (\($0.outputChannels) ch)" }.joined(separator: ", ")
    }
}

extension DualSenseHaptics: PadOutput {
    /// The process is ending: stops playing on the pad, as when the session ends.
    func quiet() { stop() }
}

/// 3 kHz stereo haptics → 48 kHz, linearly between samples (16 out per sample in), as floats in -1…1.
struct HapticsUpsampler {
    static let factor = 16
    /// The last sample of the previous frame, where the next one's ramp starts.
    private var last: (Float, Float) = (0, 0)

    /// Interleaved stereo in, interleaved stereo out.
    mutating func upsample(_ samples: UnsafeBufferPointer<Int16>) -> [Float] {
        let frames = samples.count / 2
        var out = [Float](repeating: 0, count: frames * Self.factor * 2)
        for i in 0..<frames {
            let next = (Float(samples[2 * i]) / 32768, Float(samples[2 * i + 1]) / 32768)
            for step in 0..<Self.factor {
                let t = Float(step + 1) / Float(Self.factor)
                let o = (i * Self.factor + step) * 2
                out[o] = last.0 + (next.0 - last.0) * t
                out[o + 1] = last.1 + (next.1 - last.1) * t
            }
            last = next
        }
        return out
    }
}

/// The 48 kHz haptics waiting to be played: written from the engine's thread, read by the output's render
/// callback. Kept short so the motors never lag the game after a network stall (60 ms).
final class HapticsBuffer: @unchecked Sendable {
    static let maxFrames = 48_000 * 60 / 1000
    private var lock = os_unfair_lock()
    private var samples: [Float] = [] // interleaved stereo

    /// Adds interleaved stereo frames, dropping the oldest beyond `maxFrames`.
    func append(_ stereo: [Float]) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        samples.append(contentsOf: stereo)
        let excess = samples.count - Self.maxFrames * 2
        if excess > 0 { samples.removeFirst(excess) }
    }

    var bufferedFrames: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return samples.count / 2
    }

    /// Fills `frames` of the device's non-interleaved float buffers: the motors are channels 3 and 4 (the first
    /// two are the pad's speaker, kept silent). Missing haptics are silence.
    func render(frames: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        for buffer in buffers { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
        guard buffers.count >= 4,
              let left = buffers[2].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[3].mData?.assumingMemoryBound(to: Float.self) else { return }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let available = min(frames, samples.count / 2)
        for i in 0..<available {
            left[i] = samples[2 * i]
            right[i] = samples[2 * i + 1]
        }
        samples.removeFirst(available * 2)
    }
}

/// The Mac's sound output devices, with their output channel counts.
enum HapticsDevices {
    static func all() -> [DualSenseHaptics.Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let channels = outputChannels(id)
            guard channels > 0, let name = name(id) else { return nil }
            return DualSenseHaptics.Device(id: id, name: name, outputChannels: channels)
        }
    }

    private static func name(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private static func outputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let list = AudioBufferList.allocate(maximumBuffers: Int(size) / MemoryLayout<AudioBuffer>.stride + 1)
        defer { list.unsafeMutablePointer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list.unsafeMutablePointer) == noErr else { return 0 }
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// Plays a HapticsBuffer on one device through an AUHAL output unit (it converts to the device's rate). The thin
/// hardware adapter: everything it plays comes from HapticsBuffer.render.
final class HapticsOutputUnit: DualSenseHaptics.Output {
    private let unit: AudioUnit
    private let buffer: HapticsBuffer

    init?(device: DualSenseHaptics.Device, buffer: HapticsBuffer) {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        var unit: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &description), AudioComponentInstanceNew(component, &unit) == noErr,
              let unit else { return nil }
        var id = device.id
        let float = UInt32(MemoryLayout<Float>.size)
        var format = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
            mBytesPerPacket: float, mFramesPerPacket: 1, mBytesPerFrame: float, mChannelsPerFrame: UInt32(device.outputChannels),
            mBitsPerChannel: float * 8, mReserved: 0)
        var callback = AURenderCallbackStruct(inputProc: renderHaptics, inputProcRefCon: Unmanaged.passUnretained(buffer).toOpaque())
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                   UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr,
              AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format,
                                   UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr,
              AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                                   UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
              AudioUnitInitialize(unit) == noErr
        else {
            AudioComponentInstanceDispose(unit)
            return nil
        }
        guard AudioOutputUnitStart(unit) == noErr else {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            return nil
        }
        self.unit = unit
        self.buffer = buffer // the render callback holds it unretained
    }

    func stop() {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }
}

/// The output unit's render callback (CoreAudio's real-time thread).
private func renderHaptics(_ refCon: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                           _ time: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                           _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    guard let data else { return noErr }
    Unmanaged<HapticsBuffer>.fromOpaque(refCon).takeUnretainedValue()
        .render(frames: Int(frames), into: UnsafeMutableAudioBufferListPointer(data))
    return noErr
}
