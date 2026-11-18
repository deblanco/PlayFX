import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import StreamCore

/// Tests that touch process-wide state (the C bridge's globals, libchiaki's sockets, the PSN
/// session) run one at a time under this suite.
@Suite(.serialized) enum Serial {}

// MARK: Pixel buffers

/// NV12 (video range) buffer, IOSurface-backed and Metal-compatible, filled with one YCbCr color.
func makeNV12(width: Int, height: Int, y: UInt8, cb: UInt8, cr: UInt8) throws -> CVPixelBuffer {
    try makeNV12(width: width, height: height, cb: cb, cr: cr) { _, _ in y }
}

/// An NV12 frame with uniform chroma and per-pixel luma.
func makeNV12(width: Int, height: Int, cb: UInt8, cr: UInt8, luma y: (Int, Int) -> UInt8) throws -> CVPixelBuffer {
    try makeNV12(width: width, height: height, luma: y) { _, _ in (cb, cr) }
}

/// An NV12 frame with per-pixel luma and per-chroma-texel (Cb, Cr), tagged like a decoded HD
/// stream (BT.709, left-sited chroma) unless `matrix`/`siting` say otherwise (nil = untagged).
func makeNV12(width: Int, height: Int, fullRange: Bool = false,
              matrix: CFString? = kCVImageBufferYCbCrMatrix_ITU_R_709_2,
              siting: CFString? = kCVImageBufferChromaLocation_Left,
              luma y: (Int, Int) -> UInt8, chroma: (Int, Int) -> (UInt8, UInt8)) throws -> CVPixelBuffer {
    let attrs: [CFString: Any] = [
        kCVPixelBufferMetalCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
    ]
    var out: CVPixelBuffer?
    let format = fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    let status = CVPixelBufferCreate(nil, width, height, format, attrs as CFDictionary, &out)
    let buffer = try #require(status == kCVReturnSuccess ? out : nil)
    if let matrix { CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate) }
    if let siting { CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, siting, .shouldPropagate) }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    for row in 0..<height {
        let line = luma + row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for x in 0..<width { line[x] = y(x, row) }
    }
    let chromaPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
    for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
        let line = chromaPlane + row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for x in 0..<CVPixelBufferGetWidthOfPlane(buffer, 1) {
            (line[2 * x], line[2 * x + 1]) = chroma(x, row)
        }
    }
    return buffer
}

// MARK: Encoding (VideoToolbox) → Annex-B, the format libchiaki delivers

struct EncodedFrame {
    let annexB: Data
    let keyframe: Bool
}

/// Encodes `count` synthetic frames (a moving gradient) and returns them as Annex-B access units,
/// with parameter sets in front of every keyframe.
func encodeFrames(codec: CMVideoCodecType, count: Int, width: Int = 320, height: Int = 240) throws -> [EncodedFrame] {
    var sessionOut: VTCompressionSession?
    let created = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: codec,
                                             encoderSpecification: nil, imageBufferAttributes: nil,
                                             compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                             compressionSessionOut: &sessionOut)
    let session = try #require(created == noErr ? sessionOut : nil)
    defer { VTCompressionSessionInvalidate(session) }
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber)

    var samples: [CMSampleBuffer] = []
    let lock = NSLock()
    for i in 0..<count {
        let frame = try makeNV12(width: width, height: height, y: UInt8(16 + (i * 20) % 200), cb: 100, cr: 150)
        let pts = CMTime(value: CMTimeValue(i), timescale: 30)
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: frame, presentationTimeStamp: pts,
                                                     duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
            guard status == noErr, let sample else { return }
            lock.withLock { samples.append(sample) }
        }
        #expect(status == noErr)
    }
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    return try lock.withLock { try samples.map { try annexB(from: $0, codec: codec) } }
}

private func annexB(from sample: CMSampleBuffer, codec: CMVideoCodecType) throws -> EncodedFrame {
    let startCode: [UInt8] = [0, 0, 0, 1]
    var out = Data()
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
    let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
        var count = 0
        if codec == kCMVideoCodecType_H264 {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
        } else {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
        }
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            if codec == kCMVideoCodecType_H264 {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                   parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                   nalUnitHeaderLengthOut: nil)
            } else {
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                   parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                   nalUnitHeaderLengthOut: nil)
            }
            let p = try #require(ptr)
            out.append(contentsOf: startCode)
            out.append(p, count: size)
        }
    }
    let block = try #require(CMSampleBufferGetDataBuffer(sample))
    var length = 0
    var base: UnsafeMutablePointer<CChar>?
    #expect(CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                        dataPointerOut: &base) == noErr)
    let bytes = UnsafeRawBufferPointer(start: try #require(base), count: length)
    var offset = 0
    while offset + 4 <= length {
        let nalLength = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian)
        out.append(contentsOf: startCode)
        out.append(contentsOf: bytes[(offset + 4)..<(offset + 4 + nalLength)])
        offset += 4 + nalLength
    }
    return EncodedFrame(annexB: out, keyframe: keyframe)
}

// MARK: Network stub for PSN

final class StubURLProtocol: URLProtocol {
    /// Returns (status, body) for a request, or nil to fail it with a network error.
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data)?)?

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let (status, body) = Self.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Answers the token exchange like Sony's endpoint does, for `userId`.
func psnStub(userId: String?) -> (URLRequest) -> (Int, Data)? {
    { request in
        if request.httpMethod == "POST" { return (200, Data(#"{"access_token":"tok123"}"#.utf8)) }
        if request.url?.lastPathComponent == "tok123" {
            return (200, Data((userId.map { #"{"user_id":"\#($0)"}"# } ?? "{}").utf8))
        }
        return nil
    }
}

/// Valid-looking credentials for a console at `address` (keys are well-formed but not real).
func fakeCredentials(address: String = "127.0.0.1", registKey: String = "0123abcd") -> ConsoleCredentials {
    var key = Data(registKey.utf8)
    key.append(Data(repeating: 0, count: max(0, 16 - key.count)))
    return ConsoleCredentials(address: address, ps5: true, nickname: "Test", mac: "00:11:22:33:44:55",
                              registKey: key.base64EncodedString(),
                              rpKey: Data(repeating: 7, count: 16).base64EncodedString(),
                              accountId: Data(repeating: 1, count: 8).base64EncodedString())
}

/// Polls `condition` until it holds or `timeout` elapses.
func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}
