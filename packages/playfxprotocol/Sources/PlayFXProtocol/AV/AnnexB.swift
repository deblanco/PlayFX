/// A growable byte buffer the access unit of each frame is built in. It is reused for every frame, so
/// after it has grown to the biggest frame seen, building an access unit allocates nothing.
///
/// Ownership: the buffer belongs to the `VideoReceiver`. What the video callback gets is a view of it that is
/// valid until the callback returns (and mutated by the next frame); a consumer that needs the bytes longer
/// makes its one copy (for VideoToolbox, the block buffer it creates anyway).
final class AccessUnitBuffer {
    private(set) var base: UnsafeMutablePointer<UInt8>
    private(set) var capacity: Int
    private(set) var count = 0

    init(capacity: Int = 256 * 1024) {
        self.capacity = capacity
        base = .allocate(capacity: capacity)
    }

    deinit { base.deallocate() }

    func reset() { count = 0 }

    func append(_ source: UnsafePointer<UInt8>, count n: Int) {
        guard n > 0 else { return }
        if count + n > capacity { grow(to: count + n) }
        (base + count).update(from: source, count: n)
        count += n
    }

    var bytes: UnsafeRawBufferPointer { UnsafeRawBufferPointer(start: base, count: count) }
    var mutableBytes: UnsafeMutableBufferPointer<UInt8> { UnsafeMutableBufferPointer(start: base, count: count) }

    private func grow(to needed: Int) {
        var newCapacity = capacity
        while newCapacity < needed { newCapacity *= 2 }
        let bigger = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
        bigger.update(from: base, count: count)
        base.deallocate()
        base = bigger
        capacity = newCapacity
    }
}

/// Helpers for Annex-B byte streams (H.264 Annex B / H.265 Annex B): NAL units separated by `00 00 01` or
/// `00 00 00 01`.
enum AnnexB {
    /// The first start code at or after `from`, searching only positions below `limit`: the index of its first
    /// `00` and of the NAL header byte after it. A 4-byte start code is reported from its leading zero.
    static func startCode(in bytes: UnsafeRawBufferPointer, from: Int = 0, limit: Int? = nil) -> (start: Int, nal: Int)? {
        let end = min(limit ?? bytes.count, bytes.count - 2)
        var i = max(from, 0)
        while i < end {
            if bytes[i + 2] > 1 {
                i += 3
            } else if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                let start = (i > from && bytes[i - 1] == 0) ? i - 1 : i
                return (start, i + 3)
            } else {
                i += 1
            }
        }
        return nil
    }

    /// Ranges of the NAL units in `bytes` (header byte to the byte before the next start code, trailing zero
    /// bytes belonging to the next 4-byte start code left out).
    static func nalUnits(in bytes: UnsafeRawBufferPointer) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var position = 0
        guard var current = startCode(in: bytes, from: position) else { return out }
        while true {
            let nalStart = current.nal
            let next = startCode(in: bytes, from: nalStart)
            let end = next?.start ?? bytes.count
            if end > nalStart { out.append(nalStart..<end) }
            guard let n = next else { break }
            current = n
            position = n.nal
        }
        return out
    }
}
