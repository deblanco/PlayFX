import CoreGraphics
import CoreVideo
import Metal
import Testing
@testable import StreamCore

@Suite struct MLScaleFactorTests {
    let screen = CGSize(width: 2560, height: 1440)

    @Test func picksTheLargestFactorThatFitsTheScreen() {
        #expect(MLSuperResolution.scaleFactor(supported: [1.5], width: 1280, height: 720, target: screen) == 1.5)
        #expect(MLSuperResolution.scaleFactor(supported: [1.5, 2], width: 960, height: 540, target: screen) == 2)
        // Small window: 2× would overshoot, 1.5× fits.
        #expect(MLSuperResolution.scaleFactor(supported: [1.5, 2], width: 960, height: 540,
                                              target: CGSize(width: 1600, height: 900)) == 1.5)
    }

    @Test func fallsBackOrDeclines() {
        // Nothing fits but it's still an upscale: the smallest factor.
        #expect(MLSuperResolution.scaleFactor(supported: [1.5, 2], width: 1280, height: 720,
                                              target: CGSize(width: 1400, height: 800)) == 1.5)
        // Not upscaling at all, or no factors: no ML.
        #expect(MLSuperResolution.scaleFactor(supported: [1.5], width: 1280, height: 720,
                                              target: CGSize(width: 1280, height: 720)) == nil)
        #expect(MLSuperResolution.scaleFactor(supported: [], width: 1920, height: 1080, target: screen) == nil)
    }

    @Test func evenOutputsOnly() {
        #expect(MLSuperResolution.evenOutput(factor: 1.5, width: 1920, height: 1080)) // 2880×1620
        #expect(MLSuperResolution.evenOutput(factor: 2, width: 960, height: 540))
        #expect(!MLSuperResolution.evenOutput(factor: 1.5, width: 1920, height: 1078)) // 1617 rows
        #expect(!MLSuperResolution.evenOutput(factor: 1.5, width: 1918, height: 1080)) // 2877 columns
    }
}

@Suite struct MLTilingTests {
    @Test func framesTheModelTakesGoWhole() throws {
        let t = try #require(MLSuperResolution.tiling(width: 1280, height: 720))
        #expect(t == MLTiling(width: 1280, height: 720, tiles: [.init(x: 0, keep: 0..<1280)]))
        #expect(t.isWholeFrame(width: 1280, height: 720))
    }

    @Test func rowsArePaddedToMultiplesOf16() throws {
        // The model fails on 540 rows: one 960×544 tile, the last 4 rows repeated.
        let t = try #require(MLSuperResolution.tiling(width: 960, height: 540))
        #expect(t == MLTiling(width: 960, height: 544, tiles: [.init(x: 0, keep: 0..<960)]))
        #expect(!t.isWholeFrame(width: 960, height: 540))
    }

    @Test func wideFramesAreCutIntoOverlappingTiles() throws {
        let t = try #require(MLSuperResolution.tiling(width: 1920, height: 1080))
        #expect(t.width == 1088 && t.height == 1088)
        #expect(t.tiles == [.init(x: 0, keep: 0..<960), .init(x: 832, keep: 960..<1920)])
        // Every tile holds the columns it keeps, with context around each cut, and the tiles cover the frame.
        for tile in t.tiles {
            #expect(tile.x <= tile.keep.lowerBound && tile.x + t.width >= tile.keep.upperBound)
            #expect(tile.x + t.width <= 1920 && tile.x % 4 == 0 && tile.keep.lowerBound % 4 == 0)
            if tile.keep.lowerBound > 0 { #expect(tile.keep.lowerBound - tile.x >= MLSuperResolution.overlap) }
            if tile.keep.upperBound < 1920 { #expect(tile.x + t.width - tile.keep.upperBound >= MLSuperResolution.overlap) }
        }
        #expect(t.tiles.map(\.keep.count).reduce(0, +) == 1920)
    }

    /// Cuts the second tile out of a 1080p frame the way `encode` does, bottom rows repeated into the padding.
    /// Plain Metal and CoreVideo, so it runs without the model (in CI's VM too).
    @Test func cutsAPaddedTileOutOfTheFrame() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        var cacheOut: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cacheOut)
        let cache = try #require(cacheOut)
        // Luma tells the column band and row apart: x / 64 + 1 (1-30); 200 on the last 8 rows.
        let frame = try makeNV12(width: 1920, height: 1080, luma: { x, y in y >= 1072 ? 200 : UInt8(x / 64 + 1) },
                                 chroma: { x, _ in (UInt8(x / 32), 128) })
        let tiling = try #require(MLSuperResolution.tiling(width: 1920, height: 1080))
        let tile = try #require(tiling.tiles.last)
        let pool = try #require(MLSuperResolution.makePool(MLSuperResolution.nv12Attributes(
            CVPixelBufferGetPixelFormatType(frame), tiling.width, tiling.height)))
        let out = try #require(MLSuperResolution.buffer(from: pool))
        let from = try #require(MLSuperResolution.planes(frame, cache: cache))
        let to = try #require(MLSuperResolution.planes(out, cache: cache))
        let cb = try #require(queue.makeCommandBuffer())
        let blit = try #require(cb.makeBlitCommandEncoder())
        MLSuperResolution.copy(blit, from, x: tile.x, y: 0, width: tiling.width, height: 1080, to: to, x: 0, y: 0)
        MLSuperResolution.copy(blit, from, x: tile.x, y: 1072, width: tiling.width, height: 8, to: to, x: 0, y: 1080)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        #expect(CVPixelBufferGetWidth(out) == 1088 && CVPixelBufferGetHeight(out) == 1088)
        CVPixelBufferLockBaseAddress(out, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(out, 0)).assumingMemoryBound(to: UInt8.self)
        let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(out, 1)).assumingMemoryBound(to: UInt8.self)
        let ls = CVPixelBufferGetBytesPerRowOfPlane(out, 0), cs = CVPixelBufferGetBytesPerRowOfPlane(out, 1)
        #expect(luma[0] == UInt8(832 / 64 + 1)) // the tile starts at frame column 832
        #expect(luma[100 * ls + 1087] == UInt8(1919 / 64 + 1)) // and ends at the frame's right edge
        #expect(luma[1079 * ls + 10] == 200 && luma[1087 * ls + 10] == 200) // last row, then padding
        #expect(chroma[0] == UInt8(832 / 2 / 32)) // chroma moved with it (Cb of chroma column 416)
        #expect(chroma[543 * cs] == UInt8(832 / 2 / 32)) // padded chroma rows too
    }

    @Test func declinesWhatItCantTake() {
        #expect(MLSuperResolution.tiling(width: 2560, height: 1440) == nil) // taller than the model's limit
        #expect(MLSuperResolution.tiling(width: 1000, height: 720) == nil) // width not a multiple of 16
        #expect(MLSuperResolution.tiling(width: 0, height: 0) == nil)
        #expect(MLSuperResolution.tiling(width: 3840, height: 1080)?.tiles.count == 4)
    }
}

extension StreamRendererTests {
    @Test func mlParamDecodes() throws {
        let p = try JSONDecoder().decode(RenderParams.self, from: Data(#"{"mlUpscale":true}"#.utf8))
        #expect(p.mlUpscale && !RenderParams().mlUpscale)
    }

    /// A gray NV12 frame with a darker left half (so the compare baseline can be told apart).
    func mlFrame(width: Int, height: Int) throws -> CVPixelBuffer {
        try makeNV12(width: width, height: height, luma: { x, _ in x < width / 2 ? 90 : 160 },
                     chroma: { _, _ in (128, 128) })
    }

    /// Shows `frame` the way the app does: the screen area known from earlier draws, ML upscaling on its own
    /// lane (waited for here), then a draw.
    func show(_ r: StreamRenderer, _ frame: CVPixelBuffer, size: (Int, Int), index: UInt64? = nil) throws -> [UInt8] {
        r.setUpscaleTarget(drawableSize: CGSize(width: size.0, height: size.1))
        r.display(frame, index: index)
        r.waitForUpscaling()
        return try render(r, size: size)
    }

    @Test func mlUpscalesSmallStreamsWhereSupported() throws {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64))
        r.showsTestPattern = false
        r.params.mlUpscale = true
        r.params.sharpness = 0
        let out = try show(r, try mlFrame(width: 1280, height: 720), size: (2560, 1440))
        #expect(r.mlActive == r.mlSupported)
        guard r.mlSupported else { return } // older macOS / unsupported Mac / a VM: plain pipeline
        #expect(r.inputSize == (1920, 1080)) // 1.5× before the rest of the pipeline
        // Flat areas keep their brightness through the model.
        #expect(abs(pixel(out, width: 2560, x: 300, y: 700).g - 86) <= 6, "\(pixel(out, width: 2560, x: 300, y: 700))")
        #expect(abs(pixel(out, width: 2560, x: 2200, y: 700).g - 168) <= 6)
    }

    @Test func mlUpscales1080pInTiles() throws {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64))
        r.showsTestPattern = false
        r.params.mlUpscale = true
        r.params.sharpness = 0
        let out = try show(r, try mlFrame(width: 1920, height: 1080), size: (3840, 2160))
        #expect(r.mlActive == r.mlSupported)
        guard r.mlSupported else { return }
        #expect(r.inputSize == (2880, 1620)) // two tiles put back together
        // Both halves keep their brightness, the tile cut (in the middle of the dark half's right edge) and
        // the padded bottom rows included.
        for (x, y, g) in [(300, 1000, 86), (1880, 1000, 86), (1960, 1000, 168), (3500, 1000, 168), (300, 2150, 86), (3500, 2150, 168)] {
            #expect(abs(pixel(out, width: 3840, x: x, y: y).g - g) <= 6, "\(x),\(y): \(pixel(out, width: 3840, x: x, y: y))")
        }
    }

    @Test func mlUpscales540p() throws {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64))
        r.showsTestPattern = false
        r.params.mlUpscale = true
        r.params.sharpness = 0
        let out = try show(r, try mlFrame(width: 960, height: 540), size: (1920, 1080))
        #expect(r.mlActive == r.mlSupported)
        guard r.mlSupported else { return }
        #expect(r.inputSize == (1920, 1080)) // 2×, from a 960×544 padded tile
        #expect(abs(pixel(out, width: 1920, x: 300, y: 1070).g - 86) <= 6, "\(pixel(out, width: 1920, x: 300, y: 1070))")
        #expect(abs(pixel(out, width: 1920, x: 1600, y: 1070).g - 168) <= 6)
    }

    @Test func blockGridFollowsTheMLScale() {
        #expect(StreamRenderer.blockGrid(texture: 1280, decoded: 1280) == 8)
        #expect(StreamRenderer.blockGrid(texture: 1920, decoded: 1280) == 12)
        #expect(StreamRenderer.blockGrid(texture: 1920, decoded: 960) == 16)
        #expect(StreamRenderer.blockGrid(texture: 64, decoded: 0) == 8) // nothing decoded yet
    }

    @Test func aSmallWindowDoesNotDisableMLForGood() throws {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64))
        guard r.mlSupported else { return }
        r.showsTestPattern = false
        r.params.mlUpscale = true
        _ = try show(r, try mlFrame(width: 1280, height: 720), size: (1280, 720)) // no upscale needed: ML skipped
        #expect(!r.mlActive)
        // A jump in the index restarts the stream clock: shown at once, not one frame interval later.
        _ = try show(r, try mlFrame(width: 1280, height: 720), size: (2560, 1440), index: 1000) // bigger: ML again
        #expect(r.mlActive)
    }

    @Test func mlPassesThroughWhatItCantTake() throws {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64))
        r.showsTestPattern = false
        r.params.mlUpscale = true
        _ = try show(r, try mlFrame(width: 2560, height: 1440), size: (2560, 1440)) // taller than its 1280 px limit
        #expect(!r.mlActive)
        #expect(r.inputSize == (2560, 1440))
        r.params.mlUpscale = false
        // A jump in the index restarts the stream clock: shown at once, not one frame interval later.
        _ = try show(r, try mlFrame(width: 1280, height: 720), size: (2560, 1440), index: 1000)
        #expect(!r.mlActive && r.inputSize == (1280, 720))
    }

    @Test func compareBaselineStaysRawWithML() throws {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64))
        guard r.mlSupported else { return }
        r.showsTestPattern = false
        r.params.mlUpscale = true
        r.params.compare = true
        let out = try show(r, try mlFrame(width: 1280, height: 720), size: (2560, 1440))
        #expect(r.mlActive)
        // Left half: the raw stream (dark); right half: processed (light) — split at the center line.
        #expect(abs(pixel(out, width: 2560, x: 300, y: 700).g - 86) <= 6)
        #expect(abs(pixel(out, width: 2560, x: 2200, y: 700).g - 168) <= 6)
        #expect(pixel(out, width: 2560, x: 1280, y: 700) == (255, 255, 255, 255))
    }
}
