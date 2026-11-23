/// The erasure decoder of av.md section 3: a systematic Cauchy Reed-Solomon code over GF(2^8).
///
/// Units live in one block of memory, unit `u` at `storage + u * size` (source units `0..<k`, then the `m`
/// parity units). `recover` fills in the missing source units in place. The decoder keeps its scratch
/// memory between calls, so after warm-up it allocates nothing.
final class FECDecoder {
    /// `k + m` may not exceed this (the Cauchy point sets must fit in the field).
    static let maxUnits = 256

    private let gf = GF256.shared
    private let method: GF256.Method
    private var syndromes: UnsafeMutablePointer<UInt8>
    private var syndromeCapacity: Int
    private var matrix: [UInt8] = []
    private var inverse: [UInt8] = []
    private var missing: [Int] = []
    private var rows: [Int] = []

    init(method: GF256.Method = .default) {
        self.method = method
        syndromeCapacity = 64 * 1024
        syndromes = .allocate(capacity: syndromeCapacity)
        missing.reserveCapacity(Self.maxUnits)
        rows.reserveCapacity(Self.maxUnits)
    }

    deinit { syndromes.deallocate() }

    /// The coding matrix entry `C[i][j] = inv(i ^ (m + j))` (section 3.2). Requires `i < m`, `m + j < 256`.
    @inline(__always)
    func coefficient(row i: Int, column j: Int, m: Int) -> UInt8 {
        gf.inv[i ^ (m + j)]
    }

    /// The `m x k` coding matrix, row-major.
    func codingMatrix(k: Int, m: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: k * m)
        for i in 0..<m { for j in 0..<k { out[i * k + j] = coefficient(row: i, column: j, m: m) } }
        return out
    }

    /// Recovers every source unit `j < k` with `present[j] == false`, writing it into its slot.
    ///
    /// - Parameters:
    ///   - present: at least `k + m` flags; `present[u]` says unit `u` holds received data.
    ///   - size: the unit size `S`.
    /// - Returns: false when it can't be done (more missing source units than received parity units,
    ///   `k + m > 256`, or a zero `size`). Nothing is written then.
    func recover(
        k: Int, m: Int, size: Int, storage: UnsafeMutablePointer<UInt8>, present: UnsafePointer<Bool>
    ) -> Bool {
        guard k >= 1, m >= 0, size > 0, k + m <= Self.maxUnits else { return false }
        missing.removeAll(keepingCapacity: true)
        for j in 0..<k where !present[j] { missing.append(j) }
        let e = missing.count
        if e == 0 { return true }
        rows.removeAll(keepingCapacity: true)
        var i = 0
        while i < m && rows.count < e {
            if present[k + i] { rows.append(i) }
            i += 1
        }
        guard rows.count == e else { return false }

        // The e x e system: parity row rows[a] restricted to the missing columns.
        if matrix.count < e * e {
            matrix = [UInt8](repeating: 0, count: e * e)
            inverse = [UInt8](repeating: 0, count: e * e)
        }
        for a in 0..<e {
            for b in 0..<e { matrix[a * e + b] = coefficient(row: rows[a], column: missing[b], m: m) }
        }
        guard invert(e) else { return false }

        // Syndromes: parity row minus the received source units' contribution.
        let need = e * size
        if need > syndromeCapacity {
            syndromes.deallocate()
            syndromeCapacity = need
            syndromes = .allocate(capacity: need)
        }
        for a in 0..<e {
            (syndromes + a * size).update(from: storage + (k + rows[a]) * size, count: size)
        }
        for j in 0..<k where present[j] {
            let src = UnsafePointer(storage + j * size)
            for a in 0..<e {
                gf.multiplyAdd(
                    syndromes + a * size, src, by: coefficient(row: rows[a], column: j, m: m), count: size,
                    method: method)
            }
        }

        // D_missing[b] = sum_a inverse[b][a] * syndrome[a]
        for b in 0..<e {
            let dst = storage + missing[b] * size
            dst.update(repeating: 0, count: size)
            for a in 0..<e {
                gf.multiplyAdd(
                    dst, UnsafePointer(syndromes + a * size), by: inverse[b * e + a], count: size,
                    method: method)
            }
        }
        return true
    }

    /// Gauss-Jordan inverse of `matrix` (e x e) into `inverse`. False when singular (never, for Cauchy).
    private func invert(_ e: Int) -> Bool {
        for r in 0..<e { for c in 0..<e { inverse[r * e + c] = r == c ? 1 : 0 } }
        for col in 0..<e {
            var pivot = col
            while pivot < e && matrix[pivot * e + col] == 0 { pivot += 1 }
            if pivot == e { return false }
            if pivot != col {
                for c in 0..<e {
                    matrix.swapAt(pivot * e + c, col * e + c)
                    inverse.swapAt(pivot * e + c, col * e + c)
                }
            }
            let scale = gf.inverse(matrix[col * e + col])
            for c in 0..<e {
                matrix[col * e + c] = gf.multiply(matrix[col * e + c], scale)
                inverse[col * e + c] = gf.multiply(inverse[col * e + c], scale)
            }
            for r in 0..<e where r != col {
                let factor = matrix[r * e + col]
                if factor == 0 { continue }
                for c in 0..<e {
                    matrix[r * e + c] ^= gf.multiply(factor, matrix[col * e + c])
                    inverse[r * e + c] ^= gf.multiply(factor, inverse[col * e + c])
                }
            }
        }
        return true
    }
}
