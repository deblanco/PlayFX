import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

@Suite struct TakionCryptoTests {
    static let layouts: [GMACLayout] = [.control, .feedback, .av, .congestion]

    /// A datagram of `length` random bytes (at least big enough for the layout's fields).
    func datagram(_ length: Int, _ layout: GMACLayout, _ rng: inout LCG) -> [UInt8] {
        let n = max(length, layout.keyPosOffset + 4, layout.gmacOffset + 4)
        return (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
    }

    /// `GKCryptContext.gmac` against CryptoKit's AES-GCM with a 16-byte nonce (inside `RefCrypto`), over random
    /// lengths 0...2048, all four layouts, epochs 0...200 and key positions above 2^32.
    @Test func gmacMatchesCryptoKit() {
        var rng = LCG(state: 2024)
        let contexts = [(2, GKCryptContext(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey, index: 2)),
                        (3, GKCryptContext(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey, index: 3, prefetch: true))]
        for (index, context) in contexts {
            let ref = RefCrypto(index: UInt8(index))
            var cases = 0
            // Lengths around block boundaries, then random ones.
            var lengths = [0, 1, 15, 16, 17, 31, 32, 33, 47, 48, 64, 1400, 2047, 2048]
            for _ in 0..<60 { lengths.append(Int.random(in: 0...2048, using: &rng)) }
            for length in lengths {
                let layout = Self.layouts[cases % 4]
                cases += 1
                var d = datagram(length, layout, &rng)
                let epoch = UInt64.random(in: 0...200, using: &rng)
                let high = cases % 5 == 0
                let keyPos: UInt64 = high ? (1 << 32) + UInt64.random(in: 0..<(1 << 40), using: &rng)
                                          : (epoch == 0 ? UInt64.random(in: 0...45000, using: &rng) : epoch * 45000 + UInt64.random(in: 1...45000, using: &rng))
                let before = d
                let tag = d.withUnsafeMutableBytes { context.gmac(of: $0, layout: layout, keyPos: keyPos) }
                #expect(d == before, "gmac() must restore the packet")
                let expected = ref.gmac(d, gmacAt: layout.gmacOffset, keyPosAt: layout.keyPosOffset, zeroKeyPos: layout.zeroKeyPos, keyPos: keyPos)
                #expect(be32(tag) == expected, "index \(index) length \(d.count) layout \(layout) keyPos \(keyPos)")
            }
        }
    }

    @Test func sealAndVerifyRoundTripAndReject() {
        let up = GKCryptContext(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey, index: 2)
        let verifier = GKCryptContext(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey, index: 2)
        var d = [UInt8](repeating: 9, count: 60)
        d.withUnsafeMutableBytes { up.seal($0, layout: .feedback, keyPos: 123_456) }
        d.withUnsafeMutableBytes {
            #expect(verifier.verify($0, layout: .feedback, keyPos: 123_456))
            #expect(!verifier.verify($0, layout: .feedback, keyPos: 123_457 + 16))
            #expect(!verifier.verify($0, layout: .av, keyPos: 123_456))
        }
    }

    /// Forged far-future key positions must not evict live keys, move the newest epoch or stop prefetching.
    @Test func forgedKeyPositionsLeaveTheCachesAlone() throws {
        let ref = RefCrypto(index: 3)
        let ctx = GKCryptContext(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey, index: 3, prefetch: true)
        func valid(epoch: UInt64) -> [UInt8] {
            let k = epoch * 45000 + 100
            var d = [UInt8](repeating: 3, count: 40)
            d = ref.sealed(d, gmacAt: 10, keyPosAt: 14, zeroKeyPos: false, keyPos: k)
            return d
        }
        func accepts(_ epoch: UInt64) -> Bool {
            var d = valid(epoch: epoch)
            return d.withUnsafeMutableBytes { ctx.verify($0, layout: .av, keyPos: epoch * 45000 + 100) }
        }
        for e: UInt64 in [1, 2, 3] { #expect(accepts(e)) }
        #expect(ctx.cachedEpochList == [1, 2, 3])
        #expect(ctx.newestCommittedEpoch == 3)
        #expect(eventually { ctx.isPrefetched(4) })
        // Forged packets at ten far epochs (and one at the very next epoch): wrong tags.
        for e: UInt64 in [50, 900, 70_000, 400_000_000, 4, 6000, 7000, 8000, 9000, 10_000] {
            var forged = valid(epoch: e)
            forged[10] ^= 0xff
            let ok = forged.withUnsafeMutableBytes { ctx.verify($0, layout: .av, keyPos: e * 45000 + 100) }
            #expect(!ok)
        }
        #expect(ctx.cachedEpochList == [1, 2, 3])
        #expect(ctx.newestCommittedEpoch == 3)
        #expect(ctx.isPrefetched(4), "a forged packet at epoch 4 must not consume the prefetched key")
        // The live keys still verify, and so does the next epoch, which then moves the schedule on.
        for e: UInt64 in [1, 2, 3, 4] { #expect(accepts(e)) }
        #expect(ctx.newestCommittedEpoch == 4)
        #expect(eventually { ctx.isPrefetched(5) })
    }

    /// Epoch 0 is pinned: it verifies after every other key was evicted, and it is G(cipherKey, 0).
    @Test func epochZeroSurvivesEviction() {
        let ref = RefCrypto(index: 3)
        let ctx = GKCryptContext(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey, index: 3)
        for e: UInt64 in 1...9 {
            var d = ref.sealed([UInt8](repeating: 1, count: 30), gmacAt: 10, keyPosAt: 14, zeroKeyPos: false, keyPos: e * 45000 + 5)
            #expect(d.withUnsafeMutableBytes { ctx.verify($0, layout: .av, keyPos: e * 45000 + 5) })
        }
        #expect(ctx.cachedEpochList == [6, 7, 8, 9])
        for k: UInt64 in [0, 1, 16, 45000] {
            var d = ref.sealed([UInt8](repeating: 2, count: 30), gmacAt: 10, keyPosAt: 14, zeroKeyPos: false, keyPos: k)
            #expect(d.withUnsafeMutableBytes { ctx.verify($0, layout: .av, keyPos: k) }, "keyPos \(k)")
        }
        #expect(ctx.gmacKey0 == ref.gmacKey(epoch: 0))
    }

    @Test func softwareTimestampsAreFlagged() throws {
        let h = try MemoryHarness.secured()
        var d = h.console.video(index: 0)
        d.withUnsafeMutableBytes { h.connection.transportDidReceive($0, at: takionNow(), kernelTimestamp: false) }
        #expect(h.connection.stats.softwareTimestamps == 1)
        h.deliver(h.console.video(index: 1))
        #expect(h.connection.stats.softwareTimestamps == 1)
    }
}
