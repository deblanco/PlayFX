#if arch(arm64)
import _Builtin_intrinsics.arm.neon
#endif

/// GF(2^8) with the primitive polynomial 0x11d (av.md section 3.1), and the "region" operations the erasure
/// code is made of: `dst ^= c * src` over whole units.
///
/// The tables are built once and live for the process (`GF256.shared`); hot loops take the pointers once.
final class GF256: @unchecked Sendable {
    static let shared = GF256()

    /// `exp(i) = 0x02^i`, doubled in length (510 entries used) so a sum of two logs needs no modulo.
    let exp: UnsafeMutablePointer<UInt8>
    /// `log(a)` for a != 0 (0..254). Entry 0 is unused.
    let log: UnsafeMutablePointer<UInt8>
    /// `inv(a)` for a != 0. Entry 0 is 0 and must never be used.
    let inv: UnsafeMutablePointer<UInt8>
    /// Full 256 x 256 product table: `product[c << 8 | x] = c * x`.
    let product: UnsafeMutablePointer<UInt8>
    /// Split-nibble tables: for coefficient `c`, `low[c*16 + n] = c * n` and `high[c*16 + n] = c * (n << 4)`.
    let low: UnsafeMutablePointer<UInt8>
    let high: UnsafeMutablePointer<UInt8>

    private init() {
        exp = .allocate(capacity: 512)
        log = .allocate(capacity: 256)
        inv = .allocate(capacity: 256)
        product = .allocate(capacity: 65536)
        low = .allocate(capacity: 4096)
        high = .allocate(capacity: 4096)
        log.initialize(repeating: 0, count: 256)
        var x = 1
        for i in 0..<255 {
            exp[i] = UInt8(x)
            log[x] = UInt8(i)
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x11d }
        }
        for i in 255..<512 { exp[i] = exp[i - 255] }
        inv[0] = 0
        for a in 1..<256 { inv[a] = exp[255 - Int(log[a])] }
        for c in 0..<256 {
            for v in 0..<256 { product[c << 8 | v] = multiply(UInt8(c), UInt8(v)) }
            for n in 0..<16 {
                low[c * 16 + n] = product[c << 8 | n]
                high[c * 16 + n] = product[c << 8 | (n << 4)]
            }
        }
    }

    @inline(__always)
    func multiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
        if a == 0 || b == 0 { return 0 }
        return exp[Int(log[Int(a)]) + Int(log[Int(b)])]
    }

    func inverse(_ a: UInt8) -> UInt8 { inv[Int(a)] }

    // MARK: Region multiply-add

    /// How a region multiply is computed. `default` is what the decoder uses; the others exist for the
    /// benchmark and as the reference the tests compare it against.
    enum Method: CaseIterable, Sendable {
        /// Scalar, one log/exp lookup pair per byte.
        case logExp
        /// Scalar, one lookup in the coefficient's 256-byte row of the product table.
        case table256
        /// Portable `SIMD16<UInt8>`: for each of the 8 bits of the input, mask and multiply by `c * 2^bit`.
        case simdBitSliced
        /// Split-nibble tables with a byte shuffle (NEON `TBL`): two lookups per 16 bytes. arm64 only.
        case nibbleShuffle

        static var available: [Method] {
            #if arch(arm64)
            return allCases
            #else
            return allCases.filter { $0 != .nibbleShuffle }
            #endif
        }

        static var `default`: Method {
            #if arch(arm64)
            return .nibbleShuffle
            #else
            return .table256
            #endif
        }
    }

    /// `dst[t] ^= c * src[t]` for `t` in `0..<count`. `dst` and `src` must not overlap.
    func multiplyAdd(
        _ dst: UnsafeMutablePointer<UInt8>, _ src: UnsafePointer<UInt8>, by c: UInt8, count: Int,
        method: Method = .default
    ) {
        if c == 0 || count <= 0 { return }
        if c == 1 {
            xor(dst, src, count: count)
            return
        }
        switch method {
        case .logExp:
            let lc = Int(log[Int(c)])
            for t in 0..<count {
                let v = src[t]
                if v != 0 { dst[t] ^= exp[lc + Int(log[Int(v)])] }
            }
        case .table256:
            let row = product + (Int(c) << 8)
            for t in 0..<count { dst[t] ^= row[Int(src[t])] }
        case .simdBitSliced:
            multiplyAddBitSliced(dst, src, c, count)
        case .nibbleShuffle:
            #if arch(arm64)
            multiplyAddShuffle(dst, src, c, count)
            #else
            multiplyAdd(dst, src, by: c, count: count, method: .table256)
            #endif
        }
    }

    func xor(_ dst: UnsafeMutablePointer<UInt8>, _ src: UnsafePointer<UInt8>, count: Int) {
        var t = 0
        let rawDst = UnsafeMutableRawPointer(dst)
        let rawSrc = UnsafeRawPointer(src)
        while t + 16 <= count {
            let a = rawDst.loadUnaligned(fromByteOffset: t, as: SIMD16<UInt8>.self)
            let b = rawSrc.loadUnaligned(fromByteOffset: t, as: SIMD16<UInt8>.self)
            rawDst.storeBytes(of: a ^ b, toByteOffset: t, as: SIMD16<UInt8>.self)
            t += 16
        }
        while t < count {
            dst[t] ^= src[t]
            t += 1
        }
    }

    private func multiplyAddBitSliced(
        _ dst: UnsafeMutablePointer<UInt8>, _ src: UnsafePointer<UInt8>, _ c: UInt8, _ count: Int
    ) {
        var factors = [SIMD16<UInt8>](repeating: .zero, count: 8)
        for bit in 0..<8 { factors[bit] = SIMD16(repeating: multiply(c, UInt8(1 << bit))) }
        let rawDst = UnsafeMutableRawPointer(dst)
        let rawSrc = UnsafeRawPointer(src)
        let one = SIMD16<UInt8>(repeating: 1)
        var t = 0
        factors.withUnsafeBufferPointer { f in
            while t + 16 <= count {
                let x = rawSrc.loadUnaligned(fromByteOffset: t, as: SIMD16<UInt8>.self)
                var r = rawDst.loadUnaligned(fromByteOffset: t, as: SIMD16<UInt8>.self)
                r ^= ((x & one) &* f[0]) ^ (((x &>> 1) & one) &* f[1]) ^ (((x &>> 2) & one) &* f[2])
                    ^ (((x &>> 3) & one) &* f[3])
                r ^= (((x &>> 4) & one) &* f[4]) ^ (((x &>> 5) & one) &* f[5]) ^ (((x &>> 6) & one) &* f[6])
                    ^ ((x &>> 7) &* f[7])
                rawDst.storeBytes(of: r, toByteOffset: t, as: SIMD16<UInt8>.self)
                t += 16
            }
        }
        scalarTail(dst, src, c, from: t, count: count)
    }

    private func scalarTail(
        _ dst: UnsafeMutablePointer<UInt8>, _ src: UnsafePointer<UInt8>, _ c: UInt8, from: Int, count: Int
    ) {
        let row = product + (Int(c) << 8)
        var t = from
        while t < count {
            dst[t] ^= row[Int(src[t])]
            t += 1
        }
    }

    #if arch(arm64)
    private func multiplyAddShuffle(
        _ dst: UnsafeMutablePointer<UInt8>, _ src: UnsafePointer<UInt8>, _ c: UInt8, _ count: Int
    ) {
        let lo = UnsafeRawPointer(low + Int(c) * 16).loadUnaligned(as: SIMD16<UInt8>.self)
        let hi = UnsafeRawPointer(high + Int(c) * 16).loadUnaligned(as: SIMD16<UInt8>.self)
        let mask = SIMD16<UInt8>(repeating: 0x0f)
        let rawDst = UnsafeMutableRawPointer(dst)
        let rawSrc = UnsafeRawPointer(src)
        var t = 0
        while t + 64 <= count {
            let x0 = rawSrc.loadUnaligned(fromByteOffset: t, as: SIMD16<UInt8>.self)
            let x1 = rawSrc.loadUnaligned(fromByteOffset: t + 16, as: SIMD16<UInt8>.self)
            let x2 = rawSrc.loadUnaligned(fromByteOffset: t + 32, as: SIMD16<UInt8>.self)
            let x3 = rawSrc.loadUnaligned(fromByteOffset: t + 48, as: SIMD16<UInt8>.self)
            let r0 = vqtbl1q_u8(lo, x0 & mask) ^ vqtbl1q_u8(hi, x0 &>> 4)
            let r1 = vqtbl1q_u8(lo, x1 & mask) ^ vqtbl1q_u8(hi, x1 &>> 4)
            let r2 = vqtbl1q_u8(lo, x2 & mask) ^ vqtbl1q_u8(hi, x2 &>> 4)
            let r3 = vqtbl1q_u8(lo, x3 & mask) ^ vqtbl1q_u8(hi, x3 &>> 4)
            rawDst.storeBytes(
                of: rawDst.loadUnaligned(fromByteOffset: t, as: SIMD16<UInt8>.self) ^ r0, toByteOffset: t,
                as: SIMD16<UInt8>.self)
            rawDst.storeBytes(
                of: rawDst.loadUnaligned(fromByteOffset: t + 16, as: SIMD16<UInt8>.self) ^ r1,
                toByteOffset: t + 16, as: SIMD16<UInt8>.self)
            rawDst.storeBytes(
                of: rawDst.loadUnaligned(fromByteOffset: t + 32, as: SIMD16<UInt8>.self) ^ r2,
                toByteOffset: t + 32, as: SIMD16<UInt8>.self)
            rawDst.storeBytes(
                of: rawDst.loadUnaligned(fromByteOffset: t + 48, as: SIMD16<UInt8>.self) ^ r3,
                toByteOffset: t + 48, as: SIMD16<UInt8>.self)
            t += 64
        }
        while t + 16 <= count {
            let x = rawSrc.loadUnaligned(fromByteOffset: t, as: SIMD16<UInt8>.self)
            let r = vqtbl1q_u8(lo, x & mask) ^ vqtbl1q_u8(hi, x &>> 4)
            rawDst.storeBytes(
                of: rawDst.loadUnaligned(fromByteOffset: t, as: SIMD16<UInt8>.self) ^ r, toByteOffset: t,
                as: SIMD16<UInt8>.self)
            t += 16
        }
        scalarTail(dst, src, c, from: t, count: count)
    }
    #endif
}
