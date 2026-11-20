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
    /// The largest side the model takes.
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

    private var sessions: [AnyObject] = [] // a VTFrameProcessor per tile on macOS 26+
    private var key: (width: Int, height: Int, factor: Float)?
    /// The model's outputs; tiles cut from the frame; the tiles' outputs put back together.
    private var pool: CVPixelBufferPool?
    private var tilePool: CVPixelBufferPool?
    private var outputPool: CVPixelBufferPool?
    private var textureCache: CVMetalTextureCache?
    private var unsupported: Set<String> = []
    private var timestamp: Int64 = 0

    deinit { end() }

    /// Whether the model refused frames of this size before (it never runs on them).
    func refuses(width: Int, height: Int) -> Bool { unsupported.contains("\(width)x\(height)") }

    /// Encodes `frame` upscaled into a new NV12 buffer in `cb`; nil when it can't run for this frame
    /// size and screen (the caller then uses `frame` as is).
    func encode(_ cb: MTLCommandBuffer, _ frame: CVPixelBuffer, target: CGSize) -> CVPixelBuffer? {
        guard #available(macOS 26.0, iOS 26.0, *), Self.isAvailable,
              CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return nil }
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
            guard start(tiling, factor: factor, frame: frame, device: cb.device) else {
                end()
                unsupported.insert(sizeKey)
                Log.warning(.renderer, "ML upscaling couldn't start for \(sizeKey) streams")
                return nil
            }
            Log.info(.renderer, "ML upscaling \(sizeKey) ×\(factor)"
                + (tiling.isWholeFrame(width: w, height: h) ? "" : " in \(tiling.tiles.count) \(tiling.width)x\(tiling.height) tiles"))
            key = (w, h, factor)
        }
        timestamp += 1
        let pts = CMTime(value: timestamp, timescale: 60)
        let output = tiling.isWholeFrame(width: w, height: h)
            ? process(cb, frame, session: 0, pts: pts)
            : encodeTiles(cb, frame, tiling: tiling, factor: factor, pts: pts)
        // Keep the colorimetry so the NV12 conversion still reads the stream's matrix and siting.
        if let output { CVBufferPropagateAttachments(frame, output) }
        return output
    }

    @available(macOS 26.0, iOS 26.0, *)
    private func start(_ tiling: MLTiling, factor: Float, frame: CVPixelBuffer, device: MTLDevice) -> Bool {
        let config = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: tiling.width, frameHeight: tiling.height,
                                                                    scaleFactor: factor)
        for _ in tiling.tiles {
            let processor = VTFrameProcessor()
            guard (try? processor.startSession(configuration: config)) != nil else { return false }
            sessions.append(processor)
        }
        var attrs = config.destinationPixelBufferAttributes
        attrs[kCVPixelBufferMetalCompatibilityKey as String] = true
        pool = Self.makePool(attrs)
        guard pool != nil else { return false }
        let w = CVPixelBufferGetWidth(frame), h = CVPixelBufferGetHeight(frame)
        if tiling.isWholeFrame(width: w, height: h) { return true }
        let format = CVPixelBufferGetPixelFormatType(frame)
        tilePool = Self.makePool(Self.nv12Attributes(format, tiling.width, tiling.height))
        outputPool = Self.makePool(Self.nv12Attributes(format, Int(Float(w) * factor), Int(Float(h) * factor)))
        if textureCache == nil {
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
            textureCache = cache
        }
        return tilePool != nil && outputPool != nil && textureCache != nil
    }

    /// Runs tile `session` of the model on `source` into a new buffer from `pool`.
    private func process(_ cb: MTLCommandBuffer, _ source: CVPixelBuffer, session: Int, pts: CMTime) -> CVPixelBuffer? {
        guard #available(macOS 26.0, iOS 26.0, *), sessions.indices.contains(session),
              let processor = sessions[session] as? VTFrameProcessor,
              let pool, let output = Self.buffer(from: pool),
              let from = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: pts),
              let to = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: pts) else { return nil }
        processor.process(with: cb, parameters: VTLowLatencySuperResolutionScalerParameters(sourceFrame: from, destinationFrame: to))
        return output
    }

    /// Cuts `frame` into tiles (bottom rows repeated to pad it), runs the model on each, and copies the
    /// middle of each tile's output into one buffer.
    private func encodeTiles(_ cb: MTLCommandBuffer, _ frame: CVPixelBuffer, tiling: MLTiling, factor: Float,
                             pts: CMTime) -> CVPixelBuffer? {
        let h = CVPixelBufferGetHeight(frame)
        let pad = tiling.height - h
        guard let tilePool, let outputPool, let output = Self.buffer(from: outputPool),
              let frameTex = planes(frame), let outputTex = planes(output) else { return nil }
        var sources: [CVPixelBuffer] = []
        var textures = [frameTex, outputTex]
        guard let cut = cb.makeBlitCommandEncoder() else { return nil }
        for tile in tiling.tiles {
            guard let source = Self.buffer(from: tilePool), let tex = planes(source) else { cut.endEncoding(); return nil }
            Self.copy(cut, frameTex, x: tile.x, y: 0, width: tiling.width, height: h, to: tex, x: 0, y: 0)
            if pad > 0 { Self.copy(cut, frameTex, x: tile.x, y: h - pad, width: tiling.width, height: pad, to: tex, x: 0, y: h) }
            sources.append(source)
            textures.append(tex)
        }
        cut.endEncoding()
        let results = sources.indices.compactMap { process(cb, sources[$0], session: $0, pts: pts) }
        guard results.count == sources.count, let join = cb.makeBlitCommandEncoder() else { return nil }
        for (tile, result) in zip(tiling.tiles, results) {
            guard let tex = planes(result) else { join.endEncoding(); return nil }
            Self.copy(join, tex, x: Int(Float(tile.keep.lowerBound - tile.x) * factor), y: 0,
                      width: Int(Float(tile.keep.count) * factor), height: Int(Float(h) * factor),
                      to: outputTex, x: Int(Float(tile.keep.lowerBound) * factor), y: 0)
            textures.append(tex)
        }
        join.endEncoding()
        // Keep the CoreVideo textures and buffers alive until the GPU is done with them.
        cb.addCompletedHandler { _ in _ = (textures, sources, results, frame) }
        return output
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

    private func end() {
        if #available(macOS 26.0, iOS 26.0, *) { sessions.forEach { ($0 as? VTFrameProcessor)?.endSession() } }
        sessions = []
        pool = nil
        tilePool = nil
        outputPool = nil
        key = nil
    }
}
