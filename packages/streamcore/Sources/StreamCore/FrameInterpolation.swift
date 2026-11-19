import CoreMedia
import CoreVideo
import Metal
import VideoToolbox

/// "Frame interpolation": Apple's low-latency frame interpolation (VideoToolbox, macOS 26+) makes a frame
/// halfway between the previous decoded frame and the new one. The renderer shows it first and the new
/// frame one screen refresh later, doubling the frame rate when the screen refreshes at least twice as
/// fast as the stream (30 fps on a 60 Hz screen, 60 fps on a 120 Hz one). The cost is that the real
/// frame lands one refresh late, so it's off by default.
public final class FrameInterpolator {
    /// Whether this OS and Mac can run it at all. Not in a virtual machine: VideoToolbox reports it
    /// supported there, then crashes the process when it runs (seen on GitHub's macOS runners).
    public static var isAvailable: Bool {
        if #available(macOS 26.0, iOS 26.0, *) {
            return !isVirtualMachine && VTLowLatencyFrameInterpolationConfiguration.isSupported
        }
        return false
    }

    /// An in-between frame only shows if the screen refreshes at least ~twice per stream frame;
    /// otherwise it would just replace real frames (adding lag for nothing).
    static func helps(streamInterval: Double, displayInterval: Double) -> Bool {
        streamInterval > 0 && displayInterval > 0 && streamInterval >= displayInterval * 1.8
    }

    private var session: AnyObject? // VTFrameProcessor on macOS 26+
    private var size: (width: Int, height: Int)?
    private var pool: CVPixelBufferPool?
    private var failed: Set<String> = []
    private var timestamp: Int64 = 0

    public init() {}

    deinit { end() }

    /// Encodes the frame halfway between `previous` and `current` into a new NV12 buffer in `cb`; nil
    /// when it can't run (unsupported format or size, or the frames differ in size).
    public func encode(_ cb: MTLCommandBuffer, previous: CVPixelBuffer, current: CVPixelBuffer) -> CVPixelBuffer? {
        guard #available(macOS 26.0, iOS 26.0, *), Self.isAvailable,
              CVPixelBufferGetPixelFormatType(current) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPixelFormatType(previous) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return nil }
        let w = CVPixelBufferGetWidth(current), h = CVPixelBufferGetHeight(current)
        guard CVPixelBufferGetWidth(previous) == w, CVPixelBufferGetHeight(previous) == h else { return nil }
        guard start(width: w, height: h) else { return nil }
        var output: CVPixelBuffer?
        timestamp += 2
        guard let processor = session as? VTFrameProcessor, let pool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output,
              let before = VTFrameProcessorFrame(buffer: previous, presentationTimeStamp: CMTime(value: timestamp - 2, timescale: 120)),
              let after = VTFrameProcessorFrame(buffer: current, presentationTimeStamp: CMTime(value: timestamp, timescale: 120)),
              let middle = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: CMTime(value: timestamp - 1, timescale: 120)),
              let parameters = VTLowLatencyFrameInterpolationParameters(sourceFrame: after, previousFrame: before,
                                                                        interpolationPhase: [0.5], destinationFrames: [middle])
        else { return nil }
        // Keep the colorimetry so the NV12 conversion still reads the stream's matrix and siting.
        CVBufferPropagateAttachments(current, output)
        processor.process(with: cb, parameters: parameters)
        return output
    }

    /// Starts the session (building the model, 1–2 s the first time for a size) ahead of the first pair.
    public func prepare(width: Int, height: Int) {
        if #available(macOS 26.0, iOS 26.0, *), Self.isAvailable { _ = start(width: width, height: height) }
    }

    /// A session for this size, started if needed; false when it can't run at this size.
    @available(macOS 26.0, iOS 26.0, *)
    private func start(width w: Int, height h: Int) -> Bool {
        let sizeKey = "\(w)x\(h)"
        guard !failed.contains(sizeKey) else { return false }
        if size?.width == w, size?.height == h { return true }
        end()
        var newPool: CVPixelBufferPool?
        let processor = VTFrameProcessor()
        guard let config = VTLowLatencyFrameInterpolationConfiguration(frameWidth: w, frameHeight: h, numberOfInterpolatedFrames: 1),
              (try? processor.startSession(configuration: config)) != nil,
              CVPixelBufferPoolCreate(nil, nil, Self.metalCompatible(config.destinationPixelBufferAttributes) as CFDictionary,
                                      &newPool) == kCVReturnSuccess else {
            failed.insert(sizeKey)
            Log.warning(.renderer, "Frame interpolation couldn't start for \(sizeKey) streams")
            return false
        }
        session = processor
        pool = newPool
        size = (w, h)
        Log.info(.renderer, "Frame interpolation on for \(sizeKey) streams")
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
