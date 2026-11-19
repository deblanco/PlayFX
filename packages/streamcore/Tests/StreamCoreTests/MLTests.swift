import CoreGraphics
import CoreVideo
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

    @Test func mlUpscalesSmallStreamsWhereSupported() throws {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64))
        r.showsTestPattern = false
        r.params.mlUpscale = true
        r.params.sharpness = 0
        r.display(try mlFrame(width: 1280, height: 720))
        let out = try render(r, size: (2560, 1440))
        #expect(r.mlActive == r.mlSupported)
        guard r.mlSupported else { return } // older macOS / unsupported Mac / a VM: plain pipeline
        #expect(r.inputSize == (1920, 1080)) // 1.5× before the rest of the pipeline
        // Flat areas keep their brightness through the model.
        #expect(abs(pixel(out, width: 2560, x: 300, y: 700).g - 86) <= 6, "\(pixel(out, width: 2560, x: 300, y: 700))")
        #expect(abs(pixel(out, width: 2560, x: 2200, y: 700).g - 168) <= 6)
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
        r.display(try mlFrame(width: 1280, height: 720))
        _ = try render(r, size: (1280, 720)) // no upscale needed: ML skipped
        #expect(!r.mlActive)
// A jump in the index restarts the stream clock: shown at once, not one frame interval later.
        r.display(try mlFrame(width: 1280, height: 720), index: 1000)
        _ = try render(r, size: (2560, 1440)) // bigger window: ML again
        #expect(r.mlActive)
    }

    @Test func mlPassesThroughWhatItCantTake() throws {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64))
        r.showsTestPattern = false
        r.params.mlUpscale = true
        r.display(try mlFrame(width: 1920, height: 1080)) // wider than its 1280 px limit
        _ = try render(r, size: (2560, 1440))
        #expect(!r.mlActive)
        #expect(r.inputSize == (1920, 1080))
        r.params.mlUpscale = false
        // A jump in the index restarts the stream clock: shown at once, not one frame interval later.
        r.display(try mlFrame(width: 1280, height: 720), index: 1000)
        _ = try render(r, size: (2560, 1440))
        #expect(!r.mlActive && r.inputSize == (1280, 720))
    }

    @Test func compareBaselineStaysRawWithML() throws {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64))
        guard r.mlSupported else { return }
        r.showsTestPattern = false
        r.params.mlUpscale = true
        r.params.compare = true
        r.display(try mlFrame(width: 1280, height: 720))
        let out = try render(r, size: (2560, 1440))
        #expect(r.mlActive)
        // Left half: the raw stream (dark); right half: processed (light) — split at the center line.
        #expect(abs(pixel(out, width: 2560, x: 300, y: 700).g - 86) <= 6)
        #expect(abs(pixel(out, width: 2560, x: 2200, y: 700).g - 168) <= 6)
        #expect(pixel(out, width: 2560, x: 1280, y: 700) == (255, 255, 255, 255))
    }
}
