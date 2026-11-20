import CoreMedia
import CoreVideo
import Metal
import VideoToolbox

/// How a frame goes through Apple's model: in tiles of one size, side by side. The model only takes sides up
/// to 1280 px that are multiples of 16 (it reports others as supported, then fails on them), so a 1080p
/// frame is cut into two overlapping halves and 1080 or 540 rows are padded to 1088 or 544.
struct MLTiling: Equatable {
    struct Tile: Equatable {
        /// Where the tile starts in the frame.
        let x: Int
        /// The frame columns this tile's output covers: its middle. The overlap either side only gives the
        /// model context, so no seam shows where two tiles meet.
        let keep: Range<Int>
    }

    let width: Int
    let height: Int
    let tiles: [Tile]

    /// Whether the frame goes to the model as is: a single tile of the frame's own size.
    func isWholeFrame(width w: Int, height h: Int) -> Bool { tiles.count == 1 && width == w && height == h }
}

/// Apple's low-latency ML super-resolution (VideoToolbox, macOS 26+), run on the decoded NV12 frame
/// before the rest of the pipeline. 1.5× (and 2× for small frames); 1080p and 540p go through `MLTiling`.
final class MLSuperResolution {
    /// The largest side the model takes. macOS 27 reports the same cap:
    /// `maximumDimension(forSpatialScaleFactor: 1.5)` is 1280 and the pixel cap is 1,638,400.
    /// 1920×1080 lists no scale factor, so a whole 1080p frame cannot go through.
    static let maxInputSide = 1280
    /// Columns of context each tile gets beyond the part of it that's kept.
    static let overlap = 64

    /// Whether this OS and Mac can run it at all.
    static var isAvailable: Bool {
        // Not in a virtual machine: VideoToolbox reports it supported there, but it never runs.
        if #available(macOS 26.0, iOS 26.0, *) {
            return !isVirtualMachine && VTLowLatencySuperResolutionScalerConfiguration.isSupported
        }
        return false
    }

    /// The tiles for a `width`×`height` frame; nil when it can't go through the model (its width isn't a
    /// multiple of 16, or it's taller than the model's limit).
    static func tiling(width w: Int, height h: Int) -> MLTiling? {
        let th = (h + 15) / 16 * 16
        guard w > 0, h > 0, w % 16 == 0, th <= maxInputSide, th - h <= h else { return nil }
        if w <= maxInputSide { return MLTiling(width: w, height: th, tiles: [.init(x: 0, keep: 0..<w)]) }
        let span = maxInputSide - 2 * overlap
        let n = (w + span - 1) / span
        let tw = ((w + n - 1) / n + 2 * overlap + 15) / 16 * 16
        guard tw <= maxInputSide else { return nil }
        // Cuts on multiples of 4, so they land on whole pixels in the 1.5× output's luma and chroma.
        let cuts = (0...n).map { $0 == n ? w : w * $0 / n / 4 * 4 }
        let tiles = (0..<n).map { i in
            MLTiling.Tile(x: min(max(cuts[i] - overlap, 0), w - tw) / 4 * 4, keep: cuts[i]..<cuts[i + 1])
        }
        return MLTiling(width: tw, height: th, tiles: tiles)
    }

    /// Whether `factor` turns a `width`×`height` frame into whole, even sizes (NV12 needs both).
    static func evenOutput(factor: Float, width: Int, height: Int) -> Bool {
        [width, height].allSatisfy { side in
            let scaled = Float(side) * factor
            return scaled == scaled.rounded() && Int(scaled) % 2 == 0
        }
    }

    /// The scale factor to use: the largest supported one that doesn't overshoot the screen (the rest of
    /// the upscale is MetalFX's job), else the smallest supported one; nil when there's none.
    static func scaleFactor(supported: [Float], width: Int, height: Int, target: CGSize) -> Float? {
        let fitting = supported.filter { Double(Float(width) * $0) <= target.width && Double(Float(height) * $0) <= target.height }
        return fitting.max() ?? (target.width > Double(width) ? supported.min() : nil)
    }

    private var sessions: [GuardedProcessor] = [] // one per tile
    private var key: (width: Int, height: Int, factor: Float)?
    /// The model's outputs; tiles cut from the frame; the tiles' outputs put back together.
    private var pool: CVPixelBufferPool?
    private var tilePool: CVPixelBufferPool?
    private var outputPool: CVPixelBufferPool?
    private var textureCache: CVMetalTextureCache?
    /// Cuts the tiles out and puts them back together (frames that go through whole need no Metal work).
    private var commandQueue: MTLCommandQueue?
    private var unsupported: Set<String> = []
    /// Sizes (with factor) that were upscaled in this run, and fresh processors' errors at ones that never were.
    private var sizes = ProcessorSizes()
    private var timestamp: Int64 = 0
    private let device: MTLDevice?
    private let health: VideoProcessorHealth
    private let available: Bool
    private let makeProcessor: () -> VideoProcessing?

    /// `available` and `makeProcessor`: VideoToolbox in the app, stand-ins in tests.
    init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), health: VideoProcessorHealth = .upscaling,
         available: Bool = MLSuperResolution.isAvailable, makeProcessor: @escaping () -> VideoProcessing? = makeVTProcessor) {
        self.device = device
        self.health = health
        self.available = available
        self.makeProcessor = makeProcessor
    }

    deinit { end() }

    /// Whether the model refused frames of this size before (it never runs on them).
    func refuses(width: Int, height: Int) -> Bool { unsupported.contains("\(width)x\(height)") }

    /// Whether it's off for the rest of the run: its video processor kept failing.
    var hasFailed: Bool { health.isOff }

    /// `frame` upscaled into a new NV12 buffer, made by the time it returns; nil when it can't run for this frame
    /// size and screen, or the processor failed on it (the caller then uses `frame` as is; a fresh processor
    /// starts with the next frame).
    func upscale(_ frame: CVPixelBuffer, target: CGSize) -> CVPixelBuffer? {
        guard #available(macOS 26.0, iOS 26.0, *), available,
              CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return nil }
        guard !health.isOff else { end(); return nil }
        typealias Config = VTLowLatencySuperResolutionScalerConfiguration
        let w = CVPixelBufferGetWidth(frame), h = CVPixelBufferGetHeight(frame)
        let sizeKey = "\(w)x\(h)"
        guard !unsupported.contains(sizeKey) else { return nil }
        let tiling = Self.tiling(width: w, height: h)
        let supported = tiling.map {
            Config.__supportedScaleFactors(forFrameWidth: $0.width, frameHeight: $0.height).map(\.floatValue)
                .filter { Self.evenOutput(factor: $0, width: w, height: h) }
        } ?? []
        guard let tiling, !supported.isEmpty else {
            unsupported.insert(sizeKey) // the model can't take this size at all
            Log.info(.renderer, "ML upscaling doesn't support \(sizeKey) streams; using the rest of the pipeline")
            return nil
        }
        // No factor for the current window (e.g. too small to need upscaling): skip, but try again later.
        guard let factor = Self.scaleFactor(supported: supported, width: w, height: h, target: target) else { return nil }
        if key?.width != w || key?.height != h || key?.factor != factor {
            end()
            let proven = sizes.hasWorked(Self.configKey(w, h, factor))
            switch start(tiling, factor: factor, frame: frame, proven: proven) {
            case .done:
                break
            case .threw, .notCalled:
                end() // quarantined and counted, or off: fresh processors for the next frame
                return nil
            case .failed(let reason):
                end()
                if proven {
                    // It ran at this size before: a fault, counted, and tried again with the next frame.
                    health.failed("start at \(sizeKey): \(reason)")
                } else {
                    unsupported.insert(sizeKey)
                    Log.warning(.renderer, "ML upscaling couldn't start for \(sizeKey) streams")
                }
                return nil
            }
            Log.info(.renderer, "ML upscaling \(sizeKey) ×\(factor)"
                + (tiling.isWholeFrame(width: w, height: h) ? "" : " in \(tiling.tiles.count) \(tiling.width)x\(tiling.height) tiles"))
            key = (w, h, factor)
        }
        timestamp += 1
        let pts = CMTime(value: timestamp, timescale: 60)
        let output = tiling.isWholeFrame(width: w, height: h)
            ? process([frame], pts: pts)?.first
            : upscaleTiles(frame, tiling: tiling, factor: factor, pts: pts)
        // Keep the colorimetry so the NV12 conversion still reads the stream's matrix and siting.
        if let output { CVBufferPropagateAttachments(frame, output) }
        return output
    }

    /// A processor per tile, started; `.threw` when one raised an exception, `.failed` when this can't run.
    @available(macOS 26.0, iOS 26.0, *)
    private func start(_ tiling: MLTiling, factor: Float, frame: CVPixelBuffer, proven: Bool) -> ProcessorOutcome {
        let config = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: tiling.width, frameHeight: tiling.height,
                                                                    scaleFactor: factor)
        for _ in tiling.tiles {
            guard let made = makeProcessor() else { return .failed("no processor") }
            let processor = GuardedProcessor(made, health: health, proven: proven)
            let outcome = processor.start(config)
            guard outcome == .done else { return outcome }
            sessions.append(processor)
        }
        var attrs = config.destinationPixelBufferAttributes
        attrs[kCVPixelBufferMetalCompatibilityKey as String] = true
        pool = Self.makePool(attrs)
        guard pool != nil else { return .failed("no buffer pool") }
        let w = CVPixelBufferGetWidth(frame), h = CVPixelBufferGetHeight(frame)
        if tiling.isWholeFrame(width: w, height: h) { return .done }
        let format = CVPixelBufferGetPixelFormatType(frame)
        tilePool = Self.makePool(Self.nv12Attributes(format, tiling.width, tiling.height))
        outputPool = Self.makePool(Self.nv12Attributes(format, Int(Float(w) * factor), Int(Float(h) * factor)))
        if textureCache == nil, let device {
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
            textureCache = cache
        }
        if commandQueue == nil { commandQueue = device?.makeCommandQueue() }
        return tilePool != nil && outputPool != nil && textureCache != nil && commandQueue != nil ? .done : .failed("no Metal")
    }

    /// Runs the model on `sources` (a tile each, or the whole frame) into new buffers from `pool`, one after the other
    /// (side by side measured no faster: 8.3 ms a 1080p frame either way). When a processor fails, every tile's session
    /// is retired, so the next frame starts fresh ones (or, when fresh ones keep erring at a size that never worked, the
    /// frame's size isn't asked for again: see `ProcessorSizes`).
    private func process(_ sources: [CVPixelBuffer], pts: CMTime) -> [CVPixelBuffer]? {
        guard #available(macOS 26.0, iOS 26.0, *), sources.count == sessions.count, let key, let pool else { return nil }
        var outputs: [CVPixelBuffer] = []
        var parameters: [VTLowLatencySuperResolutionScalerParameters] = []
        for source in sources {
            guard let output = Self.buffer(from: pool),
                  let from = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: pts),
                  let to = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: pts) else { return nil }
            outputs.append(output)
            parameters.append(VTLowLatencySuperResolutionScalerParameters(sourceFrame: from, destinationFrame: to))
        }
        let config = Self.configKey(key.width, key.height, key.factor)
        for (session, parameters) in zip(sessions, parameters) {
            switch session.process(parameters) {
            case .done:
                continue
            case .refused:
                if sizes.refuses(config) {
                    unsupported.insert("\(key.width)x\(key.height)")
                    Log.warning(.renderer, "ML upscaling can't run on \(key.width)x\(key.height) streams; using the rest of the pipeline")
                } else {
                    Log.warning(.renderer, "ML upscaling's first frame at \(key.width)x\(key.height) failed; trying fresh sessions")
                }
            case .failed:
                Log.error(.renderer, "ML upscaling failed; starting its sessions over")
            }
            end()
            return nil
        }
        sizes.worked(config)
        return outputs
    }

    private static func configKey(_ width: Int, _ height: Int, _ factor: Float) -> String { "\(width)x\(height)x\(factor)" }

    /// Cuts `frame` into tiles (bottom rows repeated to pad it), runs the model on each, and copies the middle of
    /// each tile's output into one buffer. The cut is finished before the model reads the tiles, and the copies
    /// before this returns.
    private func upscaleTiles(_ frame: CVPixelBuffer, tiling: MLTiling, factor: Float, pts: CMTime) -> CVPixelBuffer? {
        let h = CVPixelBufferGetHeight(frame)
        let pad = tiling.height - h
        guard let tilePool, let outputPool, let commandQueue, let output = Self.buffer(from: outputPool),
              let frameTex = planes(frame), let outputTex = planes(output) else { return nil }
        var sources: [CVPixelBuffer] = []
        var textures = [frameTex, outputTex]
        // The CoreVideo textures stay alive until the GPU is done with them: every command buffer is waited for here.
        defer { withExtendedLifetime(textures) {} }
        guard let cut = commandQueue.makeCommandBuffer(), let blit = cut.makeBlitCommandEncoder() else { return nil }
        for tile in tiling.tiles {
            guard let source = Self.buffer(from: tilePool), let tex = planes(source) else { blit.endEncoding(); return nil }
            Self.copy(blit, frameTex, x: tile.x, y: 0, width: tiling.width, height: h, to: tex, x: 0, y: 0)
            if pad > 0 { Self.copy(blit, frameTex, x: tile.x, y: h - pad, width: tiling.width, height: pad, to: tex, x: 0, y: h) }
            sources.append(source)
            textures.append(tex)
        }
        blit.endEncoding()
        cut.commit()
        cut.waitUntilCompleted()
        guard cut.status == .completed else { return nil }
        guard let results = process(sources, pts: pts), let join = commandQueue.makeCommandBuffer(), let blit = join.makeBlitCommandEncoder() else { return nil }
        for (tile, result) in zip(tiling.tiles, results) {
            guard let tex = planes(result) else { blit.endEncoding(); return nil }
            Self.copy(blit, tex, x: Int(Float(tile.keep.lowerBound - tile.x) * factor), y: 0,
                      width: Int(Float(tile.keep.count) * factor), height: Int(Float(h) * factor),
                      to: outputTex, x: Int(Float(tile.keep.lowerBound) * factor), y: 0)
            textures.append(tex)
        }
        blit.endEncoding()
        join.commit()
        join.waitUntilCompleted()
        return join.status == .completed ? output : nil
    }

    private func planes(_ buffer: CVPixelBuffer) -> [CVMetalTexture]? {
        textureCache.flatMap { Self.planes(buffer, cache: $0) }
    }

    /// The luma and chroma planes of an 8-bit NV12 buffer as Metal textures.
    static func planes(_ buffer: CVPixelBuffer, cache textureCache: CVMetalTextureCache) -> [CVMetalTexture]? {
        let planes = [(MTLPixelFormat.r8Unorm, 0), (.rg8Unorm, 1)].compactMap { format, plane -> CVMetalTexture? in
            var tex: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                nil, textureCache, buffer, nil, format,
                CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &tex)
            return status == kCVReturnSuccess ? tex : nil
        }
        return planes.count == 2 ? planes : nil
    }

    /// Copies a `width`×`height` luma region (and the matching chroma) between NV12 plane textures.
    static func copy(_ blit: MTLBlitCommandEncoder, _ from: [CVMetalTexture], x: Int, y: Int, width: Int, height: Int,
                             to: [CVMetalTexture], x toX: Int, y toY: Int) {
        for plane in 0..<2 {
            let d = plane == 0 ? 1 : 2
            guard let src = CVMetalTextureGetTexture(from[plane]), let dst = CVMetalTextureGetTexture(to[plane]) else { continue }
            blit.copy(from: src, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x / d, y: y / d, z: 0),
                      sourceSize: MTLSize(width: width / d, height: height / d, depth: 1),
                      to: dst, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: toX / d, y: toY / d, z: 0))
        }
    }

    static func nv12Attributes(_ format: OSType, _ width: Int, _ height: Int) -> [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: format, kCVPixelBufferWidthKey as String: width,
         kCVPixelBufferHeightKey as String: height, kCVPixelBufferMetalCompatibilityKey as String: true,
         kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
    }

    static func makePool(_ attrs: [String: Any]) -> CVPixelBufferPool? {
        var pool: CVPixelBufferPool?
        return CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess ? pool : nil
    }

    static func buffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        return CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess ? buffer : nil
    }

    /// Retires every tile's session: their processors are ended later, off this queue (see `GuardedProcessor.retire`).
    private func end() {
        sessions.forEach { $0.retire() }
        sessions = []
        pool = nil
        tilePool = nil
        outputPool = nil
        key = nil
    }
}
