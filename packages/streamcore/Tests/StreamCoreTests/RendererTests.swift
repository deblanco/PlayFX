import CoreGraphics
import CoreVideo
import Metal
import MetalKit
import Testing
@testable import StreamCore

@Suite struct FittedRectTests {
    @Test func letterboxesAndPillarboxes() {
        let wide = CGSize(width: 1920, height: 1080)
        #expect(StreamRenderer.fittedRect(source: wide, drawable: wide) == CGRect(x: 0, y: 0, width: 1920, height: 1080))
        // Taller drawable: bars top and bottom.
        #expect(StreamRenderer.fittedRect(source: wide, drawable: CGSize(width: 1000, height: 1000)) ==
                CGRect(x: 0, y: 219, width: 1000, height: 563))
        // Wider drawable: bars left and right.
        #expect(StreamRenderer.fittedRect(source: wide, drawable: CGSize(width: 3000, height: 1080)) ==
                CGRect(x: 540, y: 0, width: 1920, height: 1080))
        #expect(StreamRenderer.fittedRect(source: CGSize(width: 4, height: 3), drawable: CGSize(width: 801, height: 600)) ==
                CGRect(x: 1, y: 0, width: 800, height: 600))
    }
}

@Suite struct StreamRendererTests {
    /// Encodes one frame offscreen at `size` and returns the BGRA pixels.
    func render(_ r: StreamRenderer, size: (Int, Int)) throws -> [UInt8] {
        let device = r.commandQueue.device
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size.0, height: size.1, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: td))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].storeAction = .store
        let cb = try #require(r.commandQueue.makeCommandBuffer())
        r.encode(cb, pass: pass, drawableSize: CGSize(width: size.0, height: size.1))
        cb.commit()
        cb.waitUntilCompleted()
        #expect(cb.status == .completed)
        var pixels = [UInt8](repeating: 0, count: size.0 * size.1 * 4)
        target.getBytes(&pixels, bytesPerRow: size.0 * 4, from: MTLRegionMake2D(0, 0, size.0, size.1), mipmapLevel: 0)
        return pixels
    }

    func pixel(_ p: [UInt8], width: Int, x: Int, y: Int) -> (b: Int, g: Int, r: Int, a: Int) {
        let i = (y * width + x) * 4
        return (Int(p[i]), Int(p[i + 1]), Int(p[i + 2]), Int(p[i + 3]))
    }

    @Test func initialState() throws {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 32))
        #expect(r.mode == .metalFX)
        #expect(r.activeMode == .bilinear)
        #expect(r.showsTestPattern)
        #expect(r.inputSize == (64, 32))
        #expect(r.view.delegate === r)
        #expect(r.view.colorPixelFormat == .bgra8Unorm)
        r.setInputSize(width: 0, height: 10)   // ignored
        r.setInputSize(width: 64, height: 32)  // unchanged
        #expect(r.inputSize == (64, 32))
        r.setInputSize(width: 128, height: 72)
        #expect(r.inputSize == (128, 72))
        r.mtkView(r.view, drawableSizeWillChange: CGSize(width: 10, height: 10))
        r.draw(in: r.view) // no window → no drawable → nothing to do
    }

    @Test func drawsTestPatternOrBlack() throws {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64))
        r.mode = .bilinear
        let pattern = try render(r, size: (64, 64))
        #expect(pixel(pattern, width: 64, x: 0, y: 0).a == 255)
        #expect(pattern.enumerated().contains { $0.offset % 4 != 3 && $0.element > 20 }) // something lit
        #expect(r.activeMode == .bilinear)

        // Letterboxing: a wide drawable leaves black bars at the sides.
        let wide = try render(r, size: (128, 64))
        #expect(pixel(wide, width: 128, x: 2, y: 32) == (0, 0, 0, 255))
    }

    @Test(arguments: [
        // (Y, Cb, Cr) BT.709 video range → expected RGB.
        (UInt8(235), UInt8(128), UInt8(128), (255, 255, 255)),
        (UInt8(16), UInt8(128), UInt8(128), (0, 0, 0)),
        (UInt8(63), UInt8(102), UInt8(240), (255, 0, 0)),
    ])
    func convertsNV12Frames(y: UInt8, cb: UInt8, cr: UInt8, rgb: (Int, Int, Int)) throws {
        let r = try #require(StreamRenderer(inputWidth: 16, inputHeight: 16))
        r.mode = .bilinear
        r.display(try makeNV12(width: 32, height: 32, y: y, cb: cb, cr: cr))
        let out = try render(r, size: (32, 32))
        #expect(r.inputSize == (32, 32)) // resized to the frame
        let p = pixel(out, width: 32, x: 16, y: 16)
        #expect(abs(p.r - rgb.0) <= 6 && abs(p.g - rgb.1) <= 6 && abs(p.b - rgb.2) <= 6, "got \(p)")
    }

    @Test func upscalesWithMetalFXWhenAvailable() throws {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64))
        r.display(try makeNV12(width: 64, height: 64, y: 235, cb: 128, cr: 128))
        let out = try render(r, size: (128, 128))
        #expect(r.activeMode == (r.metalFXSupported ? .metalFX : .bilinear))
        let p = pixel(out, width: 128, x: 64, y: 64)
        #expect(p.r > 240 && p.g > 240 && p.b > 240, "got \(p)")
        // Same size again reuses the scaler; a new input size rebuilds it.
        _ = try render(r, size: (128, 128))
        r.setInputSize(width: 32, height: 32)
        _ = try render(r, size: (128, 128))
        #expect(r.activeMode == (r.metalFXSupported ? .metalFX : .bilinear))
        // Not upscaling (output ≤ input): bilinear.
        _ = try render(r, size: (32, 32))
        #expect(r.activeMode == .bilinear)
    }

    @Test func noTestPatternWithoutFrames() throws {
        let r = try #require(StreamRenderer(inputWidth: 8, inputHeight: 8))
        r.showsTestPattern = false
        r.mode = .bilinear
        _ = try render(r, size: (8, 8))
        #expect(r.activeMode == .bilinear)
    }
}
