import CoreVideo
import Metal
import MetalFX
import MetalKit
import QuartzCore
import os

public enum UpscaleMode: Int32, Sendable {
    case bilinear = 0
    case metalFX = 1
}

extension UpscaleMode: Codable {
    public init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        switch name {
        case "bilinear": self = .bilinear
        case "metalfx": self = .metalFX
        default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                         debugDescription: "unknown upscaler \(name)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(self == .metalFX ? "metalfx" : "bilinear")
    }
}

/// Picture settings, applied to every frame (no reconnect). Hosts send them as JSON; missing
/// keys keep their defaults.
public struct RenderParams: Codable, Equatable, Sendable {
    public var upscaler: UpscaleMode = .metalFX
    /// Contrast-adaptive sharpening after the upscale: 0 = off … 1 = strongest.
    public var sharpness: Float = 0.3
    /// Smooths compression blocking on the 8×8 grid before the upscale: 0 = off … 1 = strongest.
    public var deblock: Float = 0
    /// Smooths banding in gradients (with a touch of dither) before the upscale: 0 = off … 1 = strongest.
    public var deband: Float = 0
    /// Apple's ML super-resolution on the decoded frame first (macOS 26+, streams up to 1280 px wide).
    public var mlUpscale = false
    /// "Frame interpolation": an interpolated frame between each pair of stream frames (macOS 26+), when the
    /// screen refreshes at least twice as fast as the stream. Adds one screen refresh of latency.
    public var frameInterpolation = false
    /// Split screen: left half is the baseline (bilinear, no processing), right half these params.
    public var compare = false
    public var colorMatrix: ColorMatrix = .auto
    public var colorRange: ColorRange = .auto
    public var chroma: ChromaFilter = .bicubic
    /// Tag the output as sRGB so macOS converts it to the display's gamut (off = unmanaged, more
    /// saturated on wide-gamut displays).
    public var accurateColor = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RenderParams()
        upscaler = try c.decodeIfPresent(UpscaleMode.self, forKey: .upscaler) ?? d.upscaler
        func strength(_ key: CodingKeys, _ fallback: Float) throws -> Float {
            min(1, max(0, try c.decodeIfPresent(Float.self, forKey: key) ?? fallback))
        }
        sharpness = try strength(.sharpness, d.sharpness)
        deblock = try strength(.deblock, d.deblock)
        deband = try strength(.deband, d.deband)
        compare = try c.decodeIfPresent(Bool.self, forKey: .compare) ?? d.compare
        colorMatrix = try c.decodeIfPresent(ColorMatrix.self, forKey: .colorMatrix) ?? d.colorMatrix
        colorRange = try c.decodeIfPresent(ColorRange.self, forKey: .colorRange) ?? d.colorRange
        chroma = try c.decodeIfPresent(ChromaFilter.self, forKey: .chroma) ?? d.chroma
        accurateColor = try c.decodeIfPresent(Bool.self, forKey: .accurateColor) ?? d.accurateColor
        mlUpscale = try c.decodeIfPresent(Bool.self, forKey: .mlUpscale) ?? d.mlUpscale
        frameInterpolation = try c.decodeIfPresent(Bool.self, forKey: .frameInterpolation) ?? d.frameInterpolation
    }
}

/// Renders the stream into an MTKView: video frame (NV12) → RGB → optional MetalFX spatial
/// upscale to the on-screen size → present, letterboxed to the source aspect ratio.
/// Platform-agnostic; macOS/iOS hosts only differ in how they embed `view`.
public final class StreamRenderer: NSObject, MTKViewDelegate {
    public let view: MTKView
    public let metalFXSupported: Bool
    public var params = RenderParams() {
        didSet { applyColorSpace() }
    }
    /// Upscaler actually used for the last frame (MetalFX is skipped when not upscaling).
    public private(set) var activeMode: UpscaleMode = .bilinear
    /// Whether Apple's ML super-resolution can run on this Mac and OS.
    public let mlSupported = MLSuperResolution.isAvailable
    /// Whether the last decoded frame went through ML super-resolution.
    public private(set) var mlActive = false
    private let ml = MLSuperResolution()
    /// Whether frame interpolation can run on this Mac and OS.
    public let interpolationSupported = FrameInterpolator.isAvailable
    /// Whether in-between images reached the screen in the last second.
    public var interpolationActive: Bool { presented.withLock { $0.generated.perSecond(now: CACurrentMediaTime()) > 0 } }
    /// The stream's nominal frame rate (30 or 60), which its clock runs on. Setting it starts pacing over
    /// (counts included), so set it once per stream, before its first frame.
    public var streamFrameRate: Double {
        get { pacing.withLock { $0.clock.fps } }
        set {
            pacing.withLock { $0 = Pacing(fps: newValue) }
            lane?.resetCounts()
        }
    }
    /// Frames shown by their stream clock (see FramePacing.swift), and the in-between images made for them.
    private struct Pacing {
        var clock: StreamClock
        var timeline = FrameTimeline<CVPixelBuffer>(capacity: 16)
        var planner = DelayPlanner()
        var rungs: RungSelector?
        var lastReal: (frame: CVPixelBuffer, time: Double)?
        var nextIndex: UInt64 = 0
        init(fps: Double) { clock = StreamClock(fps: fps) }
    }
    private let pacing = OSAllocatedUnfairLock(initialState: Pacing(fps: 60))
    /// Whether to make in-between images: wanted, supported, and the screen refreshes fast enough to show them.
    private let interpolating = OSAllocatedUnfairLock(initialState: false)
    private let lane: InterpolationLane?
    /// Smoothed seconds between screen refreshes (draws).
    private var displayInterval = 0.0
    private var lastDraw = 0.0
    /// The image drawn now, for counting it once it is actually presented.
    private var drawnItem: TimedImage<CVPixelBuffer>?
    /// Images actually presented per second, all and in-between ones (from the drawable's presented time).
    private let presented = OSAllocatedUnfairLock(initialState: PresentationCounts())
    /// Drawn images whose presentation the system reported (all), and of those, ones it never put on screen.
    public var presentationReports: (handled: Int, unpresented: Int) { presented.withLock { ($0.handled, $0.unpresented) } }
    /// Frames and in-between images that were never shown (a later one was due first), and pairs that went
    /// without an in-between image.
    public var skippedFrames: Int { pacing.withLock { $0.timeline.skippedReal } }
    public var skippedInterpolations: Int {
        pacing.withLock { $0.timeline.skippedGenerated } + (lane.map { $0.busyPairs } ?? 0)
    }
    /// The size in-between images are made at now, and what one costs (90th percentile, ms).
    public var interpolationSize: (width: Int, height: Int)? { pacing.withLock { $0.rungs?.size } }
    public var interpolationCostMilliseconds: Double { pacing.withLock { $0.planner.generationCost * 1000 } }
    /// How far behind the stream clock images are shown now (ms): jitter cover, plus interpolation's time.
    public var pacingDelayMilliseconds: Double { pacing.withLock { $0.planner.delay * 1000 } }
    /// From a decoded frame arriving to it being on screen, smoothed (ms; 0 until measured).
    public var displayMilliseconds: Double { displayTime.withLock { $0 } }
    private let displayTime = OSAllocatedUnfairLock<Double>(initialState: 0)
    /// New images actually presented per second: stream frames plus in-between images.
    public var shownFramesPerSecond: Double { presented.withLock { $0.all.perSecond(now: CACurrentMediaTime()) } }
    /// In-between images actually presented per second.
    public var generatedFramesPerSecond: Double { presented.withLock { $0.generated.perSecond(now: CACurrentMediaTime()) } }
    /// The raw stream converted at its own size, for the compare view's baseline while ML is on.
    private var baselineTexture: MTLTexture?
    /// Width of the last decoded frame, before any ML upscale (the codec's block grid lives there).
    private var decodedWidth = 0
    /// GPU time per frame (conversion, cleanup, upscale, present), smoothed; 0 until a frame finished.
    public var gpuMilliseconds: Double { gpuTime.withLock { $0 } }
    private let gpuTime = OSAllocatedUnfairLock<Double>(initialState: 0)
    /// Shows the animated test pattern when no video frames are arriving.
    public var showsTestPattern = true

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let patternPipeline: MTLComputePipelineState
    private let nv12Pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    /// The present-pass pipelines, one set per output format (8-bit SDR, 16-bit float for HDR/EDR).
    private struct Pipelines {
        let present: MTLRenderPipelineState
        let divider: MTLRenderPipelineState
        let sharpen: MTLRenderPipelineState
    }
    private let sdrPipelines: Pipelines
    private let hdrPipelines: Pipelines
    /// HDR10 frames are on screen: float textures, an EDR layer in linear BT.2020.
    public private(set) var hdrActive = false
    private let sampler: MTLSamplerState
    private let startTime = CACurrentMediaTime()

    private var inputTexture: MTLTexture
    /// The input after deblock/deband (same size); only used while either is on.
    private var cleanTexture: MTLTexture?
    private let cleanupPipeline: MTLComputePipelineState
    private var scaler: MTLFXSpatialScaler?
    private var scalerOutput: MTLTexture?

    public init?(inputWidth: Int = 1280, inputHeight: Int = 720) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: shaderSource, options: nil),
              let kernel = library.makeFunction(name: "testPattern"),
              let patternPipeline = try? device.makeComputePipelineState(function: kernel),
              let nv12Kernel = library.makeFunction(name: "nv12ToRGB"),
              let nv12Pipeline = try? device.makeComputePipelineState(function: nv12Kernel),
              let cleanupKernel = library.makeFunction(name: "cleanup"),
              let cleanupPipeline = try? device.makeComputePipelineState(function: cleanupKernel)
        else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let textureCache = cache
        else { return nil }

        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        // Two drawables instead of three: a frame waits at most one refresh for the screen (lower latency;
        // the GPU work per frame is a few ms, so double buffering doesn't starve).
        (view.layer as? CAMetalLayer)?.maximumDrawableCount = 2
        view.preferredFramesPerSecond = 120

        func pipelines(_ format: MTLPixelFormat) -> Pipelines? {
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = library.makeFunction(name: "fullscreenVertex")
            pd.colorAttachments[0].pixelFormat = format
            func make(_ fragment: String) -> MTLRenderPipelineState? {
                pd.fragmentFunction = library.makeFunction(name: fragment)
                return try? device.makeRenderPipelineState(descriptor: pd)
            }
            guard let present = make("presentFragment"), let divider = make("dividerFragment"),
                  let sharpen = make("sharpenFragment") else { return nil }
            return Pipelines(present: present, divider: divider, sharpen: sharpen)
        }
        guard let sdrPipelines = pipelines(.bgra8Unorm), let hdrPipelines = pipelines(.rgba16Float) else { return nil }

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        guard let sampler = device.makeSamplerState(descriptor: sd),
              let input = Self.makeInputTexture(device, inputWidth, inputHeight)
        else { return nil }

        self.device = device
        self.queue = queue
        self.patternPipeline = patternPipeline
        self.nv12Pipeline = nv12Pipeline
        self.cleanupPipeline = cleanupPipeline
        self.textureCache = textureCache
        self.sdrPipelines = sdrPipelines
        self.hdrPipelines = hdrPipelines
        self.sampler = sampler
        self.inputTexture = input
        self.view = view
        self.metalFXSupported = MTLFXSpatialScalerDescriptor.supportsDevice(device)
        self.lane = FrameInterpolator.isAvailable ? InterpolationLane(device: device) : nil
        Log.info(.renderer, "Renderer on \(device.name): MetalFX \(metalFXSupported ? "yes" : "no"), "
            + "ML super-resolution \(MLSuperResolution.isAvailable ? "yes" : "no")")
        super.init()
        lane?.onImage = { [pacing] image in
            pacing.withLock { p in
                p.timeline.add(TimedImage(image: image.buffer, time: image.time, generated: true, arrival: CACurrentMediaTime()))
                guard !image.warmingUp else { return } // a model being built: not the size's real cost
                p.planner.observe(cost: image.cost)
                p.rungs?.observe(cost: image.cost, budget: p.clock.interval * 0.6, now: CACurrentMediaTime())
            }
        }
        view.delegate = self
        applyColorSpace()
    }

    /// sRGB (BT.709 primaries) when color-managed; nil leaves the output in the display's space. HDR is
    /// always linear BT.2020 with extended range (1.0 = SDR white), which macOS maps to the display's EDR.
    private func applyColorSpace() {
        view.colorspace = hdrActive ? CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
            : params.accurateColor ? CGColorSpace(name: CGColorSpace.sRGB) : nil
    }

    /// Switches between SDR (8-bit) and HDR (16-bit float, EDR) output. Only between draws: the drawable's
    /// format changes with it.
    func setHDR(_ on: Bool) {
        guard on != hdrActive,
              let tex = Self.makeInputTexture(device, inputTexture.width, inputTexture.height, on ? .rgba16Float : .rgba8Unorm)
        else { return }
        hdrActive = on
        inputTexture = tex
        cleanTexture = nil
        scaler = nil
        baselineTexture = nil
        view.colorPixelFormat = on ? .rgba16Float : .bgra8Unorm
        (view.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = on
        applyColorSpace()
        Log.info(.renderer, on ? "HDR stream: showing it in HDR (EDR)" : "Back to SDR output")
    }

    public func setInputSize(width: Int, height: Int) {
        guard width > 0, height > 0,
              width != inputTexture.width || height != inputTexture.height,
              let tex = Self.makeInputTexture(device, width, height, inputTexture.pixelFormat) else { return }
        inputTexture = tex
        cleanTexture = nil
        scaler = nil
    }

    /// Queues a decoded frame. Thread-safe. `index` is its place in the stream (one more than the last,
    /// plus any frames lost); without it frames count up by one. The frame shows when the stream clock
    /// says, not when it arrives; with frame interpolation on, the image between it and the previous frame
    /// is made on the interpolation lane meanwhile. The first one replaces the idle backdrop.
    public func display(_ frame: CVPixelBuffer, index: UInt64? = nil, arrival: Double = CACurrentMediaTime()) {
        showsTestPattern = false
        let wanted = interpolating.withLock { $0 }
        let pair: (previous: CVPixelBuffer, time: Double, size: (width: Int, height: Int), prepare: [(width: Int, height: Int)])? =
            pacing.withLock { p in
                let i = index ?? p.nextIndex
                p.nextIndex = i + 1
                guard var stamp = p.clock.time(index: i, arrival: arrival) else { return nil }
                // Far earlier than the clock expects: its rate is wrong for this stream; start it over here.
                if stamp.time - arrival > p.clock.interval / 2 {
                    p.clock = StreamClock(fps: p.clock.fps)
                    stamp = p.clock.time(index: i, arrival: arrival) ?? (arrival, true)
                }
                if stamp.restarted {
                    p.timeline.clear()
                    p.lastReal = nil
                }
                p.planner.observe(lateness: arrival - stamp.time)
                let delay = p.planner.update(interval: p.clock.interval, interpolating: wanted)
                // After a start or a break the frame shows at once; later ones keep to the clock.
                let time = stamp.restarted ? arrival - delay : stamp.time
                p.timeline.add(TimedImage(image: frame, time: time, generated: false, arrival: arrival))
                defer { p.lastReal = (frame, time) }
                let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
                guard wanted, let last = p.lastReal,
                      CVPixelBufferGetWidth(last.frame) == width, CVPixelBufferGetHeight(last.frame) == height else { return nil }
                var prepare: [(width: Int, height: Int)] = []
                if p.rungs.map({ $0.rungs[0] != (width, height) }) ?? true {
                    p.rungs = RungSelector(width: width, height: height)
                    prepare = p.rungs?.rungs ?? []
                }
                guard let size = p.rungs?.size else { return nil }
                return (last.frame, (last.time + time) / 2, size, prepare)
            }
        guard let pair, let lane else { return }
        for size in pair.prepare.dropFirst() { lane.prepare(size: size) }
        lane.submit(previous: pair.previous, current: frame, time: pair.time, size: pair.size)
    }

    /// Waits until the interpolation lane has finished the pair in hand (tests).
    func waitForInterpolation() { lane?.waitUntilIdle() }

    // MARK: MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        // Switch SDR ↔ HDR before taking the drawable, whose format follows the mode.
        if let layer = view.layer as? CAMetalLayer, layer.maximumDrawableCount != 2 { layer.maximumDrawableCount = 2 }
        let pending = pacing.withLock { $0.timeline.entries.last?.image }
        if let pending { setHDR(FrameColor.isHDR(pending)) } else if showsTestPattern { setHDR(false) }
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer() else { return }
        drawnItem = nil
        encode(cb, pass: pass, drawableSize: view.drawableSize)
        if let item = drawnItem {
            drawable.addPresentedHandler { [displayTime, presented] shown in
                let onScreen = presented.withLock {
                    $0.report(presentedAt: shown.presentedTime, generated: item.generated, now: CACurrentMediaTime())
                }
                guard onScreen, shown.presentedTime > 0 else { return }
                guard !item.generated, shown.presentedTime > item.arrival else { return }
                displayTime.withLock { $0 = Self.smoothed($0, (shown.presentedTime - item.arrival) * 1000) }
            }
        }
        cb.present(drawable)
        cb.commit()
    }

    /// Everything `draw` does short of presenting: pending frame (or test pattern) → input texture →
    /// optional MetalFX upscale → letterboxed into `pass`.
    func encode(_ cb: MTLCommandBuffer, pass: MTLRenderPassDescriptor, drawableSize: CGSize,
                now: Double = CACurrentMediaTime()) {
        cb.addCompletedHandler { [gpuTime] done in
            let ms = (done.gpuEndTime - done.gpuStartTime) * 1000
            guard ms > 0 else { return }
            gpuTime.withLock { $0 = Self.smoothed($0, ms) }
        }
        if let frame = nextFrame(now: now) {
            let enhanced = params.mlUpscale ? ml.encode(cb, frame, target: fittedRect(drawable: drawableSize).size) : nil
            mlActive = enhanced != nil
            decodedWidth = CVPixelBufferGetWidth(frame)
            encodeVideoFrame(enhanced ?? frame, cb)
            if enhanced != nil, params.compare {
                let w = CVPixelBufferGetWidth(frame), h = CVPixelBufferGetHeight(frame)
                if baselineTexture?.width != w || baselineTexture?.height != h {
                    baselineTexture = Self.makeInputTexture(device, w, h, inputTexture.pixelFormat)
                }
                if let baseline = baselineTexture { convert(frame, into: baseline, cb) }
            } else {
                baselineTexture = nil
            }
        } else if showsTestPattern {
            encodeTestPattern(cb)
        }

        let target = fittedRect(drawable: drawableSize)
        let params = self.params
        let source = encodeCleanup(cb, params) ?? inputTexture
        var upscaled: MTLTexture?
        if params.upscaler == .metalFX, metalFXSupported,
           let (scaler, output) = scaler(outputWidth: Int(target.width), outputHeight: Int(target.height)) {
            scaler.colorTexture = source
            scaler.outputTexture = output
            scaler.encode(commandBuffer: cb)
            upscaled = output
        }
        activeMode = upscaled == nil ? .bilinear : .metalFX

        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        let pipes = pass.colorAttachments[0].texture?.pixelFormat == .rgba16Float ? hdrPipelines : sdrPipelines
        enc.setViewport(MTLViewport(originX: target.minX, originY: target.minY,
                                    width: target.width, height: target.height, znear: 0, zfar: 1))
        enc.setFragmentSamplerState(sampler, index: 0)

        /// The processed picture: upscaled (or the input, sampled bilinearly) plus sharpening.
        func drawProcessed() {
            if params.sharpness > 0 {
                var step = SIMD2<Float>(1 / Float(target.width), 1 / Float(target.height))
                var peak = Self.casPeak(sharpness: params.sharpness)
                enc.setRenderPipelineState(pipes.sharpen)
                enc.setFragmentBytes(&step, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
                enc.setFragmentBytes(&peak, length: MemoryLayout<Float>.size, index: 1)
            } else {
                enc.setRenderPipelineState(pipes.present)
            }
            enc.setFragmentTexture(upscaled ?? source, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        // The split compares stream processing; it means nothing over the idle test pattern.
        if params.compare && !showsTestPattern {
            let split = Self.compareRects(target)
            enc.setScissorRect(Self.scissor(split.left))
            enc.setRenderPipelineState(pipes.present)
            enc.setFragmentTexture(baselineTexture ?? inputTexture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.setScissorRect(Self.scissor(split.right))
            drawProcessed()
            enc.setScissorRect(Self.scissor(split.divider))
            enc.setRenderPipelineState(pipes.divider)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        } else {
            drawProcessed()
        }
        enc.endEncoding()
    }

    /// Deblock/deband `inputTexture` into `cleanTexture`; nil (nothing encoded) when both are off.
    private func encodeCleanup(_ cb: MTLCommandBuffer, _ params: RenderParams) -> MTLTexture? {
        guard params.deblock > 0 || params.deband > 0 else { return nil }
        if cleanTexture == nil {
            cleanTexture = Self.makeInputTexture(device, inputTexture.width, inputTexture.height, inputTexture.pixelFormat)
        }
        guard let clean = cleanTexture, let enc = cb.makeComputeCommandEncoder() else { return nil }
        var strengths = SIMD4<Float>(params.deblock, params.deband, Self.blockGrid(texture: inputTexture.width, decoded: decodedWidth), 0)
        enc.setComputePipelineState(cleanupPipeline)
        enc.setTexture(inputTexture, index: 0)
        enc.setTexture(clean, index: 1)
        enc.setBytes(&strengths, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        dispatch(enc, clean)
        enc.endEncoding()
        return clean
    }

    /// The codec's 8×8 block grid in input-texture pixels: wider after an ML upscale (e.g. 12 px at 1.5×).
    static func blockGrid(texture: Int, decoded: Int) -> Float {
        decoded > 0 ? (8 * Float(texture) / Float(decoded)).rounded() : 8
    }

    /// Exponential moving average for the GPU time readout (the first sample starts it).
    static func smoothed(_ average: Double, _ sample: Double) -> Double {
        average == 0 ? sample : average * 0.9 + sample * 0.1
    }

    /// CAS's negative lobe weight for a 0–1 sharpness (AMD FidelityFX CAS: -1 / lerp(8, 5, s)).
    static func casPeak(sharpness: Float) -> Float {
        -1 / (8 - 3 * min(1, max(0, sharpness)))
    }

    /// Splits the video rect into a bilinear left half, a MetalFX right half and a thin divider
    /// between them (pixels; the divider is ~0.2% of the width, at least 2 px).
    static func compareRects(_ target: CGRect) -> (left: CGRect, right: CGRect, divider: CGRect) {
        let mid = (target.minX + target.width / 2).rounded()
        let line = max(2, (target.width / 500).rounded())
        return (CGRect(x: target.minX, y: target.minY, width: mid - target.minX, height: target.height),
                CGRect(x: mid, y: target.minY, width: target.maxX - mid, height: target.height),
                CGRect(x: mid - (line / 2).rounded(.down), y: target.minY, width: line, height: target.height))
    }

    private static func scissor(_ r: CGRect) -> MTLScissorRect {
        MTLScissorRect(x: Int(r.minX), y: Int(r.minY), width: Int(r.width), height: Int(r.height))
    }

    /// Renders the pending (or last decoded) frame with the current `mode` into a `width`×`height`
    /// image, offscreen. For screenshots and A/B comparisons.
    public func snapshot(width: Int, height: Int) -> CGImage? {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                          mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard width > 0, height > 0, let target = device.makeTexture(descriptor: td),
              let cb = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].storeAction = .store
        encode(cb, pass: pass, drawableSize: CGSize(width: width, height: height))
        cb.commit()
        cb.waitUntilCompleted()
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            target.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Command queue on the renderer's device (tests encode offscreen with it).
    var commandQueue: MTLCommandQueue { queue }
    var inputSize: (width: Int, height: Int) { (inputTexture.width, inputTexture.height) }

    // MARK: Private

    /// NV12 → RGBA into `inputTexture` (resized to the frame), zero-copy via CVMetalTextureCache.
    private func encodeVideoFrame(_ frame: CVPixelBuffer, _ cb: MTLCommandBuffer) {
        let w = CVPixelBufferGetWidth(frame), h = CVPixelBufferGetHeight(frame)
        if w != inputTexture.width || h != inputTexture.height { setInputSize(width: w, height: h) }
        convert(frame, into: inputTexture, cb)
    }

    /// NV12 `frame` → RGBA `target` (same size), zero-copy via CVMetalTextureCache.
    private func convert(_ frame: CVPixelBuffer, into target: MTLTexture, _ cb: MTLCommandBuffer) {
        let tenBit = CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        guard let luma = planeTexture(frame, plane: 0, format: tenBit ? .r16Unorm : .r8Unorm),
              let chroma = planeTexture(frame, plane: 1, format: tenBit ? .rg16Unorm : .rg8Unorm),
              let lumaTex = CVMetalTextureGetTexture(luma), let chromaTex = CVMetalTextureGetTexture(chroma),
              let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(nv12Pipeline)
        enc.setTexture(lumaTex, index: 0)
        enc.setTexture(chromaTex, index: 1)
        enc.setTexture(target, index: 2)
        var conversion = YCbCrConversion(frame: FrameColor(frame), matrix: params.colorMatrix,
                                         range: params.colorRange, chroma: params.chroma)
        enc.setBytes(&conversion, length: MemoryLayout<YCbCrConversion>.stride, index: 0)
        dispatch(enc, target)
        enc.endEncoding()
        // Keep the CoreVideo textures (and the frame) alive until the GPU is done with them.
        cb.addCompletedHandler { _ in _ = (luma, chroma, frame) }
    }

    private func planeTexture(_ frame: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        var tex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, frame, nil, format,
            CVPixelBufferGetWidthOfPlane(frame, plane), CVPixelBufferGetHeightOfPlane(frame, plane), plane, &tex)
        return status == kCVReturnSuccess ? tex : nil
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ target: MTLTexture) {
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: (target.width + 15) / 16, height: (target.height + 15) / 16, depth: 1)
        enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
    }

    private func encodeTestPattern(_ cb: MTLCommandBuffer) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        // With Reduce motion on, the backdrop holds still.
        var t = Self.reduceMotion ? 14 : Float(CACurrentMediaTime() - startTime)
        enc.setComputePipelineState(patternPipeline)
        enc.setTexture(inputTexture, index: 0)
        enc.setBytes(&t, length: MemoryLayout<Float>.size, index: 0)
        dispatch(enc, inputTexture)
        enc.endEncoding()
    }

    private static var reduceMotion: Bool {
        #if canImport(AppKit)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        UIAccessibility.isReduceMotionEnabled
        #endif
    }

    /// The image to show on this refresh: the newest one the stream clock says is due (a frame, or an
    /// in-between image), nil when nothing new is due. Also decides whether in-between images can show.
    private func nextFrame(now: Double) -> CVPixelBuffer? {
        if lastDraw > 0 { displayInterval = Self.smoothedInterval(displayInterval, now - lastDraw) }
        lastDraw = now
        let interval = pacing.withLock { $0.clock.interval }
        let wanted = params.frameInterpolation && interpolationSupported
            && FrameInterpolator.helps(streamInterval: interval, displayInterval: displayInterval)
        interpolating.withLock { $0 = wanted }
        let item = pacing.withLock { p in p.timeline.next(now: now, delay: p.planner.delay) }
        drawnItem = item
        return item?.image
    }

    /// Running average of an interval; gaps over a quarter second (pauses) are ignored.
    static func smoothedInterval(_ average: Double, _ sample: Double) -> Double {
        guard sample > 0, sample < 0.25 else { return average }
        return average == 0 ? sample : average * 0.9 + sample * 0.1
    }

    /// Largest rect with the source aspect ratio that fits the drawable, centered (pixels).
    private func fittedRect(drawable: CGSize) -> CGRect {
        Self.fittedRect(source: CGSize(width: inputTexture.width, height: inputTexture.height), drawable: drawable)
    }

    static func fittedRect(source: CGSize, drawable: CGSize) -> CGRect {
        let srcAspect = source.width / source.height
        var w = drawable.width
        var h = (w / srcAspect).rounded()
        if h > drawable.height {
            h = drawable.height
            w = (h * srcAspect).rounded()
        }
        return CGRect(x: ((drawable.width - w) / 2).rounded(), y: ((drawable.height - h) / 2).rounded(),
                      width: w, height: h)
    }

    /// Returns a spatial scaler for input → output, rebuilding it when sizes change.
    /// Nil when the output isn't larger than the input (nothing to upscale).
    private func scaler(outputWidth: Int, outputHeight: Int) -> (MTLFXSpatialScaler, MTLTexture)? {
        guard outputWidth > inputTexture.width, outputHeight > inputTexture.height else { return nil }
        if let scaler, let scalerOutput,
           scalerOutput.width == outputWidth, scalerOutput.height == outputHeight {
            return (scaler, scalerOutput)
        }

        let desc = MTLFXSpatialScalerDescriptor()
        desc.inputWidth = inputTexture.width
        desc.inputHeight = inputTexture.height
        desc.outputWidth = outputWidth
        desc.outputHeight = outputHeight
        desc.colorTextureFormat = inputTexture.pixelFormat
        desc.outputTextureFormat = inputTexture.pixelFormat
        desc.colorProcessingMode = inputTexture.pixelFormat == .rgba16Float ? .hdr : .perceptual
        guard let newScaler = desc.makeSpatialScaler(device: device) else { return nil }

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: inputTexture.pixelFormat,
                                                          width: outputWidth, height: outputHeight, mipmapped: false)
        td.usage = newScaler.outputTextureUsage.union(.shaderRead)
        td.storageMode = .private
        guard let output = device.makeTexture(descriptor: td) else { return nil }

        newScaler.inputContentWidth = inputTexture.width
        newScaler.inputContentHeight = inputTexture.height
        scaler = newScaler
        scalerOutput = output
        return (newScaler, output)
    }

    private static func makeInputTexture(_ device: MTLDevice, _ width: Int, _ height: Int,
                                         _ format: MTLPixelFormat = .rgba8Unorm) -> MTLTexture? {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                                                          width: width, height: height, mipmapped: false)
        td.usage = [.shaderRead, .shaderWrite, .renderTarget]
        td.storageMode = .private
        return device.makeTexture(descriptor: td)
    }
}

/// Counts the images put on screen and reports them per second, over windows of about a second.
struct ShownRate {
    private var rate: Double = 0
    private var windowStart: Double = 0
    private var inWindow = 0
    private var last: Double = 0

    mutating func count(at now: Double) {
        if windowStart == 0 || now - last > 1 { (windowStart, inWindow, rate) = (now, 0, 0) }
        last = now
        inWindow += 1
        let elapsed = now - windowStart
        if elapsed >= 1 {
            rate = Double(inWindow - 1) / elapsed // intervals between the window's images
            (windowStart, inWindow) = (now, 1)
        }
    }

    /// The last full window's rate; 0 once nothing new has been shown for a second (a pause).
    func perSecond(now: Double) -> Double {
        now - last > 1 ? 0 : rate
    }
}

/// Counts images by their presentation reports. A presented time of 0 means the system dropped the image,
/// except on displays that never report times (Sidecar reports 0 for everything): after 30 zeros in a row
/// the display is taken to be one of those, and each report counts as shown at the time it arrives,
/// until a real time comes back.
struct PresentationCounts {
    var all = ShownRate()
    var generated = ShownRate()
    private(set) var handled = 0
    private(set) var unpresented = 0
    private var zerosInARow = 0

    /// Whether the image counts as shown.
    mutating func report(presentedAt time: Double, generated isGenerated: Bool, now: Double) -> Bool {
        handled += 1
        let at: Double
        if time > 0 {
            zerosInARow = 0
            at = time
        } else {
            zerosInARow += 1
            unpresented += 1
            guard zerosInARow > 30 else { return false }
            at = now
        }
        all.count(at: at)
        if isGenerated { generated.count(at: at) }
        return true
    }
}
