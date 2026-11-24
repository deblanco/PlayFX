import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

@Suite("AV: GF(2^8) and the erasure code")
struct FECTests {
    let gf = GF256.shared

    @Test("V-AV1: field arithmetic")
    func fieldVectors() {
        #expect(gf.exp[8] == 0x1d)
        #expect(gf.log[3] == 25)
        #expect(gf.multiply(0x02, 0x80) == 0x1d)
        #expect(gf.multiply(0x53, 0xca) == 0x8f)
        #expect(gf.multiply(0xff, 0xff) == 0xe2)
        #expect(gf.inverse(0x02) == 0x8e)
        #expect(gf.inverse(0x03) == 0xf4)
        #expect(gf.inverse(0x53) == 0x8c)
        #expect(gf.multiply(0, 0x53) == 0)
    }

    @Test("the tables agree with shift-and-add multiplication and with inverses, for every pair")
    func tablesAgreeWithReference() {
        for a in 0..<256 {
            for b in 0..<256 {
                #expect(gf.multiply(UInt8(a), UInt8(b)) == ReferenceFEC.multiply(UInt8(a), UInt8(b)))
            }
            if a > 0 { #expect(gf.multiply(UInt8(a), gf.inverse(UInt8(a))) == 1) }
        }
    }

    @Test("V-AV2: coding matrices")
    func codingMatrices() {
        let decoder = FECDecoder()
        #expect(decoder.codingMatrix(k: 4, m: 3) == hex("f447a77a 8ea747ba 017aba47"))
        #expect(decoder.codingMatrix(k: 17, m: 1) == hex("018ef447a77abaad9ddd983daa5d96d872"))
        #expect(decoder.codingMatrix(k: 1, m: 1) == [1])
        #expect(decoder.codingMatrix(k: 4, m: 3).chunks(ofCount: 4).map(Array.init) == ReferenceFEC.matrix(k: 4, m: 3))
    }

    @Test("the matrix depends on m, not just k")
    func matrixDependsOnM() {
        let decoder = FECDecoder()
        #expect(decoder.codingMatrix(k: 4, m: 3)[0..<4] != decoder.codingMatrix(k: 4, m: 2)[0..<4])
    }

    static let source: [[UInt8]] = (0..<4).map { j in (0..<8).map { UInt8(16 * j + $0) } }

    @Test("V-AV3: encoding k=4 m=3 S=8")
    func encodingVector() {
        let parity = ReferenceFEC.encode(source: Self.source, m: 3)
        #expect(parity[0] == hex("553b89e7f09e2c42"))
        #expect(parity[1] == hex("1bcfae7a6cb8d90d"))
        #expect(parity[2] == hex("21a730b603851294"))
    }

    /// Decodes with the given units missing and returns the source units afterwards.
    func decode(k: Int, m: Int, units: [[UInt8]], missing: Set<Int>, method: GF256.Method = .default) -> [[UInt8]]? {
        let size = units[0].count
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: units.count * size)
        let present = UnsafeMutablePointer<Bool>.allocate(capacity: units.count)
        defer {
            storage.deallocate()
            present.deallocate()
        }
        for (u, bytes) in units.enumerated() {
            present[u] = !missing.contains(u)
            for t in 0..<size { storage[u * size + t] = missing.contains(u) ? 0x42 : bytes[t] }
        }
        guard FECDecoder(method: method).recover(k: k, m: m, size: size, storage: storage, present: present)
        else { return nil }
        return (0..<k).map { j in Array(UnsafeBufferPointer(start: storage + j * size, count: size)) }
    }

    @Test("V-AV4: units 0, 2 and 5 missing are recovered; only parity left is unrecoverable")
    func decodingVectors() {
        let units = Self.source + ReferenceFEC.encode(source: Self.source, m: 3)
        #expect(decode(k: 4, m: 3, units: units, missing: [0, 2, 5]) == Self.source)
        #expect(decode(k: 4, m: 3, units: units, missing: [0, 1, 2, 3]) == nil)
        #expect(decode(k: 4, m: 3, units: units, missing: []) == Self.source)
        #expect(decode(k: 4, m: 3, units: units, missing: [4, 5, 6]) == Self.source)
    }

    @Test("every multiply method equals the reference, for odd sizes and every coefficient class")
    func regionMethods() {
        var rng = SeededRandom(1)
        for size in [1, 15, 16, 17, 63, 64, 65, 200, 1400] {
            let src = (0..<size).map { _ in UInt8.random(in: 0...255, using: &rng) }
            let base = (0..<size).map { _ in UInt8.random(in: 0...255, using: &rng) }
            for c in [0, 1, 2, 0x1d, 0x53, 0x80, 0xff] as [UInt8] {
                let expected = (0..<size).map { base[$0] ^ ReferenceFEC.multiply(c, src[$0]) }
                for method in GF256.Method.available {
                    var dst = base
                    dst.withUnsafeMutableBufferPointer { d in
                        src.withUnsafeBufferPointer { s in
                            gf.multiplyAdd(d.baseAddress!, s.baseAddress!, by: c, count: size, method: method)
                        }
                    }
                    #expect(dst == expected, "method \(method) c \(c) size \(size)")
                }
            }
        }
    }

    @Test("region multiply-add on misaligned pointers and sizes up to 1500 bytes, every method")
    func regionMisaligned() {
        var rng = SeededRandom(33)
        let capacity = 1500 + 32
        let srcBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer {
            srcBuffer.deallocate()
            dstBuffer.deallocate()
        }
        for _ in 0..<300 {
            let size = Int.random(in: 0...1500, using: &rng)
            let srcOffset = Int.random(in: 0...15, using: &rng)
            let dstOffset = Int.random(in: 0...15, using: &rng)
            let c = UInt8.random(in: 0...255, using: &rng)
            for i in 0..<capacity {
                srcBuffer[i] = .random(in: 0...255, using: &rng)
                dstBuffer[i] = .random(in: 0...255, using: &rng)
            }
            let before = Array(UnsafeBufferPointer(start: dstBuffer, count: capacity))
            var expected = before
            for t in 0..<size { expected[dstOffset + t] ^= ReferenceFEC.multiply(c, srcBuffer[srcOffset + t]) }
            for method in GF256.Method.available {
                for i in 0..<capacity { dstBuffer[i] = before[i] }
                gf.multiplyAdd(dstBuffer + dstOffset, srcBuffer + srcOffset, by: c, count: size, method: method)
                // Bytes outside the region must be untouched too.
                #expect(Array(UnsafeBufferPointer(start: dstBuffer, count: capacity)) == expected, "\(method) c \(c) size \(size) offsets \(srcOffset) \(dstOffset)")
            }
        }
    }

    @Test("m in {2, 4, 8, 56} with several erasures, checked against the independent encoder")
    func parityCounts() {
        var rng = SeededRandom(8)
        for m in [2, 4, 8, 56] {
            for k in [1, 3, 17, 60, 200] where k + m <= 256 {
                let size = Int.random(in: 1...300, using: &rng)
                let source = (0..<k).map { _ in (0..<size).map { _ in UInt8.random(in: 0...255, using: &rng) } }
                let units = source + ReferenceFEC.encode(source: source, m: m)
                // e > 1 erasures: lose as many source units as there is parity (all of it when k >= m), and a
                // different mix of source and parity.
                let sourceLosses = Set((0..<k).shuffled(using: &rng).prefix(min(k, m)))
                #expect(decode(k: k, m: m, units: units, missing: sourceLosses) == source, "k \(k) m \(m) source losses")
                if m >= 2, k >= 2 {
                    let mixed = Set((0..<(k + m)).shuffled(using: &rng).prefix(m))
                    #expect(decode(k: k, m: m, units: units, missing: mixed) == source, "k \(k) m \(m) mixed")
                }
                // One more than the parity can cover is refused.
                if k > m {
                    let tooMany = Set((0..<k).shuffled(using: &rng).prefix(m + 1))
                    #expect(decode(k: k, m: m, units: units, missing: tooMany) == nil)
                }
            }
        }
    }

    @Test("randomised: decode equals the source (V-AV5 shape), k up to 200, m up to 56")
    func randomisedErasures() {
        var rng = SeededRandom(0xfec)
        var cases: [(k: Int, m: Int, size: Int)] = [(200, 56, 48), (1, 1, 1), (255, 1, 9), (1, 255, 5), (4, 3, 8)]
        for _ in 0..<300 {
            let m = Int.random(in: 1...56, using: &rng)
            let k = Int.random(in: 1...min(200, 256 - m), using: &rng)
            cases.append((k, m, Int.random(in: 1...120, using: &rng)))
        }
        for (k, m, size) in cases {
            let source = (0..<k).map { _ in (0..<size).map { _ in UInt8.random(in: 0...255, using: &rng) } }
            let units = source + ReferenceFEC.encode(source: source, m: m)
            let losses = Int.random(in: 0...m, using: &rng)
            let missing = Set((0..<(k + m)).shuffled(using: &rng).prefix(losses))
            #expect(decode(k: k, m: m, units: units, missing: missing) == source, "k \(k) m \(m) S \(size) lost \(losses)")
        }
    }

    @Test("every method decodes the same way")
    func methodsDecodeAlike() {
        var rng = SeededRandom(9)
        let source = (0..<30).map { _ in (0..<333).map { _ in UInt8.random(in: 0...255, using: &rng) } }
        let units = source + ReferenceFEC.encode(source: source, m: 8)
        for method in GF256.Method.available {
            #expect(decode(k: 30, m: 8, units: units, missing: [0, 5, 6, 29, 33, 37], method: method) == source)
        }
    }

    @Test("limits: too many missing, k + m over 256, zero sizes, and nothing to do")
    func limits() {
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        let present = UnsafeMutablePointer<Bool>.allocate(capacity: 600)
        defer {
            storage.deallocate()
            present.deallocate()
        }
        present.initialize(repeating: false, count: 600)
        let decoder = FECDecoder()
        #expect(!decoder.recover(k: 2, m: 1, size: 4, storage: storage, present: present))  // 3 missing, 0 parity... 
        #expect(!decoder.recover(k: 200, m: 57, size: 4, storage: storage, present: present))
        #expect(!decoder.recover(k: 2, m: 1, size: 0, storage: storage, present: present))
        #expect(!decoder.recover(k: 0, m: 1, size: 4, storage: storage, present: present))
        present[0] = true
        present[1] = true
        #expect(decoder.recover(k: 2, m: 0, size: 4, storage: storage, present: present))  // nothing missing
        present[1] = false
        #expect(!decoder.recover(k: 2, m: 0, size: 4, storage: storage, present: present))  // no parity at all
    }

    @Test("a large frame grows the scratch memory once and still decodes")
    func largeScratch() {
        var rng = SeededRandom(4)
        let size = 4096
        let source = (0..<40).map { _ in (0..<size).map { _ in UInt8.random(in: 0...255, using: &rng) } }
        let units = source + ReferenceFEC.encode(source: source, m: 20)
        #expect(decode(k: 40, m: 20, units: units, missing: Set(0..<20)) == source)
    }
}

extension Array {
    func chunks(ofCount n: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: n).map { self[$0..<Swift.min($0 + n, count)] }
    }
}
