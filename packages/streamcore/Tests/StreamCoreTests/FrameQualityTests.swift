import Testing
@testable import StreamCore

@Suite struct FrameQualityTests {
    /// A 160×90 BGRA image (10×10 px tiles on the 16×9 grid), every colour byte `value`, with the tile at
    /// (`column`, `row`) set to its own `value` when given. Rows are padded to 656 bytes, as CoreVideo pads them.
    static func image(_ value: UInt8, tile: (column: Int, row: Int, value: UInt8)? = nil) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: rowBytes * 90)
        for y in 0..<90 {
            for x in 0..<160 {
                var v = value
                if let tile, x / 10 == tile.column, y / 10 == tile.row { v = tile.value }
                for c in 0..<3 { bytes[y * rowBytes + x * 4 + c] = v }
            }
        }
        return bytes
    }
    static let rowBytes = 656

    static func quality(_ a: [UInt8], _ b: [UInt8], width: Int = 160, height: Int = 90) -> FrameQuality {
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                FrameQuality(pa.baseAddress!, rowBytes: rowBytes, pb.baseAddress!, rowBytes: rowBytes,
                             width: width, height: height)
            }
        }
    }

    @Test func identicalFramesScorePerfect() {
        let frame = Self.image(100, tile: (column: 3, row: 4, value: 7))
        #expect(Self.quality(frame, frame) == FrameQuality(psnr: FrameQuality.identical, worstTile: FrameQuality.identical))
    }

    @Test func theWorstTileCatchesWhatTheMeanHides() {
        // Everywhere 2 off (42.1 dB); then one tile 20 off, like a small object gone from a generated frame.
        let real = Self.image(100)
        let close = Self.quality(Self.image(102), real)
        let missing = Self.quality(Self.image(102, tile: (column: 15, row: 8, value: 120)), real)
        #expect(abs(close.psnr - 42.11) < 0.01 && abs(close.worstTile - close.psnr) < 1e-9) // uniform: tiles = frame
        #expect(close.psnr - missing.psnr < 2.5) // the whole frame barely moves…
        #expect(abs(missing.worstTile - 22.11) < 0.01) // …the tile drops 20 dB
    }

    @Test func anImageSmallerThanTheGridStillScores() {
        // 8×4 pixels on a 16×9 grid: half the tiles get no pixels and don't count as the worst.
        let same = Self.quality(Self.image(50), Self.image(50), width: 8, height: 4)
        #expect(same.worstTile == FrameQuality.identical)
        let off = Self.quality(Self.image(52), Self.image(50), width: 8, height: 4)
        #expect(abs(off.psnr - 42.11) < 0.01 && abs(off.worstTile - off.psnr) < 1e-9)
    }
}
