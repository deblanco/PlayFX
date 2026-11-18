import CoreVideo
import Testing
@testable import StreamCore

extension StreamRendererTests {
    /// Green channel along the middle row of a gray frame with luma `luma(x)`, rendered 1:1 with
    /// bilinear and no sharpening, after the given cleanup.
    func grayRow(deblock: Float = 0, deband: Float = 0, compare: Bool = false,
                 luma: @escaping (Int) -> UInt8) throws -> [Int] {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64))
        r.showsTestPattern = false
        r.params.upscaler = .bilinear
        r.params.sharpness = 0
        r.params.deblock = deblock
        r.params.deband = deband
        r.params.compare = compare
        r.display(try makeNV12(width: 64, height: 64, cb: 128, cr: 128) { x, _ in luma(x) })
        let out = try render(r, size: (64, 64))
        return (0..<64).map { pixel(out, width: 64, x: $0, y: 32).g }
    }

    /// Blocks of 8 columns alternating between two luma values.
    func blocks(_ a: UInt8, _ b: UInt8) -> (Int) -> UInt8 { { ($0 / 8) % 2 == 0 ? a : b } }

    @Test func deblockSmoothsSmallGridStepsOnly() throws {
        let raw = try grayRow(luma: blocks(100, 104))
        let fixed = try grayRow(deblock: 1, luma: blocks(100, 104))
        // The step across the 8-pixel grid line shrinks; block interiors stay put.
        #expect(abs(fixed[8] - fixed[7]) < abs(raw[8] - raw[7]), "fixed \(fixed[6...9]) raw \(raw[6...9])")
        #expect(fixed[3] == raw[3] && fixed[12] == raw[12])
        // A real edge (large step) is left alone.
        let edge = try grayRow(luma: blocks(60, 200)), kept = try grayRow(deblock: 1, luma: blocks(60, 200))
        #expect(kept == edge)
    }

    @Test func debandRemovesBandStepsButKeepsEdges() throws {
        // A gentle gradient quantized into bands 3 codes apart every 16 pixels.
        let banded: (Int) -> UInt8 = { UInt8(90 + 3 * ($0 / 16)) }
        let jumps = { (row: [Int]) in zip(row, row.dropFirst()).filter { abs($0 - $1) >= 3 }.count }
        let raw = try grayRow(luma: banded), smooth = try grayRow(deband: 1, luma: banded)
        #expect(jumps(raw) >= 3)
        #expect(jumps(smooth) < jumps(raw), "raw \(raw) smooth \(smooth)")
        // A real edge stays sharp: still one big jump.
        let half: (Int) -> UInt8 = { $0 < 32 ? 60 : 200 }
        let edge = try grayRow(deband: 1, luma: half)
        #expect(abs(edge[32] - edge[31]) > 100)
        #expect(abs(edge[8] - 52) <= 2 && abs(edge[56] - 215) <= 2) // flat areas only get faint dither
    }

    @Test func cleanupOffIsIdentityAndCompareBaselineIsRaw() throws {
        let raw = try grayRow(luma: blocks(100, 104))
        #expect(try grayRow(deblock: 0, deband: 0, luma: blocks(100, 104)) == raw)
        // Compare: the left half is the unprocessed baseline even with cleanup on.
        let split = try grayRow(deblock: 1, compare: true, luma: blocks(100, 104))
        #expect(split[7] == raw[7] && split[8] == raw[8])
        let fixed = try grayRow(deblock: 1, luma: blocks(100, 104))
        #expect(split[40] == fixed[40] && split[39] == fixed[39]) // right half processed
    }

    @Test func cleanupFollowsInputSizeChanges() throws {
        let r = try #require(StreamRenderer(inputWidth: 64, inputHeight: 64))
        r.showsTestPattern = false
        r.params.deband = 0.5
        r.display(try makeNV12(width: 64, height: 64, y: 120, cb: 128, cr: 128))
        _ = try render(r, size: (128, 128))
        r.display(try makeNV12(width: 32, height: 32, y: 120, cb: 128, cr: 128))
        let out = try render(r, size: (128, 128))
        #expect(r.inputSize == (32, 32))
        #expect(abs(pixel(out, width: 128, x: 64, y: 64).g - 121) <= 3)
    }
}
