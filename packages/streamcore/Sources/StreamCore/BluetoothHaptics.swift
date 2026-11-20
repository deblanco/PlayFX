import Foundation
import IOKit.hid
import os

// Real DualSense haptics for a pad on Bluetooth. On USB the pad is a 4-channel sound device (see
// DualSenseHaptics); on Bluetooth it has no sound device, and the console's haptics audio (stereo, 3 kHz)
// travels to it in HID output report 0x32 instead: signed 8-bit stereo, 32 frames (10.7 ms) per report.
//
// Sony doesn't document the report. The layout was first published by SAxense
// (https://github.com/egormanga/SAxense) and is described in dualsense-companion
// (https://github.com/vingt-2/dualsense-companion) and in Veyra's pull request #165, whose measurements
// (buffer depth, the reserve the sender keeps) this follows; the code here is written from those
// descriptions.

/// HID output report 0x32 with one block of haptics audio.
enum DualSenseHapticsReport {
    static let id: UInt8 = 0x32
    static let size = 142
    /// Stereo frames per report: 10.7 ms at 3 kHz.
    static let frames = 32
    /// How far ahead the pad buffers before it plays (about milliseconds). 0x40 measured ~70 ms from write to
    /// vibration and rode out Bluetooth stalls; 0x20 dropped out several times in 10 s; 0x04 plays nothing.
    static let bufferDepth: UInt8 = 0x40

    /// The report for `samples` (32 interleaved left/right frames, 16-bit). `sequence` counts reports (its low
    /// four bits are used), `counter` is the control section's running count.
    static func build(_ samples: [Int16], sequence: UInt8, counter: UInt8, bufferDepth: UInt8 = bufferDepth) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: size)
        report[0] = id
        report[1] = (sequence & 0x0f) << 4
        // Control section (0x11 with its "present" bit): 7 bytes.
        report[2] = 0x80 | 0x11
        report[3] = 7
        report[4] = 0xfe
        report[9] = bufferDepth
        report[10] = counter
        // Samples section (0x12): 64 bytes, left then right for each frame.
        report[11] = 0x80 | 0x12
        report[12] = UInt8(frames * 2)
        for (i, sample) in samples.prefix(frames * 2).enumerated() { report[13 + i] = UInt8(bitPattern: narrow(sample)) }
        // Bluetooth output reports end in a CRC-32 over the byte 0xA2 and the report, little endian.
        let crc = ~crc32(crc32(0xffff_ffff, [0xa2]), report[0..<(size - 4)])
        for i in 0..<4 { report[size - 4 + i] = UInt8(truncatingIfNeeded: crc >> (8 * i)) }
        return report
    }

    /// 16 bits to the pad's 8, rounded half away from zero (truncating would silence quiet effects).
    static func narrow(_ sample: Int16) -> Int8 {
        let value = Int(sample)
        return Int8(clamping: (value >= 0 ? value + 128 : value - 128) / 256)
    }

    /// Above the noise floor of one 8-bit step, which the console sends between effects.
    static func audible(_ sample: Int16) -> Bool { abs(Int(narrow(sample))) > 1 }

    /// CRC-32 (reflected 0xEDB88320), without the final inversion, continuing from `crc`.
    static func crc32<C: Collection>(_ crc: UInt32, _ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc = crc
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1))) }
        }
        return crc
    }

    /// `count` interleaved frames (1…33) fitted into one 32-frame block: 31 and 33 are stretched or squeezed
    /// linearly (first and last frame kept, so blocks join without a step), 32 are copied, fewer are the end of
    /// an effect and padded with silence.
    static func fit(_ input: ArraySlice<Int16>) -> [Int16] {
        let count = input.count / 2
        let source = Array(input)
        if count != frames - 1 && count != frames + 1 {
            var out = Array(source.prefix(frames * 2))
            out += [Int16](repeating: 0, count: frames * 2 - out.count)
            return out
        }
        var out = [Int16](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let position = Double(i) * Double(count - 1) / Double(frames - 1)
            let index = Int(position), after = min(index + 1, count - 1), part = position - Double(index)
            for channel in 0..<2 {
                let a = Double(source[index * 2 + channel]), b = Double(source[after * 2 + channel])
                out[i * 2 + channel] = Int16(clamping: Int((a + (b - a) * part).rounded()))
            }
        }
        return out
    }
}

/// When to send a report and how much audio to put in it. The audio arrives in uneven batches (none, 10 or
/// 20 ms at a time) and the console's 3 kHz clock isn't the Mac's, so the sender keeps a reserve: a stream
/// starts with 96 frames queued (or once a short effect has stopped arriving); while the reserve runs low a
/// report takes 31 frames (stretched to 32), while it stays high 33; with too little audio still arriving the
/// report waits; an effect's last frames go out padded once its audio has stopped.
struct HapticsPacer {
    static let startFrames = 96
    /// Reserve thresholds (frames), over the last `shortWindow` reports for low, `longWindow` for high.
    static let lowEnter = 44, lowExit = 76, highEnter = 200, highExit = 150
    static let shortWindow = 16, longWindow = 64

    enum Step: Equatable {
        /// Nothing to send now.
        case idle
        /// Audio is still arriving but there isn't a block's worth yet: try again next tick.
        case wait
        /// Send a report with this many frames from the queue.
        case send(Int)
    }

    private var flowing = false
    private var shortEffect = false
    /// The queue's level before each recent report, newest last.
    private var levels: [Int] = []
    /// Added to a block's 32 frames: −1 while the reserve is low (31 frames stretched, one frame of reserve
    /// back per report), +1 while it stays high (33 squeezed), 0 otherwise.
    private(set) var mode = 0

    mutating func reset() { self = HapticsPacer() }

    /// `queued`: frames waiting; `sinceAudio`: seconds since audio last arrived; `waited`: how long the oldest
    /// queued frame has waited.
    mutating func next(queued: Int, sinceAudio: Double, waited: Double) -> Step {
        let arriving = sinceAudio < 0.028
        if !flowing {
            guard queued > 0, queued >= Self.startFrames || !arriving || waited >= 0.08 else { return .idle }
            flowing = true
            levels.removeAll()
            mode = 0
            shortEffect = queued < Self.startFrames && !arriving
        }
        if arriving { shortEffect = false }
        let want = DualSenseHapticsReport.frames + mode
        if queued < want {
            if !shortEffect && sinceAudio < 0.04 { return .wait }
            guard queued > 0 else { flowing = false; return .idle } // the effect is over
        }
        observe(queued)
        return .send(min(queued, want))
    }

    /// Lowest queue level before a report within the last `reports` reports.
    private func reserve(_ reports: Int) -> Int { levels.suffix(reports).min() ?? 0 }

    private mutating func observe(_ level: Int) {
        levels.append(level)
        if levels.count > Self.longWindow { levels.removeFirst(levels.count - Self.longWindow) }
        guard levels.count >= Self.shortWindow else { return }
        let recent = reserve(Self.shortWindow)
        switch mode {
        case -1: if recent >= Self.lowExit { mode = 0 }
        case 1: if recent <= Self.highExit { mode = 0 }
        default:
            if recent < Self.lowEnter { mode = -1 }
            else if levels.count == Self.longWindow && reserve(Self.longWindow) > Self.highEnter { mode = 1 }
        }
    }
}

/// The haptics audio waiting for the Bluetooth sender: appended from libchiaki's haptics thread, taken by the
/// sender's thread.
final class BluetoothHapticsQueue: @unchecked Sendable {
    private struct State {
        var samples: [Int16] = []
        var lastAudio = -Double.infinity
        var oldestSince = 0.0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// At most this much is kept (frames): beyond it the oldest audio is dropped, as on USB.
    static let capacity = 600

    func append(_ samples: UnsafeBufferPointer<Int16>, now: Double) {
        state.withLock { s in
            if s.samples.isEmpty { s.oldestSince = now }
            s.samples.append(contentsOf: samples)
            s.lastAudio = now
            let excess = s.samples.count - Self.capacity * 2
            if excess > 0 { s.samples.removeFirst(excess + excess % 2) }
        }
    }

    /// (queued frames, seconds since audio arrived, seconds the oldest frame has waited).
    func levels(now: Double) -> (queued: Int, sinceAudio: Double, waited: Double) {
        state.withLock { s in (s.samples.count / 2, now - s.lastAudio, s.samples.isEmpty ? 0 : now - s.oldestSince) }
    }

    /// Takes up to `frames` frames (interleaved).
    func take(_ frames: Int, now: Double) -> ArraySlice<Int16> {
        state.withLock { s in
            let n = min(frames * 2, s.samples.count)
            let taken = s.samples.prefix(n)
            s.samples.removeFirst(n)
            s.oldestSince = now
            return ArraySlice(Array(taken))
        }
    }

    func clear() { state.withLock { $0.samples.removeAll() } }
}

/// Fills reports from the queue: what one tick of the sender does, apart from the write itself.
struct HapticsReportMaker {
    private var pacer = HapticsPacer()
    private var sequence: UInt8 = 0
    private var counter: UInt8 = 0

    /// The report to write now, if any.
    mutating func next(_ queue: BluetoothHapticsQueue, now: Double) -> [UInt8]? {
        let level = queue.levels(now: now)
        guard case .send(let frames) = pacer.next(queued: level.queued, sinceAudio: level.sinceAudio, waited: level.waited)
        else { return nil }
        let block = DualSenseHapticsReport.fit(queue.take(frames, now: now))
        defer { sequence &+= 1; counter &+= 1 }
        return DualSenseHapticsReport.build(block, sequence: sequence, counter: counter)
    }
}

/// A DualSense connected over Bluetooth, as the HID system lists it.
struct BluetoothPad: Equatable, @unchecked Sendable {
    let name: String
    /// Tells pads apart (the HID location); the device itself is nil for stand-ins in tests.
    let id: Int
    let device: IOHIDDevice?

    static func == (a: BluetoothPad, b: BluetoothPad) -> Bool { a.id == b.id && a.name == b.name }

    /// The first DualSense (054C:0CE6) on Bluetooth, if any. Thin: needs a real pad.
    static func find() -> BluetoothPad? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x054c, kIOHIDProductIDKey: 0x0ce6, kIOHIDTransportKey: "Bluetooth",
        ] as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = devices.first else { return nil }
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "DualSense"
        let location = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int ?? 0
        return BluetoothPad(name: name, id: location, device: device)
    }
}

/// Writes haptics reports to a pad on Bluetooth every 10.7 ms, on a thread of its own (the write call returns
/// long before the pad plays the report, so it gives nothing to pace by). Thin: needs a real pad.
final class BluetoothHapticsSender: DualSenseHaptics.Output, @unchecked Sendable {
    private let device: IOHIDDevice
    private let queue: BluetoothHapticsQueue
    private let running = OSAllocatedUnfairLock(initialState: true)
    private var thread: Thread?

    init?(pad: BluetoothPad, queue: BluetoothHapticsQueue) {
        guard let device = pad.device, IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return nil }
        self.device = device
        self.queue = queue
        let thread = Thread { [weak self] in self?.run() }
        thread.qualityOfService = .userInteractive
        thread.name = "streamcore.bluetooth-haptics"
        self.thread = thread
        thread.start()
    }

    private func run() {
        var maker = HapticsReportMaker()
        let period = Double(DualSenseHapticsReport.frames) / 3000
        var deadline = ProcessInfo.processInfo.systemUptime
        var failures = 0
        while running.withLock({ $0 }) {
            let now = ProcessInfo.processInfo.systemUptime
            if let report = maker.next(queue, now: now) {
                let result = report.withUnsafeBufferPointer {
                    IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(DualSenseHapticsReport.id), $0.baseAddress!, $0.count)
                }
                if result != kIOReturnSuccess {
                    failures += 1
                    if failures == 1 { Log.warning(.input, "DualSense haptics over Bluetooth: write failed (\(result))") }
                } else {
                    failures = 0
                }
            }
            deadline += period
            if deadline < now { deadline = now + period } // fell behind (a stall): don't burst to catch up
            Thread.sleep(forTimeInterval: max(0, deadline - ProcessInfo.processInfo.systemUptime))
        }
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func stop() {
        running.withLock { $0 = false }
        queue.clear()
    }
}
