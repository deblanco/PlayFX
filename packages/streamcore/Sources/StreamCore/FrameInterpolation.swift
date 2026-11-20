import CObjCCatch
import CoreMedia
import CoreVideo
import Metal
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
        let processor: AnyObject // VTFrameProcessor on macOS 26+
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
    private var timestamp: Int64 = 0

    public init() {}

    deinit { end() }

    /// Encodes the images at `phases` between `previous` and `current` (each one of the processor's points
    /// for `steps`: 1 gives ½, 2 gives ¼, ½, ¾) into new NV12 buffers in `cb`, in order; nil when it can't run
    /// (unsupported format or size, the frames differ in size, or a phase isn't one of the points).
    public func encode(_ cb: MTLCommandBuffer, previous: CVPixelBuffer, current: CVPixelBuffer,
                       phases: [Float], steps: Int) -> [CVPixelBuffer]? {
        guard #available(macOS 26.0, iOS 26.0, *), Self.isAvailable, !phases.isEmpty,
              phases.allSatisfy({ Self.isPoint($0, steps: steps) }),
              CVPixelBufferGetPixelFormatType(current) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPixelFormatType(previous) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return nil }
        let w = CVPixelBufferGetWidth(current), h = CVPixelBufferGetHeight(current)
        guard CVPixelBufferGetWidth(previous) == w, CVPixelBufferGetHeight(previous) == h else { return nil }
        guard start(width: w, height: h, steps: steps) else { return nil }
        // Timestamps on a grid fine enough for every point: the pair is `scale` ticks apart.
        let scale = Int64(1 << steps)
        timestamp += scale
        var outputs: [CVPixelBuffer] = []
        var destinations: [VTFrameProcessorFrame] = []
        guard let running = sessions[steps], let processor = running.processor as? VTFrameProcessor else { return nil }
        let pool = running.pool
        for phase in phases {
            var output: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output,
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
        // VideoToolbox can throw an Objective-C exception from inside this call (seen once in a 40-minute
        // session: "insertObject: object cannot be nil"), which would end the app. Caught: this pair gets no
        // images, and the session starts over with the next pair (a size that keeps failing is dropped by
        // the lane).
        if let reason = playfx_catch({ processor.process(with: cb, parameters: parameters) }) {
            Log.error(.renderer, "Frame interpolation failed at \(w)x\(h) (\(reason)); starting its session over")
            (sessions.removeValue(forKey: steps)?.processor as? VTFrameProcessor)?.endSession()
            return nil
        }
        return outputs
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
        if #available(macOS 26.0, iOS 26.0, *), Self.isAvailable {
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
        var newPool: CVPixelBufferPool?
        let processor = VTFrameProcessor()
        guard let config = VTLowLatencyFrameInterpolationConfiguration(frameWidth: w, frameHeight: h, numberOfInterpolatedFrames: steps),
              (try? processor.startSession(configuration: config)) != nil,
              CVPixelBufferPoolCreate(nil, nil, Self.metalCompatible(config.destinationPixelBufferAttributes) as CFDictionary,
                                      &newPool) == kCVReturnSuccess, let newPool else {
            failed.insert("\(sizeKey)/\(steps)")
            Log.warning(.renderer, "Frame interpolation couldn't start for \(sizeKey) streams (\(steps == 1 ? "halves" : "quarters"))")
            return false
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

    private func end() {
        if #available(macOS 26.0, iOS 26.0, *) {
            for running in sessions.values { (running.processor as? VTFrameProcessor)?.endSession() }
        }
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
