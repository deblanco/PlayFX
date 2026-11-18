import CoreVideo
import Metal
import MetalFX
import MetalKit
import QuartzCore
import os

public enum UpscaleMode: Int32 {
    case bilinear = 0
    case metalFX = 1
    /// Split screen for A/B: left half bilinear, right half MetalFX (falls back to bilinear).
    case compare = 2
}

/// Renders the stream into an MTKView: video frame (NV12) → RGB → optional MetalFX spatial
/// upscale to the on-screen size → present, letterboxed to the source aspect ratio.
/// Platform-agnostic; macOS/iOS hosts only differ in how they embed `view`.
public final class StreamRenderer: NSObject, MTKViewDelegate {
    public let view: MTKView
    public let metalFXSupported: Bool
    public var mode: UpscaleMode = .metalFX
    /// Upscaler actually used for the last frame (MetalFX is skipped when not upscaling).
    public private(set) var activeMode: UpscaleMode = .bilinear
    /// Shows the animated test pattern when no video frames are arriving.
    public var showsTestPattern = true

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let patternPipeline: MTLComputePipelineState
    private let nv12Pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private let frameLock = OSAllocatedUnfairLock<CVPixelBuffer?>(initialState: nil)
    private let presentPipeline: MTLRenderPipelineState
    private let dividerPipeline: MTLRenderPipelineState
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
              let patternPipeline = try? device.makeComputePipelineState(function: kernel),
              let nv12Kernel = library.makeFunction(name: "nv12ToRGB"),
              let nv12Pipeline = try? device.makeComputePipelineState(function: nv12Kernel)
        else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let textureCache = cache
        else { return nil }

        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 120

        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        pd.fragmentFunction = library.makeFunction(name: "presentFragment")
        pd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        guard let presentPipeline = try? device.makeRenderPipelineState(descriptor: pd) else { return nil }
        pd.fragmentFunction = library.makeFunction(name: "dividerFragment")
        guard let dividerPipeline = try? device.makeRenderPipelineState(descriptor: pd) else { return nil }

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
        self.textureCache = textureCache
        self.presentPipeline = presentPipeline
        self.dividerPipeline = dividerPipeline
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

    /// Queues a decoded frame for the next draw. Thread-safe; only the newest frame is kept.
    public func display(_ frame: CVPixelBuffer) {
        frameLock.withLock { $0 = frame }
    }

    // MARK: MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer() else { return }
        encode(cb, pass: pass, drawableSize: view.drawableSize)
        cb.present(drawable)
        cb.commit()
    }

    /// Everything `draw` does short of presenting: pending frame (or test pattern) → input texture →
    /// optional MetalFX upscale → letterboxed into `pass`.
    func encode(_ cb: MTLCommandBuffer, pass: MTLRenderPassDescriptor, drawableSize: CGSize) {
        if let frame = frameLock.withLock({ f -> CVPixelBuffer? in defer { f = nil }; return f }) {
            encodeVideoFrame(frame, cb)
        } else if showsTestPattern {
            encodeTestPattern(cb)
        }

        let target = fittedRect(drawable: drawableSize)
        var upscaled: MTLTexture?
        if mode != .bilinear, metalFXSupported,
           let (scaler, output) = scaler(outputWidth: Int(target.width), outputHeight: Int(target.height)) {
            scaler.colorTexture = inputTexture
            scaler.outputTexture = output
            scaler.encode(commandBuffer: cb)
            upscaled = output
        }
        activeMode = upscaled == nil ? .bilinear : mode

        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setViewport(MTLViewport(originX: target.minX, originY: target.minY,
                                    width: target.width, height: target.height, znear: 0, zfar: 1))
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.setRenderPipelineState(presentPipeline)
        if activeMode == .compare, let upscaled {
            let split = Self.compareRects(target)
            for (rect, texture) in [(split.left, inputTexture), (split.right, upscaled)] {
                enc.setScissorRect(Self.scissor(rect))
                enc.setFragmentTexture(texture, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            enc.setScissorRect(Self.scissor(split.divider))
            enc.setRenderPipelineState(dividerPipeline)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        } else {
            enc.setFragmentTexture(upscaled ?? inputTexture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
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
        guard let luma = planeTexture(frame, plane: 0, format: .r8Unorm),
              let chroma = planeTexture(frame, plane: 1, format: .rg8Unorm),
              let lumaTex = CVMetalTextureGetTexture(luma), let chromaTex = CVMetalTextureGetTexture(chroma),
              let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(nv12Pipeline)
        enc.setTexture(lumaTex, index: 0)
        enc.setTexture(chromaTex, index: 1)
        enc.setTexture(inputTexture, index: 2)
        dispatch(enc, inputTexture)
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
        var t = Float(CACurrentMediaTime() - startTime)
        enc.setComputePipelineState(patternPipeline)
        enc.setTexture(inputTexture, index: 0)
        enc.setBytes(&t, length: MemoryLayout<Float>.size, index: 0)
        dispatch(enc, inputTexture)
        enc.endEncoding()
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
