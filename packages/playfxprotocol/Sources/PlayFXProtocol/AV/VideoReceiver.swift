import Foundation
import os

/// One resolution the console may encode (stream.md section 8.1): its size and Annex-B parameter sets.
public struct VideoProfile: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// H.264: SPS and PPS; HEVC: VPS, SPS and PPS, each after a 4-byte start code.
    public var header: [UInt8]

    public init(width: Int, height: Int, header: [UInt8]) {
        self.width = width
        self.height = height
        self.header = header
    }
}

/// What goes with each access unit handed to the decoder (av.md section 4.4).
public struct VideoFrameInfo: Sendable, Equatable {
    public var frameIndex: UInt16
    /// Frames skipped since the previous frame handed over, whatever the reason.
    public var framesLost: Int
    /// The slice header was rewritten to an older reference: decodable, but may show artefacts.
    public var recovered: Bool
    /// True/false when the first slice was parsed; nil when it couldn't be.
    public var isKeyFrame: Bool?
    /// Missing source units were rebuilt with the erasure code.
    public var fecRecovered: Bool
    /// The stream-info resolution this frame belongs to.
    public var profileIndex: Int
    public var codec: VideoCodec?
}

/// Why the receiver wants a key frame.
public enum IDRReason: Sendable, Equatable {
    case fecFailed
    case missingReference
    case waitingForKeyFrame
}

/// The video receiver's outputs. All are called synchronously on the thread that fed the unit, so they
/// must be quick (hand off to a queue).
public struct VideoCallbacks {
    /// One complete Annex-B access unit. The bytes are valid only during the call (see `AccessUnitBuffer`).
    /// Return false when the decoder rejected it.
    public var accessUnit: (_ bytes: UnsafeRawBufferPointer, _ info: VideoFrameInfo) -> Bool
    /// The parameter sets of a resolution, to be given to the decoder as their own sample before the next
    /// frame: on the first frame and whenever the adaptive stream index changes. Valid only during the call.
    public var parameterSets: (_ profileIndex: Int, _ profile: VideoProfile, _ codec: VideoCodec?) -> Void
    /// Send stream.md's CorruptFrame message for these frames (inclusive, 16-bit frame indices).
    public var corruptFrames: (_ first: UInt16, _ last: UInt16) -> Void
    /// Send stream.md's IdrRequest message.
    public var needsIDR: (_ reason: IDRReason) -> Void
    /// PlayFX addition, not in av.md (see DESIGN.md, Deviations): the decoder has rejected this many frames in
    /// a row. Raised at most once per second while it keeps happening; it is NOT an IDR request, and the
    /// receiver does nothing else about it. The integrator decides (rebuild the decoder, ask for a key frame).
    public var decoderRejecting: (_ consecutiveRejections: Int) -> Void

    public init(
        accessUnit: @escaping (UnsafeRawBufferPointer, VideoFrameInfo) -> Bool,
        parameterSets: @escaping (Int, VideoProfile, VideoCodec?) -> Void,
        corruptFrames: @escaping (UInt16, UInt16) -> Void,
        needsIDR: @escaping (IDRReason) -> Void,
        decoderRejecting: @escaping (Int) -> Void = { _ in }
    ) {
        self.accessUnit = accessUnit
        self.parameterSets = parameterSets
        self.corruptFrames = corruptFrames
        self.needsIDR = needsIDR
        self.decoderRejecting = decoderRejecting
    }
}

public struct VideoStatistics: Sendable, Equatable {
    public var framesHandedOver = 0
    /// The running total of `VideoFrameInfo.framesLost`.
    public var framesLost = 0
    public var framesRecoveredByFEC = 0
    public var framesFECFailed = 0
    public var framesRewritten = 0
    public var framesDropped = 0
}

/// Video frame assembly and the per-frame rules of av.md sections 2 and 4.
///
/// Not thread safe: feed it from one thread (the transport's receive thread). Allocates only while growing to
/// the largest frame seen.
public final class VideoReceiver {
    /// Frames of more than this many units (`k + max(m, 1)`) are invalid (av.md section 2.1).
    public static let maxUnitsPerFrame = 512
    /// The largest unit size `S` accepted. Real units are at most an MTU; this bounds memory for hostile input.
    public static let defaultMaxUnitSize = 4096
    /// IDR requests are repeated at most this often (seconds).
    public static let idrRepeatInterval = 1.0
    /// How many handed-over frames are remembered as references.
    public static let referenceHistory = 16
    /// The farthest back an HEVC rewrite looks.
    public static let maxRewriteDistance = 15

    private let callbacks: VideoCallbacks
    private let clock: () -> Double
    private let maxUnitSize: Int
    private let idrOnMissingReference: Bool

    // Stream info.
    private var profiles: [VideoProfile] = []
    private var profileInfos: [VideoProfileInfo] = []
    private var currentProfile: Int?

    // Per-frame rules (section 4.3).
    private var lastGood: UInt16 = 0
    private var lastHandedOver: UInt16?
    private var waitingForIdr = false
    private var lastIdrRequest = -Double.infinity
    private var refs = [UInt16](repeating: 0, count: VideoReceiver.referenceHistory)
    private var refCount = 0
    private var refHead = 0

    // The frame being assembled.
    private var hasFrame = false
    private var frame: UInt16 = 0
    private var frameProfile = 0
    private var finished = false
    private var unitsTotal = 0
    private var sourceUnits = 0
    private var fecUnits = 0
    private var slotCount = 0
    private var unitSize = 0
    private var received = 0
    private var sourceReceived = 0
    private let storage: UnsafeMutablePointer<UInt8>
    private let present: UnsafeMutablePointer<Bool>

    private let decoder: FECDecoder
    private let accessUnit = AccessUnitBuffer()
    private let slices = SliceParser()

    // Congestion counters (section 4.5), reset by `takeCongestionCounters`. A timer thread reads them while
    // the receive thread adds to them (once per frame), so they sit behind a lock.
    private let congestion = OSAllocatedUnfairLock(initialState: (received: 0, lost: 0))

    // Decoder rejections (not in av.md): see `VideoCallbacks.decoderRejecting`.
    public static let rejectionThreshold = 5
    private var consecutiveRejections = 0
    private var lastRejectionEvent = -Double.infinity

    public private(set) var statistics = VideoStatistics()

    public init(
        callbacks: VideoCallbacks, maxUnitSize: Int = VideoReceiver.defaultMaxUnitSize,
        idrOnMissingReference: Bool = false,
        clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.callbacks = callbacks
        self.clock = clock
        self.maxUnitSize = maxUnitSize
        self.idrOnMissingReference = idrOnMissingReference
        decoder = FECDecoder()
        storage = .allocate(capacity: Self.maxUnitsPerFrame * maxUnitSize)
        present = .allocate(capacity: Self.maxUnitsPerFrame)
        present.initialize(repeating: false, count: Self.maxUnitsPerFrame)
    }

    deinit {
        storage.deallocate()
        present.deallocate()
    }

    /// Sets the stream's resolutions (from stream info) and starts over: a new stream.
    /// - Parameter codec: the codec that was negotiated, when the integrator knows it. The video `codec` byte
    ///   isn't read (av.md clarification 5); without this the codec is detected from each profile's header.
    public func setProfiles(_ newProfiles: [VideoProfile], codec: VideoCodec? = nil) {
        profiles = Array(newProfiles.prefix(8))
        profileInfos = profiles.map { VideoProfileInfo(header: $0.header, codec: codec) }
        currentProfile = nil
        lastGood = 0
        lastHandedOver = nil
        waitingForIdr = false
        lastIdrRequest = -Double.infinity
        consecutiveRejections = 0
        lastRejectionEvent = -Double.infinity
        refCount = 0
        refHead = 0
        hasFrame = false
        finished = false
    }

    /// Units received and units missing since the last call (av.md section 4.5), for the congestion report.
    /// Safe to call from another thread than the one feeding units.
    public func takeCongestionCounters() -> (received: Int, lost: Int) {
        congestion.withLock { counters in
            defer { counters = (0, 0) }
            return counters
        }
    }

    // MARK: Receiving

    public func receive(_ unit: AVUnit) {
        guard unit.kind == .video else { return }
        let word = unit.video
        let m = word.fecUnits
        let n = word.unitsTotal
        guard n >= m else { return }
        let k = n - m
        guard k >= 1 else { return }
        guard k + max(m, 1) <= Self.maxUnitsPerFrame else { return }
        let f = unit.frameIndex

        if !hasFrame || Serial16.isNewer(f, than: frame) {
            let profile = Int(unit.adaptiveStreamIndex)
            if profile != currentProfile && profile >= profiles.count { return }
            startFrame(f, profile: profile, total: n, fec: m)
        } else if f != frame {
            return
        }
        guard n == unitsTotal, m == fecUnits else { return }
        add(unit: unit, index: word.unitIndex)
    }

    private func startFrame(_ f: UInt16, profile: Int, total: Int, fec: Int) {
        if hasFrame {
            if !finished { finishFrame() }
            let (got, missing) = (received, max(slotCount - received, 0))
            congestion.withLock { $0 = ($0.received + got, $0.lost + missing) }
        }
        if Serial16.isNewer(f, than: lastGood &+ 1) { callbacks.corruptFrames(lastGood &+ 1, f &- 1) }
        if profile != currentProfile {
            currentProfile = profile
            callbacks.parameterSets(profile, profiles[profile], profileInfos[profile].codec)
        }
        hasFrame = true
        frame = f
        frameProfile = profile
        finished = false
        unitsTotal = total
        fecUnits = fec
        sourceUnits = total - fec
        slotCount = sourceUnits + max(fec, 1)
        unitSize = 0
        received = 0
        sourceReceived = 0
        present.update(repeating: false, count: slotCount)
    }

    private func add(unit: AVUnit, index: Int) {
        accept(unit: unit, index: index)
        // av.md 2.4: the last unit finishes the frame unconditionally, also when it was rejected or is the
        // frame's first unit.
        if index == unitsTotal - 1 && !finished { finishFrame() }
    }

    private func accept(unit: AVUnit, index: Int) {
        let length = unit.payload.count
        guard index < unitsTotal, length > 0, !present[index] else { return }
        let isSource = index < sourceUnits
        var size = unitSize
        if isSource {
            guard length >= 2 else { return }
            if size == 0 { size = length + (Int(unit.payload[0]) << 8 | Int(unit.payload[1])) }
        } else if size == 0 {
            size = length
        }
        guard size > 0, size <= maxUnitSize, length <= size else { return }
        if finished {
            // Late: only counted for the statistics.
            present[index] = true
            received += 1
            return
        }
        unitSize = size
        let slot = storage + index * size
        slot.update(repeating: 0, count: size)
        if let base = unit.payload.baseAddress {
            UnsafeMutableRawPointer(slot).copyMemory(from: base, byteCount: length)
        }
        present[index] = true
        received += 1
        if isSource { sourceReceived += 1 }
        if received >= sourceUnits { finishFrame() }
    }

    // MARK: Finishing a frame (sections 2.5 and 4.3)

    private func finishFrame() {
        finished = true
        guard unitSize > 0 else { return failFrame() }
        var fecRecovered = false
        if sourceReceived < sourceUnits {
            guard decoder.recover(k: sourceUnits, m: fecUnits, size: unitSize, storage: storage, present: present)
            else { return failFrame() }
            fecRecovered = true
        }
        guard buildAccessUnit(), accessUnit.count > 0 else { return failFrame() }
        if fecRecovered { statistics.framesRecoveredByFEC += 1 }
        frameSucceeded(fecRecovered: fecRecovered)
    }

    /// Section 2.5 step 3: drops each source unit's 2-byte prefix and its padding.
    private func buildAccessUnit() -> Bool {
        accessUnit.reset()
        for j in 0..<sourceUnits {
            let slot = storage + j * unitSize
            let pad = Int(slot[0]) << 8 | Int(slot[1])
            let length = unitSize - pad
            if !present[j] && length < 2 { return false }  // a rebuilt unit that makes no sense
            if length > 2 { accessUnit.append(slot + 2, count: length - 2) }
        }
        return true
    }

    private func failFrame() {
        statistics.framesFECFailed += 1
        callbacks.corruptFrames(lastGood &+ 1, frame)
        requestIDR(.fecFailed)
    }

    private func requestIDR(_ reason: IDRReason) {
        let now = clock()
        if !waitingForIdr || now - lastIdrRequest >= Self.idrRepeatInterval {
            waitingForIdr = true
            lastIdrRequest = now
            callbacks.needsIDR(reason)
        }
    }

    private func frameSucceeded(fecRecovered: Bool) {
        let info = profileInfos[frameProfile]
        var recovered = false
        var keyFrame: Bool?
        if let codec = info.codec,
            let slice = slices.firstSlice(in: accessUnit.bytes, codec: codec, h264: info.h264, hevc: info.hevc)
        {
            keyFrame = slice.kind == .i
            if waitingForIdr {
                if slice.kind == .i {
                    waitingForIdr = false
                } else {
                    statistics.framesDropped += 1
                    requestIDR(.waitingForKeyFrame)
                    return
                }
            }
            if slice.kind == .p, let d = slice.referenceDistance, !isReference(frame &- UInt16(d) &- 1) {
                guard codec == .hevc, let newDistance = olderReference(than: d),
                    slices.rewriteHEVCReference(accessUnit.mutableBytes, info: slice, to: newDistance)
                else {
                    // av.md 4.3 step 2: no IDR request and no waiting state; the next frame's corrupt-frame
                    // report covers it. The option below is NOT in the spec (default off): a stream whose console
                    // ignores corrupt-frame reports would otherwise drop every P frame until it sends an IDR.
                    statistics.framesDropped += 1
                    if idrOnMissingReference { requestIDR(.missingReference) }
                    return
                }
                recovered = true
                statistics.framesRewritten += 1
            }
        }
        handOver(recovered: recovered, keyFrame: keyFrame, fecRecovered: fecRecovered, codec: info.codec)
    }

    private func handOver(recovered: Bool, keyFrame: Bool?, fecRecovered: Bool, codec: VideoCodec?) {
        let lost: Int
        if let previous = lastHandedOver {
            let gap = Int(frame &- previous)
            lost = gap == 0 ? 0 : gap - 1
        } else {
            lost = 0
        }
        lastHandedOver = frame
        statistics.framesHandedOver += 1
        statistics.framesLost += lost
        let info = VideoFrameInfo(
            frameIndex: frame, framesLost: lost, recovered: recovered, isKeyFrame: keyFrame,
            fecRecovered: fecRecovered, profileIndex: frameProfile, codec: codec)
        if callbacks.accessUnit(accessUnit.bytes, info) {
            consecutiveRejections = 0
            addReference(frame)
            lastGood = frame
        } else {
            // av.md 4.3 step 3: only lastGood stays put. No IDR request, and waitingForIdr is not touched.
            consecutiveRejections += 1
            if consecutiveRejections >= Self.rejectionThreshold {
                let now = clock()
                if now - lastRejectionEvent >= Self.idrRepeatInterval {
                    lastRejectionEvent = now
                    callbacks.decoderRejecting(consecutiveRejections)
                }
            }
        }
    }

    // MARK: Reference history

    private func isReference(_ f: UInt16) -> Bool {
        for i in 0..<refCount where refs[i] == f { return true }
        return false
    }

    private func addReference(_ f: UInt16) {
        refs[refHead] = f
        refHead = (refHead + 1) % Self.referenceHistory
        refCount = min(refCount + 1, Self.referenceHistory)
    }

    /// The smallest `d' > d`, `d' <= 15`, whose picture is a known reference (section 4.3 step 2).
    private func olderReference(than d: Int) -> Int? {
        guard d < Self.maxRewriteDistance else { return nil }
        for candidate in (d + 1)...Self.maxRewriteDistance where isReference(frame &- UInt16(candidate) &- 1) {
            return candidate
        }
        return nil
    }
}
