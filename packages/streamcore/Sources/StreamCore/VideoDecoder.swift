import CoreMedia
import CoreVideo
import Foundation
import os
import QuartzCore
import VideoToolbox

/// Hardware H.264 / HEVC decoder for the Annex-B access units the engine delivers.
/// Call `decode` from one thread (the engine's video thread). Asynchronous by default: VideoToolbox decodes on
/// its own threads, so the caller (the engine's receive thread) goes back to reading packets instead of
/// waiting the few milliseconds a frame takes. Frames come out in order, on VideoToolbox's thread.
public final class VideoDecoder {
    public enum Codec { case h264, hevc }

    /// Called with each decoded frame (NV12, Metal-compatible). Set before decoding starts.
    public var onFrame: ((CVPixelBuffer) -> Void)?
    /// Also called for each decoded frame, with the index given to `decode` (its place in the stream).
    public var onIndexedFrame: ((CVPixelBuffer, UInt64?) -> Void)?
    /// Time from handing a frame to VideoToolbox to getting the picture back, smoothed (ms).
    public var decodeMilliseconds: Double { results.withLock { $0.decodeMs } }

    /// Written where frames come out (VideoToolbox's thread when asynchronous): the decode time, and whether
    /// a frame failed since `decode` last reported.
    private let results = OSAllocatedUnfairLock(initialState: (decodeMs: 0.0, failed: false))
    private let asynchronous: Bool

    static func smoothed(_ average: Double, _ sample: Double) -> Double {
        average == 0 ? sample : average * 0.9 + sample * 0.1
    }

    private let codec: Codec
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []

    /// 10-bit output (HDR streams); otherwise 8-bit NV12.
    private let tenBit: Bool

    public init(codec: Codec, tenBit: Bool = false, asynchronous: Bool = true) {
        self.codec = codec
        self.tenBit = tenBit
        self.asynchronous = asynchronous
    }

    deinit {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }

    /// Waits for the frames still being decoded. Returns false if any frame failed since `decode` last said.
    @discardableResult
    public func flush() -> Bool {
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
        return !takeFailure()
    }

    /// As if a frame had failed where frames come out (tests: an asynchronous failure's timing isn't controllable).
    func markFailedForTesting() { results.withLock { $0.failed = true } }

    private func takeFailure() -> Bool {
        results.withLock { state in
            defer { state.failed = false }
            return state.failed
        }
    }

    /// Returns false when this frame, or (decoding asynchronously) one before it, could not be decoded: the
    /// caller should request a keyframe.
    @discardableResult
    public func decode(_ accessUnit: UnsafeRawBufferPointer, index: UInt64? = nil) -> Bool {
        let nalus = Self.splitAnnexB(accessUnit)
        var params: [Data] = []
        var payload = Data()
        for nalu in nalus where !nalu.isEmpty {
            if Self.isParameterSet(nalu[nalu.startIndex], codec: codec) {
                params.append(Data(nalu))
            } else {
                var len = UInt32(nalu.count).bigEndian
                payload.append(Data(bytes: &len, count: 4))
                payload.append(contentsOf: nalu)
            }
        }
        if !params.isEmpty, params != parameterSets {
            guard makeSession(params) else { return false }
        }
        guard let session, let format, !payload.isEmpty else { return session != nil }
        guard let sample = makeSampleBuffer(payload, format: format) else { return false }

        let started = CACurrentMediaTime()
        let flags: VTDecodeFrameFlags = asynchronous ? [._1xRealTimePlayback, ._EnableAsynchronousDecompression] : [._1xRealTimePlayback]
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: flags,
                                                       infoFlagsOut: nil) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            let frame = status == noErr ? imageBuffer : nil
            results.withLock { state in
                if frame == nil { state.failed = true }
                else { state.decodeMs = Self.smoothed(state.decodeMs, (CACurrentMediaTime() - started) * 1000) }
            }
            guard let frame else { return }
            onFrame?(frame)
            onIndexedFrame?(frame, index)
        }
        if status == kVTInvalidSessionErr {
            // e.g. after sleep/GPU change: rebuild on the next keyframe, releasing the dead session's resources.
            VTDecompressionSessionInvalidate(session)
            self.session = nil
            parameterSets = []
        }
        // Synchronously this frame's own result; asynchronously, any earlier frame's that failed since.
        return !takeFailure() && status == noErr
    }

    // MARK: Private

    /// Whether a NAL unit (by its first header byte) is a parameter set for `codec`.
    static func isParameterSet(_ header: UInt8, codec: Codec) -> Bool {
        switch codec {
        case .h264: return [7, 8].contains(header & 0x1F)              // SPS, PPS
        case .hevc: return [32, 33, 34].contains((header >> 1) & 0x3F) // VPS, SPS, PPS
        }
    }

    private func makeSession(_ params: [Data]) -> Bool {
        var newFormat: CMFormatDescription?
        let pointers = params.map { d -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
            d.copyBytes(to: p, count: d.count)
            return p
        }
        defer { pointers.forEach { $0.deallocate() } }
        let ptrs = pointers.map { UnsafePointer($0) }
        let sizes = params.map(\.count)
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil, parameterSetCount: params.count, parameterSetPointers: ptrs,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &newFormat)
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: nil, parameterSetCount: params.count, parameterSetPointers: ptrs,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &newFormat)
        }
        guard status == noErr, let newFormat else { return false }

        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session) // the old size's frames first
            VTDecompressionSessionInvalidate(session)
        }
        session = nil

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        let spec: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
        var newSession: VTDecompressionSession?
        let s = VTDecompressionSessionCreate(allocator: nil, formatDescription: newFormat,
                                             decoderSpecification: spec as CFDictionary,
                                             imageBufferAttributes: attrs as CFDictionary,
                                             outputCallback: nil, decompressionSessionOut: &newSession)
        guard s == noErr, let newSession else { return false }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
        format = newFormat
        parameterSets = params
        return true
    }

    private func makeSampleBuffer(_ payload: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: payload.count,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: payload.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = payload.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: payload.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = payload.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    /// Splits an Annex-B byte stream on 3- or 4-byte start codes.
    static func splitAnnexB(_ buf: UnsafeRawBufferPointer) -> [Slice<UnsafeRawBufferPointer>] {
        var result: [Slice<UnsafeRawBufferPointer>] = []
        let n = buf.count
        var i = 0
        var start = -1
        while i + 2 < n {
            if buf[i] == 0, buf[i + 1] == 0, buf[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    if end > start, buf[end - 1] == 0 { end -= 1 } // 4-byte start code
                    result.append(buf[start..<end])
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0, start < n { result.append(buf[start..<n]) }
        return result
    }
}
