/// Reads the bit fields of H.264/H.265 syntax (ITU-T H.264 section 7.2, H.265 section 7.2) from an RBSP,
/// i.e. bytes with the emulation-prevention bytes already removed.
///
/// Reading past the end doesn't trap: it returns zeros and sets `overrun`, which parsers check once at the end.
struct BitReader {
    private let bytes: [UInt8]
    private(set) var position = 0
    private(set) var overrun = false

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var bitCount: Int { bytes.count * 8 }

    mutating func bit() -> UInt32 {
        guard position < bitCount else {
            overrun = true
            return 0
        }
        let value = (bytes[position >> 3] >> UInt8(7 - (position & 7))) & 1
        position += 1
        return UInt32(value)
    }

    /// `u(n)`, n in 0...32.
    mutating func bits(_ n: Int) -> UInt32 {
        var v: UInt64 = 0
        for _ in 0..<n { v = (v << 1) | UInt64(bit()) }
        return UInt32(truncatingIfNeeded: v)
    }

    mutating func skip(_ n: Int) {
        position += n
        if position > bitCount {
            position = bitCount
            overrun = true
        }
    }

    /// `ue(v)`: unsigned Exp-Golomb. A prefix longer than 31 zeros is invalid and sets `overrun`.
    mutating func ue() -> UInt32 {
        var zeros = 0
        while bit() == 0 {
            if overrun { return 0 }
            zeros += 1
            if zeros > 31 {
                overrun = true
                return 0
            }
        }
        return (UInt32(1) << UInt32(zeros)) - 1 + bits(zeros)
    }

    /// `se(v)`: signed Exp-Golomb.
    mutating func se() -> Int64 {
        let k = Int64(ue())
        return k & 1 == 1 ? (k + 1) / 2 : -(k / 2)
    }
}

enum NALEscape {
    /// Removes the emulation-prevention bytes (`00 00 03` -> `00 00`) from `source[from ..< from + limit]`
    /// (clamped to the data, and stopping at the next start code) into `rbsp`, and records in `origin` where each output byte came from.
    static func unescape(
        _ source: UnsafeRawBufferPointer, from: Int, limit: Int, into rbsp: inout [UInt8],
        origin: inout [Int]
    ) {
        rbsp.removeAll(keepingCapacity: true)
        origin.removeAll(keepingCapacity: true)
        let end = min(source.count, from + max(limit, 0))
        var zeros = 0
        var i = max(from, 0)
        while i < end {
            let b = source[i]
            if zeros >= 2 && b < 3 {
                break  // `00 00 00` or `00 00 01`: the next start code, i.e. the end of this NAL unit
            } else if zeros >= 2 && b == 3 {
                zeros = 0
            } else {
                rbsp.append(b)
                origin.append(i)
                zeros = b == 0 ? zeros + 1 : 0
            }
            i += 1
        }
    }

    /// Whole-buffer variant for parameter sets.
    static func unescape(_ bytes: UnsafeRawBufferPointer) -> [UInt8] {
        var rbsp: [UInt8] = []
        var origin: [Int] = []
        unescape(bytes, from: 0, limit: bytes.count, into: &rbsp, origin: &origin)
        return rbsp
    }
}
