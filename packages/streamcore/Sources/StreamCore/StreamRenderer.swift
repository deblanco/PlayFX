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
    /// Apple's ML super-resolution on the decoded frame first (macOS 26+, 1080p and lower streams).
    public var mlUpscale = false
    /// "Frame interpolation": an interpolated frame between each pair of stream frames (macOS 26+), when the
    /// screen refreshes at least twice as fast as the stream. Adds one screen refresh of latency. VideoToolbox's
    /// on SDR streams, MetalFX's on HDR ones.
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
        didSet {
            applyColorSpace()
            upscaleTarget.withLock { $0.enabled = params.mlUpscale }
        }
    }
    /// Upscaler actually used for the last frame (MetalFX is skipped when not upscaling).
    public private(set) var activeMode: UpscaleMode = .bilinear
    /// Whether Apple's ML super-resolution can run on this Mac and OS.
    public var mlSupported: Bool { upscaleLane != nil }
    /// Whether the last frame shown went through ML super-resolution.
    public private(set) var mlActive = false
    /// ML upscaling, on its own lane ahead of the stream clock (nil where it can't run).
    private let upscaleLane: UpscaleLane?
    /// Whether to upscale decoded frames, and the screen area they're shown in (from the last draw), read
    /// where frames arrive.
    private let upscaleTarget = OSAllocatedUnfairLock(initialState: (enabled: false, drawable: CGSize.zero))
    /// Counts streams (see `streamFrameRate`): a frame the lane finishes after a new stream started belongs
    /// to the old one, and its index would hold up the new stream's clock.
    private let upscaleGeneration = OSAllocatedUnfairLock(initialState: 0)
    /// Whether frame interpolation can run on this Mac and OS: on SDR streams (VideoToolbox's), on HDR ones (MetalFX's),
    /// and on either (the setting can be turned on).
    let sdrInterpolationSupported: Bool
    public let hdrInterpolationSupported: Bool
    public var interpolationSupported: Bool { sdrInterpolationSupported || hdrInterpolationSupported }
    /// Whether in-between images reached the screen in the last second.
    public var interpolationActive: Bool { presented.withLock { $0.generated.perSecond(now: CACurrentMediaTime()) > 0 } }
    /// What each optional step did with the last frame, and why an idle one is idle (for the stats line).
    public var pipeline: PipelineState { pipelineState.withLock { $0 } }
    private let pipelineState = OSAllocatedUnfairLock(initialState: PipelineState())
    /// The stream's nominal frame rate (30 or 60), which its clock runs on. Setting it starts pacing over
    /// (counts included), so set it once per stream, before its first frame.
    public var streamFrameRate: Double {
        get { pacing.withLock { $0.clock.fps } }
        set {
            upscaleGeneration.withLock { $0 += 1 }
            pacing.withLock { $0 = Pacing(fps: newValue) }
            lane?.resetCounts()
            lane?.releaseHDREngines()
            upscaleLane?.reset()
        }
    }
    /// Frames shown by their stream clock (see FramePacing.swift), and the in-between images made for them.
    private struct Pacing {
        var clock: StreamClock
        var timeline = FrameTimeline<CVPixelBuffer>(capacity: 16)
        var planner = DelayPlanner()
        var rungs: RungSelector?
        /// Whether an engine here takes the stream's frames (the newest one's kind; nil before any): not 10-bit SDR
        /// frames (the HDR setting on, an SDR game), which neither does.
        var taken: Bool?
        /// The newest frame is 10-bit SDR (the HDR setting on, an SDR game): why no engine takes it.
        var tenBitSDR = false
        var lastReal: (frame: CVPixelBuffer, time: Double)?
        var nextIndex: UInt64 = 0
        /// The newest frame's arrival, and what it was when the lane last made an image (nil before any).
        var lastArrival = 0.0
        var lastMade: Double?
        /// Times the clock started over (a gap, a jump of frames, or a frame too far off it to slide to).
        var restarts = 0
        /// The last decoded frame (repeat or not), to tell a repeat of it; the game's rate from its new
        /// pictures; even times for them; and frames that repeated the one before.
        var lastDecoded: CVPixelBuffer?
        /// The last decoded frame handed to ML, including one still in the model. With ML on, a repeat is
        /// told against this: `lastDecoded` only moves once a frame reaches the clock, which is after the model.
        var submitted: CVPixelBuffer?
        var content = ContentRate()
        var cadence = CadenceClock()
        var repeats = RepeatDetector()
        var repeated = 0
        /// The screen's fastest recent time between refreshes (see `InBetween.fastest`), for halves or quarters.
        var refreshInterval = 0.0
        /// Where in the stream's time the screen is (see `Playhead`); the last picture up to which every image
        /// is in the timeline; and the pair the lane has in hand.
        var playhead = Playhead()
        var populated: Double?
        var handoff = LaneHandoff()
        /// Halves or quarters (see `InBetween.steps`), and when the game's last new picture arrived.
        var steps = 2
        var lastPicture = -Double.infinity
        /// The Wi-Fi's periodic stall, from when frames arrive (before ML upscaling).
        var stalls = StallPattern()
        init(fps: Double) { clock = StreamClock(fps: fps) }

        /// Seconds between the pictures images are made between: the game's when measured, else the stream's.
        var sourceInterval: Double { content.interval ?? clock.interval }
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
    /// Frames that repeated the picture before them (a game slower than the stream).
    public var repeatedFrames: Int { pacing.withLock { $0.repeated } }
    /// Frames and in-between images that were never shown: a later one was due first. For in-between images
    /// that's by design when there are more of them than refreshes (quarters on a 75 Hz screen), or when the
    /// playhead passes several at once, so they aren't counted as missed. Real frames the ML upscaler had to drop
    /// count as skipped too.
    public var skippedFrames: Int { pacing.withLock { $0.timeline.skippedReal } + (upscaleLane?.dropped ?? 0) }
    public var skippedGenerated: Int { pacing.withLock { $0.timeline.skippedGenerated } }
    /// Pairs that got no in-between images: the lane was still busy with the last pair, or the size gave
    /// nothing. Scene cuts are left out (no image is wanted there).
    public var missedInterpolations: Int { lane.map { $0.busyPairs + $0.failedPairs } ?? 0 }
    /// The size in-between images are made at now, and what one costs (90th percentile, ms).
    public var interpolationSize: (width: Int, height: Int)? { pacing.withLock { $0.rungs?.size } }
    public var interpolationCostMilliseconds: Double { pacing.withLock { $0.planner.generationCost * 1000 } }
    /// Where the last in-between image's time went (ms), for the bench.
    public var interpolationStages: String {
        guard let s = lane?.stages else { return "—" }
        return String(format: "cut %.1f · scale %.1f · interpolate %.1f · blend %.1f", s.cut, s.scale, s.interpolate, s.blend)
    }
    /// How far behind the stream clock images are shown now (ms): jitter cover, plus interpolation's time.
    public var pacingDelayMilliseconds: Double { pacing.withLock { $0.planner.delay * 1000 } }
    /// What the delay is made of, for diagnosis: lateness behind the clock (p90, ms), the in-between
    /// image's cost (p90, ms), and how often the clock started over.
    public var pacingParts: (latenessMs: Double, costMs: Double, restarts: Int) {
        pacing.withLock { ($0.planner.jitter * 1000, $0.planner.generationCost * 1000, $0.restarts) }
    }
    /// Whether frames keep stopping and coming in a burst at a steady period, as AirDrop's radio makes them
    /// (see `StallPattern`).
    public var wifiStalls: Bool { pacing.withLock { $0.stalls.period != nil } }
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

    public convenience init?(inputWidth: Int = 1280, inputHeight: Int = 720) {
        self.init(inputWidth: inputWidth, inputHeight: inputHeight,
                  upscaler: MLSuperResolution.isAvailable ? MLSuperResolution() : nil)
    }

    /// `upscaler`: what ML upscaling runs (nil: none on this Mac); `stallLimit`: see `UpscaleLane`; `interpolation`:
    /// whether frame interpolation can run on SDR and HDR streams (tests: as if it couldn't); `engines`: the lane's,
    /// VideoToolbox's and MetalFX's unless given (tests: stand-ins).
    init?(inputWidth: Int, inputHeight: Int, upscaler: FrameUpscaler?, stallLimit: Double = 15,
          interpolation: (sdr: Bool, hdr: Bool) = (FrameInterpolator.isAvailable, HDRFrameInterpolator.isAvailable),
          engines: (sdr: (() -> MiddleFrameMaker)?, hdr: (() -> MiddleFrameMaker)?) = (nil, nil)) {
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
        sdrInterpolationSupported = interpolation.sdr
        hdrInterpolationSupported = interpolation.hdr
        self.lane = interpolation.sdr || interpolation.hdr
            ? InterpolationLane(device: device, engine: engines.sdr, hdrEngine: engines.hdr) : nil
        self.upscaleLane = upscaler.map { UpscaleLane(engine: $0, stallLimit: stallLimit) }
        Log.info(.renderer, "Renderer on \(device.name): MetalFX \(metalFXSupported ? "yes" : "no"), "
            + "ML super-resolution \(upscaleLane != nil ? "yes" : "no")")
        super.init()
        lane?.onImage = { [pacing] image in
            pacing.withLock { p in
                p.lastMade = p.lastArrival
                p.timeline.add(TimedImage(image: image.buffer, time: image.time, generated: true, arrival: CACurrentMediaTime()))
                Self.trace("I \(CACurrentMediaTime()) \(image.time) \(image.cost) \(image.size.width) \(p.planner.delay)")
                // Once per pair (its images come out together), and not while a model is being built: that's
                // not the size's real cost.
                guard image.last, !image.warmingUp else { return }
                p.planner.observe(cost: image.cost)
                let budget = p.sourceInterval * 0.75
                p.rungs?.observe(cost: image.cost, budget: budget, now: CACurrentMediaTime())
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
    /// says, not when it arrives. With frame interpolation on, a frame that repeats the last picture (a game
    /// slower than the stream) is left out, and the images between the game's last two pictures, one per
    /// screen refresh between them, are made on the interpolation lane meanwhile. The first frame replaces
    /// the idle backdrop. With ML upscaling on, a new picture is upscaled on its own lane first and joins the
    /// stream clock when that's done, so a refresh never waits for the model. A repeat of that picture does
    /// not run the model again: it takes the last upscaled frame, and with interpolation on it is left out.
    public func display(_ frame: CVPixelBuffer, index: UInt64? = nil, arrival: Double = CACurrentMediaTime()) {
        showsTestPattern = false
        let (i, stalls) = pacing.withLock { p in
            let i = index ?? p.nextIndex
            p.nextIndex = i + 1
            // The stall pattern's period when it started (or nil when it ended) with this frame.
            let change: Double?? = p.stalls.add(index: i, arrival: arrival) ? .some(p.stalls.period) : .none
            return (i, change)
        }
        if let stalls {
            if let period = stalls {
                Log.warning(.renderer, "Frames stop and come in a burst about every \(Int(period * 1000)) ms: the Wi-Fi is stalling")
            } else {
                Log.info(.renderer, "The Wi-Fi's regular stalls stopped")
            }
        }
        let (enabled, drawable) = upscaleTarget.withLock { ($0.enabled, $0.drawable) }
        let size = CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
        let target = Self.fittedRect(source: size, drawable: drawable).size
        // Only a frame the model can make bigger goes to the lane. Any other skips it, unless the lane still
        // holds earlier frames: then it queues behind them, so frames reach the clock in order, one at a time.
        let upscale = enabled && Self.interpolates(frame) && target.width > size.width && !(upscaleLane?.hasFailed ?? false)
        // A frame stuck in the model (a call that doesn't return) mustn't hold the picture: frames go around the
        // lane, and whatever it finishes later is left out as if from the stream before.
        let stalled = upscaleLane?.isStalled() ?? false
        if stalled { upscaleGeneration.withLock { $0 += 1 } }
        // Not through the model: the next frame that is mustn't be told against one from before this stretch.
        if !upscale || stalled { pacing.withLock { $0.submitted = nil } }
        guard let upscaleLane, !stalled, upscale || upscaleLane.isBusy else {
            intake(frame, decoded: frame, index: i, arrival: arrival, decodedAt: arrival)
            return
        }
        // Read once: a repeat takes the branch this saw. The lane only goes idle after its callback returns,
        // so an idle lane isn't inside `intake`, and a busy one keeps this frame behind the one it holds.
        let busy = upscaleLane.isBusy
        if upscale {
            switch takeRepeat(frame, index: i, arrival: arrival, laneBusy: busy) {
            case .samePicture:
                // It takes the last upscale, so if the clock starts over at it (and it shows as a new picture)
                // it's the size the frames around it are. With interpolation on it's otherwise left out.
                if busy {
                    // Behind the frame already in the model, so the clock still sees frames in order.
                    submit(frame, to: upscaleLane, target: target, upscale: false, reuse: true, index: i,
                           arrival: arrival, repeated: true)
                } else {
                    intake(upscaleLane.lastUpscaled ?? frame, decoded: frame, index: i, arrival: arrival,
                           decodedAt: arrival, repeated: true)
                }
                return
            case .newPicture:
                submit(frame, to: upscaleLane, target: target, upscale: true, index: i, arrival: arrival, repeated: false)
                return
            case .undecided:
                break
            }
        }
        submit(frame, to: upscaleLane, target: target, upscale: upscale, index: i, arrival: arrival, repeated: nil)
    }

    /// Hands `frame` to the lane. `done` runs on the lane's queue once it's this frame's turn; a frame from
    /// the stream before (the generation moved) is left out. `repeated` nil lets `intake` classify it.
    private func submit(_ frame: CVPixelBuffer, to lane: UpscaleLane, target: CGSize, upscale: Bool, reuse: Bool = false,
                        index i: UInt64, arrival: Double, repeated: Bool?) {
        let generation = upscaleGeneration.withLock { $0 }
        lane.submit(frame, target: target, upscale: upscale, reuse: reuse) { [weak self] upscaled in
            guard let self, upscaleGeneration.withLock({ $0 }) == generation else { return }
            // On the clock from when it's ready: the delay planner then covers the model's time.
            intake(upscaled ?? frame, decoded: frame, index: i, arrival: CACurrentMediaTime(), decodedAt: arrival,
                   repeated: repeated)
        }
    }

    /// How a frame ML would upscale compares with the last one submitted. `.undecided` still runs the model
    /// (the first frame, a size change, a frame out of order, or a real gap with the lane idle) and `intake`
    /// classifies it. A gap while the lane is busy is classified here: the frame already in the model is the
    /// one the clock hasn't taken yet, and this one repeats it.
    private enum SubmittedRepeat { case samePicture, newPicture, undecided }

    private func takeRepeat(_ frame: CVPixelBuffer, index: UInt64, arrival: Double, laneBusy: Bool) -> SubmittedRepeat {
        enum Peek { case classify(CVPixelBuffer), undecided }
        let peek: Peek = pacing.withLock { p in
            switch p.clock.wouldRestart(index: index, arrival: arrival) {
            case nil:
                return .undecided // out of order: intake drops it, so the detector stays put
            case .some(true) where !laneBusy:
                p.submitted = frame
                return .undecided
            default:
                break
            }
            if let submitted = p.submitted {
                let same = CVPixelBufferGetWidth(submitted) == CVPixelBufferGetWidth(frame)
                    && CVPixelBufferGetHeight(submitted) == CVPixelBufferGetHeight(frame)
                if !same {
                    p.repeats.reset()
                    p.submitted = frame
                    return .undecided
                }
                return .classify(submitted)
            }
            p.submitted = frame
            return .undecided
        }
        guard case .classify(let previous) = peek else { return .undecided }
        // Outside the lock: it reads both frames' luma on the CPU.
        let difference = Self.interpolates(previous) && Self.interpolates(frame)
            ? InterpolationLane.difference(previous, frame) : nil
        let repeated = pacing.withLock { p in
            p.submitted = frame
            return difference.map { p.repeats.isRepeat(difference: $0) } ?? false
        }
        return repeated ? .samePicture : .newPicture
    }

    /// The rest of `display` for `frame` (upscaled, or the decoded frame itself): onto the stream clock at
    /// `arrival`, into the timeline, and in-between images for it. `decoded` is the frame as decoded (repeats
    /// are told on it), and `decodedAt` when it arrived (for the display-latency stat). `repeated` set means
    /// `display` already classified this frame against the one it submitted; nil classifies here, which is
    /// the path with ML off. A frame `display` classified is a new picture if the clock starts over at it.
    private func intake(_ frame: CVPixelBuffer, decoded: CVPixelBuffer, index i: UInt64, arrival: Double, decodedAt: Double,
                        repeated known: Bool? = nil) {
        // HDR frames go to MetalFX's engine, 8-bit ones to VideoToolbox's; others (10-bit SDR) to neither, and for them
        // nothing changes for interpolation's sake (repeats show, no game grid).
        let hdr = FrameColor.isHDR(frame)
        let takes = hdr ? hdrInterpolationSupported : Self.interpolates(frame) && sdrInterpolationSupported
        let wanted = interpolating.withLock { $0 } && takes
        let before = pacing.withLock { p in
            defer { p.lastDecoded = decoded }
            return p.lastDecoded
        }
        // Compared outside the lock: it reads both frames' luma on the CPU (8 or 10 bits; nil across a switch between them).
        // Skipped when `display` already classified this frame, so the detector moves once.
        let difference = known != nil ? nil : before.flatMap { InterpolationLane.difference($0, decoded) }
        let pair: (previous: CVPixelBuffer, between: [InBetween.Image], steps: Int, size: (width: Int, height: Int),
                   prepare: [(width: Int, height: Int)])? =
            pacing.withLock { p in
                p.taken = takes
                p.tenBitSDR = !hdr && !Self.interpolates(frame)
                guard let stamp = p.clock.time(index: i, arrival: arrival) else { return nil }
                // A gap or a jump of frames (a late stretch only slides the clock): no images across it, and the
                // game's rate and cadence start over. What's in the timeline stays, and so does the playhead's
                // place: the clock never goes back, so nothing older than what was shown can come next.
                if stamp.restarted {
                    p.restarts += 1
                    p.lastReal = nil
                    p.content.reset()
                    p.cadence.reset()
                    p.repeats.reset()
                    p.populated = nil
                }
                // After a start-over, `known` was told against a frame from before it: the frame is the new start.
                let repeated = (stamp.restarted ? nil : known) ?? (difference.map { p.repeats.isRepeat(difference: $0) } ?? false)
                p.lastArrival = arrival
                if repeated {
                    p.repeated += 1
                    // Interpolating: nothing new to show or to make images towards; the images between the game's
                    // pictures fill its place. Otherwise it shows as before (the same picture).
                    if wanted { return nil }
                } else {
                    p.content.add(time: stamp.time, maxGap: p.clock.interval * Self.stillGap)
                    p.lastPicture = arrival
                }
                p.planner.observe(lateness: arrival - stamp.time)
                let interval = p.sourceInterval
                p.steps = InBetween.steps(interval: interval, refreshInterval: p.refreshInterval, current: p.steps,
                                          most: hdr ? HDRFrameInterpolator.maxSteps : 2)
                let steps = p.steps
                // The extra delay for in-between images only while the lane is making them: not for frames
                // it can't take (10-bit SDR, or HDR where MetalFX can't run), nor at a size the engine couldn't
                // start, where it would only add lag.
                let making = p.lastMade.map { arrival - $0 < 2 } ?? false
                let delay = p.planner.update(interval: interval, interpolating: wanted && making, lead: steps == 1 ? 0.5 : 0.75)
                Self.trace("F \(i) \(arrival) \(stamp.time) \(stamp.restarted ? 1 : 0) \(delay) \(wanted ? 1 : 0) \(repeated ? 1 : 0) \(steps) \(p.planner.jitter) \(p.planner.generationCost)")
                // Frames keep to the clock, on the game's even grid while interpolating. After a start or a break
                // the frame shows at once: the playhead goes on from it, falling back to its delay by slowing down.
                var time = stamp.time
                if wanted, !stamp.restarted {
                    time = p.cadence.time(for: time, interval: p.content.interval, streamInterval: p.clock.interval)
                } else {
                    p.cadence.reset()
                }
                p.timeline.add(TimedImage(image: frame, time: time, generated: false, arrival: decodedAt))
                if stamp.restarted { p.playhead.start(at: time) }
                // Without images towards this picture (decided below), everything up to it is there already.
                var paired = false
                defer {
                    p.lastReal = (frame, time)
                    if !paired, p.handoff.since == nil { p.populated = time }
                }
                let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
                // Not across a still stretch (a paused game sends repeats for seconds): there's no motion to
                // fill in, and the images would spread one step over the whole pause.
                guard wanted, let last = p.lastReal, time - last.time <= p.clock.interval * Self.stillGap,
                      CVPixelBufferGetWidth(last.frame) == width, CVPixelBufferGetHeight(last.frame) == height else { return nil }
                var prepare: [(width: Int, height: Int)] = []
                // Sizes from the decoded frame: an upscaled one is scaled back down to them (VideoToolbox's fast
                // path at 720p and below), never interpolated at its upscaled size. HDR pairs at their own size only.
                let base = (width: CVPixelBufferGetWidth(decoded), height: CVPixelBufferGetHeight(decoded))
                if p.rungs.map({ $0.rungs[0] != base || $0.scales == hdr }) ?? true {
                    p.rungs = RungSelector(width: base.width, height: base.height, scales: !hdr)
                    prepare = p.rungs?.rungs ?? []
                }
                guard var rungs = p.rungs else { return nil }
                if let lane, lane.isBroken(rungs.size, hdr: hdr) {
                    guard rungs.markBroken() else { p.rungs = rungs; return nil } // nothing left that works
                }
                p.rungs = rungs
                let between = InBetween.images(start: last.time, end: time, steps: steps)
                guard !between.isEmpty, lane != nil else { return nil }
                paired = true
                p.handoff.handing(at: arrival)
                return (last.frame, between, steps, rungs.size, prepare)
            }
        guard let pair, let lane else { return }
        for size in pair.prepare.dropFirst() { lane.prepare(size: size, hdr: hdr) }
        // The playhead waits before this pair until its images are in the timeline (or it ends without any).
        let taken = lane.submit(previous: pair.previous, current: frame, between: pair.between, steps: pair.steps,
                                size: pair.size) { [pacing] in
            pacing.withLock { p in
                if p.handoff.finished() { p.populated = p.lastReal?.time }
            }
        }
        pacing.withLock { p in
            if p.handoff.handed(taken: taken, at: arrival) { p.populated = p.lastReal?.time }
        }
    }

    /// Stream intervals without a new picture after which the game counts as holding it (a pause): no images
    /// are made across the gap, and the game's rate starts over.
    static let stillGap = 4.5

    /// `STREAMCORE_PACING_TRACE=<file>`: a line per stream frame (`F`), made image (`I`) and refresh (`R`), to
    /// measure what the screen showed (see docs/FRAME_INTERPOLATION.md, "Pacing trace").
    private static let traceHandle: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["STREAMCORE_PACING_TRACE"] else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()
    private static func trace(_ line: String) { traceHandle?.write((line + "\n").data(using: .utf8)!) }

    /// Whether VideoToolbox's frame interpolation (and ML upscaling) takes this frame: 8-bit 4:2:0, video range. HDR
    /// frames go to MetalFX's frame interpolation instead (`HDRFrameInterpolator`).
    static func interpolates(_ frame: CVPixelBuffer) -> Bool {
        CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    /// Waits until the interpolation lane has finished the pair in hand (tests).
    func waitForInterpolation() { lane?.waitUntilIdle() }

    /// Waits until every frame handed to `display` so far is through ML upscaling and on the stream clock
    /// (tests, offscreen renders).
    public func waitForUpscaling() { upscaleLane?.waitUntilIdle() }

    /// Tests: whether in-between images are being made. `nextFrame` normally decides this from the screen's
    /// rate; a test forces it so a repeated picture can be checked without a 120 Hz display.
    func setFrameInterpolationActive(_ on: Bool) { interpolating.withLock { $0 = on } }

    /// The screen area frames are upscaled for, which each draw sets; set it ahead for an offscreen render.
    public func setUpscaleTarget(drawableSize: CGSize) { upscaleTarget.withLock { $0.drawable = drawableSize } }

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
        // Frames arriving from now on are upscaled for this screen area.
        upscaleTarget.withLock { $0.drawable = drawableSize }
        if let frame = nextFrame(now: now) {
            // Upscaled on the lane before it reached the clock (an in-between image made from upscaled frames
            // carries the decoded frame too): the decoded one is the compare view's baseline.
            let decoded = UpscaleLane.decodedFrame(of: frame)
            let raw = decoded ?? frame
            mlActive = decoded != nil
            let width = CVPixelBufferGetWidth(raw), height = CVPixelBufferGetHeight(raw)
            let mlState = Self.mlState(enabled: params.mlUpscale, supported: mlSupported, ran: decoded != nil,
                                       width: width, height: height, eightBit: Self.interpolates(raw),
                                       refused: upscaleLane?.status.refused ?? false,
                                       failed: upscaleLane?.hasFailed ?? false, stalled: upscaleLane?.isStalled() ?? false)
            pipelineState.withLock { $0.ml = mlState }
            decodedWidth = width
            encodeVideoFrame(frame, cb)
            // An in-between image carries the later frame it was made towards, not a decoded frame of its own
            // moment: it is its own baseline, so both halves show the same moment.
            let baselineFrame = drawnItem?.generated == true ? frame : decoded
            if decoded != nil, params.compare, let baselineFrame {
                let bw = CVPixelBufferGetWidth(baselineFrame), bh = CVPixelBufferGetHeight(baselineFrame)
                if baselineTexture?.width != bw || baselineTexture?.height != bh {
                    baselineTexture = Self.makeInputTexture(device, bw, bh, inputTexture.pixelFormat)
                }
                if let baseline = baselineTexture { convert(baselineFrame, into: baseline, cb) }
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
        let upscale = Self.upscaleState(selected: params.upscaler, supported: metalFXSupported, ran: upscaled != nil,
                                        source: (inputTexture.width, inputTexture.height), target: target.size)
        pipelineState.withLock { $0.upscale = upscale }

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
                var ceiling = hdrActive ? Float.greatestFiniteMagnitude : 1
                enc.setFragmentBytes(&ceiling, length: MemoryLayout<Float>.size, index: 2)
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
        var strengths = SIMD4<Float>(params.deblock, params.deband, Self.blockGrid(texture: inputTexture.width, decoded: decodedWidth),
                                     hdrActive ? .greatestFiniteMagnitude : 1)
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
        let refreshInterval = displayInterval
        // For the stream as it is now: VideoToolbox's engine on SDR, MetalFX's on HDR.
        let hdr = hdrActive
        let (interval, streamInterval, gameInterval, still, taken, tenBitSDR, exhausted) = pacing.withLock { p in
            p.refreshInterval = InBetween.fastest(p.refreshInterval, refreshInterval)
            // No size works for this kind of stream (HDR has only its own): off for it, as when the engine keeps failing.
            let exhausted = p.rungs.map { $0.exhausted && $0.scales != hdr } ?? false
            return (p.sourceInterval, p.clock.interval, p.content.interval, now - p.lastPicture > p.clock.interval * Self.stillGap,
                    p.taken ?? true, p.tenBitSDR, exhausted)
        }
        var state = Self.interpolationState(enabled: params.frameInterpolation, hdr: hdr,
                                            supported: hdr ? hdrInterpolationSupported : sdrInterpolationSupported,
                                            taken: taken, tenBitSDR: tenBitSDR,
                                            failed: (hdr ? lane?.hdrHasFailed : lane?.hasFailed) ?? false || exhausted,
                                            streamInterval: interval, displayInterval: displayInterval,
                                            current: interpolating.withLock { $0 })
        let wanted = state == .on
        // Nothing to make while the game holds its picture; said apart from "not making any".
        if wanted, still { state = .still }
        interpolating.withLock { $0 = wanted }
        let displayHz = displayInterval > 0 ? 1 / displayInterval : 0
        pipelineState.withLock {
            $0.interpolation = state
            $0.displayHz = displayHz
            $0.streamFps = streamInterval > 0 ? 1 / streamInterval : 0
            $0.gameFps = gameInterval.map { 1 / $0 } ?? 0
        }
        let item = pacing.withLock { p in
            // While images are made between the game's pictures, the playhead waits for them, but not for
            // longer than the delay and a picture's time.
            let limit = wanted ? Playhead.limit(populated: p.populated, newest: p.lastReal?.time, pendingSince: p.handoff.since,
                                                now: now, wait: p.planner.delay + p.sourceInterval,
                                                step: p.sourceInterval / Double(1 << p.steps)) : nil
            return p.timeline.next(now: p.playhead.advance(now: now, delay: p.planner.delay, limit: limit,
                                                           refresh: refreshInterval), delay: 0)
        }
        Self.trace("R \(now) \(item.map { "\($0.time) \($0.generated ? 1 : 0)" } ?? "- -") \(refreshInterval)")
        drawnItem = item
        return item?.image
    }

    /// Whether in-between images can be made and shown, and if not, why; `current`: whether they are now;
    /// `hdr`: the stream is HDR (MetalFX's engine) rather than SDR (VideoToolbox's); `supported`: that engine runs on
    /// this Mac; `taken`: an engine takes the newest frame, which `tenBitSDR` says it isn't because it's 10-bit SDR
    /// (the HDR setting on, an SDR game); `failed`: whether it's off for the rest of the run (its engine kept failing)
    /// or for this stream (no size works for it; the lane keeps sizes that didn't work dropped for the run).
    static func interpolationState(enabled: Bool, hdr: Bool = false, supported: Bool, taken: Bool = true,
                                   tenBitSDR: Bool = false, failed: Bool = false, streamInterval: Double,
                                   displayInterval: Double, current: Bool = false) -> PipelineState.Interpolation {
        guard enabled else { return .off }
        guard supported else { return hdr ? .hdrUnsupported : .unsupported }
        // Not taken otherwise only for a frame or two while the stream switches between SDR and HDR.
        guard taken else { return tenBitSDR ? .sdrInHdr : .unsupported }
        guard !failed else { return .failed }
        return FrameInterpolator.helps(streamInterval: streamInterval, displayInterval: displayInterval,
                                       current: current) ? .on : .screen
    }

    /// What the upscale step did: MetalFX, bilinear by choice, or why MetalFX was skipped.
    static func upscaleState(selected: UpscaleMode, supported: Bool, ran: Bool, source: (width: Int, height: Int),
                             target: CGSize) -> PipelineState.Upscale {
        guard selected == .metalFX else { return .bilinear }
        if ran { return .metalfx }
        guard supported else { return .unsupported }
        // MetalFX only enlarges: a picture no larger than the stream is scaled down (or 1:1) instead.
        return Int(target.width) > source.width && Int(target.height) > source.height ? .failed : .notLarger
    }

    /// What ML upscaling did with a frame, and if it was skipped, why.
    /// `failed`: it's off for the rest of the run (its video processor kept failing); `stalled`: a frame has been in
    /// the model for longer than the lane's limit (a slow first model build, or a call that doesn't return).
    static func mlState(enabled: Bool, supported: Bool, ran: Bool, width: Int, height: Int, eightBit: Bool = true,
                        refused: Bool = false, failed: Bool = false, stalled: Bool = false) -> PipelineState.ML {
        guard enabled else { return .off }
        if ran { return .on }
        guard supported else { return .unsupported }
        guard !failed else { return .failed }
        guard !stalled else { return .stalled }
        guard eightBit else { return .hdr } // the model takes 8-bit frames only
        // Apple's model takes 1080p and lower streams (larger ones in tiles), and not every size.
        if refused || MLSuperResolution.tiling(width: width, height: height) == nil { return .streamTooLarge }
        return .notLarger
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

/// What the optional picture steps are doing, so the app can say why one that's turned on is idle.
public struct PipelineState: Sendable, Equatable {
    public enum Interpolation: String, Sendable {
        /// Turned off; making in-between images; this Mac or OS can't for an SDR stream (VideoToolbox's engine); the
        /// screen doesn't refresh often enough per frame of the game to show them; on, but the game holds its picture
        /// (nothing to make); off because its engine kept failing (until the app restarts) or no size works for this
        /// stream; no engine takes its frames because they're 10-bit SDR (the HDR setting on, an SDR game); this Mac
        /// or OS can't for an HDR stream (MetalFX's engine).
        case off, on, unsupported, screen, still, failed, sdrInHdr, hdrUnsupported
    }
    public enum Upscale: String, Sendable {
        /// MetalFX ran; bilinear was chosen; MetalFX was skipped because the picture on screen isn't larger
        /// than the stream; MetalFX isn't available; MetalFX couldn't be set up for this size.
        case metalfx, bilinear, notLarger, unsupported, failed
    }
    public enum ML: String, Sendable {
        /// Turned off; ran; not available; the stream's size isn't one the model takes (larger than 1080p, or
        /// refused); the picture on screen isn't larger than the stream; an HDR (10-bit) stream; off until the
        /// app restarts because its video processor kept failing; waiting on a frame that's been in the model for
        /// longer than the lane's limit (frames go around it meanwhile).
        case off, on, unsupported, streamTooLarge, notLarger, hdr, failed, stalled
    }
    public var interpolation = Interpolation.off
    public var upscale = Upscale.bilinear
    public var ml = ML.off
    /// The screen's measured refresh rate (0 until known); the rate interpolation works from (the game's when
    /// measured, else the stream's); and the game's own rate, from its new pictures (0 until measured).
    public var displayHz = 0.0
    public var streamFps = 0.0
    public var gameFps = 0.0
}
