import CObjCCatch
import CoreVideo
import Metal
import MetalFX

/// Frame interpolation for HDR streams. VideoToolbox's low-latency frame interpolation (`FrameInterpolator`, the SDR
/// engine) takes 8-bit 4:2:0 video-range frames only, and HDR10 streams decode to 10-bit (`x420`, BT.2020, PQ). MetalFX's
/// frame interpolator takes float and 10-bit colour, so HDR pairs go to it instead. Per pair, on the GPU:
/// 1. each frame's 10-bit YCbCr becomes non-linear R'G'B' (still PQ-encoded) in a float texture, by the present pass's
///    own conversion (`nv12ToRGB`, without its PQ → light step). PQ, not linear light: MetalFX was built for perceptual
///    colour, and measured on a synthetic HDR scene it was worse than a plain cross-fade on linear light and better
///    on PQ (see docs/FRAME_INTERPOLATION.md, "HDR");
/// 2. MetalFX makes the image halfway between them, with no motion given (a zero motion field and a flat depth: a
///    stream has neither, and MetalFX finds the motion itself), keeping its history from pair to pair;
/// 3. the image goes back to 10-bit YCbCr in the frame's own format, with the same matrix, range and chroma siting,
///    and the frame's colour attachments, so the rest (the lane's still-area blend, the timeline, the HDR present
///    pass, MetalFX upscaling, EDR) takes it like a decoded frame.
/// MetalFX makes the midpoint only (it has no phase), so HDR gets halves: one image per pair, never quarters.
/// Unlike VideoToolbox's Metal call, MetalFX makes no Metal shared event per call (tested). Runs on the lane's queue.
final class HDRFrameInterpolator: MiddleFrameMaker {
    /// Whether this Mac and OS can run it: macOS 26 and a GPU MetalFX's frame interpolator supports, and not a virtual
    /// machine (`STREAMCORE_SIMULATE_VM=1` makes a real Mac answer like one, as CI's do).
    static let isAvailable: Bool = {
        guard #available(macOS 26.0, iOS 26.0, *), !isVirtualMachine, let device = MTLCreateSystemDefaultDevice() else { return false }
        return MTLFXFrameInterpolatorDescriptor.supportsDevice(device)
    }()

    /// The most points per pair (see `InBetween.steps`): MetalFX makes the midpoint only.
    static let maxSteps = 1
    /// The float format of the R'G'B' images MetalFX works on (the one measured).
    static let colorFormat = MTLPixelFormat.rgba16Float

    private let device: MTLDevice
    private let health: VideoProcessorHealth
    private let available: Bool
    /// Makes the midpoint maker for a frame size: MetalFX in the app, a stand-in in tests.
    private let makeMidpoint: (MTLDevice, Int, Int) -> MidpointEncoder?
    private lazy var gpu = GPU(device: device)
    /// What's set up for the current frame size: the midpoint maker, two R'G'B' images (the pair, used in turn so the
    /// last pair's newer frame needn't be converted again) and MetalFX's output.
    private struct Sized {
        let width: Int, height: Int
        let midpoint: MidpointEncoder
        let colour: [MTLTexture]
        let output: MTLTexture
    }
    private var sized: Sized?
    /// Sizes MetalFX couldn't be set up for (never tried again).
    private var refused: Set<String> = []
    /// The last pair's newer frame (held, so its buffer can't come back as another frame) and which R'G'B' image holds
    /// it: a pair that starts from it goes on with MetalFX's history; any other pair starts afresh.
    private var history: (frame: CVPixelBuffer, slot: Int)?
    private var pools: [OSType: CVPixelBufferPool] = [:]
    /// Pairs started without history (the first, or after a gap, a cut or a reset); for tests.
    private(set) var freshStarts = 0
    /// The last midpoint as MetalFX made it (R'G'B', PQ); for tests.
    var lastMidpoint: MTLTexture? { sized?.output }

    /// `available` and `makeMidpoint`: MetalFX in the app, stand-ins in tests.
    init(device: MTLDevice, health: VideoProcessorHealth = .hdrInterpolation, available: Bool = HDRFrameInterpolator.isAvailable,
         makeMidpoint: @escaping (MTLDevice, Int, Int) -> MidpointEncoder? = makeMetalFXMidpoint) {
        self.device = device
        self.health = health
        self.available = available
        self.makeMidpoint = makeMidpoint
    }

    /// Whether it's off for the rest of the run: its GPU work kept failing.
    var hasFailed: Bool { health.isOff }

    /// The next pair starts without history (a cut, or the stream switching between SDR and HDR).
    func reset() { history = nil }

    /// Sets up MetalFX for this size ahead of the first pair.
    func prepare(width: Int, height: Int) {
        if available, !health.isOff { _ = setUp(width: width, height: height) }
    }

    /// The image halfway between two HDR frames, made by the time it returns, in a new buffer of `current`'s format
    /// with its attachments; nil when it can't (not HDR, sizes differ, a phase other than ½, no MetalFX at this size)
    /// or the GPU work failed (counted against the feature: see `VideoProcessorHealth`).
    func make(previous: CVPixelBuffer, current: CVPixelBuffer, phases: [Float], steps: Int) -> [CVPixelBuffer]? {
        guard available, steps == Self.maxSteps, phases == [0.5], FrameColor.isHDR(previous), FrameColor.isHDR(current) else { return nil }
        guard !health.isOff else {
            history = nil
            sized = nil
            return nil
        }
        let w = CVPixelBufferGetWidth(current), h = CVPixelBufferGetHeight(current)
        guard CVPixelBufferGetWidth(previous) == w, CVPixelBufferGetHeight(previous) == h,
              let gpu, let sized = setUp(width: w, height: h),
              let output = buffer(w, h, CVPixelBufferGetPixelFormatType(current)),
              let cb = gpu.queue.makeCommandBuffer() else { return nil }
        let continuing = history.map { $0.frame === previous } ?? false
        let before = continuing ? history?.slot ?? 0 : 0, after = 1 - before
        history = nil
        var held: [CVMetalTexture] = [] // CoreVideo's textures stay alive until the GPU is done (waited for below)
        guard continuing || gpu.encodeToRGB(cb, previous, into: sized.colour[before], held: &held),
              gpu.encodeToRGB(cb, current, into: sized.colour[after], held: &held) else { return nil }
        if !continuing { freshStarts += 1 }
        guard sized.midpoint.encode(cb, previous: sized.colour[before], current: sized.colour[after], output: sized.output,
                                    reset: !continuing) else {
            health.failed("couldn't encode the midpoint at \(w)x\(h)")
            return nil
        }
        guard gpu.encodeToYCbCr(cb, sized.output, into: output, color: FrameColor(current), held: &held) else { return nil }
        cb.commit()
        cb.waitUntilCompleted()
        guard cb.status == .completed else {
            health.failed("GPU error at \(w)x\(h): \(cb.error.map { "\($0)" } ?? "\(cb.status)")")
            return nil
        }
        history = (current, after)
        // A pooled buffer may come back with the last use's attachments: propagating only adds.
        CVBufferRemoveAllAttachments(output)
        CVBufferPropagateAttachments(current, output)
        return [output]
    }

    /// The midpoint maker and images for this size, set up if needed; nil when MetalFX can't run at it.
    private func setUp(width: Int, height: Int) -> Sized? {
        if let sized, sized.width == width, sized.height == height { return sized }
        let key = "\(width)x\(height)"
        guard !refused.contains(key) else { return nil }
        sized = nil
        history = nil
        guard let midpoint = makeMidpoint(device, width, height) else {
            refused.insert(key)
            Log.warning(.renderer, "HDR frame interpolation (MetalFX) can't run at \(key); not using that size")
            return nil
        }
        func texture(_ usage: MTLTextureUsage) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.colorFormat, width: width, height: height, mipmapped: false)
            d.storageMode = .private
            d.usage = usage
            return device.makeTexture(descriptor: d)
        }
        guard let a = texture(midpoint.colorUsage.union([.shaderRead, .shaderWrite])),
              let b = texture(midpoint.colorUsage.union([.shaderRead, .shaderWrite])),
              let output = texture(midpoint.outputUsage.union(.shaderRead)) else { return nil }
        let made = Sized(width: width, height: height, midpoint: midpoint, colour: [a, b], output: output)
        sized = made
        Log.info(.renderer, "HDR frame interpolation on for \(key) streams (MetalFX, halves)")
        return made
    }

    private func buffer(_ width: Int, _ height: Int, _ format: OSType) -> CVPixelBuffer? {
        if pools[format] == nil {
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, [
                kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ] as CFDictionary, &pool)
            pools[format] = pool
        }
        guard let pool = pools[format] else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        return out
    }

    /// The conversions between a frame's YCbCr planes and R'G'B' textures.
    private final class GPU {
        let queue: MTLCommandQueue
        private let toRGB: MTLComputePipelineState
        private let toLuma: MTLComputePipelineState
        private let toChroma: MTLComputePipelineState
        private let cache: CVMetalTextureCache

        init?(device: MTLDevice) {
            var cache: CVMetalTextureCache?
            // The forward conversion is the present pass's own kernel, so the maths can't drift apart.
            guard let queue = device.makeCommandQueue(),
                  let present = try? device.makeLibrary(source: shaderSource, options: nil),
                  let back = try? device.makeLibrary(source: HDRFrameInterpolator.shaders, options: nil),
                  let toRGB = present.makeFunction(name: "nv12ToRGB").flatMap({ try? device.makeComputePipelineState(function: $0) }),
                  let toLuma = back.makeFunction(name: "rgbToLuma").flatMap({ try? device.makeComputePipelineState(function: $0) }),
                  let toChroma = back.makeFunction(name: "rgbToChroma").flatMap({ try? device.makeComputePipelineState(function: $0) }),
                  CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
            self.queue = queue
            self.toRGB = toRGB
            self.toLuma = toLuma
            self.toChroma = toChroma
            self.cache = cache
        }

        /// `frame` → R'G'B' (PQ-encoded, 0–1) in `target`.
        func encodeToRGB(_ cb: MTLCommandBuffer, _ frame: CVPixelBuffer, into target: MTLTexture, held: inout [CVMetalTexture]) -> Bool {
            guard let (luma, chroma) = planes(frame, held: &held), let enc = cb.makeComputeCommandEncoder() else { return false }
            var params = HDRFrameInterpolator.conversion(FrameColor(frame))
            enc.setComputePipelineState(toRGB)
            enc.setTexture(luma, index: 0)
            enc.setTexture(chroma, index: 1)
            enc.setTexture(target, index: 2)
            enc.setBytes(&params, length: MemoryLayout<YCbCrConversion>.stride, index: 0)
            enc.dispatchThreads(MTLSize(width: target.width, height: target.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            enc.endEncoding()
            return true
        }

        /// R'G'B' `source` → `frame`'s YCbCr planes, as 10-bit codes, by `color`'s matrix, range and chroma siting.
        func encodeToYCbCr(_ cb: MTLCommandBuffer, _ source: MTLTexture, into frame: CVPixelBuffer, color: FrameColor,
                           held: inout [CVMetalTexture]) -> Bool {
            guard let (luma, chroma) = planes(frame, held: &held), let enc = cb.makeComputeCommandEncoder() else { return false }
            var params = HDRFrameInterpolator.conversion(color)
            var steps = HDRFrameInterpolator.codeSteps(tenBit: color.tenBit)
            for (pipeline, plane) in [(toLuma, luma), (toChroma, chroma)] {
                enc.setComputePipelineState(pipeline)
                enc.setTexture(source, index: 0)
                enc.setTexture(plane, index: 1)
                enc.setBytes(&params, length: MemoryLayout<YCbCrConversion>.stride, index: 0)
                enc.setBytes(&steps, length: MemoryLayout<Float>.size, index: 1)
                enc.dispatchThreads(MTLSize(width: plane.width, height: plane.height, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            }
            enc.endEncoding()
            return true
        }

        /// A 10-bit frame's luma and chroma planes as 16-bit textures.
        private func planes(_ frame: CVPixelBuffer, held: inout [CVMetalTexture]) -> (MTLTexture, MTLTexture)? {
            var textures: [MTLTexture] = []
            for (plane, format) in [(0, MTLPixelFormat.r16Unorm), (1, .rg16Unorm)] {
                var texture: CVMetalTexture?
                CVMetalTextureCacheCreateTextureFromImage(nil, cache, frame, nil, format, CVPixelBufferGetWidthOfPlane(frame, plane),
                                                          CVPixelBufferGetHeightOfPlane(frame, plane), plane, &texture)
                guard let texture, let metal = CVMetalTextureGetTexture(texture) else { return nil }
                held.append(texture)
                textures.append(metal)
            }
            return (textures[0], textures[1])
        }
    }

    /// The frame's own conversion (no user overrides: the round trip only has to land back on its codes), with the
    /// PQ → light step off, so the R'G'B' stays PQ-encoded. Bicubic chroma, as the present pass's default.
    static func conversion(_ color: FrameColor) -> YCbCrConversion {
        var c = YCbCrConversion(frame: color, matrix: .auto, range: .auto, chroma: .bicubic)
        c.chroma.w = 0
        return c
    }

    /// Code steps per unit as the shader reads the planes: 10-bit codes high-bit aligned in 16-bit words read as
    /// c·64/65535 (see `YCbCrConversion.range`); 8-bit ones as c/255.
    static func codeSteps(tenBit: Bool) -> Float { tenBit ? 65535.0 / 64 : 255 }

    /// R'G'B' → YCbCr: the inverse of `nv12ToRGB`'s matrix and range (its parameters: Kr and Kb come back from its
    /// coefficients, R←Cr = 2(1−Kr) and B←Cb = 2(1−Kb)). Values are rounded to whole codes. Chroma is filtered down to
    /// where its samples sit (the siting shift the present pass undoes going up): a tent two luma pixels wide each way,
    /// [1 2 1]/4 on a co-sited axis and [1 3 3 1]/8 on a centred one. Not-a-number counts as 0.
    static let shaders = """
    #include <metal_stdlib>
    using namespace metal;
    struct YCbCrParams { float4 range; float4 coef; float4 chroma; };
    static float3 clean(float3 c) { return clamp(select(c, float3(0.0), isnan(c)), 0.0, 1.0); }
    static float lumaOf(float3 c, constant YCbCrParams &p) {
        float kr = 1.0 - p.coef.x * 0.5, kb = 1.0 - p.coef.w * 0.5;
        return kr * c.r + (1.0 - kr - kb) * c.g + kb * c.b;
    }
    static float code(float v, float steps) { return min(round(saturate(v) * steps), floor(steps)) / steps; }
    kernel void rgbToLuma(texture2d<float, access::read> rgb [[texture(0)]],
                          texture2d<float, access::write> luma [[texture(1)]],
                          constant YCbCrParams &p [[buffer(0)]], constant float &steps [[buffer(1)]],
                          uint2 g [[thread_position_in_grid]]) {
        if (g.x >= luma.get_width() || g.y >= luma.get_height()) return;
        float y = lumaOf(clean(rgb.read(g).rgb), p);
        luma.write(float4(code(y / p.range.y + p.range.x, steps)), g);
    }
    kernel void rgbToChroma(texture2d<float, access::read> rgb [[texture(0)]],
                            texture2d<float, access::write> chroma [[texture(1)]],
                            constant YCbCrParams &p [[buffer(0)]], constant float &steps [[buffer(1)]],
                            uint2 g [[thread_position_in_grid]]) {
        if (g.x >= chroma.get_width() || g.y >= chroma.get_height()) return;
        // Where this chroma sample sits, in luma pixels (pixel k's centre at k).
        float2 at = float2(g) * 2.0 + 0.5 - p.chroma.xy * 2.0;
        int2 base = int2(floor(at)) - 1, last = int2(rgb.get_width(), rgb.get_height()) - 1;
        float2 sum = float2(0.0);
        float total = 0.0;
        for (int j = 0; j < 4; j++) for (int i = 0; i < 4; i++) {
            int2 q = base + int2(i, j);
            float w = max(0.0, 2.0 - abs(float(q.x) - at.x)) * max(0.0, 2.0 - abs(float(q.y) - at.y));
            if (w <= 0.0) continue;
            float3 c = clean(rgb.read(uint2(clamp(q, int2(0), last))).rgb);
            float y = lumaOf(c, p);
            sum += w * float2((c.b - y) / p.coef.w, (c.r - y) / p.coef.x);
            total += w;
        }
        float2 cc = sum / total / p.range.w + p.range.z;
        chroma.write(float4(code(cc.x, steps), code(cc.y, steps), 0.0, 0.0), g);
    }
    """
}

/// What makes the image halfway between two R'G'B' images: MetalFX's frame interpolator in the app (`MetalFXMidpoint`),
/// a stand-in in tests (CI's virtual machines have no MetalFX frame interpolation), so the work around it (conversions,
/// history, failures) is tested everywhere.
protocol MidpointEncoder: AnyObject {
    /// The usage the colour images (inputs) and the output need.
    var colorUsage: MTLTextureUsage { get }
    var outputUsage: MTLTextureUsage { get }
    /// Encodes the midpoint of `previous` and `current` into `output` (all `HDRFrameInterpolator.colorFormat`, one
    /// size); `reset`: no history to go on from (the first pair, or after a gap). False when it can't be encoded.
    func encode(_ cb: MTLCommandBuffer, previous: MTLTexture, current: MTLTexture, output: MTLTexture, reset: Bool) -> Bool
}

/// MetalFX's maker for a frame size (macOS 26+), nil where it can't run.
func makeMetalFXMidpoint(device: MTLDevice, width: Int, height: Int) -> MidpointEncoder? {
    if #available(macOS 26.0, iOS 26.0, *) { return MetalFXMidpoint(device: device, width: width, height: height) }
    return nil
}

/// MetalFX's frame interpolator with no motion given: a zero motion field and a flat depth, at 1/16 of the frame (the
/// field's size barely matters when it's empty), cleared at each fresh start; MetalFX estimates the motion itself.
/// The camera values are placeholders it needs set (there's no camera). See docs/FRAME_INTERPOLATION.md, "HDR".
@available(macOS 26.0, iOS 26.0, *)
final class MetalFXMidpoint: MidpointEncoder {
    private let interpolator: MTLFXFrameInterpolator
    private let depth: MTLTexture
    private let motion: MTLTexture
    private let aspect: Float

    init?(device: MTLDevice, width: Int, height: Int) {
        let fieldWidth = max(1, width / 16), fieldHeight = max(1, height / 16)
        let d = MTLFXFrameInterpolatorDescriptor()
        d.colorTextureFormat = HDRFrameInterpolator.colorFormat
        d.outputTextureFormat = HDRFrameInterpolator.colorFormat
        d.depthTextureFormat = .depth32Float
        d.motionTextureFormat = .rg16Float
        d.inputWidth = fieldWidth
        d.inputHeight = fieldHeight
        d.outputWidth = width
        d.outputHeight = height
        guard let interpolator = d.makeFrameInterpolator(device: device) else { return nil }
        func texture(_ format: MTLPixelFormat, _ usage: MTLTextureUsage) -> MTLTexture? {
            let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: fieldWidth, height: fieldHeight, mipmapped: false)
            t.storageMode = .private
            t.usage = usage.union(.renderTarget)
            return device.makeTexture(descriptor: t)
        }
        guard let depth = texture(.depth32Float, interpolator.depthTextureUsage),
              let motion = texture(.rg16Float, interpolator.motionTextureUsage) else { return nil }
        self.interpolator = interpolator
        self.depth = depth
        self.motion = motion
        aspect = Float(width) / Float(height)
    }

    var colorUsage: MTLTextureUsage { interpolator.colorTextureUsage }
    var outputUsage: MTLTextureUsage { interpolator.outputTextureUsage }

    func encode(_ cb: MTLCommandBuffer, previous: MTLTexture, current: MTLTexture, output: MTLTexture, reset: Bool) -> Bool {
        if reset {
            let pass = MTLRenderPassDescriptor()
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 0.5
            pass.depthAttachment.storeAction = .store
            pass.colorAttachments[0].texture = motion
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            guard let clear = cb.makeRenderCommandEncoder(descriptor: pass) else { return false }
            clear.endEncoding()
        }
        interpolator.colorTexture = current
        interpolator.prevColorTexture = previous
        interpolator.motionTexture = motion
        interpolator.depthTexture = depth
        interpolator.outputTexture = output
        interpolator.motionVectorScaleX = 1
        interpolator.motionVectorScaleY = 1
        interpolator.deltaTime = 1.0 / 30
        interpolator.nearPlane = 0.1
        interpolator.farPlane = 1000
        interpolator.fieldOfView = 60
        interpolator.aspectRatio = aspect
        interpolator.jitterOffsetX = 0
        interpolator.jitterOffsetY = 0
        interpolator.shouldResetHistory = reset
        // An Objective-C exception from inside MetalFX ends this pair (counted as a failure), not the app.
        return playfx_catch { self.interpolator.encode(commandBuffer: cb) } == nil
    }
}
