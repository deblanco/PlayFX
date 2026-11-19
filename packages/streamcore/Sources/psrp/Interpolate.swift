import AVFoundation
import CoreVideo
import Foundation
import Metal
import StreamCore
import VideoToolbox

// psrp interpolate <in.mov> [--engine vt|metalfx-flow|metalfx-estimate|metalfx-zero] [--truth] [--out out.mov]
//                  [--frames N] [--flow-scale 0.5]
// A bench for frame interpolation without a console. Reads a video's frames as the decoder hands them over
// (NV12 IOSurfaces) and makes the image halfway between each pair, timing every one (wall clock and GPU).
// --out writes real, in-between, real… at twice the frame rate to look at.
// --truth measures quality instead: every other frame is dropped, each dropped frame is predicted from its
// neighbours, and the prediction is compared with the real one (PSNR over RGB), next to two baselines:
// repeating the previous frame, and a plain cross-fade. See docs/FRAME_INTERPOLATION.md.

/// One way to make the in-between image of the frames given so far.
private protocol Engine: AnyObject {
    var name: String { get }
    /// The image halfway between `previous` and `current`, as BGRA, encoded into `cb`; nil for none.
    func middle(_ cb: MTLCommandBuffer, previous: CVPixelBuffer, current: CVPixelBuffer) -> CVPixelBuffer?
    /// Turns what `middle` returned into BGRA once the command buffer has completed.
    func finish(_ image: CVPixelBuffer) -> CVPixelBuffer?
}

private final class VideoToolboxEngine: Engine {
    let name = "VideoToolbox low-latency frame interpolation (Neural Engine)"
    let interpolator = FrameInterpolator()
    let toBGRA: (CVPixelBuffer) -> CVPixelBuffer?
    init(toBGRA: @escaping (CVPixelBuffer) -> CVPixelBuffer?) { self.toBGRA = toBGRA }
    func middle(_ cb: MTLCommandBuffer, previous: CVPixelBuffer, current: CVPixelBuffer) -> CVPixelBuffer? {
        interpolator.encode(cb, previous: previous, current: current)
    }
    func finish(_ image: CVPixelBuffer) -> CVPixelBuffer? { toBGRA(image) }
}

@available(macOS 26.0, *)
private final class MetalFXEngine: Engine {
    let bench: MetalFXInterpolatorBench
    var name: String { bench.description }
    init(_ bench: MetalFXInterpolatorBench) { self.bench = bench }
    func middle(_ cb: MTLCommandBuffer, previous: CVPixelBuffer, current: CVPixelBuffer) -> CVPixelBuffer? {
        // The MetalFX bench keeps its own previous frame: prime it with `previous` the first time.
        guard let result = bench.buffer(kCVPixelFormatType_32BGRA, bench.width, bench.height) else { return nil }
        return bench.encode(cb, current, into: result) ? result : nil
    }
    func finish(_ image: CVPixelBuffer) -> CVPixelBuffer? { image }
}

func interpolate(_ args: Args) throws {
    guard let input = args.positional.first else {
        throw fail("usage: psrp interpolate <in.mov> [--engine vt|metalfx-flow|metalfx-estimate|metalfx-zero] [--truth] [--out out.mov] [--frames N]")
    }
    guard FrameInterpolator.isAvailable else { throw fail("Frame interpolation isn't available on this Mac or macOS") }
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw fail("no Metal device") }
    let limit = Int(args["frames"] ?? "") ?? .max
    let truth = args.has("truth")

    let asset = AVURLAsset(url: URL(fileURLWithPath: input))
    let track = try blocking { try await asset.loadTracks(withMediaType: .video).first }
    guard let track else { throw fail("\(input) has no video") }
    let size = try blocking { try await track.load(.naturalSize) }
    let width = Int(size.width), height = Int(size.height)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ])
    reader.add(output)
    guard reader.startReading() else { throw fail("can't read \(input): \(reader.error?.localizedDescription ?? "?")") }

    var transfer: VTPixelTransferSession?
    VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
    func toBGRA(_ frame: CVPixelBuffer) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &out)
        guard let transfer, let out, VTPixelTransferSessionTransferImage(transfer, from: frame, to: out) == noErr else { return nil }
        return out
    }

    let engineName = args["engine"] ?? "vt"
    let engine: Engine
    if engineName == "vt" {
        engine = VideoToolboxEngine(toBGRA: toBGRA)
    } else {
        guard #available(macOS 26.0, *) else { throw fail("MetalFX frame interpolation needs macOS 26") }
        let motionName = engineName.replacingOccurrences(of: "metalfx-", with: "").replacingOccurrences(of: "metalfx", with: "flow")
        guard let motion = MetalFXInterpolatorBench.Motion(rawValue: motionName),
              let made = MetalFXInterpolatorBench(device: device, width: width, height: height, motion: motion,
                                                  flowScale: Double(args["flow-scale"] ?? "") ?? 0.5) else {
            throw fail("engine must be vt, metalfx-flow, metalfx-estimate or metalfx-zero (and supported here)")
        }
        engine = MetalFXEngine(made)
    }
    print("engine: \(engine.name)\(truth ? " — quality against the real frames (every other frame dropped)" : "")")

    var writer: BenchWriter?
    if let out = args["out"] { writer = try BenchWriter(url: URL(fileURLWithPath: out)) }

    var wall: [Double] = [], gpu: [Double] = []
    var scores: (engine: [Double], repeat: [Double], blend: [Double]) = ([], [], [])
    var previous: CVPixelBuffer?, held: CVPixelBuffer?
    var index = 0, pairs = 0, refused = 0
    while index < limit, let sample = output.copyNextSampleBuffer(), let frame = CMSampleBufferGetImageBuffer(sample) {
        defer { index += 1 }
        // In truth mode the odd frames are held back as the answers; the engine sees only the even ones.
        if truth, index % 2 == 1 { held = frame; continue }
        defer { previous = frame }
        guard let previous else {
            if !truth { writer?.append(frame, at: 0) }
            _ = engine.middle(queue.makeCommandBuffer()!, previous: frame, current: frame) // primes engines with history
            continue
        }
        guard let cb = queue.makeCommandBuffer() else { throw fail("no command buffer") }
        let start = DispatchTime.now().uptimeNanoseconds
        let made = engine.middle(cb, previous: previous, current: frame)
        cb.commit()
        cb.waitUntilCompleted()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        pairs += 1
        guard let made, let image = engine.finish(made) else { refused += 1; continue }
        wall.append(ms)
        gpu.append((cb.gpuEndTime - cb.gpuStartTime) * 1000)
        if truth, let held, let real = toBGRA(held), let a = toBGRA(previous), let b = toBGRA(frame) {
            scores.engine.append(psnr(image, real))
            scores.repeat.append(psnr(a, real))
            scores.blend.append(psnr(average(a, b), real))
        } else if !truth {
            writer?.append(made, at: 2 * index - 1)
            writer?.append(frame, at: 2 * index)
        }
    }
    writer?.finish()

    print("frames: \(index) (\(width)x\(height)); in-between images made: \(wall.count) of \(pairs)\(refused > 0 ? " (\(refused) refused)" : "")")
    print("wall per in-between image: \(stats(wall))")
    print("GPU per in-between image:  \(stats(gpu))")
    if truth {
        func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(max(v.count, 1)) }
        print(String(format: "PSNR against the real frame: engine %.2f dB · repeat previous %.2f dB · cross-fade %.2f dB",
                     mean(scores.engine), mean(scores.repeat), mean(scores.blend)))
    } else {
        let over = wall.filter { $0 > 1000.0 / 60 }.count
        print(String(format: "over one 60 Hz refresh (16.7 ms): %d of %d (%.0f%%)", over, wall.count, 100 * Double(over) / Double(max(wall.count, 1))))
        if let out = args["out"] { print("wrote \(out) at twice the input frame rate") }
    }
}

private func stats(_ v: [Double]) -> String {
    guard !v.isEmpty else { return "—" }
    let s = v.sorted()
    func pct(_ p: Double) -> Double { s[min(s.count - 1, Int(Double(s.count - 1) * p))] }
    return String(format: "mean %.1f ms · p50 %.1f · p95 %.1f · max %.1f", s.reduce(0, +) / Double(s.count), pct(0.5), pct(0.95), s.last ?? 0)
}

/// PSNR (dB) of two BGRA images of the same size, over the colour channels.
private func psnr(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
    CVPixelBufferLockBaseAddress(a, .readOnly)
    CVPixelBufferLockBaseAddress(b, .readOnly)
    defer {
        CVPixelBufferUnlockBaseAddress(a, .readOnly)
        CVPixelBufferUnlockBaseAddress(b, .readOnly)
    }
    guard let pa = CVPixelBufferGetBaseAddress(a)?.assumingMemoryBound(to: UInt8.self),
          let pb = CVPixelBufferGetBaseAddress(b)?.assumingMemoryBound(to: UInt8.self) else { return 0 }
    let ra = CVPixelBufferGetBytesPerRow(a), rb = CVPixelBufferGetBytesPerRow(b)
    let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
    var sum = 0.0
    for y in 0..<h {
        for x in 0..<w {
            for c in 0..<3 {
                let d = Double(pa[y * ra + x * 4 + c]) - Double(pb[y * rb + x * 4 + c])
                sum += d * d
            }
        }
    }
    let mse = sum / Double(w * h * 3)
    return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
}

/// The plain cross-fade of two BGRA images.
private func average(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> CVPixelBuffer {
    var out: CVPixelBuffer?
    CVPixelBufferCreate(nil, CVPixelBufferGetWidth(a), CVPixelBufferGetHeight(a), kCVPixelFormatType_32BGRA, nil, &out)
    guard let out else { return a }
    CVPixelBufferLockBaseAddress(a, .readOnly)
    CVPixelBufferLockBaseAddress(b, .readOnly)
    CVPixelBufferLockBaseAddress(out, [])
    defer {
        CVPixelBufferUnlockBaseAddress(out, [])
        CVPixelBufferUnlockBaseAddress(b, .readOnly)
        CVPixelBufferUnlockBaseAddress(a, .readOnly)
    }
    if let pa = CVPixelBufferGetBaseAddress(a)?.assumingMemoryBound(to: UInt8.self),
       let pb = CVPixelBufferGetBaseAddress(b)?.assumingMemoryBound(to: UInt8.self),
       let po = CVPixelBufferGetBaseAddress(out)?.assumingMemoryBound(to: UInt8.self) {
        let ra = CVPixelBufferGetBytesPerRow(a), rb = CVPixelBufferGetBytesPerRow(b), ro = CVPixelBufferGetBytesPerRow(out)
        for y in 0..<CVPixelBufferGetHeight(a) {
            for x in 0..<(CVPixelBufferGetWidth(a) * 4) {
                po[y * ro + x] = UInt8((Int(pa[y * ra + x]) + Int(pb[y * rb + x])) / 2)
            }
        }
    }
    return out
}

/// Writes frames as HEVC at 60 fps (frame `i` at i/60 s).
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
