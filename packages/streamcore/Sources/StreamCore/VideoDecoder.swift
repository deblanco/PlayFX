import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import VideoToolbox

/// Hardware H.264 / HEVC decoder for the Annex-B access units libchiaki delivers.
/// Not thread-safe: call `decode` from one thread (libchiaki's video thread).
public final class VideoDecoder {
    public enum Codec { case h264, hevc }

    /// Called synchronously from `decode` with each decoded frame (NV12, Metal-compatible).
    public var onFrame: ((CVPixelBuffer) -> Void)?
    /// Time from handing a frame to VideoToolbox to getting the picture back, smoothed (ms).
    public private(set) var decodeMilliseconds = 0.0

    static func smoothed(_ average: Double, _ sample: Double) -> Double {
        average == 0 ? sample : average * 0.9 + sample * 0.1
    }

    private let codec: Codec
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []

    /// 10-bit output (HDR streams); otherwise 8-bit NV12.
    private let tenBit: Bool

    public init(codec: Codec, tenBit: Bool = false) {
        self.codec = codec
        self.tenBit = tenBit
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Returns false when the frame could not be decoded (caller should request a keyframe).
    @discardableResult
    public func decode(_ accessUnit: UnsafeRawBufferPointer) -> Bool {
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

        var ok = true
        let started = CACurrentMediaTime()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._1xRealTimePlayback],
                                                       infoFlagsOut: nil) { [weak self] status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else { ok = false; return }
            if let self { self.decodeMilliseconds = Self.smoothed(self.decodeMilliseconds, (CACurrentMediaTime() - started) * 1000) }
            self?.onFrame?(imageBuffer)
        }
        if status == kVTInvalidSessionErr {
            // e.g. after sleep/GPU change: rebuild on the next keyframe.
            self.session = nil
            parameterSets = []
        }
        return status == noErr && ok
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

        if let session { VTDecompressionSessionInvalidate(session) }
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
