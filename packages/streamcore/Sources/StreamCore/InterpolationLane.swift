import CoreVideo
import Foundation
import Metal
import os
import QuartzCore
import VideoToolbox

/// Makes in-between images away from the display: its own queue and Metal command queue, one pair at a
/// time, so making one never holds up a refresh. A pair that arrives while the last is still being made
/// goes without its image (counted). Per pair: skip across a scene cut; make the image at the size the
/// renderer asks for (scaling down first and back up after when that is smaller than the frames); then
/// blend areas that didn't change between the two frames back from them, since generated images are
/// lossy there (a HUD, subtitles). See docs/FRAME_INTERPOLATION.md.
/// What makes the image halfway between two frames: VideoToolbox's frame interpolation for SDR pairs and MetalFX's
/// (`HDRFrameInterpolator`) for HDR ones in the app, stand-ins in tests (CI's virtual machines have neither), so the
/// lane's own work (routing, cuts, scaling, blending, empty-image checks, busy pairs) is tested everywhere. HDR engines
/// are let go when the stream turns SDR or a new one starts (`releaseHDREngines`).
protocol MiddleFrameMaker: AnyObject {
    /// The images at `phases` between the two frames (points of `steps`: see `FrameInterpolator.make`), made by
    /// the time it returns.
    func make(previous: CVPixelBuffer, current: CVPixelBuffer, phases: [Float], steps: Int) -> [CVPixelBuffer]?
    /// Gets ready for this size (building VideoToolbox's model), so the first pair doesn't wait for it.
    func prepare(width: Int, height: Int)
    /// The next pair doesn't follow on from the last (a cut, a switch between SDR and HDR): nothing to carry over.
    func reset()
}

extension MiddleFrameMaker {
    func prepare(width: Int, height: Int) {}
    func reset() {}
}

extension FrameInterpolator: MiddleFrameMaker {}

final class InterpolationLane {
    struct Image {
        let buffer: CVPixelBuffer
        /// The stream-clock time it shows at (halfway between the pair).
        let time: Double
        /// Seconds from submitting the pair to the image being ready.
        let cost: Double
        let size: (width: Int, height: Int)
        /// One of the first images at its size: the cost includes building that size's model, so it
        /// says nothing about the size's steady cost.
        let warmingUp: Bool
        /// The pair's last image: its cost is the pair's (observe it once).
        let last: Bool
    }

    /// Called on the lane's queue with each image made.
    var onImage: ((Image) -> Void)?
    /// Pairs gone without an image: still making the last one, a scene cut (or the stream switching between SDR and
    /// HDR), or the size gave nothing.
    var busyPairs: Int { state.withLock { $0.busyPairs } }
    var cutPairs: Int { state.withLock { $0.cutPairs } }
    var failedPairs: Int { state.withLock { $0.failedPairs } }

    private let queue = DispatchQueue(label: "streamcore.interpolation", qos: .userInteractive)
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let blendLuma: MTLComputePipelineState
    private let blendChroma: MTLComputePipelineState
    private let scaleLuma: MTLComputePipelineState
    private let scaleChroma: MTLComputePipelineState

    private var textureCache: CVMetalTextureCache?
    /// The CoreVideo textures behind the Metal ones in the pair's command buffers: CoreVideo wants them alive
    /// until the GPU is done with them. Cleared once it is. On `queue`.
    private var inFlight: [CVMetalTexture] = []
    /// Pairs in a row that came out with no image at each size; a size that keeps failing is dropped.
    private var failures: [String: Int] = [:]
    private var interpolators: [String: MiddleFrameMaker] = [:]
    /// Make the engine for each size: SDR pairs' and HDR pairs'.
    private let makeEngine: () -> MiddleFrameMaker
    private let makeHDREngine: () -> MiddleFrameMaker
    /// How the engines are doing (each turns off when it keeps failing).
    private let health: VideoProcessorHealth
    private let hdrHealth: VideoProcessorHealth
    private var pools: [String: CVPixelBufferPool] = [:]
    /// Time spent in each stage of the last pair (ms): cut check, scaling, interpolation, static blend.
    private(set) var stages: (cut: Double, scale: Double, interpolate: Double, blend: Double) = (0, 0, 0, 0)
    /// Images made at each size so far.
    private var madeAt: [String: Int] = [:]
    /// Whether a pair is in hand, pairs gone without an image, and sizes that came out empty (never used again).
    private let state = OSAllocatedUnfairLock(initialState: (busy: false, busyPairs: 0, cutPairs: 0, failedPairs: 0, broken: Set<String>()))

    /// `engine`: VideoToolbox's frame interpolation (reporting to `health`) unless given, for SDR pairs; `hdrEngine`:
    /// MetalFX's (reporting to `hdrHealth`) unless given, for HDR ones.
    init?(device: MTLDevice, health: VideoProcessorHealth = .interpolation, hdrHealth: VideoProcessorHealth = .hdrInterpolation,
          engine: (() -> MiddleFrameMaker)? = nil, hdrEngine: (() -> MiddleFrameMaker)? = nil) {
        makeEngine = engine ?? { FrameInterpolator(health: health) }
        makeHDREngine = hdrEngine ?? { HDRFrameInterpolator(device: device, health: hdrHealth) }
        self.health = health
        self.hdrHealth = hdrHealth
        guard let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaders, options: nil),
              let luma = library.makeFunction(name: "blendStaticLuma").flatMap({ try? device.makeComputePipelineState(function: $0) }),
              let chroma = library.makeFunction(name: "blendStaticChroma").flatMap({ try? device.makeComputePipelineState(function: $0) }),
              let sLuma = library.makeFunction(name: "scaleLuma").flatMap({ try? device.makeComputePipelineState(function: $0) }),
              let sChroma = library.makeFunction(name: "scaleChroma").flatMap({ try? device.makeComputePipelineState(function: $0) })
        else { return nil }
        scaleLuma = sLuma
        scaleChroma = sChroma
        self.device = device
        commandQueue = queue
        blendLuma = luma
        blendChroma = chroma
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    /// Queues the pair (previous, current) for the images `between` it (each at its phase, shown at its
    /// time; see `InBetween`); false when the lane is still busy with the last one. `done` is called on the
    /// lane's queue when the pair is over, with its images or without (a cut, a failure), before the lane
    /// takes another. HDR pairs go to the HDR engine, others to VideoToolbox's; a pair with one of each (the moment
    /// the stream switches) gets no images, like a cut, and the HDR engine starts afresh after it (from HDR to SDR,
    /// it's let go: see `releaseHDREngines`).
    @discardableResult
    func submit(previous: CVPixelBuffer, current: CVPixelBuffer, between: [InBetween.Image], steps: Int,
                size: (width: Int, height: Int), done: (() -> Void)? = nil) -> Bool {
        let free = state.withLock { state in
            guard !state.busy else { state.busyPairs += 1; return false }
            state.busy = true
            return true
        }
        guard free else { return false }
        let started = CACurrentMediaTime()
        queue.async { [self] in
            defer {
                done?()
                state.withLock { $0.busy = false }
            }
            let t0 = CACurrentMediaTime()
            let hdr = FrameColor.isHDR(current)
            let switched = FrameColor.isHDR(previous) != hdr
            if switched || Self.isCut(previous, current) {
                for (key, engine) in interpolators where key.hasSuffix(Self.hdrSuffix) { engine.reset() }
                if switched, !hdr { dropHDREngines() }
                state.withLock { $0.cutPairs += 1 }
                return
            }
            stages.cut = (CACurrentMediaTime() - t0) * 1000
            let key = Self.key(size, hdr: hdr)
            guard let made = make(previous, current, phases: between.map(\.phase), steps: steps, size: size, hdr: hdr),
                  made.count == between.count else {
                // A size that never gives an image (VideoToolbox couldn't start there) is dropped like an
                // empty one, so the renderer moves to the next size instead of waiting on it.
                failures[key, default: 0] += 1
                let dropped = failures[key, default: 0] >= 5
                state.withLock { state in
                    state.failedPairs += 1
                    if dropped { state.broken.insert(key) }
                }
                return
            }
            failures[key] = 0
            madeAt[key, default: 0] += 1
            // One cost for the pair: the images come out of one pass together.
            let cost = CACurrentMediaTime() - started
            for (image, plan) in zip(made, between) {
                onImage?(Image(buffer: image, time: plan.time, cost: cost, size: size, warmingUp: madeAt[key, default: 0] <= 2,
                               last: plan == between.last))
            }
        }
        return true
    }

    /// Whether frame interpolation is off for the rest of the run, for SDR or HDR streams: its engine kept failing.
    var hasFailed: Bool { health.isOff }
    var hdrHasFailed: Bool { hdrHealth.isOff }

    /// Whether a size came out empty before (and so is never used), for SDR or HDR pairs.
    func isBroken(_ size: (width: Int, height: Int), hdr: Bool = false) -> Bool {
        state.withLock { $0.broken.contains(Self.key(size, hdr: hdr)) }
    }

    /// Engines and sizes are kept apart for SDR and HDR pairs.
    private static let hdrSuffix = "/hdr"
    private static func key(_ size: (width: Int, height: Int), hdr: Bool) -> String {
        "\(size.width)x\(size.height)\(hdr ? hdrSuffix : "")"
    }

    /// Starts the counts over (a new stream).
    func resetCounts() { state.withLock { $0.busyPairs = 0; $0.cutPairs = 0; $0.failedPairs = 0 } }

    /// Lets go of the HDR engines and what they hold (MetalFX, its float images, the last frame of the stream before):
    /// a new stream, or the stream back to SDR. An HDR pair after it sets one up again.
    func releaseHDREngines() { queue.async { [self] in dropHDREngines() } }

    private func dropHDREngines() { interpolators = interpolators.filter { !$0.key.hasSuffix(Self.hdrSuffix) } }

    /// Waits until the pair in hand (if any) is done; for tests and shutdown.
    func waitUntilIdle() { queue.sync {} }

    /// Builds the size's interpolation model ahead of the first pair that needs it (1–2 s the first time).
    func prepare(size: (width: Int, height: Int), hdr: Bool = false) {
        queue.async { [self] in interpolator(size, hdr: hdr).prepare(width: size.width, height: size.height) }
    }

    private func interpolator(_ size: (width: Int, height: Int), hdr: Bool) -> MiddleFrameMaker {
        let key = Self.key(size, hdr: hdr)
        if let made = interpolators[key] { return made }
        let made = hdr ? makeHDREngine() : makeEngine()
        interpolators[key] = made
        return made
    }

    /// One pair: scale down (if asked) and wait for it, VideoToolbox's images (its synchronous call, on this
    /// queue), then scale back up and blend still areas back in one more command buffer, waited for too.
    /// VideoToolbox's command-buffer call would spare the first wait, but leaks a Metal shared event per call (see
    /// docs/FRAME_INTERPOLATION.md, "Which VideoToolbox call").
    private func make(_ previous: CVPixelBuffer, _ current: CVPixelBuffer, phases: [Float], steps: Int,
                      size: (width: Int, height: Int), hdr: Bool) -> [CVPixelBuffer]? {
        defer { inFlight.removeAll() } // every command buffer is done (or never committed) by the time this returns
        let width = CVPixelBufferGetWidth(current), height = CVPixelBufferGetHeight(current)
        let format = CVPixelBufferGetPixelFormatType(current)
        let scaled = size.width != width || size.height != height
        var t = CACurrentMediaTime()
        func lap() -> Double { defer { t = CACurrentMediaTime() }; return (CACurrentMediaTime() - t) * 1000 }
        var a = previous, b = current
        if scaled {
            guard let cb = commandQueue.makeCommandBuffer(),
                  let sa = buffer(size.width, size.height, format), let sb = buffer(size.width, size.height, format),
                  encodeScale(cb, previous, into: sa), encodeScale(cb, current, into: sb) else { return nil }
            cb.commit()
            // The scaled copies keep the frames' colorimetry (matrix, primaries, transfer, chroma siting), as
            // VideoToolbox expects of the frames it's given.
            CVBufferPropagateAttachments(previous, sa)
            CVBufferPropagateAttachments(current, sb)
            cb.waitUntilCompleted()
            guard cb.status == .completed else { return nil }
            a = sa
            b = sb
        }
        stages.scale = lap()
        guard let made = interpolator(size, hdr: hdr).make(previous: a, current: b, phases: phases, steps: steps),
              let first = made.first else { return nil }
        stages.interpolate = lap()
        // VideoToolbox can report success and write nothing (sizes it doesn't take); never show that.
        // Checked on the engine's own image: after the blend, still areas come from the real frames and would
        // hide an empty one. Not on HDR images: MetalFX's failures come back as command-buffer errors, and its image
        // is converted to codes that are never all zero in video range, while in full range black is zero (a fade
        // to black would read as empty).
        guard hdr || !Self.isEmpty(first) else {
            state.withLock { _ = $0.broken.insert(Self.key(size, hdr: hdr)) }
            Log.warning(.renderer, "Frame interpolation made an empty image at \(size.width)x\(size.height); not using that size")
            return nil
        }
        guard let cb = commandQueue.makeCommandBuffer() else { return nil }
        var outputs: [CVPixelBuffer] = []
        for image in made {
            var middle = image
            if scaled {
                guard let full = buffer(width, height, format), encodeScale(cb, middle, into: full) else { return nil }
                CVBufferPropagateAttachments(current, full)
                middle = full
            }
            guard let output = buffer(width, height, format),
                  encodeBlend(cb, previous, current, middle, into: output) else { return nil }
            // A pooled buffer may come back with the last use's attachments: propagating only adds, so the
            // decoded frame of an upscaled pair from before (ML since turned off) would otherwise stay on it.
            CVBufferRemoveAttachment(output, UpscaleLane.decodedKey)
            CVBufferPropagateAttachments(current, output)
            outputs.append(output)
        }
        cb.commit()
        cb.waitUntilCompleted()
        stages.blend = lap()
        return cb.status == .completed ? outputs : nil
    }

    /// Bilinear resample of a 4:2:0 frame into another of a different size, on the GPU.
    private func encodeScale(_ cb: MTLCommandBuffer, _ source: CVPixelBuffer, into target: CVPixelBuffer) -> Bool {
        guard let sy = plane(source, 0), let sc = plane(source, 1), let ty = plane(target, 0), let tc = plane(target, 1),
              let enc = cb.makeComputeCommandEncoder() else { return false }
        enc.setComputePipelineState(scaleLuma)
        enc.setTexture(sy, index: 0)
        enc.setTexture(ty, index: 1)
        enc.dispatchThreads(MTLSize(width: ty.width, height: ty.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.setComputePipelineState(scaleChroma)
        enc.setTexture(sc, index: 0)
        enc.setTexture(tc, index: 1)
        enc.dispatchThreads(MTLSize(width: tc.width, height: tc.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        return true
    }

    /// The in-between image with areas that didn't change between `a` and `b` taken from them instead.
    private func encodeBlend(_ cb: MTLCommandBuffer, _ a: CVPixelBuffer, _ b: CVPixelBuffer, _ middle: CVPixelBuffer,
                             into output: CVPixelBuffer) -> Bool {
        guard let ya = plane(a, 0), let yb = plane(b, 0), let ym = plane(middle, 0),
              let ca = plane(a, 1), let cbt = plane(b, 1), let cm = plane(middle, 1),
              let yo = plane(output, 0), let co = plane(output, 1),
              let enc = cb.makeComputeCommandEncoder() else { return false }
        enc.setComputePipelineState(blendLuma)
        for (i, t) in [ya, yb, ym, yo].enumerated() { enc.setTexture(t, index: i) }
        enc.dispatchThreads(MTLSize(width: yo.width, height: yo.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.setComputePipelineState(blendChroma)
        for (i, t) in [ya, yb, ca, cbt, cm, co].enumerated() { enc.setTexture(t, index: i) }
        enc.dispatchThreads(MTLSize(width: co.width, height: co.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        return true
    }

    /// Whether a frame's luma is (nearly) all zero, which no video frame is (video-range black is 16, 64 in 10 bits).
    static func isEmpty(_ frame: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard let luma = Luma(frame) else { return true }
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        var total = 0
        for gy in 0..<9 { for gx in 0..<16 { total += Int(luma[(gx * 2 + 1) * width / 32, (gy * 2 + 1) * height / 18]) } }
        return total / 144 < 8
    }

    /// A frame's luma plane read as 8-bit samples (0–255): 8-bit frames as they are, 10-bit ones (high-bit aligned in
    /// 16-bit little-endian words) by their high byte, so the thresholds on them (cuts, repeats, empty images) hold for
    /// both. The frame's base address must be locked.
    struct Luma {
        let base: UnsafePointer<UInt8>
        /// Bytes from one row to the next, and from one sample to the next.
        let row: Int
        let pixel: Int

        init?(_ frame: CVPixelBuffer) {
            guard CVPixelBufferGetPlaneCount(frame) > 0,
                  let base = CVPixelBufferGetBaseAddressOfPlane(frame, 0)?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let wide = InterpolationLane.isTenBit(frame)
            self.base = UnsafePointer(base) + (wide ? 1 : 0)
            row = CVPixelBufferGetBytesPerRowOfPlane(frame, 0)
            pixel = wide ? 2 : 1
        }

        subscript(x: Int, y: Int) -> UInt8 { base[y * row + x * pixel] }
    }

    static func isTenBit(_ frame: CVPixelBuffer) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(frame)
        return format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    }

    /// One plane of a 4:2:0 frame as a texture: 8-bit planes as 8-bit unorm, 10-bit ones as 16-bit unorm (the same
    /// 0–1 scale, so the shaders' thresholds hold for both).
    private func plane(_ buffer: CVPixelBuffer, _ index: Int) -> MTLTexture? {
        guard let textureCache else { return nil }
        let wide = Self.isTenBit(buffer)
        let format: MTLPixelFormat = index == 0 ? (wide ? .r16Unorm : .r8Unorm) : (wide ? .rg16Unorm : .rg8Unorm)
        var texture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, format,
                                                  CVPixelBufferGetWidthOfPlane(buffer, index),
                                                  CVPixelBufferGetHeightOfPlane(buffer, index), index, &texture)
        guard let texture else { return nil }
        inFlight.append(texture)
        return CVMetalTextureGetTexture(texture)
    }

    private func buffer(_ width: Int, _ height: Int, _ format: OSType) -> CVPixelBuffer? {
        let key = "\(width)x\(height)-\(format)"
        if pools[key] == nil {
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, [
                kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ] as CFDictionary, &pool)
            pools[key] = pool
        }
        guard let pool = pools[key] else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        return out
    }

    /// How much `b`'s picture changed from `a`'s (see `RepeatDetector`); nil for frames of different sizes or formats
    /// (8 and 10 bits, at a switch between SDR and HDR).
    static func difference(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double? {
        let width = CVPixelBufferGetWidth(a), height = CVPixelBufferGetHeight(a)
        guard CVPixelBufferGetWidth(b) == width, CVPixelBufferGetHeight(b) == height,
              CVPixelBufferGetPixelFormatType(a) == CVPixelBufferGetPixelFormatType(b) else { return nil }
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        guard let la = Luma(a), let lb = Luma(b) else { return nil }
        return RepeatDetector.difference(width: width, height: height, a: la.base, aRow: la.row, b: lb.base, bRow: lb.row,
                                         pixel: la.pixel)
    }

    /// Whether the pair is across a cut, from their luma on a coarse grid.
    static func isCut(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Bool {
        let width = CVPixelBufferGetWidth(b), height = CVPixelBufferGetHeight(b)
        guard CVPixelBufferGetWidth(a) == width, CVPixelBufferGetHeight(a) == height else { return false }
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        guard let la = Luma(a), let lb = Luma(b) else { return false }
        return SceneCut.isCut(width: width, height: height, a: { la[$0, $1] }, b: { lb[$0, $1] })
    }

    /// Where |A − B| is small (the area didn't change), the output is the average of A and B; where it
    /// changed, the generated image; a soft ramp in between. Chroma follows the luma of its 2×2 block. The planes
    /// read 0–1 at 8 and 10 bits alike, so the thresholds are the same share of the signal range for both.
    static let shaders = """
    #include <metal_stdlib>
    using namespace metal;
    constant float lo = 2.0 / 255.0, hi = 8.0 / 255.0;
    kernel void blendStaticLuma(texture2d<float, access::read> ya [[texture(0)]],
                                texture2d<float, access::read> yb [[texture(1)]],
                                texture2d<float, access::read> ym [[texture(2)]],
                                texture2d<float, access::write> yo [[texture(3)]],
                                uint2 g [[thread_position_in_grid]]) {
        if (g.x >= yo.get_width() || g.y >= yo.get_height()) return;
        float a = ya.read(g).r, b = yb.read(g).r;
        float moved = smoothstep(lo, hi, abs(a - b));
        yo.write(float4(mix((a + b) * 0.5, ym.read(g).r, moved)), g);
    }
    constexpr sampler bilinear(filter::linear, address::clamp_to_edge);
    kernel void scaleLuma(texture2d<float, access::sample> src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]], uint2 g [[thread_position_in_grid]]) {
        if (g.x >= dst.get_width() || g.y >= dst.get_height()) return;
        float2 uv = (float2(g) + 0.5) / float2(dst.get_width(), dst.get_height());
        dst.write(src.sample(bilinear, uv), g);
    }
    kernel void scaleChroma(texture2d<float, access::sample> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]], uint2 g [[thread_position_in_grid]]) {
        if (g.x >= dst.get_width() || g.y >= dst.get_height()) return;
        float2 uv = (float2(g) + 0.5) / float2(dst.get_width(), dst.get_height());
        dst.write(src.sample(bilinear, uv), g);
    }
    kernel void blendStaticChroma(texture2d<float, access::read> ya [[texture(0)]],
                                  texture2d<float, access::read> yb [[texture(1)]],
                                  texture2d<float, access::read> ca [[texture(2)]],
                                  texture2d<float, access::read> cb [[texture(3)]],
                                  texture2d<float, access::read> cm [[texture(4)]],
                                  texture2d<float, access::write> co [[texture(5)]],
                                  uint2 g [[thread_position_in_grid]]) {
        if (g.x >= co.get_width() || g.y >= co.get_height()) return;
        float d = 0;
        for (uint j = 0; j < 2; j++) for (uint i = 0; i < 2; i++) {
            uint2 p = min(g * 2 + uint2(i, j), uint2(ya.get_width() - 1, ya.get_height() - 1));
            d = max(d, abs(ya.read(p).r - yb.read(p).r));
        }
        float moved = smoothstep(lo, hi, d);
        float2 still = (ca.read(g).rg + cb.read(g).rg) * 0.5;
        co.write(float4(mix(still, cm.read(g).rg, moved), 0, 0), g);
    }
    """
}
