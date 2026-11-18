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
    func render(_ r: StreamRenderer, size: (Int, Int), now: Double? = nil) throws -> [UInt8] {
        let device = r.commandQueue.device
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size.0, height: size.1, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: td))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].storeAction = .store
        let cb = try #require(r.commandQueue.makeCommandBuffer())
        if let now {
            r.encode(cb, pass: pass, drawableSize: CGSize(width: size.0, height: size.1), now: now)
        } else {
            r.encode(cb, pass: pass, drawableSize: CGSize(width: size.0, height: size.1))
        }
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
        #expect(r.params == RenderParams())
        #expect(r.params.upscaler == .metalFX && r.params.sharpness == 0.3 && !r.params.compare)
        #expect(r.activeMode == .bilinear)
        #expect(r.showsTestPattern)
        #expect(r.inputSize == (64, 32))
        r.display(try makeNV12(width: 64, height: 32, y: 120, cb: 128, cr: 128))
        #expect(!r.showsTestPattern) // the first frame replaces the backdrop
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
        r.params.upscaler = .bilinear
        r.params.sharpness = 0
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
        r.params.upscaler = .bilinear
        r.params.sharpness = 0
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
        r.params.upscaler = .bilinear
        r.params.sharpness = 0
        _ = try render(r, size: (8, 8))
        #expect(r.activeMode == .bilinear)
    }

    @Test func compareRectsSplitTheVideo() {
        let split = StreamRenderer.compareRects(CGRect(x: 100, y: 0, width: 2000, height: 1000))
        #expect(split.left == CGRect(x: 100, y: 0, width: 1000, height: 1000))
        #expect(split.right == CGRect(x: 1100, y: 0, width: 1000, height: 1000))
        #expect(split.divider == CGRect(x: 1098, y: 0, width: 4, height: 1000))
        #expect(StreamRenderer.compareRects(CGRect(x: 0, y: 0, width: 64, height: 64)).divider.width == 2)
    }

    @Test func compareSplitsBaselineAndProcessed() throws {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64))
        r.params.compare = true
        r.showsTestPattern = false
        r.display(try makeNV12(width: 64, height: 64, y: 16, cb: 128, cr: 128)) // black
        let out = try render(r, size: (128, 128))
        #expect(r.activeMode == (r.metalFXSupported ? .metalFX : .bilinear))
        #expect(pixel(out, width: 128, x: 64, y: 64) == (255, 255, 255, 255)) // divider
        #expect(pixel(out, width: 128, x: 20, y: 64).r < 10)  // baseline half
        #expect(pixel(out, width: 128, x: 108, y: 64).r < 10) // processed half
        // Not upscaling still splits (baseline vs sharpened).
        let same = try render(r, size: (64, 64))
        #expect(r.activeMode == .bilinear)
        #expect(pixel(same, width: 64, x: 32, y: 32) == (255, 255, 255, 255))
        #expect(pixel(same, width: 64, x: 10, y: 32).r < 10)
        // Over the idle test pattern there is no split (no divider down the middle).
        r.showsTestPattern = true
        let idle = try render(r, size: (64, 64))
        let whiteInMiddleColumn = (0..<64).filter { pixel(idle, width: 64, x: 32, y: $0) == (255, 255, 255, 255) }.count
        #expect(whiteInMiddleColumn < 64, "a full-height divider was drawn")
    }

    /// A 64×64 frame: left half dark gray, right half light gray (a vertical edge at x = 32).
    func edgeFrame() throws -> CVPixelBuffer {
        try makeNV12(width: 64, height: 64, cb: 128, cr: 128) { x, _ in x < 32 ? 80 : 170 }
    }

    @Test func sharpnessZeroIsIdentity() throws {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64))
        r.showsTestPattern = false
        r.params = RenderParams()
        r.params.upscaler = .bilinear
        r.params.sharpness = 0
        r.display(try edgeFrame())
        let plain = try render(r, size: (64, 64))
        r.params.sharpness = 0.000_1 // tiny but on: same pixels away from the edge
        let barely = try render(r, size: (64, 64))
        #expect(pixel(plain, width: 64, x: 8, y: 32) == pixel(barely, width: 64, x: 8, y: 32))
        #expect(pixel(plain, width: 64, x: 56, y: 32) == pixel(barely, width: 64, x: 56, y: 32))
    }

    @Test(arguments: [UpscaleMode.bilinear, .metalFX])
    func sharpeningIncreasesEdgeContrast(upscaler: UpscaleMode) throws {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64))
        r.showsTestPattern = false
        r.params.upscaler = upscaler
        func edgeContrast(_ sharpness: Float) throws -> (dark: Int, light: Int, flat: Int) {
            r.params.sharpness = sharpness
            r.display(try edgeFrame())
            let p = try render(r, size: (128, 128))
            // Darkest pixel just left of the edge, lightest just right, and a flat area.
            let dark = (56..<64).map { pixel(p, width: 128, x: $0, y: 64).g }.min()!
            let light = (64..<72).map { pixel(p, width: 128, x: $0, y: 64).g }.max()!
            return (dark, light, pixel(p, width: 128, x: 16, y: 64).g)
        }
        let soft = try edgeContrast(0), sharp = try edgeContrast(1)
        #expect(sharp.dark < soft.dark, "dark side: \(sharp.dark) vs \(soft.dark)")
        #expect(sharp.light > soft.light, "light side: \(sharp.light) vs \(soft.light)")
        #expect(abs(sharp.flat - soft.flat) <= 1) // flat areas untouched
        #expect(sharp.dark > 0 && sharp.light < 255) // no clipping halos
    }

    @Test func measuresGPUTime() throws {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64))
        #expect(r.gpuMilliseconds == 0)
        _ = try render(r, size: (256, 256))
        // The completed handler can run just after waitUntilCompleted returns.
        for _ in 0..<100 where r.gpuMilliseconds == 0 { usleep(10_000) }
        #expect(r.gpuMilliseconds > 0)
        #expect(StreamRenderer.smoothed(0, 4) == 4)
        #expect(abs(StreamRenderer.smoothed(2, 12) - 3) < 1e-9)
    }

    @Test func casPeakFollowsSharpness() {
        #expect(abs(StreamRenderer.casPeak(sharpness: 0) - -1.0 / 8) < 1e-6)
        #expect(abs(StreamRenderer.casPeak(sharpness: 1) - -1.0 / 5) < 1e-6)
        #expect(abs(StreamRenderer.casPeak(sharpness: 7) - -1.0 / 5) < 1e-6) // clamped
    }

    @Test func renderParamsJSON() throws {
        let decode = { (json: String) in try JSONDecoder().decode(RenderParams.self, from: Data(json.utf8)) }
        #expect(try decode("{}") == RenderParams())
        let p = try decode(#"{"upscaler":"bilinear","sharpness":2,"compare":true}"#)
        #expect(p.upscaler == .bilinear && p.sharpness == 1 && p.compare)
        #expect(try decode(#"{"sharpness":-1}"#).sharpness == 0)
        #expect(throws: DecodingError.self) { try decode(#"{"upscaler":"fsr"}"#) }
        let color = try decode(#"{"colorMatrix":"bt2020","colorRange":"full","chroma":"bilinear","accurateColor":false}"#)
        #expect(color.colorMatrix == .bt2020 && color.colorRange == .full && color.chroma == .bilinear && !color.accurateColor)
        #expect(throws: DecodingError.self) { try decode(#"{"chroma":"lanczos"}"#) }
        let clean = try decode(#"{"deblock":0.5,"deband":3}"#)
        #expect(clean.deblock == 0.5 && clean.deband == 1 && RenderParams().deblock == 0 && RenderParams().deband == 0)
        let roundTrip = try decode(String(decoding: JSONEncoder().encode(p), as: UTF8.self))
        #expect(roundTrip == p)
    }

    @Test func snapshotsTheLastFrame() throws {
        let r = try #require(StreamRenderer(inputWidth: 32, inputHeight: 32))
        r.showsTestPattern = false
        r.params.upscaler = .metalFX
        r.display(try makeNV12(width: 32, height: 32, y: 63, cb: 102, cr: 240)) // red
        let image = try #require(r.snapshot(width: 96, height: 64))
        #expect(image.width == 96 && image.height == 64)
        let data = try #require(image.dataProvider?.data as Data?)
        let center = (32 * 96 + 48) * 4 // BGRA
        #expect(data[center + 2] > 240 && data[center + 1] < 15 && data[center] < 15)
        #expect(data[(32 * 96 + 2) * 4 + 2] == 0) // pillarbox stays black
        // The frame was consumed; later snapshots keep re-rendering the last one.
        r.params.upscaler = .bilinear
        r.params.sharpness = 0
        let again = try #require(r.snapshot(width: 32, height: 32)?.dataProvider?.data as Data?)
        #expect(again[(16 * 32 + 16) * 4 + 2] > 240)
        #expect(r.snapshot(width: 0, height: 10) == nil)
    }
}
