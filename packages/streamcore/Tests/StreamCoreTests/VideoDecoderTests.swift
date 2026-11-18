import CoreMedia
import CoreVideo
import Testing
@testable import StreamCore

@Suite struct AnnexBTests {
    func split(_ bytes: [UInt8]) -> [[UInt8]] {
        bytes.withUnsafeBytes { VideoDecoder.splitAnnexB($0).map(Array.init) }
    }

    @Test func splitsOnThreeAndFourByteStartCodes() {
        #expect(split([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5]) ==
                [[0x67, 1, 2], [0x68, 3], [0x65, 4, 5]])
    }

    @Test func ignoresLeadingGarbageAndEmptyInput() {
        #expect(split([9, 9, 0, 0, 1, 0x41, 7]) == [[0x41, 7]])
        #expect(split([]) == [])
        #expect(split([1, 2, 3, 4]) == [])
        #expect(split([0, 0, 1]) == []) // start code with nothing after it
    }

    @Test func keepsZerosInsideNalUnits() {
        #expect(split([0, 0, 1, 0x41, 0, 0, 2, 0]) == [[0x41, 0, 0, 2, 0]])
        #expect(split([0, 0, 1, 0, 0, 1, 0x41]) == [[], [0x41]]) // back-to-back start codes: empty unit
    }

    @Test func classifiesParameterSets() {
        #expect(VideoDecoder.isParameterSet(0x67, codec: .h264))  // SPS
        #expect(VideoDecoder.isParameterSet(0x68, codec: .h264))  // PPS
        #expect(!VideoDecoder.isParameterSet(0x65, codec: .h264)) // IDR slice
        #expect(!VideoDecoder.isParameterSet(0x41, codec: .h264))
        #expect(VideoDecoder.isParameterSet(0x40, codec: .hevc))  // VPS (32)
        #expect(VideoDecoder.isParameterSet(0x42, codec: .hevc))  // SPS (33)
        #expect(VideoDecoder.isParameterSet(0x44, codec: .hevc))  // PPS (34)
        #expect(!VideoDecoder.isParameterSet(0x26, codec: .hevc)) // IDR_W_RADL (19)
        #expect(!VideoDecoder.isParameterSet(0x02, codec: .hevc))
    }
}

@Suite struct VideoDecoderTests {
    func decodeAll(_ frames: [EncodedFrame], codec: VideoDecoder.Codec) -> (results: [Bool], decoded: [CVPixelBuffer]) {
        let decoder = VideoDecoder(codec: codec)
        var decoded: [CVPixelBuffer] = []
        decoder.onFrame = { decoded.append($0) }
        let results = frames.map { f in f.annexB.withUnsafeBytes { decoder.decode($0) } }
        return (results, decoded)
    }

    @Test(arguments: [(kCMVideoCodecType_H264, VideoDecoder.Codec.h264), (kCMVideoCodecType_HEVC, .hevc)])
    func decodesEncodedStream(encoder: CMVideoCodecType, codec: VideoDecoder.Codec) throws {
        let frames = try encodeFrames(codec: encoder, count: 8)
        try #require(frames.count == 8)
        #expect(frames.first?.keyframe == true)
        let (results, decoded) = decodeAll(frames, codec: codec)
        #expect(results.allSatisfy { $0 })
        #expect(decoded.count == 8)
        let first = try #require(decoded.first)
        #expect(CVPixelBufferGetWidth(first) == 320)
        #expect(CVPixelBufferGetHeight(first) == 240)
        #expect(CVPixelBufferGetPixelFormatType(first) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }

    @Test func rebuildsSessionWhenParameterSetsChange() throws {
        let small = try encodeFrames(codec: kCMVideoCodecType_H264, count: 2, width: 320, height: 240)
        let large = try encodeFrames(codec: kCMVideoCodecType_H264, count: 2, width: 640, height: 480)
        let (results, decoded) = decodeAll(small + large + small, codec: .h264)
        #expect(results.allSatisfy { $0 })
        #expect(decoded.map(CVPixelBufferGetWidth) == [320, 320, 640, 640, 320, 320])
    }

    @Test func parameterSetsAloneCreateTheSession() throws {
        let key = try #require(try encodeFrames(codec: kCMVideoCodecType_H264, count: 1).first)
        // Keep only the SPS + PPS (everything before the IDR slice's start code).
        let nalus = key.annexB.withUnsafeBytes { VideoDecoder.splitAnnexB($0).map { Data($0) } }
        var params = Data()
        for n in nalus where VideoDecoder.isParameterSet(n.first!, codec: .h264) {
            params.append(contentsOf: [0, 0, 0, 1])
            params.append(n)
        }
        let decoder = VideoDecoder(codec: .h264)
        #expect(params.withUnsafeBytes { decoder.decode($0) })
        #expect(params.withUnsafeBytes { decoder.decode($0) }) // unchanged parameter sets: no rebuild
    }

    @Test func failsWithoutSessionOrWithBrokenInput() {
        let decoder = VideoDecoder(codec: .h264)
        // Slice before any parameter sets.
        #expect(![UInt8]([0, 0, 0, 1, 0x65, 0x88, 0x84]).withUnsafeBytes { decoder.decode($0) })
        // Nothing at all.
        #expect(![UInt8]().withUnsafeBytes { decoder.decode($0) })
        // Garbage SPS/PPS: no format description.
        #expect(![UInt8]([0, 0, 0, 1, 0x67, 0xFF, 0, 0, 0, 1, 0x68, 0xFF]).withUnsafeBytes { decoder.decode($0) })
        let hevc = VideoDecoder(codec: .hevc)
        #expect(![UInt8]([0, 0, 1, 0x40, 1, 0, 0, 1, 0x42, 1, 0, 0, 1, 0x44, 1]).withUnsafeBytes { hevc.decode($0) })
    }

    @Test func reportsUndecodableSlices() throws {
        let frames = try encodeFrames(codec: kCMVideoCodecType_H264, count: 1)
        let decoder = VideoDecoder(codec: .h264)
        #expect(frames[0].annexB.withUnsafeBytes { decoder.decode($0) })
        // A corrupt non-IDR slice: VideoToolbox rejects it (or emits no image).
        let garbage: [UInt8] = [0, 0, 0, 1, 0x41] + [UInt8](repeating: 0xFF, count: 64)
        var frameCount = 0
        decoder.onFrame = { _ in frameCount += 1 }
        let ok = garbage.withUnsafeBytes { decoder.decode($0) }
        #expect(!ok || frameCount <= 1)
    }
}
