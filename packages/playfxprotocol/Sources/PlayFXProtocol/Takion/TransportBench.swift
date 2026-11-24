import Darwin
import Foundation

// A loopback-only benchmark of the two receive transports (`pfxp bench-transport`): a sender thread plays the
// console on 127.0.0.1, does the Takion handshake and then blasts AV-sized encrypted video packets; the transport
// under test receives them, verifies the GMAC, decrypts, reorders and hands them up.

public struct TransportBenchResult: Sendable {
    public var transport: String
    public var timestampSource: String
    public var packetsSent: Int
    public var packetsReceived: Int
    /// Sent but never delivered (socket overflow on loopback), reported apart from the latencies.
    public var packetsDropped: Int
    public var packetsPerSecond: Double
    /// Receiving-side CPU time (process CPU minus the sender thread's), in milliseconds per 1,000 packets.
    public var cpuMillisPer1000: Double
    /// Receive timestamp to hand-up, in microseconds, over packets that were not held behind a hole (so the
    /// reorder wait isn't in it).
    public var p50Micros: Double
    public var p99Micros: Double
    public var maxMicros: Double
    /// Allocations per packet over the second half of the run, on the threads that ran the receive path (for `nw`
    /// that is the dispatch worker threads its callbacks hopped between). nil if the hook is missing.
    public var allocationsPerPacket: Double?
}

public enum TransportBenchError: Error, CustomStringConvertible {
    case failed(String)
    public var description: String {
        switch self { case .failed(let message): return message }
    }
}

public enum TransportBench {
    /// Runs one transport (`"bsd"` or `"nw"`) against `packets` packets at `rate` packets per second (0 = as fast
    /// as the sender can go). `countAllocations` installs a libmalloc `malloc_logger` hook for the second half of
    /// the run to count allocations on the receive path; it writes a process-wide libmalloc global, so it's for the
    /// `pfxp bench-transport` tool only (off in tests and the library's other users).
    /// Receive depth for both transports: datagrams drained per wake-up (BSD ring) or receives kept outstanding (NW).
    static let receiveDepth = 32

    public static func run(transport name: String, packets: Int, rate: Int, countAllocations: Bool = false) throws -> TransportBenchResult {
        guard (1...500_000).contains(packets), rate >= 0 else { throw TransportBenchError.failed("packets 1...500000, rate >= 0") }
        let packetSize = 1400
        let secret = [UInt8](repeating: 0x42, count: 32)
        let handshakeKey = [UInt8](repeating: 0x24, count: 16)

        let console = try BenchConsole(packets: packets, packetSize: packetSize, rate: rate, secret: secret, handshakeKey: handshakeKey)
        defer { console.close() }
        let transport: DatagramTransport = name == "nw"
            ? NWDatagramTransport(host: "127.0.0.1", port: console.port, outstandingReceives: receiveDepth)
            : BSDDatagramTransport(host: "127.0.0.1", port: console.port, ringSlots: receiveDepth)
        let recorder = BenchRecorder(capacity: packets)
        var configuration = TakionConfiguration()
        configuration.clientTag = 0x0bad_cafe
        let connection = TakionConnection(configuration: configuration, transport: transport, delegate: recorder)
        defer { connection.close() }
        console.start()
        do { try connection.connect() } catch { throw TransportBenchError.failed("connect: \(error)") }
        guard recorder.waitConnected(seconds: 5) else { throw TransportBenchError.failed("handshake did not finish") }
        connection.enableCrypto(ecdhSecret: secret, handshakeKey: handshakeKey)

        if countAllocations { recorder.allocationStart = packets / 2 }
        let cpuBefore = cpuSeconds(CLOCK_PROCESS_CPUTIME_ID)
        let start = takionNow()
        console.blast()
        let sent = console.waitSent(seconds: 60)
        // Wait until everything arrived, or nothing has for a while (drops leave holes the reorder wait skips).
        var lastCount = -1
        var lastChange = Date()
        while recorder.count < packets, Date().timeIntervalSince(lastChange) < 0.7 {
            usleep(2000)
            if recorder.count != lastCount {
                lastCount = recorder.count
                lastChange = Date()
            }
        }
        recorder.endAllocationWindow()
        let end = recorder.lastDone
        let cpu = cpuSeconds(CLOCK_PROCESS_CPUTIME_ID) - cpuBefore - console.senderCPUSeconds
        let received = recorder.count
        guard received > 0 else { throw TransportBenchError.failed("no packets arrived") }
        var latencies = recorder.sortedLatencies()
        guard !latencies.isEmpty else { throw TransportBenchError.failed("no undelayed packets to measure") }
        let seconds = Double(max(end - start, 1)) / 1e9
        let pick = { (q: Double) -> Double in Double(latencies[min(latencies.count - 1, Int(Double(latencies.count) * q))]) / 1000 }
        let result = TransportBenchResult(
            transport: name, timestampSource: (transport as? BSDDatagramTransport)?.timestampSource ?? "NWProtocolIP receiveTime (CLOCK_MONOTONIC_RAW age)",
            packetsSent: sent, packetsReceived: received, packetsDropped: max(sent - received, 0), packetsPerSecond: Double(received) / seconds,
            cpuMillisPer1000: max(cpu, 0) * 1000 / Double(received) * 1000, p50Micros: pick(0.5), p99Micros: pick(0.99),
            maxMicros: Double(latencies.removeLast()) / 1000,
            allocationsPerPacket: recorder.allocationsPerPacket)
        return result
    }

    private static func cpuSeconds(_ clock: clockid_t) -> Double { Double(clock_gettime_nsec_np(clock)) / 1e9 }
}

/// Collects hand-up latencies into a preallocated array: no allocation in the callback.
private final class BenchRecorder: TakionDelegate, @unchecked Sendable {
    private let latencies: UnsafeMutablePointer<UInt64>
    private let capacity: Int
    private let connected = DispatchSemaphore(value: 0)
    private let lock = UnfairLock()
    private var written = 0
    private var sampled = 0
    private var done: UInt64 = 0
    private var lastIndex: UInt16 = 0
    private var blockedUntil: UInt64 = 0
    /// Packet number at which to start counting allocations.
    var allocationStart: Int?
    private var counting = false
    private var countedAtStart = 0
    private var countedPackets = 0
    private var finalCount: Int?

    init(capacity: Int) {
        self.capacity = capacity
        latencies = .allocate(capacity: capacity)
        latencies.initialize(repeating: 0, count: capacity)
    }

    deinit { latencies.deallocate() }

    var count: Int { lock.withLock { written } }
    var lastDone: UInt64 { lock.withLock { done } }

    func waitConnected(seconds: Double) -> Bool { connected.wait(timeout: .now() + seconds) == .success }
    func sortedLatencies() -> [UInt64] {
        let n = lock.withLock { sampled }
        return Array(UnsafeBufferPointer(start: latencies, count: n)).sorted()
    }

    func takionConnected() { connected.signal() }

    func takionData(channel: UInt16, dataType: UInt8, message: UnsafeRawBufferPointer) {}

    /// Stops the allocation count (called after the run, from the benchmark's thread).
    func endAllocationWindow() {
        guard counting, let hook = BenchAllocationHook.shared else { return }
        finalCount = hook.stop()
        countedPackets = count - countedAtStart
        counting = false
    }

    var allocationsPerPacket: Double? {
        guard let count = finalCount, countedPackets > 0 else { return nil }
        return Double(count) / Double(countedPackets)
    }

    func takionAV(_ header: TakionAVHeader, payload: UnsafeMutableRawBufferPointer, receivedAt: UInt64) {
        // The hook is only touched when counting was asked for (it writes libmalloc's global).
        let hook = allocationStart == nil ? nil : BenchAllocationHook.shared
        hook?.registerCurrentThread()
        if let start = allocationStart, written == start, !counting {
            counting = true
            hook?.start()
            countedAtStart = written
        }
        let now = takionNow()
        lock.withLock {
            if written < capacity {
                // A packet after a gap, and every packet that was queued behind the hole (received before the gap
                // packet was delivered), carries the reorder wait: left out of the latencies.
                if written > 0 && header.packetIndex != lastIndex &+ 1 { blockedUntil = now }
                if receivedAt > blockedUntil {
                    latencies[sampled] = now &- min(receivedAt, now)
                    sampled += 1
                }
                lastIndex = header.packetIndex
                written += 1
            }
            done = now
        }
    }
}

/// The console side of the benchmark: a loopback UDP socket and one thread.
private final class BenchConsole: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let packets: Int
    private let packetSize: Int
    private let rate: Int
    private let buffer: UnsafeMutableRawPointer
    private let go = DispatchSemaphore(value: 0)
    private let started = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var sent = 0
    private var cpu = 0.0
    private var thread: Thread?

    init(packets: Int, packetSize: Int, rate: Int, secret: [UInt8], handshakeKey: [UInt8]) throws {
        self.packets = packets
        self.packetSize = packetSize
        self.rate = rate
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { throw TransportBenchError.failed("socket: \(errno)") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, size) } }
        guard bound == 0 else {
            Darwin.close(s)
            throw TransportBenchError.failed("bind: \(errno)")
        }
        var length = size
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &length) } }
        var buf: Int32 = 1 << 20
        setsockopt(s, SOL_SOCKET, SO_SNDBUF, &buf, 4)
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        fd = s
        port = UInt16(bigEndian: addr.sin_port)
        buffer = .allocate(byteCount: packets * packetSize, alignment: 16)
        // Pre-build every packet: video, 8 units per frame, key position advancing like a real console's.
        let down = GKCryptContext(ecdhSecret: secret, handshakeKey: handshakeKey, index: 3)
        var keyPos: UInt64 = 0
        for i in 0..<packets {
            let p = UnsafeMutableRawBufferPointer(start: buffer + i * packetSize, count: packetSize)
            p.initializeMemory(as: UInt8.self, repeating: UInt8(truncatingIfNeeded: i))
            p[0] = 0x02
            p.putBE16(UInt16(truncatingIfNeeded: i), at: 1)
            p.putBE16(UInt16(truncatingIfNeeded: i / 8), at: 3)
            p.putBE32(UInt32(i % 8) << 21 | UInt32(7) << 10 | 1, at: 5)
            p[9] = 3
            p.putBE16(0x0367, at: 18)
            p[20] = 0x20
            p.putBE32(UInt32(truncatingIfNeeded: keyPos), at: 14)
            down.apply(to: UnsafeMutableRawBufferPointer(rebasing: p[21...]), keyPos: keyPos)
            down.seal(p, layout: .av, keyPos: keyPos)
            keyPos &+= keyPosAdvance(16 + packetSize - 21)
        }
    }

    deinit { buffer.deallocate() }

    func start() {
        let thread = Thread { [self] in
            run()
            finished.signal()
        }
        thread.qualityOfService = .userInitiated
        thread.name = "playfx.bench.console"
        self.thread = thread
        thread.start()
    }

    func blast() { go.signal() }
    var senderCPUSeconds: Double { lock.lock(); defer { lock.unlock() }; return cpu }

    func waitSent(seconds: Double) -> Int {
        _ = started.wait(timeout: .now() + seconds)
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    func close() {
        if thread != nil { _ = finished.wait(timeout: .now() + 5) }
        Darwin.close(fd)
    }

    private func run() {
        var peer = sockaddr_in()
        var havePeer = false
        var clientTag: UInt32 = 0
        var datagram = [UInt8](repeating: 0, count: 2048)
        // Handshake: answer INIT and COOKIE; the first datagram tells us the client's loopback address.
        var steps = 0
        while steps < 2 {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &datagram, datagram.count, 0, $0, &length) }
            }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                started.signal()
                return
            }
            guard from.sin_addr.s_addr == inet_addr("127.0.0.1"), n >= 14 else { continue }
            peer = from
            havePeer = true
            var reply: [UInt8]?
            if datagram[13] == 0x01 {
                clientTag = UInt32(datagram[17]) << 24 | UInt32(datagram[18]) << 16 | UInt32(datagram[19]) << 8 | UInt32(datagram[20])
                reply = TakionWire.initAck(clientTag: clientTag, consoleTag: 0x5a5a_a5a5, initialTSN: 0x5a5a_a5a5,
                                           cookie: [UInt8](repeating: 0xc3, count: 32))
            } else if datagram[13] == 0x0a {
                reply = TakionWire.cookieAck(clientTag: clientTag)
                steps = 2
            }
            if let reply, havePeer {
                _ = withUnsafePointer(to: &peer) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, reply, reply.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
        }
        go.wait()
        guard havePeer, peer.sin_addr.s_addr == inet_addr("127.0.0.1") else {
            started.signal()
            return
        }
        _ = withUnsafePointer(to: &peer) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let begin = takionNow()
        var count = 0
        for i in 0..<packets {
            if rate > 0 {
                let due = begin + UInt64(Double(i) / Double(rate) * 1e9)
                while true {
                    let now = takionNow()
                    if now >= due { break }
                    if due - now > 300_000 { usleep(UInt32((due - now - 200_000) / 1000)) }
                }
            }
            var attempts = 0
            while send(fd, buffer + i * packetSize, packetSize, 0) < 0, errno == ENOBUFS, attempts < 1000 {
                attempts += 1
                usleep(50)
            }
            count += 1
        }
        lock.lock()
        sent = count
        cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e9
        lock.unlock()
        started.signal()
    }
}

/// Counts allocation events through libmalloc's `malloc_logger` hook (the same technique as the unit test), on
/// the threads that ran the receive path. Each such thread increments its own slot, so no atomics are needed.
private final class BenchAllocationHook: @unchecked Sendable {
    private typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
    private static let slotCount = 16
    nonisolated(unsafe) fileprivate static var threads = UnsafeMutablePointer<mach_port_t>.allocate(capacity: slotCount)
    nonisolated(unsafe) fileprivate static var counts = UnsafeMutablePointer<Int>.allocate(capacity: slotCount)
    nonisolated(unsafe) fileprivate static var registered = 0

    private static let logger: Logger = { type, _, _, _, _, _ in
        guard type & 2 != 0 else { return }
        let me = pthread_mach_thread_np(pthread_self())
        var i = 0
        while i < BenchAllocationHook.registered {
            if BenchAllocationHook.threads[i] == me {
                BenchAllocationHook.counts[i] += 1
                return
            }
            i += 1
        }
    }

    private let slot: UnsafeMutablePointer<Logger?>
    private let lock = UnfairLock()

    static let shared: BenchAllocationHook? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        threads.initialize(repeating: 0, count: slotCount)
        counts.initialize(repeating: 0, count: slotCount)
        return BenchAllocationHook(slot: symbol.assumingMemoryBound(to: Logger?.self))
    }()

    private init(slot: UnsafeMutablePointer<Logger?>) { self.slot = slot }

    /// Adds the calling thread to the counted set (does nothing if already there; never allocates).
    func registerCurrentThread() {
        let me = pthread_mach_thread_np(pthread_self())
        lock.withLock {
            var i = 0
            while i < Self.registered { if Self.threads[i] == me { return }; i += 1 }
            if Self.registered < Self.slotCount {
                Self.threads[Self.registered] = me
                Self.counts[Self.registered] = 0
                Self.registered += 1
            }
        }
    }

    func start() {
        lock.withLock { for i in 0..<Self.slotCount { Self.counts[i] = 0 } }
        slot.pointee = Self.logger
    }

    func stop() -> Int {
        slot.pointee = nil
        return lock.withLock { (0..<Self.slotCount).reduce(0) { $0 + Self.counts[$1] } }
    }
}
