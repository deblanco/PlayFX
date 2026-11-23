import Darwin
import Foundation
import Testing

@testable import PlayFXProtocol

enum TransportKind: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case bsd, nw
    var testDescription: String { rawValue }

    func make(port: UInt16) -> DatagramTransport {
        switch self {
        case .bsd: return BSDDatagramTransport(host: "127.0.0.1", port: port)
        case .nw: return NWDatagramTransport(host: "127.0.0.1", port: port)
        }
    }
}

/// A connection over a real transport talking to the fake console on a loopback socket.
final class LoopbackHarness {
    let link: UDPConsoleLink
    let console = FakeTakionConsole()
    let delegate = RecordingDelegate()
    let connection: TakionConnection
    let transport: DatagramTransport

    init(_ kind: TransportKind, version: Int = 12, tweak: (inout TakionConfiguration) -> Void = { _ in }) throws {
        link = try UDPConsoleLink(console: console)
        transport = kind.make(port: link.port)
        var configuration = TakionConfiguration()
        configuration.version = version
        configuration.clientTag = TakionVec.clientTag
        tweak(&configuration)
        connection = TakionConnection(configuration: configuration, transport: transport, delegate: delegate)
    }

    deinit {
        connection.close()
        link.stop()
    }

    func connect() throws {
        try connection.connect()
        #expect(eventually { delegate.connected })
    }

    /// Handshake, then the crypto switch the way the stream layer does it: from the bang's callback.
    func connectSecured() throws {
        let connection = connection
        delegate.onData = { message in
            if message.bytes == [0xb4, 0x4e] { connection.enableCrypto(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey) }
        }
        try connect()
        let bang = console.dataChunk(message: [0xb4, 0x4e])
        console.secure()
        link.send(bang)
        #expect(eventually { delegate.messages.count == 1 })
        #expect(eventually { console.packets.contains { $0.chunkType == 3 } })
    }
}

@Suite struct TakionTransportTests {
    @Test(arguments: TransportKind.allCases)
    func handshakeOverRealSockets(kind: TransportKind) throws {
        let h = try LoopbackHarness(kind)
        try h.connect()
        let packets = h.console.packets
        #expect(packets[0].bytes == hex("00000000000000000000000000010000141234abcd00019000006400641234abcd"))
        #expect(packets[1].bytes == hex("005a5aa5a500000000000000000a000024c0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf"))
        #expect(h.transport.localPort != 0)
    }

    @Test(arguments: TransportKind.allCases)
    func theSecureSessionWorksEndToEnd(kind: TransportKind) throws {
        let h = try LoopbackHarness(kind)
        try h.connectSecured()
        let ack = try #require(h.console.packets.first { $0.chunkType == 3 })
        #expect(ack.gmacOK == true && ack.keyPos == 0)

        h.link.send(h.console.dataChunk(message: [9, 9]))
        #expect(eventually { h.delegate.messages.count == 2 })
        let tsn = try #require(h.connection.sendMessage(channel: 1, [1, 2, 3]))
        #expect(eventually { h.connection.isAcknowledged(tsn) })
        let sent = try #require(h.console.dataChunks().last)
        #expect(sent.gmacOK == true)

        let before = takionNow()
        for i in 0..<20 { h.link.send(h.console.video(index: UInt16(i), frame: UInt16(i / 4), unit: i % 4, total: 4)) }
        h.link.send(h.console.av(video: false, packetIndex: 0, frameIndex: 0, word: 0x0002_5021, codec: 5, payload: [1, 2, 3]))
        #expect(eventually { h.delegate.av.count == 21 })
        let video = h.delegate.av.filter { $0.header.isVideo }
        #expect(video.map(\.header.packetIndex) == (0..<20).map { UInt16($0) })
        // Kernel receive times: after we started sending, before now, and not going backwards.
        let stamps = video.map(\.receivedAt)
        #expect(stamps.allSatisfy { $0 >= before && $0 <= takionNow() })
        #expect(zip(stamps, stamps.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test(arguments: TransportKind.allCases)
    func aHoleIsSkippedByTheTimerWithoutFurtherPackets(kind: TransportKind) throws {
        let h = try LoopbackHarness(kind)
        try h.connectSecured()
        h.link.send(h.console.video(index: 0))
        // Packet 1 is lost; 2 arrives, and nothing else ever does: the receive loop's timer must skip the hole.
        let start = Date()
        h.link.send(h.console.video(index: 2))
        #expect(eventually { h.delegate.av.count == 2 })
        #expect(h.delegate.av.map(\.header.packetIndex) == [0, 2])
        #expect(Date().timeIntervalSince(start) >= 0.012)
        #expect(h.connection.stats.reorder.timeoutSkips == 1)
        // A late packet arriving afterwards counts as late and is dropped.
        h.link.send(h.console.video(index: 1))
        #expect(eventually { h.connection.stats.reorder.latePackets == 1 })
    }

    @Test(arguments: TransportKind.allCases)
    func unackedDataIsRetransmittedUnchangedFromAnotherThread(kind: TransportKind) throws {
        let h = try LoopbackHarness(kind) { $0.retransmitAfter = 0.05; $0.retransmitCheck = 0.02 }
        h.console.ackData = false
        try h.connect()
        h.connection.sendMessage(channel: 1, [4, 5, 6])
        #expect(eventually { h.console.dataChunks().count >= 3 })
        let copies = h.console.dataChunks().map(\.bytes)
        #expect(Set(copies).count == 1)
        // Now acknowledge it: the retransmissions stop.
        h.link.send(h.console.dataAck(cumulative: TakionVec.clientTag))
        #expect(eventually { h.connection.unackedCount == 0 })
    }

    @Test(arguments: TransportKind.allCases)
    func congestionReportsKeepComing(kind: TransportKind) throws {
        let h = try LoopbackHarness(kind) { $0.congestionPeriod = 0.05 }
        try h.connectSecured()
        #expect(eventually { h.console.packets(ofType: 5).count >= 4 })
        let reports = h.console.packets(ofType: 5)
        #expect(reports.dropFirst().allSatisfy { $0.gmacOK == true || $0.gmacOK == nil })
        #expect(reports.contains { $0.gmacOK == true })
    }

    @Test(arguments: TransportKind.allCases)
    func theHandshakeTimesOutWithNoAnswer(kind: TransportKind) throws {
        let h = try LoopbackHarness(kind) { $0.stepTimeout = 0.1; $0.stepTries = 2; $0.handshakeTimeout = 5 }
        h.console.replyToHandshake = false
        try h.connection.connect()
        #expect(eventually { !h.delegate.closed.isEmpty })
        #expect(h.delegate.closed == [.handshakeTimeout])
        #expect(h.console.initCount == 2)
    }

    @Test(arguments: TransportKind.allCases)
    func closingFromACallbackDoesNotDeadlock(kind: TransportKind) throws {
        let h = try LoopbackHarness(kind)
        let connection = h.connection
        h.delegate.onData = { _ in connection.close() }
        try h.connect()
        h.link.send(h.console.dataChunk(message: [1]))
        #expect(eventually { h.delegate.closed == [.local] })
        h.transport.stop()
    }

    @Test(arguments: TransportKind.allCases)
    func aBurstBiggerThanTheRingIsReceivedWhole(kind: TransportKind) throws {
        let h = try LoopbackHarness(kind)
        try h.connectSecured()
        let payload = [UInt8](repeating: 7, count: 1300)
        let packets = (0..<300).map { h.console.video(index: UInt16($0), frame: UInt16($0 / 8), unit: $0 % 8, total: 8, payload: payload) }
        for p in packets { h.link.send(p) }
        #expect(eventually(5) { h.delegate.av.count == 300 })
        #expect(h.delegate.av.allSatisfy { $0.payload == payload })
    }

    @Test func theBSDTransportReportsItsSocketSetup() throws {
        let h = try LoopbackHarness(.bsd)
        try h.connect()
        let bsd = try #require(h.transport as? BSDDatagramTransport)
        #expect(bsd.timestampSource == "SO_TIMESTAMP_MONOTONIC")
        #expect(bsd.receiveBufferBytes >= 102_400)
        #expect(bsd.name == "bsd")
    }

    @Test func theBSDTransportSeesIcmpPortUnreachable() throws {
        // A port nobody listens on: bind, note the port, close.
        let probe = socket(AF_INET, SOCK_DGRAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(probe, $0, length) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(probe, $0, &length) } }
        let port = UInt16(bigEndian: addr.sin_port)
        close(probe)
        let delegate = RecordingDelegate()
        var configuration = TakionConfiguration()
        configuration.clientTag = TakionVec.clientTag
        let connection = TakionConnection(configuration: configuration, transport: BSDDatagramTransport(host: "127.0.0.1", port: port), delegate: delegate)
        try connection.connect()
        #expect(eventually { !delegate.closed.isEmpty })
        #expect(delegate.closed == [.socketError(ECONNREFUSED)])
    }

    /// A socket error on the receive thread while another thread keeps sending: every send that starts after the
    /// failure was reported must fail, and none may reach a descriptor number that was recycled for a new socket.
    @Test func noSendReachesARecycledDescriptorAfterAFailure() throws {
        // A listener, and the unused port the transport will talk to.
        let listener = socket(AF_INET, SOCK_DGRAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
        let unused = socket(AF_INET, SOCK_DGRAM, 0)
        var dead = sockaddr_in()
        dead.sin_family = sa_family_t(AF_INET)
        dead.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dead.sin_addr.s_addr = inet_addr("127.0.0.1")
        var deadLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &dead) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(unused, $0, deadLength) } }
        _ = withUnsafeMutablePointer(to: &dead) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(unused, $0, &deadLength) } }
        let deadPort = UInt16(bigEndian: dead.sin_port)
        close(unused)

        let handler = FailureHandler()
        let transport = BSDDatagramTransport(host: "127.0.0.1", port: deadPort)
        try transport.start(handler: handler)
        let violations = Locked(0)
        let attempts = Locked(0)
        let senderDone = DispatchSemaphore(value: 0)
        Thread {
            let deadline = Date().addingTimeInterval(5)
            var afterFailure = 0
            while Date() < deadline {
                let failedBefore = handler.failed
                do {
                    try transport.send([0xee, 0xee, 0xee])
                    if failedBefore { violations.with { $0 += 1 } }
                } catch {}
                attempts.with { $0 += 1 }
                if failedBefore { afterFailure += 1 }
                if afterFailure >= 3000 { break }
                usleep(50)
            }
            senderDone.signal()
        }.start()
        usleep(5000)
        try? transport.send([1])            // ICMP port unreachable comes back as a socket error
        #expect(eventually { handler.failed })
        // Recycle descriptor numbers into sockets connected to the listener: a stray send would land there.
        var decoys: [Int32] = []
        for _ in 0..<8 {
            let decoy = socket(AF_INET, SOCK_DGRAM, 0)
            _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(decoy, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            decoys.append(decoy)
        }
        senderDone.wait()
        var received = 0
        var buffer = [UInt8](repeating: 0, count: 16)
        while recv(listener, &buffer, buffer.count, 0) > 0 { received += 1 }
        #expect(violations.with { $0 } == 0)
        #expect(received == 0)
        #expect(throws: FailureKind.disconnected) { try transport.send([1]) }
        transport.stop()
        decoys.forEach { close($0) }
        close(listener)
    }

    @Test func aSecondStopAndSendAfterStopAreSafe() throws {
        let console = FakeTakionConsole()
        let link = try UDPConsoleLink(console: console)
        defer { link.stop() }
        let transport = BSDDatagramTransport(host: "127.0.0.1", port: link.port)
        try transport.start(handler: MemoryHandler())
        transport.stop()
        transport.stop()
        transport.reschedule()
        #expect(throws: FailureKind.disconnected) { try transport.send([1]) }
    }

    @Test func transportsRejectBadAddresses() {
        #expect(throws: FailureKind.badAddress) { try BSDDatagramTransport(host: "not an address", port: 1).start(handler: MemoryHandler()) }
    }

    @Test(arguments: TransportKind.allCases)
    func transportsCallTheirTimerAndCanBePoked(kind: TransportKind) throws {
        let handler = MemoryHandler()
        // A server socket so that the transport has a peer.
        let console = FakeTakionConsole()
        let link = try UDPConsoleLink(console: console)
        defer { link.stop() }
        let transport = kind.make(port: link.port)
        try transport.start(handler: handler)
        defer { transport.stop() }
        try transport.send([1, 2, 3])
        #expect(eventually { console.packets.count == 1 })
        link.send([9, 8, 7, 6])
        #expect(eventually { handler.datagrams.count == 1 })
        #expect(handler.datagrams[0] == [9, 8, 7, 6])
        handler.setWake(takionNow() + 30_000_000)
        transport.reschedule()
        #expect(eventually { handler.wakes >= 1 })
        // A deadline moved earlier from another thread is honoured without a datagram arriving.
        let wakes = handler.wakes
        handler.setWake(takionNow() + 2_000_000_000)
        transport.reschedule()
        usleep(20_000)
        handler.setWake(takionNow() + 5_000_000)
        transport.reschedule()
        #expect(eventually { handler.wakes > wakes })
    }

    @Test func datagramTransportSendsArrays() throws {
        let console = FakeTakionConsole()
        let link = try UDPConsoleLink(console: console)
        defer { link.stop() }
        let transport = BSDDatagramTransport(host: "127.0.0.1", port: link.port)
        try transport.start(handler: MemoryHandler())
        defer { transport.stop() }
        try transport.send([UInt8](repeating: 1, count: 100) as [UInt8])
        #expect(eventually { console.packets.first?.bytes.count == 100 })
    }

    @Test func machTimeConvertsTicks() {
        let t = MachTime(numer: 125, denom: 3)
        #expect(t.nanoseconds(3) == 125)
        #expect(t.nanoseconds(7_188_851_166_023) == 7_188_851_166_023 / 3 * 125 + (7_188_851_166_023 % 3) * 125 / 3)
        #expect(MachTime.current.nanoseconds(1) >= 1)
    }

    // MARK: Bench

    @Test(arguments: TransportKind.allCases)
    func theLoopbackBenchmarkRuns(kind: TransportKind) throws {
        let result = try TransportBench.run(transport: kind.rawValue, packets: 400, rate: 4000)
        #expect(result.packetsSent == 400)
        #expect(result.packetsReceived >= 380)
        #expect(result.packetsPerSecond > 0 && result.p50Micros >= 0 && result.p99Micros >= result.p50Micros)
        #expect(result.maxMicros >= result.p99Micros)
        #expect(result.cpuMillisPer1000 >= 0)
        #expect(!result.timestampSource.isEmpty)
    }

    @Test func theBenchmarkChecksItsArguments() {
        #expect(throws: TransportBenchError.self) { try TransportBench.run(transport: "bsd", packets: 0, rate: 1) }
        #expect(throws: TransportBenchError.self) { try TransportBench.run(transport: "bsd", packets: 10, rate: -1) }
        #expect(TransportBenchError.failed("x").description == "x")
    }
}

/// A handler for exercising a transport on its own.
final class MemoryHandler: TransportHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var _datagrams: [[UInt8]] = []
    private var _wakes = 0
    private var wake: UInt64?
    var datagrams: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return _datagrams }
    var wakes: Int { lock.lock(); defer { lock.unlock() }; return _wakes }
    func setWake(_ t: UInt64?) { lock.lock(); wake = t; lock.unlock() }
    func transportDidReceive(_ datagram: UnsafeMutableRawBufferPointer, at timestamp: UInt64, kernelTimestamp: Bool) {
        lock.lock(); _datagrams.append(Array(datagram)); lock.unlock()
    }
    func transportNextWake() -> UInt64? { lock.lock(); defer { lock.unlock() }; return wake }
    func transportWake(now: UInt64) { lock.lock(); _wakes += 1; wake = nil; lock.unlock() }
    func transportFailed(errno: Int32) {}
}

/// Records that the transport reported a failure.
final class FailureHandler: TransportHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var _failed = false
    var failed: Bool { lock.lock(); defer { lock.unlock() }; return _failed }
    func transportDidReceive(_ datagram: UnsafeMutableRawBufferPointer, at timestamp: UInt64, kernelTimestamp: Bool) {}
    func transportNextWake() -> UInt64? { nil }
    func transportWake(now: UInt64) {}
    func transportFailed(errno: Int32) { lock.lock(); _failed = true; lock.unlock() }
}
