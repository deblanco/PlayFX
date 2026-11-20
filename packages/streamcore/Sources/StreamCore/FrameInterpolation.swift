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
    /// (`streamInterval`: the game's interval when known); otherwise they'd just replace real frames.
    static func helps(streamInterval: Double, displayInterval: Double) -> Bool {
        streamInterval > 0 && displayInterval > 0 && streamInterval >= displayInterval * minimumRatio
    }

    /// How many screen refreshes per frame there must be at least: with fewer, most refreshes would show a
    /// real frame anyway (a 60 fps game on a 60 Hz screen). From 1.2 (60 fps on 75 Hz) each refresh between
    /// two frames gets an image of its own moment, which also evens out the uneven 1-or-2-refresh rhythm.
    static let minimumRatio = 1.2

    private var session: AnyObject? // VTFrameProcessor on macOS 26+
    private var size: (width: Int, height: Int, steps: Int)?
    private var pool: CVPixelBufferPool?
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
        guard let processor = session as? VTFrameProcessor, let pool else { return nil }
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
        processor.process(with: cb, parameters: parameters)
        return outputs
    }

    /// Whether `phase` is one of the points the processor makes for `steps` (2^steps − 1 evenly spaced ones).
    static func isPoint(_ phase: Float, steps: Int) -> Bool {
        let points = Float(1 << steps)
        let scaled = phase * points
        return phase > 0 && phase < 1 && abs(scaled - scaled.rounded()) < 1e-4
    }

    /// Starts the session (building the model, 1–2 s the first time for a size) ahead of the first pair.
    public func prepare(width: Int, height: Int) {
        if #available(macOS 26.0, iOS 26.0, *), Self.isAvailable { _ = start(width: width, height: height, steps: 1) }
    }

    /// A session for this size and number of points, started if needed; false when it can't run at this size.
    @available(macOS 26.0, iOS 26.0, *)
    private func start(width w: Int, height h: Int, steps: Int) -> Bool {
        let sizeKey = "\(w)x\(h)"
        guard !failed.contains("\(sizeKey)/\(steps)") else { return false }
        if size?.width == w, size?.height == h, size?.steps == steps { return true }
        end()
        var newPool: CVPixelBufferPool?
        let processor = VTFrameProcessor()
        guard let config = VTLowLatencyFrameInterpolationConfiguration(frameWidth: w, frameHeight: h, numberOfInterpolatedFrames: steps),
              (try? processor.startSession(configuration: config)) != nil,
              CVPixelBufferPoolCreate(nil, nil, Self.metalCompatible(config.destinationPixelBufferAttributes) as CFDictionary,
                                      &newPool) == kCVReturnSuccess else {
            failed.insert("\(sizeKey)/\(steps)")
            Log.warning(.renderer, "Frame interpolation couldn't start for \(sizeKey) streams (\(steps == 1 ? "halves" : "quarters"))")
            return false
        }
        session = processor
        pool = newPool
        size = (w, h, steps)
        Log.info(.renderer, "Frame interpolation on for \(sizeKey) streams, at \(steps == 1 ? "halves" : "quarters")")
        return true
    }

    private static func metalCompatible(_ attributes: [String: Any]) -> [String: Any] {
        var attrs = attributes
        attrs[kCVPixelBufferMetalCompatibilityKey as String] = true
        return attrs
    }

    private func end() {
        if #available(macOS 26.0, iOS 26.0, *) { (session as? VTFrameProcessor)?.endSession() }
        session = nil
        pool = nil
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
