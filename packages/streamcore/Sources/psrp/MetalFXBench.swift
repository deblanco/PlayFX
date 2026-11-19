import CoreVideo
import Foundation
import Metal
import MetalFX
import VideoToolbox

/// Prototype for the bench: MetalFX frame interpolation on a video stream. MetalFX is built for games and
/// wants per-pixel motion vectors and depth with every frame; a stream has neither. The depth is one
/// constant plane; the motion comes from one of:
/// - `flow`: VideoToolbox optical flow (at `flowScale` of the frame),
/// - `estimate`: the media engine's motion estimation (VTMotionEstimationSession, multi-pass, 16×16 blocks),
/// - `zero`: none at all (MetalFX refines motion itself).
/// Motion vectors are in pixels of the motion texture, pointing to where the pixel was in the previous
/// frame. See docs/FRAME_INTERPOLATION.md.
@available(macOS 26.0, *)
final class MetalFXInterpolatorBench {
    enum Motion: String { case flow, estimate, zero }

    let device: MTLDevice
    let width: Int, height: Int
    let motion: Motion
    private(set) var fieldWidth = 0, fieldHeight = 0
    private let block = 16
    private var interpolator: MTLFXFrameInterpolator?
    private var depth: MTLTexture?
    private var zeroMotion: MTLTexture?
    private let output: MTLTexture
    private let transfer: VTPixelTransferSession
    private var textureCache: CVMetalTextureCache?
    // Optical flow
    private var flow: VTFrameProcessor?
    private var flowConfig: VTOpticalFlowConfiguration?
    private var flowPool: CVPixelBufferPool?
    // Motion estimation
    private var estimator: __VTMotionEstimationSession?
    private var started = false
    private var previous: (color: CVPixelBuffer, small: CVPixelBuffer?, luma: CVPixelBuffer?)?

    var description: String {
        switch motion {
        case .flow: "MetalFX, optical flow at \(fieldWidth)x\(fieldHeight)"
        case .estimate: "MetalFX, media-engine motion (\(block)x\(block) blocks, multi-pass)"
        case .zero: "MetalFX, zero motion"
        }
    }

    init?(device: MTLDevice, width: Int, height: Int, motion: Motion, flowScale: Double) {
        self.device = device
        self.width = width
        self.height = height
        self.motion = motion
        guard MTLFXFrameInterpolatorDescriptor.supportsDevice(device) else { return nil }
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == noErr, let session else { return nil }
        transfer = session
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        let o = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        o.storageMode = .private
        o.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let out = device.makeTexture(descriptor: o) else { return nil }
        output = out

        switch motion {
        case .flow:
            fieldWidth = Int((Double(width) * flowScale).rounded()) & ~1
            fieldHeight = Int((Double(height) * flowScale).rounded()) & ~1
            let processor = VTFrameProcessor()
            guard let config = VTOpticalFlowConfiguration(frameWidth: fieldWidth, frameHeight: fieldHeight,
                                                          qualityPrioritization: .normal, revision: VTOpticalFlowConfiguration.defaultRevision),
                  (try? processor.startSession(configuration: config)) != nil else { return nil }
            flow = processor
            flowConfig = config
            CVPixelBufferPoolCreate(nil, nil, Self.metal(config.destinationPixelBufferAttributes) as CFDictionary, &flowPool)
        case .estimate:
            let options = [
                kVTMotionEstimationSessionCreationOption_MotionVectorSize as String: block as CFNumber,
                kVTMotionEstimationSessionCreationOption_UseMultiPassSearch as String: kCFBooleanTrue as Any,
            ] as CFDictionary
            var created: __VTMotionEstimationSession?
            guard __VTMotionEstimationSessionCreate(kCFAllocatorDefault, options, UInt32(width), UInt32(height), &created) == noErr,
                  let created else { return nil }
            estimator = created
        case .zero:
            fieldWidth = width / block
            fieldHeight = height / block
        }
    }

    deinit {
        flow?.endSession()
        if let estimator { __VTMotionEstimationSessionInvalidate(estimator) }
    }

    static func metal(_ attrs: [String: Any]) -> [String: Any] {
        var a = attrs
        a[kCVPixelBufferMetalCompatibilityKey as String] = true
        a[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]
        return a
    }

    func buffer(_ format: OSType, _ w: Int, _ h: Int) -> CVPixelBuffer? {
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, format, [
            kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary, &b)
        return b
    }

    func texture(_ buffer: CVPixelBuffer, _ format: MTLPixelFormat) -> MTLTexture? {
        guard let textureCache else { return nil }
        var t: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, format,
                                                  CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &t)
        return t.flatMap(CVMetalTextureGetTexture)
    }

    /// BGRA copy of a decoded frame at full size.
    func bgra(_ frame: CVPixelBuffer) -> CVPixelBuffer? {
        guard let b = buffer(kCVPixelFormatType_32BGRA, width, height),
              VTPixelTransferSessionTransferImage(transfer, from: frame, to: b) == noErr else { return nil }
        return b
    }

    /// The frame's luma alone (what motion estimation takes).
    private func luma(_ frame: CVPixelBuffer) -> CVPixelBuffer? {
        guard let out = buffer(kCVPixelFormatType_OneComponent8, width, height) else { return nil }
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        }
        guard let src = CVPixelBufferGetBaseAddressOfPlane(frame, 0), let dst = CVPixelBufferGetBaseAddress(out) else { return nil }
        let srcRow = CVPixelBufferGetBytesPerRowOfPlane(frame, 0), dstRow = CVPixelBufferGetBytesPerRow(out)
        for y in 0..<height { memcpy(dst + y * dstRow, src + y * srcRow, width) }
        return out
    }

    /// Backward motion of `current` against `reference`, from the media engine.
    private func estimate(_ reference: CVPixelBuffer, _ current: CVPixelBuffer) -> CVPixelBuffer? {
        guard let estimator else { return nil }
        var vectors: CVPixelBuffer?
        let done = DispatchSemaphore(value: 0)
        let status = __VTMotionEstimationSessionEstimateMotionVectors(estimator, reference, current, [], nil) { status, _, _, field in
            if status == noErr { vectors = field }
            done.signal()
        }
        guard status == noErr else { return nil }
        done.wait()
        return vectors
    }

    private func ensureInterpolator() -> MTLFXFrameInterpolator? {
        if let interpolator { return interpolator }
        let desc = MTLFXFrameInterpolatorDescriptor()
        desc.colorTextureFormat = .bgra8Unorm
        desc.outputTextureFormat = .bgra8Unorm
        desc.depthTextureFormat = .depth32Float
        desc.motionTextureFormat = .rg16Float
        desc.inputWidth = fieldWidth
        desc.inputHeight = fieldHeight
        desc.outputWidth = width
        desc.outputHeight = height
        guard let made = desc.makeFrameInterpolator(device: device) else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: fieldWidth, height: fieldHeight, mipmapped: false)
        d.storageMode = .private
        d.usage = [made.depthTextureUsage, .renderTarget]
        depth = device.makeTexture(descriptor: d)
        if motion == .zero {
            let m = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float, width: fieldWidth, height: fieldHeight, mipmapped: false)
            m.storageMode = .private
            m.usage = [made.motionTextureUsage, .renderTarget]
            zeroMotion = device.makeTexture(descriptor: m)
        }
        interpolator = made
        return made
    }

    /// The image halfway between the last frame given and `frame`, as BGRA into `result`, encoded into `cb`.
    /// False for the first frame (nothing to interpolate from yet) or on failure.
    func encode(_ cb: MTLCommandBuffer, _ frame: CVPixelBuffer, into result: CVPixelBuffer) -> Bool {
        guard let color = bgra(frame) else { return false }
        var small: CVPixelBuffer?
        if motion == .flow, let flowConfig {
            let format = flowConfig.frameSupportedPixelFormats.first?.uint32Value ?? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            small = buffer(format, fieldWidth, fieldHeight)
            if let small { VTPixelTransferSessionTransferImage(transfer, from: frame, to: small) }
        }
        let currentLuma = motion == .estimate ? luma(frame) : nil
        defer { previous = (color, small, currentLuma) }
        guard let previous else { return false }

        // Motion: a texture of backward vectors, in pixels of the motion texture.
        var motionTexture: MTLTexture?
        var scale: Float = 1
        switch motion {
        case .flow:
            var forward: CVPixelBuffer?, backward: CVPixelBuffer?
            guard let flow, let flowPool, let prevSmall = previous.small, let small else { return false }
            CVPixelBufferPoolCreatePixelBuffer(nil, flowPool, &forward)
            CVPixelBufferPoolCreatePixelBuffer(nil, flowPool, &backward)
            guard let forward, let backward,
                  let source = VTFrameProcessorFrame(buffer: prevSmall, presentationTimeStamp: .zero),
                  let next = VTFrameProcessorFrame(buffer: small, presentationTimeStamp: CMTime(value: 1, timescale: 30)),
                  let destination = VTFrameProcessorOpticalFlow(forwardFlow: forward, backwardFlow: backward),
                  let parameters = VTOpticalFlowParameters(sourceFrame: source, nextFrame: next, submissionMode: .sequential,
                                                           destinationOpticalFlow: destination) else { return false }
            flow.process(with: cb, parameters: parameters)
            motionTexture = texture(backward, .rg16Float)
        case .estimate:
            guard let prevLuma = previous.luma, let currentLuma, let field = estimate(prevLuma, currentLuma) else { return false }
            if fieldWidth == 0 { fieldWidth = CVPixelBufferGetWidth(field); fieldHeight = CVPixelBufferGetHeight(field) }
            motionTexture = texture(field, .rg16Float)
            scale = 1 / Float(block) // full-frame pixels → motion-texture pixels
        case .zero:
            break
        }
        guard let interpolator = ensureInterpolator(), let depth else { return false }
        if !started {
            let pass = MTLRenderPassDescriptor()
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 0.5
            pass.depthAttachment.storeAction = .store
            if let zeroMotion {
                pass.colorAttachments[0].texture = zeroMotion
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                pass.colorAttachments[0].storeAction = .store
            }
            cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
        guard let colorTexture = texture(color, .bgra8Unorm), let prevColor = texture(previous.color, .bgra8Unorm),
              let motion = motionTexture ?? zeroMotion, let out = texture(result, .bgra8Unorm) else { return false }
        interpolator.colorTexture = colorTexture
        interpolator.prevColorTexture = prevColor
        interpolator.motionTexture = motion
        interpolator.depthTexture = depth
        interpolator.outputTexture = output
        interpolator.motionVectorScaleX = scale
        interpolator.motionVectorScaleY = scale
        interpolator.deltaTime = 1.0 / 30
        interpolator.nearPlane = 0.1
        interpolator.farPlane = 1000
        interpolator.fieldOfView = 60
        interpolator.aspectRatio = Float(width) / Float(height)
        interpolator.jitterOffsetX = 0
        interpolator.jitterOffsetY = 0
        interpolator.shouldResetHistory = !started
        interpolator.encode(commandBuffer: cb)
        started = true
        guard let blit = cb.makeBlitCommandEncoder() else { return false }
        blit.copy(from: output, to: out)
        blit.endEncoding()
        return true
    }
}
