import Foundation

@testable import PlayFXProtocol

/// A small deterministic generator (SplitMix64) so randomised tests are repeatable.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

/// The erasure code written separately from the decoder, straight from av.md section 3 with no tables:
/// shift-and-add field multiplication, inverse by exponentiation, and a plain per-byte encoder.
enum ReferenceFEC {
    static func multiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var a = a
        var b = b
        var product: UInt8 = 0
        while b != 0 {
            if b & 1 != 0 { product ^= a }
            let carry = a & 0x80
            a <<= 1
            if carry != 0 { a ^= 0x1d }
            b >>= 1
        }
        return product
    }

    /// Products and inverses by brute force, built once from `multiply` (independent of the decoder's tables).
    static let products: [UInt8] = (0..<65536).map { multiply(UInt8($0 >> 8), UInt8($0 & 0xff)) }
    static let inverses: [UInt8] = (0..<256).map { a in
        a == 0 ? 0 : UInt8((1..<256).first { products[a << 8 | $0] == 1 }!)
    }

    static func inverse(_ a: UInt8) -> UInt8 { inverses[Int(a)] }

    static func matrix(k: Int, m: Int) -> [[UInt8]] {
        (0..<m).map { i in (0..<k).map { j in inverse(UInt8(i ^ (m + j))) } }
    }

    /// The `m` parity units of `source` (all the same length).
    static func encode(source: [[UInt8]], m: Int) -> [[UInt8]] {
        let k = source.count
        let size = source.first?.count ?? 0
        let c = matrix(k: k, m: m)
        return (0..<m).map { i in
            (0..<size).map { t in
                var sum: UInt8 = 0
                for j in 0..<k { sum ^= products[Int(c[i][j]) << 8 | Int(source[j][t])] }
                return sum
            }
        }
    }
}

/// Runs `body` with the bytes as an `UnsafeRawBufferPointer`.
func withBytes<R>(_ bytes: [UInt8], _ body: (UnsafeRawBufferPointer) -> R) -> R {
    bytes.withUnsafeBytes(body)
}

func videoWord(index: Int, total: Int, fec: Int) -> UInt32 {
    UInt32(index) << 21 | UInt32(total - 1) << 10 | UInt32(fec)
}

func audioWord(total: Int, unitSize: Int, redundant: Int, source: Int) -> UInt32 {
    (UInt32(truncatingIfNeeded: total - 1) & 0xff) << 16 | UInt32(unitSize) << 8 | UInt32(redundant) << 4 | UInt32(source)
}

/// Everything a `VideoReceiver` reported.
final class VideoLog {
    struct Frame { var bytes: [UInt8]; var info: VideoFrameInfo }
    var frames: [Frame] = []
    var corrupt: [[UInt16]] = []
    var idr: [IDRReason] = []
    var rejecting: [Int] = []
    var parameterSets: [Int] = []
    var accept = true
    var now = 0.0

    func makeReceiver(profiles: [VideoProfile]? = nil) -> VideoReceiver {
        let receiver = VideoReceiver(
            callbacks: VideoCallbacks(
                accessUnit: { [self] bytes, info in
                    frames.append(Frame(bytes: Array(bytes), info: info))
                    return accept
                },
                parameterSets: { [self] index, _, _ in parameterSets.append(index) },
                corruptFrames: { [self] a, b in corrupt.append([a, b]) },
                needsIDR: { [self] reason in idr.append(reason) },
                decoderRejecting: { [self] n in rejecting.append(n) }),
            clock: { [self] in now })
        receiver.setProfiles(profiles ?? [VideoProfile(width: 1920, height: 1080, header: [])])
        return receiver
    }
}

extension VideoReceiver {
    /// Feeds one video unit.
    func feed(
        frame: UInt16, index: Int, total: Int, fec: Int, payload: [UInt8], profile: UInt8 = 0
    ) {
        payload.withUnsafeBytes { raw in
            receive(
                AVUnit(
                    kind: .video, frameIndex: frame, unitWord: videoWord(index: index, total: total, fec: fec),
                    codec: 3, adaptiveStreamIndex: profile, payload: raw))
        }
    }
}

/// Annex-B access unit of one slice for the given slice-header bytes: `00 00 00 01 | nal bytes`.
func annexB(_ nal: [UInt8]) -> [UInt8] { [0, 0, 0, 1] + nal }

/// A bit string writer for building parameter sets and slice headers.
struct BitWriter {
    var bytes: [UInt8] = []
    var bitCount = 0

    mutating func bit(_ b: Int) {
        if bitCount % 8 == 0 { bytes.append(0) }
        if b != 0 { bytes[bytes.count - 1] |= 0x80 >> UInt8(bitCount % 8) }
        bitCount += 1
    }

    mutating func bits(_ value: Int, _ n: Int) {
        for i in stride(from: n - 1, through: 0, by: -1) { bit((value >> i) & 1) }
    }

    mutating func ue(_ v: Int) {
        let x = v + 1
        let length = Int.bitWidth - x.leadingZeroBitCount
        bits(0, length - 1)
        bits(x, length)
    }

    mutating func se(_ v: Int) { ue(v > 0 ? 2 * v - 1 : -2 * v) }

    /// The RBSP trailing bits, then the byte array.
    mutating func finish() -> [UInt8] {
        bit(1)
        while bitCount % 8 != 0 { bit(0) }
        return bytes
    }
}

/// Inserts emulation-prevention bytes.
func escape(_ rbsp: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    var zeros = 0
    for b in rbsp {
        if zeros >= 2 && b <= 3 {
            out.append(3)
            zeros = 0
        }
        out.append(b)
        zeros = b == 0 ? zeros + 1 : 0
    }
    return out
}
