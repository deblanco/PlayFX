import Foundation

// PlayFX's reorder policy for video packets (takion.md §12.2–§12.3, our own design): the measured reorder-wait
// estimator and the 256-slot queue. Times inside the estimator are microseconds.

/// 256 "seen" flags, inline (no allocation).
struct SeenBits: Sendable, Equatable {
    private var w0: UInt64 = 0
    private var w1: UInt64 = 0
    private var w2: UInt64 = 0
    private var w3: UInt64 = 0

    /// Sets bit `i` (0...255); returns whether it was already set.
    @_optimize(speed) mutating func testAndSet(_ i: Int) -> Bool {
        let mask = UInt64(1) << UInt64(i & 63)
        switch (i >> 6) & 3 {
        case 0: defer { w0 |= mask }; return w0 & mask != 0
        case 1: defer { w1 |= mask }; return w1 & mask != 0
        case 2: defer { w2 |= mask }; return w2 & mask != 0
        default: defer { w3 |= mask }; return w3 & mask != 0
        }
    }
}

/// The reorder-wait estimator (§12.3): a smoothed lateness of packets that arrived after we gave up on them.
struct ReorderEstimator: Sendable {
    static let minWait: Int64 = 3000
    static let maxWait: Int64 = 20000
    static let initialWait: Int64 = 16000
    static let lostAfter: Int64 = 100_000
    static let holeSlots = 32
    static let maxHolePackets = 256

    private struct Hole: Sendable {
        var begin: UInt16
        var count: Int
        var waitStart: Int64
        var skippedAt: Int64
        var queueFull: Bool
        var late = false
        var seen = SeenBits()
    }

    private(set) var wait: Int64 = initialWait
    private(set) var sampled = false
    private var srtt: Int64 = 0
    private var rttvar: Int64 = 0
    private var holes = [Hole?](repeating: nil, count: holeSlots)
    private var nextSlot = 0
    private var outstanding = 0
    /// Packets that arrived after their hole was skipped (first copy only).
    private(set) var latePackets = 0
    /// Skipped holes that expired without any late packet: real loss.
    private(set) var holesLost = 0

    private static func clamp(_ x: Int64) -> Int64 { min(max(x, minWait), maxWait) }
    private var target: Int64 { Self.clamp(srtt + 4 * rttvar) }

    /// Feeds one lateness sample `d` (negative counts as 0).
    @_optimize(speed) mutating func sample(_ lateness: Int64) {
        let d = max(lateness, 0)
        if !sampled {
            sampled = true
            srtt = d
            rttvar = d / 2
        } else {
            rttvar += (abs(d - srtt) - rttvar) / 4
            srtt += (d - srtt) / 8
        }
        let t = target
        let floor = wait - wait / 20
        wait = t >= wait ? t : Self.clamp(max(t, floor))
    }

    /// A hole that was waited for was filled in `lateness` µs.
    mutating func holeFilled(lateness: Int64) { sample(lateness) }

    /// Remembers a skipped hole (§12.3 "Hole skipped").
    @_optimize(speed) mutating func holeSkipped(begin: UInt16, count: Int, waitStart: Int64, now: Int64, queueFull: Bool) {
        var begin = begin
        var count = count
        if count > Self.maxHolePackets {
            begin &+= UInt16(truncatingIfNeeded: count - Self.maxHolePackets)
            count = Self.maxHolePackets
        }
        let slot = nextSlot
        nextSlot = (nextSlot + 1) % Self.holeSlots
        if holes[slot] != nil { resolve(slot) }
        holes[slot] = Hole(begin: begin, count: count, waitStart: waitStart, skippedAt: now, queueFull: queueFull)
        outstanding += 1
    }

    /// A packet before the queue start arrived. Returns whether it was late: the first copy of a packet of a
    /// remembered skipped hole.
    @_optimize(speed) mutating func packetBeforeStart(_ index: UInt16, now: Int64) -> Bool {
        expire(now: now)
        guard outstanding > 0 else { return false }
        for slot in 0..<Self.holeSlots {
            guard var hole = holes[slot] else { continue }
            let offset = Int(index &- hole.begin)
            guard offset < hole.count else { continue }
            if hole.seen.testAndSet(offset) {
                holes[slot] = hole
                return false
            }
            hole.late = true
            holes[slot] = hole
            latePackets += 1
            let d = now - hole.waitStart
            sample(min(d, Self.maxWait))
            wait = max(wait, Self.clamp(d + d / 4))
            return true
        }
        return false
    }

    /// Resolves every remembered hole skipped at least `lostAfter` ago.
    @_optimize(speed) mutating func expire(now: Int64) {
        guard outstanding > 0 else { return }
        for slot in 0..<Self.holeSlots {
            if let hole = holes[slot], now - hole.skippedAt >= Self.lostAfter { resolve(slot) }
        }
    }

    @_optimize(speed) private mutating func resolve(_ slot: Int) {
        guard let hole = holes[slot] else { return }
        if !hole.late {
            holesLost += 1
            if !hole.queueFull {
                var w = Self.clamp(wait - wait / 20)
                if sampled && w < target { w = min(target, wait) }
                wait = w
            }
        }
        holes[slot] = nil
        outstanding -= 1
    }
}

/// Counters of the reorder queue, for diagnostics.
struct ReorderStats: Sendable, Equatable {
    /// The current reorder wait, µs.
    var waitMicros = Int(ReorderEstimator.initialWait)
    /// Holes that filled while being waited for.
    var holesFilled = 0
    /// Packets that arrived after their hole was skipped.
    var latePackets = 0
    /// Skipped holes that never filled (real loss).
    var holesLost = 0
    /// Skips forced because the 256 slots were full.
    var queueFullSkips = 0
    /// Holes skipped after the wait ran out.
    var timeoutSkips = 0
    var delivered = 0
    var duplicates = 0
    /// Dropped for being before the queue start, ambiguous, or too big for a slot.
    var dropped = 0
}

/// The 256-slot video queue (§12.2): delivers packets in packet-index order, waiting up to the measured reorder
/// wait for a missing one. Payloads that have to wait are copied into preallocated slots; a packet that arrives
/// in order is handed up straight from the receive buffer. Not thread safe: owned by the receive thread.
final class VideoReorderQueue {
    static let slotCount = 256
    static let slotBytes = TakionConstants.maxDatagram

    typealias Deliver = (TakionAVHeader, UnsafeMutableRawBufferPointer, UInt64) -> Void

    private(set) var stats = ReorderStats()
    private var estimator = ReorderEstimator()
    private var started = false
    private var start: UInt16 = 0
    private var count = 0
    private var waiting = false
    private var waitStart: Int64 = 0
    private var holeEnd: UInt16 = 0

    private let headers: UnsafeMutablePointer<TakionAVHeader>
    private let lengths: UnsafeMutablePointer<Int>
    private let times: UnsafeMutablePointer<UInt64>
    private let occupied: UnsafeMutablePointer<Bool>
    private let payloads: UnsafeMutableRawPointer

    init() {
        let n = Self.slotCount
        headers = .allocate(capacity: n)
        headers.initialize(repeating: TakionAVHeader(kind: .video, packetIndex: 0, frameIndex: 0, unitIndex: 0, totalUnits: 0,
                                                     fecUnits: 0, sourceUnits: 0, unitSize: 0, codec: 0, field18: 0,
                                                     adaptiveStreamIndex: 0, extensionFlag: false, keyPosLow: 0),
                           count: n)
        lengths = .allocate(capacity: n)
        lengths.initialize(repeating: 0, count: n)
        times = .allocate(capacity: n)
        times.initialize(repeating: 0, count: n)
        occupied = .allocate(capacity: n)
        occupied.initialize(repeating: false, count: n)
        payloads = .allocate(byteCount: n * Self.slotBytes, alignment: 16)
    }

    deinit {
        headers.deallocate()
        lengths.deallocate()
        times.deallocate()
        occupied.deallocate()
        payloads.deallocate()
    }

    /// The current wait in microseconds.
    var waitMicros: Int { Int(estimator.wait) }

    /// Estimator-backed counters.
    var snapshot: ReorderStats {
        var s = stats
        s.waitMicros = Int(estimator.wait)
        s.latePackets = estimator.latePackets
        s.holesLost = estimator.holesLost
        return s
    }

    /// When the running wait runs out (monotonic ns), or nil when nothing is waiting.
    var nextDeadline: UInt64? {
        guard waiting else { return nil }
        return UInt64(max(waitStart + estimator.wait, 0)) * 1000 + 1000
    }

    /// A video packet arrived (already authenticated and decrypted). Delivers whatever is now in order.
    @_optimize(speed) func insert(_ header: TakionAVHeader, payload: UnsafeMutableRawBufferPointer, at now: UInt64, deliver: Deliver) {
        let nowUs = Int64(now / 1000)
        let index = header.packetIndex
        if !started {
            started = true
            start = index &- UInt16(truncatingIfNeeded: header.unitIndex)
        }
        if count == 0 && index == start {
            deliver(header, payload, now)
            stats.delivered += 1
            start &+= 1
            flush(nowUs, deliver)
            return
        }
        if Serial.isBefore(index, start) {
            if estimator.packetBeforeStart(index, now: nowUs) { /* counted by the estimator */ }
            stats.dropped += 1
            return
        }
        if (index &- start) >= 0x8000 {
            guard count == 0 else {
                stats.dropped += 1
                return
            }
            start = index
            waiting = false
        }
        if Int(index &- start) >= Self.slotCount { makeRoom(for: index, nowUs, deliver) }
        guard payload.count <= Self.slotBytes else {
            stats.dropped += 1
            return
        }
        let slot = Int(index & 0xff)
        guard !occupied[slot] else {
            stats.duplicates += 1
            return
        }
        if payload.count > 0, let base = payload.baseAddress {
            (payloads + slot * Self.slotBytes).copyMemory(from: base, byteCount: payload.count)
        }
        headers[slot] = header
        lengths[slot] = payload.count
        times[slot] = now
        occupied[slot] = true
        count += 1
        flush(nowUs, deliver)
    }

    /// The timer fired: skip the hole if the wait has run out.
    @_optimize(speed) func wake(at now: UInt64, deliver: Deliver) { flush(Int64(now / 1000), deliver) }

    // MARK: Internals

    @_optimize(speed) private func deliverHead(_ deliver: Deliver) {
        while occupied[Int(start & 0xff)] {
            let slot = Int(start & 0xff)
            let buffer = UnsafeMutableRawBufferPointer(start: payloads + slot * Self.slotBytes, count: lengths[slot])
            deliver(headers[slot], buffer, times[slot])
            stats.delivered += 1
            occupied[slot] = false
            count -= 1
            start &+= 1
        }
    }

    /// Length of the run of missing packets at the head (only meaningful while something is buffered).
    @_optimize(speed) private func missingRun() -> Int {
        var run = 0
        while run < Self.slotCount && !occupied[Int((start &+ UInt16(run)) & 0xff)] { run += 1 }
        return run
    }

    @_optimize(speed) private func skipHead(now: Int64, queueFull: Bool) {
        let run = missingRun()
        estimator.holeSkipped(begin: start, count: run, waitStart: waiting ? waitStart : now, now: now, queueFull: queueFull)
        if queueFull { stats.queueFullSkips += 1 } else { stats.timeoutSkips += 1 }
        start &+= UInt16(run)
        waiting = false
    }

    @_optimize(speed) private func makeRoom(for index: UInt16, _ now: Int64, _ deliver: Deliver) {
        while Int(index &- start) >= Self.slotCount && count > 0 {
            let before = start
            let beforeCount = count
            deliverHead(deliver)
            if start == before { skipHead(now: now, queueFull: true) }
            waiting = false
            if start == before && count == beforeCount { break }
        }
        if Int(index &- start) >= Self.slotCount {
            // Nothing is buffered and the packet is still far ahead: everything in between is lost.
            let gap = Int(index &- start)
            estimator.holeSkipped(begin: start, count: gap, waitStart: now, now: now, queueFull: true)
            stats.queueFullSkips += 1
            start = index
            waiting = false
        }
    }

    @_optimize(speed) private func flush(_ now: Int64, _ deliver: Deliver) {
        while true {
            deliverHead(deliver)
            if waiting && !Serial.isBefore(start, holeEnd) {
                estimator.holeFilled(lateness: now - waitStart)
                stats.holesFilled += 1
                waiting = false
            }
            if count == 0 {
                waiting = false
                break
            }
            if !waiting {
                waiting = true
                waitStart = now
                holeEnd = start &+ UInt16(missingRun())
                break
            }
            if now - waitStart <= estimator.wait { break }
            skipHead(now: now, queueFull: false)
        }
        estimator.expire(now: now)
    }
}
