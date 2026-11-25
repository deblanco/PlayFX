import Darwin
import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

// Allocation counting through libmalloc's `malloc_logger` hook: it is called for every malloc, calloc, realloc
// and free on every thread, so the hook filters on the calling thread and counts allocation events only.
// (`malloc_zone_statistics` can't show this: it reports blocks in use, and a block allocated and freed within
// one packet nets to zero.)

nonisolated(unsafe) private var countedThread: mach_port_t = 0
nonisolated(unsafe) private var countedAllocations = 0

private let mallocLogger: @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void = { type, _, _, _, _, _ in
    // stack_logging_type_alloc = 2 (malloc/calloc/realloc), dealloc = 4.
    if type & 2 != 0 && pthread_mach_thread_np(pthread_self()) == countedThread {
        countedAllocations += 1
    }
}

/// Runs `body` and returns how many allocations the calling thread made, or nil if the hook isn't available.
func countAllocations(_ body: () -> Void) -> Int? {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
    let slot = symbol.assumingMemoryBound(to: (@convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void)?.self)
    countedAllocations = 0
    countedThread = pthread_mach_thread_np(pthread_self())
    slot.pointee = mallocLogger
    body()
    slot.pointee = nil
    countedThread = 0
    return countedAllocations
}

/// A delegate that only counts: recording packets into arrays would allocate.
private final class CountingDelegate: TakionDelegate, @unchecked Sendable {
    var video = 0
    var audio = 0
    var bytes = 0
    var lastIndex: UInt16 = 0
    var inOrder = true
    func takionData(channel: UInt16, dataType: UInt8, message: UnsafeRawBufferPointer) {}
    func takionAV(_ header: TakionAVHeader, payload: UnsafeMutableRawBufferPointer, receivedAt: UInt64) {
        bytes += payload.count
        if header.isVideo {
            if video > 0 && !Serial.isAfter(header.packetIndex, lastIndex) { inOrder = false }
            lastIndex = header.packetIndex
            video += 1
        } else {
            audio += 1
        }
    }
}

@Suite(.serialized) struct TakionAllocationTests {
    @Test func theHookCountsAllocations() throws {
        let count = try #require(countAllocations {
            var keep: [[UInt8]] = []
            for i in 0..<10 { keep.append([UInt8](repeating: UInt8(i), count: 100 + i)) }
            #expect(keep.count == 10)
        })
        #expect(count >= 10)
    }

    /// 10,000 secured AV packets, some out of order, some audio, crossing about 300 GMAC key epochs, through the
    /// whole handler path (header, GMAC, decrypt, reorder, hand-up): no allocation.
    ///
    /// Only an optimised build can show it: a debug build doesn't specialise the standard library's generic
    /// iterators and allocates inside them. So the zero is asserted when the tests are built with
    /// `scripts/test.sh -c release -Xswiftc -enable-testing --filter TakionAllocationTests`; the default debug run
    /// uses a few hundred packets, for coverage only.
    @Test func theAVHandlerPathDoesNotAllocate() throws {
        let transport = MemoryTransport()
        let delegate = CountingDelegate()
        var configuration = TakionConfiguration()
        configuration.clientTag = TakionVec.clientTag
        let connection = TakionConnection(configuration: configuration, transport: transport, delegate: delegate)
        let console = FakeTakionConsole()
        try connection.connect()
        func feed(_ bytes: [UInt8], _ scratch: UnsafeMutableRawBufferPointer) {
            // Deterministic epoch changes: the helper thread has the next GMAC key ready before the packet arrives.
            connection.waitForPrefetch()
            bytes.withUnsafeBytes { scratch.copyMemory(from: $0) }
            connection.transportDidReceive(UnsafeMutableRawBufferPointer(rebasing: scratch[0..<bytes.count]), at: takionNow())
        }
        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: 2048, alignment: 16)
        defer { scratch.deallocate() }
        feed(console.initAck(), scratch)
        feed(console.cookieAck(), scratch)
        #expect(connection.isConnected)
        console.secure()
        connection.enableCrypto(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey)

        // Build the packets: 8,000 video (every tenth pair swapped) and 2,000 audio, 1,400 bytes each.
        var packets: [[UInt8]] = []
        let payload = [UInt8](repeating: 0x5a, count: 1379)
        var index: UInt16 = 0
        #if DEBUG
        let packetBudget = 400
        #else
        let packetBudget = 8000
        #endif
        for n in 0..<packetBudget {
            packets.append(console.video(index: index, frame: UInt16(n / 8), unit: n % 8, total: 8, fec: 1, payload: payload))
            index &+= 1
            if n % 4 == 3 { packets.append(console.av(video: false, packetIndex: UInt16(n), frameIndex: UInt16(n), word: 0x0002_5021,
                                                      codec: 5, payload: [UInt8](repeating: 3, count: 120))) }
            if n % 5 == 4 { packets.append(console.av(video: false, packetIndex: UInt16(n), frameIndex: UInt16(n), word: 0x0002_5021,
                                                      codec: 5, payload: [UInt8](repeating: 3, count: 120))) }
        }
        for i in stride(from: 10, to: packets.count - 3, by: 10) where packets[i][0] & 0x0f == 2 && packets[i + 1][0] & 0x0f == 2 {
            packets.swapAt(i, i + 1)
        }

        // Warm up (lazy statics, first key use), then count.
        let warmUp = min(300, packets.count / 4)
        for p in packets.prefix(warmUp) { feed(p, scratch) }
        let rest = Array(packets.dropFirst(warmUp))
        let measured = countAllocations {
            for p in rest { feed(p, scratch) }
        }
        // `feed` itself touches arrays only by reading them: no allocation. Reaching here with the hook gone is a skip.
        let count = try #require(measured, "malloc_logger is not available")
        #if DEBUG
        // A debug build allocates inside unspecialised standard-library iterators (measured: about 77 per packet).
        // The bound still catches a real regression (a per-packet array or closure box adds to it) and shows the
        // count is a small constant per packet, not growing with the stream.
        #expect(count <= 120 * rest.count, "\(count) allocations over \(rest.count) packets")
        #else
        #expect(count == 0, "\(count) allocations over \(rest.count) packets")
        #expect(rest.count >= 10_000)
        #endif
        #expect(delegate.video >= packetBudget * 9 / 10 && delegate.audio >= packetBudget / 5)
        #expect(connection.stats.droppedBadGMAC == 0)
        #expect(connection.stats.reorder.holesFilled > packetBudget / 80)
    }
}
