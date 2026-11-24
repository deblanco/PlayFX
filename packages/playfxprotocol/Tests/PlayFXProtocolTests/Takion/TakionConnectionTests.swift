import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

/// Handshake, reliable data, fragmentation and the crypto switch, over the in-memory link and the fake console.
@Suite struct TakionConnectionTests {
    static let second: UInt64 = 1_000_000_000

    /// Control packets (type 0) the client sent, so periodic congestion reports don't count.
    func control(_ h: MemoryHarness) -> [[UInt8]] { h.transport.sent.filter { $0[0] & 0x0f == 0 } }

    // MARK: Handshake

    @Test func handshakeMessagesAndStates() throws {
        let h = MemoryHarness()
        try h.connection.connect()
        #expect(h.transport.sent.first == hex("00000000000000000000000000010000141234abcd00019000006400641234abcd"))
        #expect(!h.delegate.connected)
        h.pump()
        #expect(h.transport.sent[1] == hex("005a5aa5a500000000000000000a000024c0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf"))
        #expect(h.delegate.connected)
        #expect(h.connection.isConnected)
        #expect(h.transport.sent.count == 2)
    }

    @Test func initIsRetriedUnchangedThenTheConnectionFails() throws {
        let h = MemoryHarness { $0.stepTimeout = 1; $0.handshakeTimeout = 30 }
        h.console.replyToHandshake = false
        try h.connection.connect()
        let init1 = try #require(h.transport.sent.first)
        let t0 = takionNow()
        h.connection.transportWake(now: t0 + Self.second / 2)
        #expect(control(h).count == 1)
        h.connection.transportWake(now: t0 + 2 * Self.second)
        h.connection.transportWake(now: t0 + 4 * Self.second)
        #expect(control(h).count == 3)
        #expect(control(h).allSatisfy { $0 == init1 })
        h.connection.transportWake(now: t0 + 6 * Self.second)
        #expect(h.delegate.closed == [.handshakeTimeout])
        #expect(h.transport.stopped)
    }

    @Test func cookieIsRetriedAndOverallLimitApplies() throws {
        let h = MemoryHarness { $0.stepTimeout = 1; $0.handshakeTimeout = 3.5 }
        h.console.replyToHandshake = false
        try h.connection.connect()
        h.deliver(h.console.initAck())
        let cookie = h.transport.sent[1]
        #expect(cookie[13] == 0x0a)
        // A repeated INIT_ACK while waiting for COOKIE_ACK is ignored.
        h.deliver(h.console.initAck())
        #expect(h.transport.sent.count == 2)
        let t0 = takionNow()
        h.connection.transportWake(now: t0 + 2 * Self.second)
        #expect(control(h).count == 3 && control(h)[2] == cookie)
        // 3.5 s since connect(): the overall limit fires before the third try.
        h.connection.transportWake(now: t0 + 4 * Self.second)
        #expect(h.delegate.closed == [.handshakeTimeout])
    }

    @Test func badInitAcksAreIgnored() throws {
        let good = FakeTakionConsole().initAck()
        var variants: [[UInt8]] = []
        var v = good; v[1] ^= 1; variants.append(v)                      // wrong tag
        v = good; v[14] = 1; variants.append(v)                          // flags
        v = good; v[13] = 0x0b; variants.append(v)                       // wrong chunk type
        v = good; v.replaceSubrange(17..<21, with: [0, 0, 0, 0]); variants.append(v)  // consoleTag 0
        v = good; v.replaceSubrange(25..<27, with: [0, 0]); variants.append(v)        // 0 outbound streams
        v = good; v.replaceSubrange(25..<27, with: [0, 101]); variants.append(v)      // too many outbound
        v = good; v.replaceSubrange(27..<29, with: [0, 99]); variants.append(v)       // too few inbound
        variants.append(Array(good.dropLast()))                          // short
        v = good; v[16] = 0x35; variants.append(v)                       // length rule
        for bad in variants {
            let h = MemoryHarness()
            try h.connection.connect()
            h.deliver(bad)
            #expect(h.transport.sent.count == 1, "answered a bad INIT_ACK: \(bad)")
            #expect(!h.delegate.connected)
        }
    }

    @Test func randomClientTagIsNeverZero() {
        for _ in 0..<50 {
            let c = TakionConnection(configuration: TakionConfiguration(), transport: MemoryTransport(), delegate: RecordingDelegate())
            #expect(c.clientTag != 0)
        }
        var configuration = TakionConfiguration()
        configuration.clientTag = 0
        #expect(TakionConnection(configuration: configuration, transport: MemoryTransport(), delegate: RecordingDelegate()).clientTag == 1)
    }

    // MARK: Sending reliable data

    @Test func dataChunkBytesAndTSNs() throws {
        let h = MemoryHarness()
        try h.handshake()
        let first = try #require(h.connection.sendMessage(channel: 1, [0x08, 0x03]))
        #expect(first == TakionVec.clientTag)
        #expect(h.transport.sent.last == hex("005a5aa5a50000000000000000" + "0001" + "000f" + "1234abcd" + "0001" + "0000" + "00" + "0803"))
        let second = try #require(h.connection.sendMessage(channel: 2, dataType: 0, [1, 2, 3]))
        #expect(second == TakionVec.clientTag &+ 1)
        #expect(h.transport.sent.last == hex("005a5aa5a50000000000000000" + "0001" + "0010" + "1234abce" + "0002" + "0000" + "00" + "010203"))
    }

    @Test func sendingNeedsAConnection() throws {
        let h = MemoryHarness()
        #expect(h.connection.sendMessage(channel: 1, [1]) == nil)
        try h.handshake()
        h.connection.close()
        #expect(h.connection.sendMessage(channel: 1, [1]) == nil)
        #expect(!h.connection.sendRaw([1, 2, 3]))
        #expect(!h.connection.sendFeedbackState(body: [UInt8](repeating: 0, count: 28)))
    }

    @Test func acksRemoveChunksAndRetransmissionsAreIdentical() throws {
        let h = MemoryHarness { $0.retransmitAfter = 0.2 }
        h.console.ackData = false
        try h.handshake()
        let t0 = takionNow()
        for i in 0..<3 { h.connection.sendMessage(channel: 1, [UInt8(i)]) }
        let originals = Array(h.transport.sent.suffix(3))
        #expect(originals.allSatisfy { $0[13] == 0 })
        #expect(h.connection.unackedCount == 3)
        h.connection.transportWake(now: t0 + 100_000_000)
        #expect(control(h).count == 2 + 3)
        h.connection.transportWake(now: t0 + 300_000_000)
        #expect(Array(h.transport.sent.filter { $0[0] == 0 && $0[13] == 0 }.suffix(3)) == originals)
        #expect(h.connection.stats.retransmissions == 3)
        // Cumulative ack of the first two (TSN clientTag + 1).
        h.deliver(h.console.dataAck(cumulative: TakionVec.clientTag &+ 1))
        #expect(h.connection.unackedCount == 1)
        #expect(h.connection.isAcknowledged(TakionVec.clientTag))
        #expect(!h.connection.isAcknowledged(TakionVec.clientTag &+ 2))
        #expect(h.delegate.acked == [TakionVec.clientTag &+ 1])
        // An older cumulative ack changes nothing.
        h.deliver(h.console.dataAck(cumulative: TakionVec.clientTag))
        #expect(h.connection.unackedCount == 1)
        h.deliver(h.console.dataAck(cumulative: TakionVec.clientTag &+ 2))
        #expect(h.connection.unackedCount == 0)
    }

    @Test func chunksAreGivenUpAfterTheResendLimit() throws {
        let h = MemoryHarness { $0.maxResends = 3; $0.retransmitAfter = 0.01; $0.retransmitCheck = 0.01 }
        h.console.ackData = false
        try h.handshake()
        h.connection.sendMessage(channel: 1, [1])
        var t = takionNow()
        for _ in 0..<10 {
            t += 50_000_000
            h.connection.transportWake(now: t)
        }
        let stats = h.connection.stats
        #expect(stats.retransmissions == 3 && stats.chunksGivenUp == 1)
        #expect(h.connection.unackedCount == 0)
        #expect(control(h).count == 2 + 1 + 3)
    }

    @Test func atMostThe1024ChunkLimitIsKept() throws {
        let h = MemoryHarness { $0.maxUnacked = 4 }
        h.console.ackData = false
        try h.handshake()
        for i in 0..<6 { h.connection.sendMessage(channel: 1, [UInt8(i)]) }
        #expect(h.connection.unackedCount == 4)
        #expect(h.transport.sent.count == 2 + 6)
        #expect(TakionConfiguration().maxUnacked == 1024)
    }

    @Test func gapBlocksInAcksAreAcceptedByLength() throws {
        let h = MemoryHarness()
        h.console.ackData = false
        try h.handshake()
        h.connection.sendMessage(channel: 1, [1])
        h.deliver(h.console.dataAck(cumulative: TakionVec.clientTag, gaps: [(2, 3), (5, 6)]))
        #expect(h.connection.unackedCount == 0)
        // A length that doesn't match 12 + 4 g is dropped.
        h.connection.sendMessage(channel: 1, [1])
        var bad = h.console.dataAck(cumulative: TakionVec.clientTag &+ 1, gaps: [(2, 3)])
        bad.removeLast()
        bad[16] = bad[16] &- 1
        h.deliver(bad)
        #expect(h.connection.unackedCount == 1)
    }

    // MARK: Fragmentation

    func fragments(_ h: MemoryHarness, after n: Int) -> [[UInt8]] { h.sent(after: n).filter { $0.count > 13 && $0[13] == 0 } }

    @Test(arguments: [0, 1, 1378, 1379, 1380, 2756, 2757, 2758, 2759, 5000, 20000])
    func largeMessagesAreSplitByTheSpecsRule(size: Int) throws {
        let h = MemoryHarness()
        h.console.ackData = false
        try h.handshake()
        let message = (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
        let before = h.transport.sent.count
        let lastTSN = try #require(h.connection.sendMessage(channel: 1, message))
        let chunks = fragments(h, after: before)
        // M = 1454 - 50 = 1404: first fragment carries up to 1378 bytes, later ones up to 1379.
        let m = 1404
        var expectedCount = 1
        if size > m - 26 { expectedCount = 1 + Int(((size - (m - 26)) + (m - 25) - 1) / (m - 25)) }
        #expect(chunks.count == expectedCount)
        var joined: [UInt8] = []
        for (i, c) in chunks.enumerated() {
            let last = i == chunks.count - 1
            #expect(c[14] == (last ? 1 : 0))
            #expect(readBE32(c, 17) == TakionVec.clientTag &+ UInt32(i))
            #expect(Int(readBE16(c, 15)) == c.count - 13)
            if i == 0 {
                joined += c[26...]
                #expect(c[25] == 0)
            } else {
                joined += c[25...]
            }
            if !last { #expect(c.count == m) }
        }
        #expect(joined == message)
        #expect(readBE32(chunks[chunks.count - 1], 17) == lastTSN)
    }

    @Test func mtuFromTheProbeSetsTheFragmentSize() throws {
        let h = MemoryHarness { $0.mtuIn = 1200; $0.mtuOut = 1454 }
        try h.handshake()
        let before = h.transport.sent.count
        h.connection.sendMessage(channel: 1, [UInt8](repeating: 7, count: 2000))
        let chunks = fragments(h, after: before)
        #expect(chunks.first?.count == 1150)
        #expect(chunks.count == 2)
    }

    // MARK: Receiving reliable data

    @Test func inOrderChunksAreDeliveredAndAcknowledgedOnce() throws {
        let h = MemoryHarness()
        try h.handshake()
        let before = h.transport.sent.count
        h.deliver(h.console.dataChunk(message: [1, 2]))
        #expect(h.delegate.messages == [.init(channel: 1, dataType: 0, bytes: [1, 2])])
        let ack = try #require(h.sent(after: before).first)
        #expect(ack == hex("005a5aa5a50000000000000000" + "03" + "00" + "0010" + "5a5aa5a5" + "00019000" + "0000" + "0000"))
    }

    @Test func outOfOrderChunksWaitInTheWindowAndGetOneAck() throws {
        let h = MemoryHarness()
        try h.handshake()
        let before = h.transport.sent.count
        let t = TakionVec.consoleTag
        h.deliver(h.console.dataChunk(tsn: t &+ 2, message: [3]))
        h.deliver(h.console.dataChunk(tsn: t &+ 1, message: [2]))
        #expect(h.delegate.messages.isEmpty)
        #expect(h.sent(after: before).isEmpty)
        // Duplicate of a stored chunk is dropped silently.
        h.deliver(h.console.dataChunk(tsn: t &+ 1, message: [2]))
        h.deliver(h.console.dataChunk(tsn: t, message: [1]))
        #expect(h.delegate.messages.map(\.bytes) == [[1], [2], [3]])
        let acks = h.sent(after: before)
        #expect(acks.count == 1)
        #expect(readBE32(acks[0], 17) == t &+ 2)
        #expect(h.connection.stats.duplicateChunks == 1)
    }

    @Test func chunksBeyondTheWindowAreDroppedAndDuplicatesReAcked() throws {
        let h = MemoryHarness()
        try h.handshake()
        let t = TakionVec.consoleTag
        h.deliver(h.console.dataChunk(tsn: t &+ 16, message: [9]))
        #expect(h.connection.stats.droppedWindow == 1)
        h.deliver(h.console.dataChunk(tsn: t &+ 15, message: [8]))
        #expect(h.delegate.messages.isEmpty)
        h.deliver(h.console.dataChunk(tsn: t, message: [1]))
        let before = h.transport.sent.count
        // A copy of an already delivered chunk: ack the same cumulative TSN again (recommendation of 5.5).
        h.deliver(h.console.dataChunk(tsn: t, message: [1]))
        let ack = try #require(h.sent(after: before).first)
        #expect(readBE32(ack, 17) == t)
        #expect(h.delegate.messages.count == 1)
    }

    @Test func tsnWrapInTheWindow() throws {
        let h = MemoryHarness()
        try h.connection.connect()
        h.deliver(h.console.initAck(initialTSN: 0xffff_fffe))
        // the window starts at consoleTag, not the INIT_ACK's initial TSN field (4.2)
        h.deliver(h.console.cookieAck())
        let t = TakionVec.consoleTag
        h.deliver(h.console.dataChunk(tsn: t, message: [1]))
        #expect(h.delegate.messages.count == 1)

        let w = MemoryHarness()
        w.console.replyToHandshake = false
        try w.connection.connect()
        // A console tag at the top of the TSN space.
        var ack = w.console.initAck()
        ack.replaceSubrange(17..<21, with: [0xff, 0xff, 0xff, 0xfe])
        w.deliver(ack)
        w.deliver(w.console.cookieAck())
        for (i, tsn) in [UInt32(0xffff_fffe), 0xffff_ffff, 0, 1].enumerated() {
            w.deliver(w.console.dataChunk(tsn: tsn, message: [UInt8(i)]))
        }
        #expect(w.delegate.messages.map(\.bytes) == [[0], [1], [2], [3]])
    }

    @Test func fragmentedConsoleMessagesAreReassembled() throws {
        let h = MemoryHarness()
        try h.handshake()
        let t = TakionVec.consoleTag
        h.deliver(h.console.dataChunk(tsn: t, channel: 4, dataType: 0, flags: 0, message: [1, 2, 3]))
        h.deliver(h.console.dataChunk(tsn: t &+ 1, channel: 4, dataType: nil, flags: 0, message: [4, 5]))
        #expect(h.delegate.messages.isEmpty)
        h.deliver(h.console.dataChunk(tsn: t &+ 2, channel: 4, dataType: nil, flags: 1, message: [6]))
        #expect(h.delegate.messages == [.init(channel: 4, dataType: 0, bytes: [1, 2, 3, 4, 5, 6])])
        h.deliver(h.console.dataChunk(tsn: t &+ 3, message: [7]))
        #expect(h.delegate.messages.last == .init(channel: 1, dataType: 0, bytes: [7]))
    }

    @Test func absurdReassemblyIsCutOff() throws {
        let h = MemoryHarness()
        try h.handshake()
        var tsn = TakionVec.consoleTag
        let big = [UInt8](repeating: 1, count: 1400)
        h.deliver(h.console.dataChunk(tsn: tsn, dataType: 0, flags: 0, message: big))
        for _ in 0..<3100 {
            tsn &+= 1
            h.deliver(h.console.dataChunk(tsn: tsn, dataType: nil, flags: 0, message: big))
        }
        #expect(h.connection.stats.droppedMalformed >= 1)
        tsn &+= 1
        h.deliver(h.console.dataChunk(tsn: tsn, dataType: nil, flags: 1, message: [1]))
        #expect(h.delegate.messages.count <= 1)
    }

    @Test func dataTypesAreFilteredAfterTheAck() throws {
        let h = MemoryHarness()
        try h.handshake()
        let t = TakionVec.consoleTag
        for (i, type) in [UInt8(0), 7, 9, 0x0b, 1, 8, 0xff].enumerated() {
            let before = h.transport.sent.count
            h.deliver(h.console.dataChunk(tsn: t &+ UInt32(i), dataType: type, message: [type]))
            #expect(h.transport.sent.count == before + 1, "chunk of type \(type) must be acked")
        }
        #expect(h.delegate.messages.map(\.dataType) == [0, 7, 9, 0x0b])
    }

    @Test func shortAndMalformedChunksAreDropped() throws {
        let h = MemoryHarness()
        try h.handshake()
        let good = h.console.dataChunk(message: [1])
        // Less than 9 payload bytes.
        var short = Array(good.prefix(25))
        short[16] = UInt8(short.count - 13)
        h.deliver(short)
        // Wrong chunk length.
        var wrong = good
        wrong[16] += 1
        h.deliver(wrong)
        // Wrong verification tag.
        var tag = good
        tag[2] ^= 1
        h.deliver(tag)
        #expect(h.delegate.messages.isEmpty)
        #expect(h.connection.stats.droppedMalformed == 3)
    }

    // MARK: Crypto switch

    @Test func theBangsAckIsTheFirstSecuredPacket() throws {
        let h = MemoryHarness()
        try h.handshake()
        h.delegate.onData = { [unowned h] message in
            if message.bytes == [0xb4, 0x4e] {
                h.connection.enableCrypto(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey)
            }
        }
        let t = TakionVec.consoleTag
        let before = h.transport.sent.count
        let bang = h.console.dataChunk(tsn: t, message: [0xb4, 0x4e])
        h.console.secure()
        h.deliver(bang)
        h.pump()
        let ack = try #require(h.console.packets.dropFirst(before).first)
        #expect(ack.chunkType == 3)
        #expect(ack.gmacOK == true)
        #expect(ack.keyPos == 0)
        let sentAck = h.sent(after: before)[0]
        #expect(Array(sentAck[0..<5]) == hex("005a5aa5a5"))
        #expect(Array(sentAck[9...]) == hex("00000000" + "03" + "00" + "0010" + "5a5aa5a5" + "00019000" + "0000" + "0000"))
        #expect(Array(sentAck[5..<9]) != [0, 0, 0, 0])
        // The console's next packets are secured; the client verifies them.
        h.deliver(h.console.dataChunk(tsn: t &+ 1, message: [1, 2, 3]))
        #expect(h.delegate.messages.last?.bytes == [1, 2, 3])
    }

    @Test func keyPositionsFollowTheAdvanceRule() throws {
        let h = MemoryHarness()
        try h.handshake()
        h.console.secure()
        h.connection.enableCrypto(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey)
        h.deliver(h.console.dataChunk(message: [1]))                  // ack, advance 42
        h.connection.sendMessage(channel: 1, [UInt8](repeating: 5, count: 5))   // advance 5 + 5 = 10
        h.connection.sendMessage(channel: 1, [UInt8](repeating: 5, count: 16))  // advance 16
        h.connection.sendMessage(channel: 1, [UInt8](repeating: 5, count: 17))  // advance 17 + 1 = 18
        h.pump()
        h.connection.transportWake(now: takionNow() + Self.second)              // congestion: advance 30
        h.pump()
        let secured = h.console.packets.filter { $0.gmacOK != nil }
        #expect(secured.map(\.keyPos) == [0, 42, 52, 68, 86])
        #expect(secured.allSatisfy { $0.gmacOK == true })
        #expect(h.connection.nextKeyPos == 116)
    }

    @Test func packetsFromBeforeTheSwitchAreRetransmittedUnchanged() throws {
        let h = MemoryHarness()
        h.console.ackData = false
        try h.handshake()
        h.connection.sendMessage(channel: 1, [1, 2, 3])
        let original = try #require(h.transport.sent.last)
        #expect(Array(original[5..<13]) == [UInt8](repeating: 0, count: 8))
        h.connection.enableCrypto(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey)
        h.connection.transportWake(now: takionNow() + Self.second)
        #expect(control(h).last == original)
    }

    @Test func queuedChunksAreCheckedWhenTheKeysAppear() throws {
        let h = MemoryHarness()
        try h.handshake()
        let t = TakionVec.consoleTag
        h.delegate.onData = { [unowned h] message in
            if message.bytes == [0xb4] { h.connection.enableCrypto(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey) }
        }
        // Chunks 1 (valid once secured) and 2 (unsecured, will fail the check) wait in the window behind the bang.
        let bang = h.console.dataChunk(tsn: t, message: [0xb4])
        h.console.secure()
        let secured = h.console.dataChunk(tsn: t &+ 1, message: [0x11])
        let plain = h.console.dataChunk(tsn: t &+ 2, message: [0x22]).enumerated().map { $0.offset >= 5 && $0.offset < 13 ? 0 : $0.element }
        h.deliver(plain)
        h.deliver(secured)
        h.deliver(bang)
        #expect(h.delegate.messages.map(\.bytes) == [[0xb4], [0x11]])
        #expect(h.connection.stats.droppedBadGMAC == 1)
    }

    @Test func badControlGMACIsDroppedAndDoesNotMoveTheReference() throws {
        let h = MemoryHarness()
        try h.handshake()
        h.console.secure()
        h.connection.enableCrypto(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey)
        let t = TakionVec.consoleTag
        var bad = h.console.dataChunk(tsn: t, message: [1], keyPos: 0x7000_0000)
        bad[5] ^= 1
        h.deliver(bad)
        #expect(h.delegate.messages.isEmpty)
        #expect(h.connection.stats.droppedBadGMAC == 1)
        // The reference is still near 0, so a packet near 0 reconstructs and verifies.
        h.deliver(h.console.dataChunk(tsn: t, message: [1], keyPos: 0x40))
        #expect(h.delegate.messages.count == 1)
    }

    @Test func keyPositionWrapAndEpochsThroughTheConnection() throws {
        let h = MemoryHarness()
        try h.handshake()
        h.console.secure()
        h.connection.enableCrypto(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey)
        let t = TakionVec.consoleTag
        var tsn = t
        for k: UInt64 in [44_990, 45_001, 90_001, 0xffff_ff00, 0x1_0000_0100, 0xffff_fff0 /* late, before the wrap */, 0x1_0000_0200, 0x1_8000_0000, 0x1_f000_0000, 0x2_0000_0040] {
            h.deliver(h.console.dataChunk(tsn: tsn, message: [UInt8(tsn & 0xff)], keyPos: k))
            tsn &+= 1
        }
        #expect(h.delegate.messages.count == 10)
    }

    @Test func closeEndsEverythingOnce() throws {
        let h = MemoryHarness()
        try h.handshake()
        h.connection.close()
        h.connection.close()
        #expect(h.delegate.closed == [.local])
        #expect(h.transport.stopped)
        #expect(!h.connection.isConnected)
        h.connection.transportFailed(errno: ECONNREFUSED)
        #expect(h.delegate.closed == [.local])
    }

    @Test func socketFailureEndsTheConnection() throws {
        let h = MemoryHarness()
        try h.handshake()
        h.connection.transportFailed(errno: ECONNREFUSED)
        #expect(h.delegate.closed == [.socketError(ECONNREFUSED)])
    }

    @Test func transientSendErrorsAreCountedAndFatalOnesEndTheConnection() throws {
        let h = MemoryHarness()
        try h.handshake()
        for code in [ENOBUFS, EAGAIN] {
            h.transport.failSend = FailureKind.other(errno: code)
            h.connection.sendMessage(channel: 1, [1])
        }
        #expect(h.connection.stats.sendErrors == 2)
        #expect(h.connection.isConnected && h.delegate.closed.isEmpty)
        let fatal: [(FailureKind, Int32)] = [(.connectionRefused, ECONNREFUSED), (.networkUnreachable, ENETUNREACH),
                                             (.hostDown, EHOSTUNREACH), (.other(errno: EACCES), EACCES)]
        for (kind, code) in fatal {
            let f = MemoryHarness()
            try f.handshake()
            f.transport.failSend = kind
            f.connection.sendMessage(channel: 1, [1])
            #expect(f.delegate.closed == [.socketError(code)], "\(kind)")
        }
        // The same from a timer-driven send (a retransmission) and from the receive path (an ack).
        let w = MemoryHarness { $0.retransmitAfter = 0.01 }
        w.console.ackData = false
        try w.handshake()
        w.connection.sendMessage(channel: 1, [1])
        w.transport.failSend = FailureKind.networkUnreachable
        w.connection.transportWake(now: takionNow() + 500_000_000)
        #expect(w.delegate.closed == [.socketError(ENETUNREACH)])
        let r = MemoryHarness()
        try r.handshake()
        r.transport.failSend = FailureKind.hostDown
        r.deliver(r.console.dataChunk(message: [1]))
        #expect(r.delegate.closed == [.socketError(EHOSTUNREACH)])
    }

    @Test func aTooBigChunkIsNotCopiedIntoAWindowSlot() throws {
        let h = MemoryHarness()
        try h.handshake()
        var big = h.console.dataChunk(message: [UInt8](repeating: 1, count: 2100))
        big.replaceSubrange(15..<17, with: be16(UInt16(big.count - 13)))
        h.deliver(big)
        #expect(h.connection.stats.droppedMalformed == 1)
        #expect(h.delegate.messages.isEmpty)
    }

    @Test func nextWakeCoversTheActiveTimers() throws {
        let h = MemoryHarness()
        #expect(h.connection.transportNextWake() == nil)
        try h.connection.connect()
        let handshake = try #require(h.connection.transportNextWake())
        #expect(handshake > takionNow())
        h.pump()
        // connected: only the congestion report is due.
        let congestion = try #require(h.connection.transportNextWake())
        #expect(congestion <= takionNow() + 250_000_000)
        h.connection.close()
        #expect(h.connection.transportNextWake() == nil)
    }
}
