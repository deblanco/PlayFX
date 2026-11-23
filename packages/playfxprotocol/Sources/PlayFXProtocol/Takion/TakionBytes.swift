import Darwin

// Byte access, serial-number arithmetic and the clock used by the Takion layer (takion.md §11).
// Everything here works on raw buffers and never allocates.

extension UnsafeRawBufferPointer {
    @inline(__always) func u8(_ offset: Int) -> UInt8 { self[offset] }
    @inline(__always) func be16(_ offset: Int) -> UInt16 {
        UInt16(bigEndian: loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }
    @inline(__always) func be32(_ offset: Int) -> UInt32 {
        UInt32(bigEndian: loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
}

extension UnsafeMutableRawBufferPointer {
    @inline(__always) func u8(_ offset: Int) -> UInt8 { self[offset] }
    @inline(__always) func be16(_ offset: Int) -> UInt16 {
        UInt16(bigEndian: loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }
    @inline(__always) func be32(_ offset: Int) -> UInt32 {
        UInt32(bigEndian: loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
    @inline(__always) func putBE16(_ value: UInt16, at offset: Int) {
        storeBytes(of: value.bigEndian, toByteOffset: offset, as: UInt16.self)
    }
    @inline(__always) func putBE32(_ value: UInt32, at offset: Int) {
        storeBytes(of: value.bigEndian, toByteOffset: offset, as: UInt32.self)
    }
    var readOnly: UnsafeRawBufferPointer { UnsafeRawBufferPointer(self) }
}

/// Serial-number arithmetic (RFC 1982, takion.md §11) for 16- and 32-bit sequence numbers.
enum Serial {
    /// `a` is before `b`: `a ≠ b` and `b − a` (mod 2^n) is below 2^(n−1). At exactly half the space neither is.
    @_optimize(speed) @inline(__always) static func isBefore(_ a: UInt16, _ b: UInt16) -> Bool {
        let d = b &- a
        return d != 0 && d < 0x8000
    }
    @_optimize(speed) @inline(__always) static func isAfter(_ a: UInt16, _ b: UInt16) -> Bool { isBefore(b, a) }
    @_optimize(speed) @inline(__always) static func isBefore(_ a: UInt32, _ b: UInt32) -> Bool {
        let d = b &- a
        return d != 0 && d < 0x8000_0000
    }
    @_optimize(speed) @inline(__always) static func isAfter(_ a: UInt32, _ b: UInt32) -> Bool { isBefore(b, a) }
    /// `a ≤ b` in serial order.
    @_optimize(speed) @inline(__always) static func isBeforeOrEqual(_ a: UInt32, _ b: UInt32) -> Bool { a == b || isBefore(a, b) }
}

/// Monotonic nanoseconds (`CLOCK_UPTIME_RAW`): the one clock for receive timestamps, deadlines and statistics.
@inline(__always) func takionNow() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// `mach_absolute_time` ticks to nanoseconds, for the kernel's `SO_TIMESTAMP_MONOTONIC` values.
struct MachTime: Sendable {
    let numer: UInt64
    let denom: UInt64
    static let current: MachTime = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return MachTime(numer: UInt64(info.numer), denom: UInt64(max(info.denom, 1)))
    }()
    @inline(__always) func nanoseconds(_ ticks: UInt64) -> UInt64 {
        (ticks / denom) &* numer &+ (ticks % denom) &* numer / denom
    }
}
