import AVFoundation
import CoreVideo
import Foundation
import Metal
import StreamCore

// psrp interpolate <in.mov> [--out out.mov] [--frames N]
// A bench for frame interpolation without a console: reads a video's frames as the decoder hands them over
// (NV12 IOSurfaces), makes the frame halfway between each pair with StreamCore's interpolator, times
// every one (wall clock and GPU), and writes real, in-between, real… at twice the frame rate to look at.

func interpolate(_ args: Args) throws {
    guard let input = args.positional.first else { throw fail("usage: psrp interpolate <in.mov> [--out out.mov] [--frames N]") }
    guard FrameInterpolator.isAvailable else { throw fail("Frame interpolation isn't available on this Mac or macOS") }
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw fail("no Metal device") }
    let limit = Int(args["frames"] ?? "") ?? .max

    let asset = AVURLAsset(url: URL(fileURLWithPath: input))
    let track = try blocking { try await asset.loadTracks(withMediaType: .video).first }
    guard let track else { throw fail("\(input) has no video") }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ])
    reader.add(output)
    guard reader.startReading() else { throw fail("can't read \(input): \(reader.error?.localizedDescription ?? "?")") }

    var writer: BenchWriter?
    if let out = args["out"] { writer = try BenchWriter(url: URL(fileURLWithPath: out)) }

    let interpolator = FrameInterpolator()
    var previous: CVPixelBuffer?
    var wall: [Double] = [], gpu: [Double] = [], misses = 0, pairs = 0, index = 0
    while index < limit, let sample = output.copyNextSampleBuffer(), let frame = CMSampleBufferGetImageBuffer(sample) {
        defer { previous = frame; index += 1 }
        guard let previous else { writer?.append(frame, at: 0); continue }
        guard let cb = queue.makeCommandBuffer() else { throw fail("no command buffer") }
        let start = DispatchTime.now().uptimeNanoseconds
        let middle = interpolator.encode(cb, previous: previous, current: frame)
        cb.commit()
        cb.waitUntilCompleted()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        pairs += 1
        guard let middle else { misses += 1; writer?.append(frame, at: 2 * index); continue }
        wall.append(ms)
        gpu.append((cb.gpuEndTime - cb.gpuStartTime) * 1000)
        writer?.append(middle, at: 2 * index - 1)
        writer?.append(frame, at: 2 * index)
    }
    writer?.finish()

    func stats(_ v: [Double]) -> String {
        guard !v.isEmpty else { return "—" }
        let s = v.sorted()
        func pct(_ p: Double) -> Double { s[min(s.count - 1, Int(Double(s.count - 1) * p))] }
        return String(format: "mean %.1f ms · p50 %.1f · p95 %.1f · max %.1f", s.reduce(0, +) / Double(s.count), pct(0.5), pct(0.95), s.last ?? 0)
    }
    let w = CVPixelBufferGetWidth(previous!), h = CVPixelBufferGetHeight(previous!)
    print("frames: \(index) (\(w)x\(h)); in-between frames made: \(wall.count) of \(pairs)\(misses > 0 ? " (\(misses) refused)" : "")")
    print("wall per in-between frame: \(stats(wall))")
    print("GPU per in-between frame:  \(stats(gpu))")
    let over = wall.filter { $0 > 1000.0 / 60 }.count
    print(String(format: "over one 60 Hz refresh (16.7 ms): %d of %d (%.0f%%)", over, wall.count, 100 * Double(over) / Double(max(wall.count, 1))))
    if let out = args["out"] { print("wrote \(out) at twice the input frame rate") }
}

/// Writes NV12 frames as HEVC at 60 fps (frame `i` at i/60 s).
final class BenchWriter {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor

    init(url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 40_000_000],
        ])
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ frame: CVPixelBuffer, at index: Int) {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        adaptor.append(frame, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 60))
    }

    func finish() {
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
    }
}
