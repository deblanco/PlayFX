import CommonCrypto
import CryptoKit
import Foundation

// GKCrypt (takion.md §6): the per-direction stream cipher and the 4-byte GMAC. A context is created once, when
// the stream keys exist, and then works on raw buffers without allocating: the AES cryptors, the GHASH tables
// and the scratch blocks all live for the context's lifetime. A context is not thread safe; its owner
// serialises access (the send lock for `ctxUp`, the receive thread for `ctxDown`).

/// AES-128 in ECB mode with a key fixed for the object's life (one CommonCrypto cryptor, created once).
final class AES128ECB {
    private var cryptor: CCCryptorRef?

    init(key: [UInt8]) {
        precondition(key.count == 16, "AES-128 key")
        var ref: CCCryptorRef?
        let status = key.withUnsafeBytes {
            CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            $0.baseAddress, 16, nil, &ref)
        }
        precondition(status == kCCSuccess && ref != nil, "AES cryptor")
        cryptor = ref
    }

    deinit { CCCryptorRelease(cryptor) }

    /// One-shot AES-128 encryption of a single block (tests and key setup).
    static func encryptOne(key: [UInt8], block: [UInt8]) -> [UInt8] {
        let cipher = AES128ECB(key: key)
        var out = [UInt8](repeating: 0, count: 16)
        block.withUnsafeBytes { i in out.withUnsafeMutableBytes { cipher.encrypt(i.baseAddress!, $0.baseAddress!, blocks: 1) } }
        return out
    }

    /// Encrypts `blocks` 16-byte blocks from `input` to `output` (distinct buffers).
    @inline(__always)
    func encrypt(_ input: UnsafeRawPointer, _ output: UnsafeMutableRawPointer, blocks: Int) {
        var moved = 0
        let status = CCCryptorUpdate(cryptor, input, blocks * 16, output, blocks * 16, &moved)
        assert(status == kCCSuccess && moved == blocks * 16)
        _ = status
    }
}

/// GHASH multiplication by a fixed hash key `H`, with the 8-bit table method (256 entries of 128 bits, 4 KiB).
final class GHashKey {
    /// `H · byte` for every byte value, as (high, low) 64-bit halves in big-endian bit order.
    private let table: UnsafeMutablePointer<UInt64>
    /// What dropping the low byte of the accumulator adds back at the top: the reduction by the GCM polynomial.
    nonisolated(unsafe) private static let reduction: UnsafeMutablePointer<UInt64> = {
        let p = UnsafeMutablePointer<UInt64>.allocate(capacity: 256)
        for r in 0..<256 {
            var v: UInt64 = 0
            for bit in 0..<8 where (r >> bit) & 1 == 1 { v ^= 0xe100 >> UInt64(7 - bit) }
            p[r] = v << 48
        }
        return p
    }()

    init(h0: UInt64, h1: UInt64) {
        table = .allocate(capacity: 512)
        table.initialize(repeating: 0, count: 512)
        var vh = h0
        var vl = h1
        table[2 * 128] = vh
        table[2 * 128 + 1] = vl
        var i = 64
        while i > 0 {
            // multiply by x: shift right one bit, reducing when a 1 falls off
            let t: UInt64 = (vl & 1) &* 0xe100_0000_0000_0000
            vl = (vh << 63) | (vl >> 1)
            vh = (vh >> 1) ^ t
            table[2 * i] = vh
            table[2 * i + 1] = vl
            i >>= 1
        }
        i = 2
        while i <= 128 {
            for j in 1..<i {
                table[2 * (i + j)] = table[2 * i] ^ table[2 * j]
                table[2 * (i + j) + 1] = table[2 * i + 1] ^ table[2 * j + 1]
            }
            i *= 2
        }
    }

    deinit { table.deallocate() }

    /// `x ← x · H` in GF(2^128); `xh`/`xl` are the big-endian halves of the 16-byte block.
    @_optimize(speed) @inline(__always)
    func multiply(_ xh: inout UInt64, _ xl: inout UInt64) {
        let t = table
        let rem8 = Self.reduction
        var b = Int(xl & 0xff)
        var zh = t[2 * b]
        var zl = t[2 * b + 1]
        var shift: UInt64 = 8
        while shift < 64 {
            let rem = Int(zl & 0xff)
            zl = (zh << 56) | (zl >> 8)
            zh = (zh >> 8) ^ rem8[rem]
            b = Int((xl >> shift) & 0xff)
            zh ^= t[2 * b]
            zl ^= t[2 * b + 1]
            shift += 8
        }
        shift = 0
        while shift < 64 {
            let rem = Int(zl & 0xff)
            zl = (zh << 56) | (zl >> 8)
            zh = (zh >> 8) ^ rem8[rem]
            b = Int((xh >> shift) & 0xff)
            zh ^= t[2 * b]
            zl ^= t[2 * b + 1]
            shift += 8
        }
        xh = zh
        xl = zl
    }
}

/// The GMAC key of one epoch: its AES cryptor (for the tag mask) and its GHASH table.
final class GMACKey {
    let aes: AES128ECB
    let ghash: GHashKey

    init(key: [UInt8]) {
        let cipher = AES128ECB(key: key)
        var zero = [UInt8](repeating: 0, count: 16)
        var h = [UInt8](repeating: 0, count: 16)
        zero.withUnsafeMutableBytes { z in h.withUnsafeMutableBytes { cipher.encrypt(z.baseAddress!, $0.baseAddress!, blocks: 1) } }
        let hh = h.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self)) }
        let hl = h.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
        aes = cipher
        ghash = GHashKey(h0: hh, h1: hl)
    }
}

/// Where a packet type keeps its GMAC and `keyPos` (takion.md §2) and whether `keyPos` is zeroed for the tag.
struct GMACLayout: Sendable, Equatable {
    var gmacOffset: Int
    var keyPosOffset: Int
    var zeroKeyPos: Bool

    static let control = GMACLayout(gmacOffset: 5, keyPosOffset: 9, zeroKeyPos: true)
    static let feedback = GMACLayout(gmacOffset: 8, keyPosOffset: 4, zeroKeyPos: false)
    static let av = GMACLayout(gmacOffset: 10, keyPosOffset: 14, zeroKeyPos: false)
    static let congestion = GMACLayout(gmacOffset: 7, keyPosOffset: 11, zeroKeyPos: true)
}

/// Derives the GMAC key of the next epoch on its own thread, so the receive path swaps in a ready key instead of
/// allocating (SHA-256, AES cryptor, GHASH table) when a stream crosses an epoch boundary every 45,000 bytes.
final class EpochKeyPrefetcher: @unchecked Sendable {
    private let gmacKey0: [UInt8]
    private let ivBase: [UInt8]
    private let lock = UnfairLock()
    private let wake = DispatchSemaphore(value: 0)
    private var requested: UInt64?
    private var ready: (epoch: UInt64, key: GMACKey)?
    private var stopped = false

    init(gmacKey0: [UInt8], ivBase: [UInt8]) {
        self.gmacKey0 = gmacKey0
        self.ivBase = ivBase
        let thread = Thread { [self] in run() }
        thread.name = "playfx.takion.epoch"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Asks for `epoch` to be derived. Does not allocate.
    func request(_ epoch: UInt64) {
        let wanted = lock.withLock { () -> Bool in
            if requested == epoch || ready?.epoch == epoch { return false }
            requested = epoch
            return true
        }
        if wanted { wake.signal() }
    }

    /// The prepared key for `epoch` without consuming it (a forged packet must not use it up).
    func peek(_ epoch: UInt64) -> GMACKey? {
        lock.withLock { ready.flatMap { $0.epoch == epoch ? $0.key : nil } }
    }

    /// The prepared key for `epoch`, if it is ready, consuming it.
    func take(_ epoch: UInt64) -> GMACKey? {
        lock.withLock {
            guard let r = ready, r.epoch == epoch else { return nil }
            ready = nil
            return r.key
        }
    }

    /// True when no derivation is pending (tests wait for this to make epoch changes deterministic).
    var isIdle: Bool { lock.withLock { requested == nil } }

    func stop() {
        lock.withLock { stopped = true }
        wake.signal()
    }

    private func run() {
        while true {
            wake.wait()
            let job = lock.withLock { () -> (UInt64?, Bool) in (requested, stopped) }
            if job.1 { return }
            guard let epoch = job.0 else { continue }
            let key = GMACKey(key: GKCryptContext.foldedKey(base: gmacKey0, ivBase: ivBase, epoch: epoch))
            lock.withLock {
                ready = (epoch, key)
                if requested == epoch { requested = nil }
            }
        }
    }
}

final class GKCryptContext {
    static let epochLength: UInt64 = 45000
    static let epochStep: UInt64 = 44910

    let cipherKey: [UInt8]
    let ivBase: [UInt8]
    let gmacKey0: [UInt8]
    private let ivLo: UInt64
    private let ivHi: UInt64
    private let streamAES: AES128ECB
    private let scratchIn: UnsafeMutableRawPointer
    private let scratchOut: UnsafeMutableRawPointer
    private static let scratchBytes = 1088
    private var cachedEpochs = [UInt64](repeating: 0, count: 4)
    private var cachedKeys = [GMACKey?](repeating: nil, count: 4)
    private var nextCacheSlot = 0
    /// gmacKey(0) = G(cipherKey, 0): pinned, never evicted.
    private let key0: GMACKey
    /// A key derived for a packet that hasn't been authenticated yet; cached only once its tag verifies.
    private var pending: (epoch: UInt64, key: GMACKey)?
    private var newestEpoch: UInt64 = 0
    private let prefetcher: EpochKeyPrefetcher?

    /// `index` is 2 for `ctxUp` and 3 for `ctxDown` (§6.1).
    /// With `prefetch`, the next epoch's GMAC key is derived ahead of time on a helper thread (for `ctxDown`, whose
    /// use is on the allocation-free receive path).
    init(ecdhSecret: [UInt8], handshakeKey: [UInt8], index: UInt8, prefetch: Bool = false) {
        precondition(ecdhSecret.count == 32 && handshakeKey.count == 16, "GKCrypt inputs")
        let message = [0x01, index, 0x00] + handshakeKey + [0x01, 0x00]
        let d = Array(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: ecdhSecret)))
        cipherKey = Array(d[0..<16])
        ivBase = Array(d[16..<32])
        ivLo = ivBase.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self)) }
        ivHi = ivBase.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
        streamAES = AES128ECB(key: cipherKey)
        scratchIn = .allocate(byteCount: Self.scratchBytes, alignment: 16)
        scratchOut = .allocate(byteCount: Self.scratchBytes, alignment: 16)
        gmacKey0 = Self.foldedKey(base: cipherKey, ivBase: ivBase, epoch: 0)
        key0 = GMACKey(key: gmacKey0)
        prefetcher = prefetch ? EpochKeyPrefetcher(gmacKey0: gmacKey0, ivBase: ivBase) : nil
        prefetcher?.request(1)
    }

    deinit {
        prefetcher?.stop()
        scratchIn.deallocate()
        scratchOut.deallocate()
    }

    /// `ivBase ⊕+ v` (little-endian 128-bit addition, §6.3) as the 16 bytes.
    static func add(_ iv: [UInt8], _ v: UInt64) -> [UInt8] {
        let lo = iv.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self)) }
        let hi = iv.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
        let sum = lo &+ v
        let high = hi &+ (sum < lo ? 1 : 0)
        var out = [UInt8](repeating: 0, count: 16)
        out.withUnsafeMutableBytes {
            $0.storeBytes(of: sum.littleEndian, toByteOffset: 0, as: UInt64.self)
            $0.storeBytes(of: high.littleEndian, toByteOffset: 8, as: UInt64.self)
        }
        return out
    }

    /// `G(base, e)` of §6.5: SHA-256 of `base || (ivBase ⊕+ e·44910)`, folded to 16 bytes.
    static func foldedKey(base: [UInt8], ivBase: [UInt8], epoch: UInt64) -> [UInt8] {
        let d = Array(SHA256.hash(data: base + add(ivBase, epoch &* epochStep)))
        return (0..<16).map { d[$0] ^ d[$0 + 16] }
    }

    @inline(__always) static func epoch(of keyPos: UInt64) -> UInt64 { keyPos == 0 ? 0 : (keyPos - 1) / epochLength }

    /// The GMAC key of `epoch`. A key that isn't cached is derived (or taken from the prefetcher without consuming
    /// it) and parked in `pending`: the caches and the prefetch schedule only change in `commitPending`, after a
    /// tag has verified, so forged far-future key positions can't evict live keys or move the schedule.
    @_optimize(speed) private func key(forEpoch epoch: UInt64) -> GMACKey {
        pending = nil
        if epoch == 0 { return key0 }
        var i = 0
        while i < 4 {
            if cachedEpochs[i] == epoch, let key = cachedKeys[i] { return key }
            i += 1
        }
        let key = prefetcher?.peek(epoch) ?? GMACKey(key: Self.foldedKey(base: gmacKey0, ivBase: ivBase, epoch: epoch))
        pending = (epoch, key)
        return key
    }

    /// Epochs whose keys are cached (not counting the pinned epoch 0), the newest epoch committed, and whether
    /// the prefetcher holds a key for an epoch (diagnostics and tests).
    var cachedEpochList: [UInt64] { (0..<4).compactMap { cachedKeys[$0] != nil ? cachedEpochs[$0] : nil }.sorted() }
    var newestCommittedEpoch: UInt64 { newestEpoch }
    /// Blocks until the helper thread has finished any requested derivation (tests only).
    func waitForPrefetch() {
        guard let prefetcher else { return }
        var spins = 0
        while !prefetcher.isIdle && spins < 100_000 {
            usleep(10)
            spins += 1
        }
    }
    func isPrefetched(_ epoch: UInt64) -> Bool { prefetcher?.peek(epoch) != nil }

    /// Called after a tag verified (or was sealed by us): cache the key just derived and, if it is the newest
    /// epoch seen, ask for the next one.
    private func commitPending() {
        guard let p = pending else { return }
        pending = nil
        _ = prefetcher?.take(p.epoch)
        cachedEpochs[nextCacheSlot] = p.epoch
        cachedKeys[nextCacheSlot] = p.key
        nextCacheSlot = (nextCacheSlot + 1) & 3
        if p.epoch >= newestEpoch {
            newestEpoch = p.epoch
            prefetcher?.request(p.epoch + 1)
        }
    }

    @_optimize(speed) @inline(__always) private func counter(_ j: UInt64) -> (lo: UInt64, hi: UInt64) {
        let lo = ivLo &+ j
        return (lo, ivHi &+ (lo < ivLo ? 1 : 0))
    }

    /// The key stream at `keyPos + 16 …` XORed over `buffer` (§6.4); encrypts and decrypts alike.
    @_optimize(speed) func apply(to buffer: UnsafeMutableRawBufferPointer, keyPos: UInt64) {
        xorStream(buffer, atPosition: keyPos &+ 16)
    }

    /// The key stream from stream position `position` XORed over `buffer` (§6.4).
    @_optimize(speed) func xorStream(_ buffer: UnsafeMutableRawBufferPointer, atPosition start: UInt64) {
        var position = start
        var done = 0
        let total = buffer.count
        guard total > 0, let base = buffer.baseAddress else { return }
        while done < total {
            let skip = Int(position & 15)
            let chunk = min(total - done, 1024)
            let blocks = (skip + chunk + 15) / 16
            let first = position >> 4
            for b in 0..<blocks {
                let c = counter(first &+ UInt64(b))
                scratchIn.storeBytes(of: c.lo.littleEndian, toByteOffset: b * 16, as: UInt64.self)
                scratchIn.storeBytes(of: c.hi.littleEndian, toByteOffset: b * 16 + 8, as: UInt64.self)
            }
            streamAES.encrypt(scratchIn, scratchOut, blocks: blocks)
            let stream = scratchOut + skip
            let data = base + done
            var k = 0
            while k + 8 <= chunk {
                let x = data.loadUnaligned(fromByteOffset: k, as: UInt64.self) ^ stream.loadUnaligned(fromByteOffset: k, as: UInt64.self)
                data.storeBytes(of: x, toByteOffset: k, as: UInt64.self)
                k += 8
            }
            while k < chunk {
                data.storeBytes(of: data.load(fromByteOffset: k, as: UInt8.self) ^ stream.load(fromByteOffset: k, as: UInt8.self),
                                toByteOffset: k, as: UInt8.self)
                k += 1
            }
            position &+= UInt64(chunk)
            done += chunk
        }
    }

    /// The 4-byte GMAC of `datagram` at `keyPos` (§6.5), as a big-endian integer. The GMAC field (and, for
    /// `layout.zeroKeyPos`, the `keyPos` field) is zeroed for the computation and put back before returning.
    @_optimize(speed) func gmac(of datagram: UnsafeMutableRawBufferPointer, layout: GMACLayout, keyPos: UInt64) -> UInt32 {
        let savedGMAC = datagram.be32(layout.gmacOffset)
        let savedKeyPos = datagram.be32(layout.keyPosOffset)
        datagram.putBE32(0, at: layout.gmacOffset)
        if layout.zeroKeyPos { datagram.putBE32(0, at: layout.keyPosOffset) }
        defer {
            datagram.putBE32(savedGMAC, at: layout.gmacOffset)
            datagram.putBE32(savedKeyPos, at: layout.keyPosOffset)
        }
        return tag(over: datagram.readOnly, keyPos: keyPos)
    }

    /// AES-128-GCM with a 16-byte IV and no plaintext: the first 4 bytes of `E(K, J0) ⊕ GHASH(aad)`, with
    /// `J0 = GHASH(IV ‖ 0^64 ‖ [128]₆₄)` because the IV is not 96 bits (SP 800-38D §7.1).
    @_optimize(speed) private func tag(over aad: UnsafeRawBufferPointer, keyPos: UInt64) -> UInt32 {
        let key = key(forEpoch: Self.epoch(of: keyPos))
        let c = counter(keyPos >> 4)
        var jh = c.lo.byteSwapped
        var jl = c.hi.byteSwapped
        key.ghash.multiply(&jh, &jl)
        jl ^= 128
        key.ghash.multiply(&jh, &jl)

        var sh: UInt64 = 0
        var sl: UInt64 = 0
        let count = aad.count
        var offset = 0
        while offset + 16 <= count {
            sh ^= UInt64(bigEndian: aad.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
            sl ^= UInt64(bigEndian: aad.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self))
            key.ghash.multiply(&sh, &sl)
            offset += 16
        }
        if offset < count {
            var hi: UInt64 = 0
            var lo: UInt64 = 0
            for i in offset..<count {
                let shift = UInt64(8 * (15 - (i - offset)))
                if shift >= 64 { hi |= UInt64(aad[i]) << (shift - 64) } else { lo |= UInt64(aad[i]) << shift }
            }
            sh ^= hi
            sl ^= lo
            key.ghash.multiply(&sh, &sl)
        }
        sh ^= UInt64(count) &* 8
        key.ghash.multiply(&sh, &sl)

        scratchIn.storeBytes(of: jh.bigEndian, toByteOffset: 0, as: UInt64.self)
        scratchIn.storeBytes(of: jl.bigEndian, toByteOffset: 8, as: UInt64.self)
        key.aes.encrypt(scratchIn, scratchOut, blocks: 1)
        let mask = UInt32(bigEndian: scratchOut.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        return mask ^ UInt32(truncatingIfNeeded: sh >> 32)
    }

    /// Computes the GMAC and writes it into the packet.
    @_optimize(speed) func seal(_ datagram: UnsafeMutableRawBufferPointer, layout: GMACLayout, keyPos: UInt64) {
        datagram.putBE32(gmac(of: datagram, layout: layout, keyPos: keyPos), at: layout.gmacOffset)
        commitPending()
    }

    /// True when the packet's GMAC field matches its tag at `keyPos`.
    @_optimize(speed) func verify(_ datagram: UnsafeMutableRawBufferPointer, layout: GMACLayout, keyPos: UInt64) -> Bool {
        let ok = gmac(of: datagram, layout: layout, keyPos: keyPos) == datagram.be32(layout.gmacOffset)
        if ok { commitPending() }
        return ok
    }
}

/// How the client advances its `keyPos` counter (§6.6): `s + (s mod 16)`.
@inline(__always) func keyPosAdvance(_ s: Int) -> UInt64 { UInt64(s + (s & 15)) }

/// Rebuilds the 64-bit `keyPos` of a received packet from its low 32 bits and the last authenticated one
/// (§6.6): serially after but numerically smaller wraps forward; serially before but numerically larger (with a
/// high half to borrow from) is a late packet from before a wrap.
func reconstructKeyPos(low: UInt32, reference: UInt64) -> UInt64 {
    let rlo = UInt32(truncatingIfNeeded: reference)
    let rhi = reference >> 32
    var hi = rhi
    if Serial.isAfter(low, rlo) && low < rlo {
        hi = rhi &+ 1
    } else if Serial.isBefore(low, rlo) && low > rlo && rhi > 0 {
        hi = rhi - 1
    }
    return (hi << 32) | UInt64(low)
}
