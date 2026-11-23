import os

/// The 14-byte audio header of stream info (av.md section 6.1).
public struct AudioHeader: Sendable, Equatable {
    public var channels: Int
    public var bitsPerSample: Int
    public var sampleRate: Int
    /// Samples per channel in one Opus frame.
    public var frameSize: Int
    /// BE32 at offset 10 (1 in headers clients make).
    public var unknown: UInt32

    public static let length = 14

    public init(channels: Int, bitsPerSample: Int, sampleRate: Int, frameSize: Int, unknown: UInt32 = 1) {
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        self.sampleRate = sampleRate
        self.frameSize = frameSize
        self.unknown = unknown
    }

    /// Nil unless `bytes` is exactly 14 bytes.
    public init?(_ bytes: [UInt8]) {
        guard bytes.count == Self.length else { return nil }
        func be32(_ i: Int) -> UInt32 {
            UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
        }
        self.init(
            channels: Int(bytes[0]), bitsPerSample: Int(bytes[1]), sampleRate: Int(be32(2)),
            frameSize: Int(be32(6)), unknown: be32(10))
    }

    public var bytes: [UInt8] {
        func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
        return [UInt8(truncatingIfNeeded: channels), UInt8(truncatingIfNeeded: bitsPerSample)]
            + be32(UInt32(truncatingIfNeeded: sampleRate)) + be32(UInt32(truncatingIfNeeded: frameSize))
            + be32(unknown)
    }
}

/// The audio packet checks and the frame index of each unit (av.md sections 6.2, 6.3), shared by game audio
/// and haptics.
struct AudioPacketLayout {
    var unitSize: Int
    var sourceUnits: Int
    var redundantUnits: Int
    var frameIndex: UInt16

    /// Nil when the packet fails section 6.2's checks: codec 5, payload not empty, `s + r = n`, payload length
    /// `n * unitSize`.
    init?(_ unit: AVUnit) {
        guard unit.codec == AVUnit.opusCodec else { return nil }
        let w = unit.audio
        guard unit.payload.count > 0, w.sourceUnits + w.redundantUnits == w.unitsTotal,
            unit.payload.count == w.unitsTotal * w.unitSize
        else { return nil }
        unitSize = w.unitSize
        sourceUnits = w.sourceUnits
        redundantUnits = w.redundantUnits
        frameIndex = unit.frameIndex
    }

    var unitCount: Int { sourceUnits + redundantUnits }

    /// The frame index of unit `i`: source units `F + i`, redundant unit `s + q` is `F - r + q`.
    func frame(ofUnit i: Int) -> UInt16 {
        i < sourceUnits
            ? frameIndex &+ UInt16(i)
            : frameIndex &- UInt16(redundantUnits) &+ UInt16(i - sourceUnits)
    }

    /// Whether the start-up rule drops unit `i` (a redundant unit naming a frame at or before 0).
    func startUpSkips(unit i: Int) -> Bool {
        guard i >= sourceUnits else { return false }
        return Int(frameIndex) + (i - sourceUnits) < redundantUnits + 1
    }
}

/// Tracks "has a packet with `F > 32768` been seen" (av.md section 6.3's start-up rule).
struct AudioStartUp {
    private(set) var passed = false

    mutating func skips(_ layout: AudioPacketLayout, unit i: Int) -> Bool {
        if layout.frameIndex > 32768 { passed = true }
        return !passed && layout.startUpSkips(unit: i)
    }
}

/// What the audio receiver hands out, in frame order.
public enum AudioEvent {
    /// One Opus packet (RFC 6716, with its TOC byte) for this frame. Valid only during the call.
    case packet(frameIndex: UInt16, opus: UnsafeRawBufferPointer)
    /// This frame never arrived: run the decoder's packet-loss concealment.
    case lost(frameIndex: UInt16)
    /// PlayFX addition (DESIGN.md, Deviations): a gap longer than the concealment cap. `maxConcealedFrames`
    /// `.lost` events were sent for its start; `count` more frames, from `firstFrame`, are skipped without
    /// concealment (the decoder should just reset or carry on).
    case skipped(firstFrame: UInt16, count: Int)
}

/// Audio counters read by the transport's congestion timer while the receive thread updates them.
public struct AudioStatistics: Sendable, Equatable {
    /// Audio packets seen, valid or not.
    public var packetsReceived = 0
    /// The highest audio frame index seen, in serial order.
    public var highestFrameIndex: UInt16 = 0
    public var framesConcealed = 0
}

/// Game audio: unit to Opus packet mapping, redundancy and the jitter buffer of av.md section 6. It doesn't
/// decode.
public final class AudioReceiver {
    /// Slots of the jitter buffer.
    public static let slotCount = 8
    /// Frames buffered before playback starts, and the concealment threshold.
    public static let prefill = 3
    /// At least this many frames can be concealed in one gap. The cap is the larger of this and 500 ms of
    /// frames at the header's rate (64 frames is 640 ms at 10 ms per frame).
    public static let minConcealedFrames = 64

    private let handler: (AudioEvent) -> Void
    private var startUp = AudioStartUp()
    private var frames = [UInt16](repeating: 0, count: slotCount)
    private var lengths = [Int](repeating: -1, count: slotCount)
    private let storage: UnsafeMutablePointer<UInt8>
    private var buffered = 0
    private var started = false
    private var next: UInt16 = 0

    public private(set) var header: AudioHeader?
    private let counters = OSAllocatedUnfairLock(initialState: AudioStatistics())

    /// The counters, safe to read from another thread.
    public var statistics: AudioStatistics { counters.withLock { $0 } }
    /// Audio packets seen, valid or not (for the transport's congestion statistics).
    public var packetsReceived: Int { statistics.packetsReceived }
    /// The highest audio frame index seen, in serial order.
    public var highestFrameIndex: UInt16 { statistics.highestFrameIndex }
    public var framesConcealed: Int { statistics.framesConcealed }

    /// The most frames one gap conceals before the rest is reported as `.skipped`.
    public var maxConcealedFrames: Int {
        guard let h = header, h.frameSize > 0 else { return Self.minConcealedFrames }
        let half = (h.sampleRate / 2 + h.frameSize - 1) / h.frameSize
        return max(Self.minConcealedFrames, min(half, 10_000))
    }

    public init(handler: @escaping (AudioEvent) -> Void) {
        self.handler = handler
        storage = .allocate(capacity: Self.slotCount * 256)
    }

    deinit { storage.deallocate() }

    /// A new audio header resets the receiver (jitter buffer and indices).
    public func setHeader(_ newHeader: AudioHeader) {
        header = newHeader
        reset()
    }

    public func reset() {
        startUp = AudioStartUp()
        lengths = [Int](repeating: -1, count: Self.slotCount)
        buffered = 0
        started = false
        next = 0
    }

    public func receive(_ unit: AVUnit) {
        guard unit.kind == .audio else { return }
        let frameIndex = unit.frameIndex
        counters.withLock {
            $0.packetsReceived += 1
            if Serial16.isNewer(frameIndex, than: $0.highestFrameIndex) { $0.highestFrameIndex = frameIndex }
        }
        guard let layout = AudioPacketLayout(unit), let base = unit.payload.baseAddress else { return }
        // Store every unit of the packet first, then decide what to play: the repeated copies fill the
        // holes the source units left (av.md section 6.5, implementer note).
        for i in 0..<layout.unitCount where !startUp.skips(layout, unit: i) {
            store(frame: layout.frame(ofUnit: i), base + i * layout.unitSize, count: layout.unitSize)
        }
        drain()
    }

    private func slot(of frame: UInt16) -> Int? {
        (0..<Self.slotCount).first { lengths[$0] >= 0 && frames[$0] == frame }
    }

    private func store(frame: UInt16, _ bytes: UnsafeRawPointer, count: Int) {
        if started && Serial16.isOlder(frame, than: next) { return }
        if slot(of: frame) != nil { return }
        var target = (0..<Self.slotCount).first { lengths[$0] < 0 }
        if target == nil {
            // Full: a frame older than the newest buffered one replaces the newest.
            let newest = (0..<Self.slotCount).reduce(0) { Serial16.isNewer(frames[$1], than: frames[$0]) ? $1 : $0 }
            guard Serial16.isOlder(frame, than: frames[newest]) else { return }
            target = newest
            buffered -= 1
        }
        guard let t = target else { return }
        frames[t] = frame
        lengths[t] = count
        (storage + t * 256).update(from: bytes.assumingMemoryBound(to: UInt8.self), count: count)
        buffered += 1
    }

    private func oldestSlot() -> Int? {
        var best: Int?
        for s in 0..<Self.slotCount where lengths[s] >= 0 {
            if let b = best, !Serial16.isOlder(frames[s], than: frames[b]) { continue }
            best = s
        }
        return best
    }

    private func drain() {
        if !started {
            guard buffered >= Self.prefill, let oldest = oldestSlot() else { return }
            started = true
            next = frames[oldest]
        }
        while buffered > 0 {
            if let s = slot(of: next) {
                handler(.packet(frameIndex: next, opus: UnsafeRawBufferPointer(start: storage + s * 256, count: lengths[s])))
                lengths[s] = -1
                buffered -= 1
                next &+= 1
                continue
            }
            // `next` is missing and something newer is buffered.
            var nearest = Int.max
            var farthest = 0
            for s in 0..<Self.slotCount where lengths[s] >= 0 {
                let ahead = Int(frames[s] &- next)
                nearest = min(nearest, ahead)
                farthest = max(farthest, ahead)
            }
            guard buffered < Self.prefill || farthest >= Self.prefill else { return }
            let cap = maxConcealedFrames
            if nearest > cap {
                // A long gap (an outage): conceal its first `cap` frames, then report the rest as one event.
                for _ in 0..<cap {
                    handler(.lost(frameIndex: next))
                    next &+= 1
                }
                counters.withLock { $0.framesConcealed += cap }
                handler(.skipped(firstFrame: next, count: nearest - cap))
                next &+= UInt16(nearest - cap)
                continue
            }
            handler(.lost(frameIndex: next))
            counters.withLock { $0.framesConcealed += 1 }
            next &+= 1
        }
    }
}
