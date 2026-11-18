import Metal
import MetalFX
import MetalKit
import QuartzCore

public enum UpscaleMode: Int32 {
    case bilinear = 0
    case metalFX = 1
}

/// Renders the stream into an MTKView: source frame (low res) → optional MetalFX spatial
/// upscale to the on-screen size → present, letterboxed to the source aspect ratio.
/// Platform-agnostic; macOS/iOS hosts only differ in how they embed `view`.
public final class StreamRenderer: NSObject, MTKViewDelegate {
    public let view: MTKView
    public let metalFXSupported: Bool
    public var mode: UpscaleMode = .metalFX
    /// Upscaler actually used for the last frame (MetalFX is skipped when not upscaling).
    public private(set) var activeMode: UpscaleMode = .bilinear

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let patternPipeline: MTLComputePipelineState
    private let presentPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let startTime = CACurrentMediaTime()

    private var inputTexture: MTLTexture
    private var scaler: MTLFXSpatialScaler?
    private var scalerOutput: MTLTexture?

    public init?(inputWidth: Int = 1280, inputHeight: Int = 720) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: shaderSource, options: nil),
              let kernel = library.makeFunction(name: "testPattern"),
              let patternPipeline = try? device.makeComputePipelineState(function: kernel)
        else { return nil }

        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 120

        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        pd.fragmentFunction = library.makeFunction(name: "presentFragment")
        pd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        guard let presentPipeline = try? device.makeRenderPipelineState(descriptor: pd) else { return nil }

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        guard let sampler = device.makeSamplerState(descriptor: sd),
              let input = Self.makeInputTexture(device, inputWidth, inputHeight)
        else { return nil }

        self.device = device
        self.queue = queue
        self.patternPipeline = patternPipeline
        self.presentPipeline = presentPipeline
        self.sampler = sampler
        self.inputTexture = input
        self.view = view
        self.metalFXSupported = MTLFXSpatialScalerDescriptor.supportsDevice(device)
        super.init()
        view.delegate = self
    }

    public func setInputSize(width: Int, height: Int) {
        guard width > 0, height > 0,
              width != inputTexture.width || height != inputTexture.height,
              let tex = Self.makeInputTexture(device, width, height) else { return }
        inputTexture = tex
        scaler = nil
    }

    // MARK: MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer() else { return }

        encodeTestPattern(cb)

        let target = fittedRect(drawable: view.drawableSize)
        var source = inputTexture
        activeMode = .bilinear
        if mode == .metalFX, metalFXSupported,
           let (scaler, output) = scaler(outputWidth: Int(target.width), outputHeight: Int(target.height)) {
            scaler.colorTexture = inputTexture
            scaler.outputTexture = output
            scaler.encode(commandBuffer: cb)
            source = output
            activeMode = .metalFX
        }

        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let enc = cb.makeRenderCommandEncoder(descriptor: pass) {
            enc.setViewport(MTLViewport(originX: target.minX, originY: target.minY,
                                        width: target.width, height: target.height, znear: 0, zfar: 1))
            enc.setRenderPipelineState(presentPipeline)
            enc.setFragmentTexture(source, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        cb.present(drawable)
        cb.commit()
    }

    // MARK: Private

    private func encodeTestPattern(_ cb: MTLCommandBuffer) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        var t = Float(CACurrentMediaTime() - startTime)
        enc.setComputePipelineState(patternPipeline)
        enc.setTexture(inputTexture, index: 0)
        enc.setBytes(&t, length: MemoryLayout<Float>.size, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: (inputTexture.width + 15) / 16, height: (inputTexture.height + 15) / 16, depth: 1)
        enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
        enc.endEncoding()
    }

    /// Largest rect with the source aspect ratio that fits the drawable, centered (pixels).
    private func fittedRect(drawable: CGSize) -> CGRect {
        let srcAspect = CGFloat(inputTexture.width) / CGFloat(inputTexture.height)
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
        desc.colorProcessingMode = .perceptual
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

    private static func makeInputTexture(_ device: MTLDevice, _ width: Int, _ height: Int) -> MTLTexture? {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                          width: width, height: height, mipmapped: false)
        td.usage = [.shaderRead, .shaderWrite, .renderTarget]
        td.storageMode = .private
        return device.makeTexture(descriptor: td)
    }
}
