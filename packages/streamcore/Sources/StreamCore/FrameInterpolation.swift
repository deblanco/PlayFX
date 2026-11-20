import CoreMedia
import CoreVideo
import VideoToolbox

/// "Frame interpolation": Apple's low-latency frame interpolation (VideoToolbox, macOS 26+) makes images
/// between two of the game's pictures, one for each screen refresh between them, so the screen shows as many
/// different images as it refreshes (a 30 fps game at 60 on a 60 Hz screen and at 120 on a 120 Hz one; a
/// 60 fps game at 75 on a 75 Hz screen). The cost is that real pictures land later (the images between two
/// can't exist before the second does), so it's off by default.
public final class FrameInterpolator {
    /// Whether this OS and Mac can run it at all. Not in a virtual machine: VideoToolbox reports it
    /// supported there, then crashes the process when it runs (seen on GitHub's macOS runners).
    public static var isAvailable: Bool {
        if #available(macOS 26.0, iOS 26.0, *) {
            return !isVirtualMachine && VTLowLatencyFrameInterpolationConfiguration.isSupported
        }
        return false
    }

    /// In-between images only help if the screen refreshes clearly more often than the game makes pictures
    /// (`streamInterval`: the game's interval when known); otherwise they'd just replace real frames. The
    /// game's measured rate wobbles with an uneven cadence (a 50 fps game on 60 Hz reads 1.18× or 1.27×), so
    /// while `current` (they're being made) they stay on down to `keepRatio`.
    static func helps(streamInterval: Double, displayInterval: Double, current: Bool = false) -> Bool {
        streamInterval > 0 && displayInterval > 0
            && streamInterval >= displayInterval * (current ? keepRatio : minimumRatio)
    }

    /// How many screen refreshes per frame there must be at least: with fewer, most refreshes would show a
    /// real frame anyway (a 60 fps game on a 60 Hz screen). From 1.2 (60 fps on 75 Hz) each refresh between
    /// two frames gets an image of its own moment, which also evens out the uneven 1-or-2-refresh rhythm.
    static let minimumRatio = 1.2
    /// Once on, kept down to here: below the wobble of a game near `minimumRatio`, above a 60 fps game on a
    /// 60 Hz screen that misses a picture in 11 (1.09×).
    static let keepRatio = 1.1

    /// A running VideoToolbox session and its output buffers.
    private struct Running {
        let processor: GuardedProcessor
        let pool: CVPixelBufferPool
    }
    /// One session per number of points (halves, quarters) for `size`, kept while the size stays: the renderer
    /// moves between halves and quarters as the screen's rate moves (a ProMotion screen), and a new session
    /// builds its model for a second or two with no images meanwhile.
    private var sessions: [Int: Running] = [:]
    private var size: (width: Int, height: Int)?
    /// Sessions started so far (tests: switching back and forth mustn't start new ones).
    private(set) var sessionsStarted = 0
    private var failed: Set<String> = []
    /// Sizes (with steps) that made images in this run, and fresh processors' errors at ones that never did.
    private var sizes = ProcessorSizes()
    private var timestamp: Int64 = 0
    private let health: VideoProcessorHealth
    private let available: Bool
    private let makeProcessor: () -> VideoProcessing?

    public convenience init() { self.init(health: .interpolation) }

    /// `available` and `makeProcessor`: VideoToolbox in the app, stand-ins in tests.
    init(health: VideoProcessorHealth, available: Bool = FrameInterpolator.isAvailable,
         makeProcessor: @escaping () -> VideoProcessing? = makeVTProcessor) {
        self.health = health
        self.available = available
        self.makeProcessor = makeProcessor
    }

    deinit { end() }

    /// Whether it's off for the rest of the run: its video processor kept failing.
    var hasFailed: Bool { health.isOff }

    /// The images at `phases` between `previous` and `current` (each one of the processor's points for `steps`:
    /// 1 gives ½, 2 gives ¼, ½, ¾), made by the time it returns into new NV12 buffers, in order; nil when it can't
    /// run (unsupported format or size, the frames differ in size, or a phase isn't one of the points) or the
    /// processor failed on this pair (a fresh one starts with the next).
    public func make(previous: CVPixelBuffer, current: CVPixelBuffer, phases: [Float], steps: Int) -> [CVPixelBuffer]? {
        guard #available(macOS 26.0, iOS 26.0, *), available, !phases.isEmpty,
              phases.allSatisfy({ Self.isPoint($0, steps: steps) }),
              CVPixelBufferGetPixelFormatType(current) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPixelFormatType(previous) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return nil }
        guard !health.isOff else { end(); return nil }
        let w = CVPixelBufferGetWidth(current), h = CVPixelBufferGetHeight(current)
        guard CVPixelBufferGetWidth(previous) == w, CVPixelBufferGetHeight(previous) == h else { return nil }
        guard start(width: w, height: h, steps: steps), let running = sessions[steps] else { return nil }
        // Timestamps on a grid fine enough for every point: the pair is `scale` ticks apart.
        let scale = Int64(1 << steps)
        timestamp += scale
        var outputs: [CVPixelBuffer] = []
        var destinations: [VTFrameProcessorFrame] = []
        for phase in phases {
            var output: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, running.pool, &output) == kCVReturnSuccess, let output,
                  let frame = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: CMTime(
                      value: timestamp - scale + Int64((phase * Float(scale)).rounded()), timescale: 240))
            else { return nil }
            // Keep the colorimetry so the NV12 conversion still reads the stream's matrix and siting.
            CVBufferPropagateAttachments(current, output)
            outputs.append(output)
            destinations.append(frame)
        }
        guard let before = VTFrameProcessorFrame(buffer: previous, presentationTimeStamp: CMTime(value: timestamp - scale, timescale: 240)),
              let after = VTFrameProcessorFrame(buffer: current, presentationTimeStamp: CMTime(value: timestamp, timescale: 240)),
              let parameters = VTLowLatencyFrameInterpolationParameters(sourceFrame: after, previousFrame: before,
                                                                        interpolationPhase: phases, destinationFrames: destinations)
        else { return nil }
        let key = "\(w)x\(h)/\(steps)"
        switch running.processor.process(parameters) {
        case .done:
            sizes.worked(key)
            return outputs
        case .refused:
            // Never made anything at this size: VideoToolbox refuses it (960×540, say) once a second fresh
            // processor errs too, and it's not asked for again; until then a fault that passed.
            sessions.removeValue(forKey: steps)?.processor.retire()
            if sizes.refuses(key) {
                failed.insert(key)
                Log.warning(.renderer, "Frame interpolation can't make images at \(w)x\(h); not using that size")
            } else {
                Log.warning(.renderer, "Frame interpolation's first pair at \(w)x\(h) failed; trying a fresh session")
            }
            return nil
        case .failed:
            // This pair gets no images; the next starts a fresh processor. One that raised an exception is never
            // called again (see `GuardedProcessor`), and a feature that keeps failing turns itself off.
            Log.error(.renderer, "Frame interpolation failed at \(w)x\(h); starting its session over")
            sessions.removeValue(forKey: steps)?.processor.retire()
            return nil
        }
    }

    /// Whether `phase` is one of the points the processor makes for `steps` (2^steps − 1 evenly spaced ones).
    static func isPoint(_ phase: Float, steps: Int) -> Bool {
        let points = Float(1 << steps)
        let scaled = phase * points
        return phase > 0 && phase < 1 && abs(scaled - scaled.rounded()) < 1e-4
    }

    /// Starts the sessions for halves and quarters (building each model, 1–2 s the first time for a size) ahead
    /// of the first pair, so neither the first pair nor a later switch between them waits for one.
    public func prepare(width: Int, height: Int) {
        if #available(macOS 26.0, iOS 26.0, *), available, !health.isOff {
            for steps in [1, 2] { _ = start(width: width, height: height, steps: steps) }
        }
    }

    /// A session for this size and number of points, started if needed; false when it can't run at this size.
    @available(macOS 26.0, iOS 26.0, *)
    private func start(width w: Int, height h: Int, steps: Int) -> Bool {
        let sizeKey = "\(w)x\(h)"
        guard !failed.contains("\(sizeKey)/\(steps)") else { return false }
        if size?.width != w || size?.height != h {
            end()
            size = (w, h)
        }
        if sessions[steps] != nil { return true }
        let key = "\(sizeKey)/\(steps)", proven = sizes.hasWorked(key)
        /// It can't start here: never tried again, unless it worked here before (then a fault: counted, and tried
        /// again with the next pair).
        func refuse(_ reason: String) -> Bool {
            if proven {
                health.failed("start at \(sizeKey): \(reason)")
                return false
            }
            failed.insert(key)
            Log.warning(.renderer, "Frame interpolation couldn't start for \(sizeKey) streams (\(steps == 1 ? "halves" : "quarters"))")
            return false
        }
        guard let config = VTLowLatencyFrameInterpolationConfiguration(frameWidth: w, frameHeight: h, numberOfInterpolatedFrames: steps),
              let made = makeProcessor() else { return refuse("no processor") }
        let processor = GuardedProcessor(made, health: health, proven: proven)
        switch processor.start(config) {
        case .done: break
        case .threw, .notCalled: return false // quarantined and counted, or the feature is off: a fresh one for the next pair
        case .failed(let reason): return refuse(reason)
        }
        var newPool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, Self.metalCompatible(config.destinationPixelBufferAttributes) as CFDictionary,
                                      &newPool) == kCVReturnSuccess, let newPool else {
            processor.retire()
            return refuse("no buffer pool")
        }
        sessions[steps] = Running(processor: processor, pool: newPool)
        sessionsStarted += 1
        Log.info(.renderer, "Frame interpolation on for \(sizeKey) streams, at \(steps == 1 ? "halves" : "quarters")")
        return true
    }

    private static func metalCompatible(_ attributes: [String: Any]) -> [String: Any] {
        var attrs = attributes
        attrs[kCVPixelBufferMetalCompatibilityKey as String] = true
        return attrs
    }

    /// Retires every session: their processors are ended later, off this queue (see `GuardedProcessor.retire`).
    private func end() {
        for running in sessions.values { running.processor.retire() }
        sessions.removeAll()
        size = nil
    }
}

/// Whether this Mac is a virtual machine, where some VideoToolbox processors don't really run.
/// `STREAMCORE_SIMULATE_VM=1` makes a real Mac behave like one, to see locally what CI's coverage sees.
let isVirtualMachine: Bool = {
    if ProcessInfo.processInfo.environment["STREAMCORE_SIMULATE_VM"] == "1" { return true }
    var present: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("kern.hv_vmm_present", &present, &size, nil, 0) == 0 && present == 1
}()
