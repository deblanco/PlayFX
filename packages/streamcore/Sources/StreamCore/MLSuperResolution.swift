import CoreMedia
import CoreVideo
import Metal
import VideoToolbox

/// Apple's low-latency ML super-resolution (VideoToolbox, macOS 26+), run on the decoded NV12 frame
/// before the rest of the pipeline. It only takes inputs up to 1280 px per side and offers 1.5×/2×,
/// so it helps 720p and lower streams; anything else passes through untouched.
final class MLSuperResolution {
    /// The largest frame side the model takes.
    static let maxInputSide = 1280

    /// Whether this OS and Mac can run it at all.
    static var isAvailable: Bool {
        // Not in a virtual machine: VideoToolbox reports it supported there, but it never runs.
        if #available(macOS 26.0, iOS 26.0, *) {
            return !isVirtualMachine && VTLowLatencySuperResolutionScalerConfiguration.isSupported
        }
        return false
    }

    /// The scale factor to use: the largest supported one that doesn't overshoot the screen (the rest of
    /// the upscale is MetalFX's job), else the smallest supported one; nil when there's none.
    static func scaleFactor(supported: [Float], width: Int, height: Int, target: CGSize) -> Float? {
        let fitting = supported.filter { Double(Float(width) * $0) <= target.width && Double(Float(height) * $0) <= target.height }
        return fitting.max() ?? (target.width > Double(width) ? supported.min() : nil)
    }

    private var session: AnyObject? // VTFrameProcessor on macOS 26+
    private var key: (width: Int, height: Int, factor: Float)?
    private var pool: CVPixelBufferPool?
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
        let supported = Config.__supportedScaleFactors(forFrameWidth: w, frameHeight: h).map(\.floatValue)
        guard !supported.isEmpty else {
            unsupported.insert(sizeKey) // the model can't take this size at all
            Log.info(.renderer, "ML upscaling doesn't support \(sizeKey) streams; using the rest of the pipeline")
            return nil
        }
        // No factor for the current window (e.g. too small to need upscaling): skip, but try again later.
        guard let factor = Self.scaleFactor(supported: supported, width: w, height: h, target: target) else { return nil }
        if key?.width != w || key?.height != h || key?.factor != factor {
            end()
            let config = Config(frameWidth: w, frameHeight: h, scaleFactor: factor)
            let processor = VTFrameProcessor()
            var attrs = config.destinationPixelBufferAttributes
            attrs[kCVPixelBufferMetalCompatibilityKey as String] = true
            var newPool: CVPixelBufferPool?
            guard (try? processor.startSession(configuration: config)) != nil,
                  CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &newPool) == kCVReturnSuccess else {
                unsupported.insert(sizeKey)
                Log.warning(.renderer, "ML upscaling couldn't start for \(sizeKey) streams")
                return nil
            }
            session = processor
            Log.info(.renderer, "ML upscaling \(sizeKey) ×\(factor)")
            pool = newPool
            key = (w, h, factor)
        }
        var output: CVPixelBuffer?
        timestamp += 1
        let pts = CMTime(value: timestamp, timescale: 60)
        guard let processor = session as? VTFrameProcessor, let pool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output,
              let source = VTFrameProcessorFrame(buffer: frame, presentationTimeStamp: pts),
              let destination = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: pts) else { return nil }
        // Keep the colorimetry so the NV12 conversion still reads the stream's matrix and siting.
        CVBufferPropagateAttachments(frame, output)
        processor.process(with: cb,
                          parameters: VTLowLatencySuperResolutionScalerParameters(sourceFrame: source, destinationFrame: destination))
        return output
    }

    private func end() {
        if #available(macOS 26.0, iOS 26.0, *) { (session as? VTFrameProcessor)?.endSession() }
        session = nil
        pool = nil
        key = nil
    }
}
