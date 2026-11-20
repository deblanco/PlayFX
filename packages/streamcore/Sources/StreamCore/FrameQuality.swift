import Foundation

/// How close a made image is to the real one: PSNR over the colour channels of two BGRA images, for the
/// whole frame and for the worst tile of a grid (16×9 by default). A fast object missing from a generated
/// frame barely moves the whole frame's score but sinks the tile it was in. Used by `psrp interpolate --truth`.
public struct FrameQuality: Equatable, Sendable {
    /// What identical images (or tiles) score, in place of infinity.
    public static let identical = 99.0

    /// PSNR (dB) of the whole frame.
    public let psnr: Double
    /// PSNR (dB) of the worst tile.
    public let worstTile: Double

    public init(psnr: Double, worstTile: Double) {
        self.psnr = psnr
        self.worstTile = worstTile
    }

    /// Compares two BGRA images of the same `width`×`height`, whose rows are `rowBytes` apart (alpha ignored).
    public init(_ a: UnsafePointer<UInt8>, rowBytes ra: Int, _ b: UnsafePointer<UInt8>, rowBytes rb: Int,
                width: Int, height: Int, columns: Int = 16, rows: Int = 9) {
        var errors = [Int](repeating: 0, count: columns * rows), samples = errors
        for y in 0..<height {
            let row = y * rows / height * columns
            for x in 0..<width {
                var error = 0
                for c in 0..<3 {
                    let d = Int(a[y * ra + x * 4 + c]) - Int(b[y * rb + x * 4 + c])
                    error += d * d
                }
                let tile = row + x * columns / width
                errors[tile] += error
                samples[tile] += 3
            }
        }
        psnr = Self.psnr(errors.reduce(0, +), samples.reduce(0, +))
        // A tile with no pixels (an image narrower than the grid) has no error and scores `identical`.
        worstTile = zip(errors, samples).map { Self.psnr($0, $1) }.min() ?? Self.identical
    }

    /// PSNR (dB) from a sum of squared errors over `samples` values.
    static func psnr(_ squaredErrors: Int, _ samples: Int) -> Double {
        guard squaredErrors > 0 else { return identical }
        return 10 * log10(255 * 255 / (Double(squaredErrors) / Double(samples)))
    }
}
