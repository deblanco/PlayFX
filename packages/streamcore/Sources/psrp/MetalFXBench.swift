import CoreVideo
import Foundation
import Metal
import MetalFX
import VideoToolbox

/// Prototype for the bench: MetalFX frame interpolation on a video stream. MetalFX is built for games and
/// wants per-pixel motion vectors and depth with every frame; a stream has neither, so the motion comes
/// from VideoToolbox optical flow (computed at a reduced size) and the depth is one constant plane.
@available(macOS 26.0, *)
final class MetalFXInterpolatorBench {
    let device: MTLDevice
    let width: Int, height: Int
    let flowWidth: Int, flowHeight: Int
    let motionScale: Float
    private let interpolator: MTLFXFrameInterpolator
    private let flow = VTFrameProcessor()
    private let flowConfig: VTOpticalFlowConfiguration
    private let transfer: VTPixelTransferSession
    private var textureCache: CVMetalTextureCache?
    private let depth: MTLTexture
    private let output: MTLTexture
    private var flowPool: CVPixelBufferPool?
    private var started = false
    private var previousColor: (buffer: CVPixelBuffer, small: CVPixelBuffer)?

    init?(device: MTLDevice, width: Int, height: Int, flowScale: Double, motionScale: Float?) {
        self.device = device
        self.width = width
        self.height = height
        flowWidth = Int((Double(width) * flowScale).rounded()) & ~1
        flowHeight = Int((Double(height) * flowScale).rounded()) & ~1
        // Motion is in pixels of the motion texture (measured by MacNativeGames' MetalFX probe), so no rescale.
        self.motionScale = motionScale ?? 1
        guard MTLFXFrameInterpolatorDescriptor.supportsDevice(device),
              let config = VTOpticalFlowConfiguration(frameWidth: flowWidth, frameHeight: flowHeight,
                                                      qualityPrioritization: .normal, revision: VTOpticalFlowConfiguration.defaultRevision),
              (try? flow.startSession(configuration: config)) != nil else { return nil }
        flowConfig = config
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == noErr, let session else { return nil }
        transfer = session
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)

        let desc = MTLFXFrameInterpolatorDescriptor()
        desc.colorTextureFormat = .bgra8Unorm
        desc.outputTextureFormat = .bgra8Unorm
        desc.depthTextureFormat = .depth32Float
        desc.motionTextureFormat = .rg16Float
        desc.inputWidth = flowWidth
        desc.inputHeight = flowHeight
        desc.outputWidth = width
        desc.outputHeight = height
        guard let made = desc.makeFrameInterpolator(device: device) else { return nil }
        interpolator = made

        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: flowWidth, height: flowHeight, mipmapped: false)
        d.storageMode = .private
        d.usage = [made.depthTextureUsage, .renderTarget]
        let o = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        o.storageMode = .private
        o.usage = made.outputTextureUsage
        guard let depthTexture = device.makeTexture(descriptor: d), let out = device.makeTexture(descriptor: o) else { return nil }
        depth = depthTexture
        output = out
        CVPixelBufferPoolCreate(nil, nil, Self.metal(config.destinationPixelBufferAttributes) as CFDictionary, &flowPool)
    }

    deinit { flow.endSession() }

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

    /// BGRA at full size and NV12 at the flow size, for one decoded frame.
    func prepare(_ frame: CVPixelBuffer) -> (buffer: CVPixelBuffer, small: CVPixelBuffer)? {
        let pixelFormat = flowConfig.frameSupportedPixelFormats.first?.uint32Value ?? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard let bgra = buffer(kCVPixelFormatType_32BGRA, width, height),
              let small = buffer(pixelFormat, flowWidth, flowHeight),
              VTPixelTransferSessionTransferImage(transfer, from: frame, to: bgra) == noErr,
              VTPixelTransferSessionTransferImage(transfer, from: frame, to: small) == noErr else { return nil }
        return (bgra, small)
    }

    /// The in-between frame of `previous` (the last frame given) and `frame`, as BGRA, into `cb`.
    /// Returns nil for the first frame. `into` receives the result (an IOSurface BGRA buffer).
    func encode(_ cb: MTLCommandBuffer, _ frame: CVPixelBuffer, into result: CVPixelBuffer) -> Bool {
        guard let current = prepare(frame) else { return false }
        defer { previousColor = current }
        guard let previous = previousColor, let flowPool else { return false }
        var forward: CVPixelBuffer?, backward: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, flowPool, &forward)
        CVPixelBufferPoolCreatePixelBuffer(nil, flowPool, &backward)
        guard let forward, let backward,
              let source = VTFrameProcessorFrame(buffer: previous.small, presentationTimeStamp: .zero),
              let next = VTFrameProcessorFrame(buffer: current.small, presentationTimeStamp: CMTime(value: 1, timescale: 30)),
              let destination = VTFrameProcessorOpticalFlow(forwardFlow: forward, backwardFlow: backward),
              let parameters = VTOpticalFlowParameters(sourceFrame: source, nextFrame: next, submissionMode: .sequential,
                                                       destinationOpticalFlow: destination),
              let color = texture(current.buffer, .bgra8Unorm), let prevColor = texture(previous.buffer, .bgra8Unorm),
              let motion = texture(backward, .rg16Float), let out = texture(result, .bgra8Unorm) else { return false }
        // Optical flow first (VideoToolbox, off the Metal GPU queue), then MetalFX on the GPU.
        flow.process(with: cb, parameters: parameters)
        if !started, let pass = clearDepth() , let encoder = cb.makeRenderCommandEncoder(descriptor: pass) {
            encoder.endEncoding()
        }
        interpolator.colorTexture = color
        interpolator.prevColorTexture = prevColor
        interpolator.motionTexture = motion
        interpolator.depthTexture = depth
        interpolator.outputTexture = output
        interpolator.motionVectorScaleX = motionScale
        interpolator.motionVectorScaleY = motionScale
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

    /// Clears the constant depth plane once (depth reversed: 0.5 is a mid-distance everywhere).
    private func clearDepth() -> MTLRenderPassDescriptor? {
        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0.5
        pass.depthAttachment.storeAction = .store
        return pass
    }

    /// BGRA copy of a decoded frame at full size (for writing the real frames next to the generated ones).
    func bgra(_ frame: CVPixelBuffer) -> CVPixelBuffer? {
        guard let b = buffer(kCVPixelFormatType_32BGRA, width, height),
              VTPixelTransferSessionTransferImage(transfer, from: frame, to: b) == noErr else { return nil }
        return b
    }
}
