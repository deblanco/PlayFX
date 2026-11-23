import CryptoKit
import Foundation
import Testing

@testable import PlayFXProtocol

/// The known-answer vectors T1...T16 of takion.md section 15 (T13's protobuf bytes belong to the stream layer;
/// its ping datagram is here).
@Suite struct TakionVectorTests {
    static func up() -> GKCryptContext { GKCryptContext(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey, index: 2) }
    static func down() -> GKCryptContext { GKCryptContext(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey, index: 3) }

    func seal(_ bytes: [UInt8], layout: GMACLayout, keyPos: UInt64, writeKeyPos: Bool = true, context: GKCryptContext = Self.up()) -> [UInt8] {
        var d = bytes
        d.withUnsafeMutableBytes {
            if writeKeyPos { $0.putBE32(UInt32(truncatingIfNeeded: keyPos), at: layout.keyPosOffset) }
            context.seal($0, layout: layout, keyPos: keyPos)
        }
        return d
    }

    // MARK: T1, T2

    @Test func t1Contexts() {
        let up = Self.up()
        let down = Self.down()
        #expect(up.cipherKey == hex("aab471a3cbf72bd3695e3c4685748764"))
        #expect(up.ivBase == hex("5f2c42295c59b08bd8eefe95fc41d933"))
        #expect(down.cipherKey == hex("5bf637e18135678aaf55ecd224d9c9d7"))
        #expect(down.ivBase == hex("31622bc48b544790e3e66edb6f076599"))
        #expect(up.gmacKey0 == hex("efb46f04ea764602469af984592adc01"))
        #expect(down.gmacKey0 == hex("9e49c31e08230d3b4bd82b3a6963990f"))
        func key(_ c: GKCryptContext, _ e: UInt64) -> [UInt8] { GKCryptContext.foldedKey(base: c.gmacKey0, ivBase: c.ivBase, epoch: e) }
        #expect(key(up, 1) == hex("b8495627df0efd22779f5fa8c3d98f29"))
        #expect(key(up, 2) == hex("eb7ea4d9e7354e87ca130c2f55928d09"))
        #expect(key(down, 1) == hex("d40895030660d42bbe9c3f489c077920"))
        #expect(key(down, 2) == hex("dbd050900085554a3aa15100599ce052"))
    }

    @Test func t2CounterAdditionAndKeyStream() {
        let a = GKCryptContext.add(hex("ffff0000000000000000000000000000"), 1)
        #expect(a == hex("00000100000000000000000000000000"))
        #expect(AES128ECB.encryptOne(key: Self.up().cipherKey, block: a) == hex("d4172304946b4cab0ecee0a585b5956b"))
        let b = GKCryptContext.add(hex("ffffffffffffffffffffffffffffffff"), 2)
        #expect(b == hex("01000000000000000000000000000000"))
        #expect(AES128ECB.encryptOne(key: Self.up().cipherKey, block: b) == hex("f2b166b7846bfe1e8fc451254950a08c"))
        let iv = hex("00112233445566778899aabbccddeeff")
        #expect(GKCryptContext.add(iv, 134730) == hex("4a1f2433445566778899aabbccddeeff"))
        #expect(GKCryptContext.foldedKey(base: Self.up().cipherKey, ivBase: iv, epoch: 3) == hex("59bb1f522ab2b2caa1bc95e1853b11c0"))

        func stream(_ position: UInt64, _ count: Int) -> [UInt8] {
            var zeros = [UInt8](repeating: 0, count: count)
            zeros.withUnsafeMutableBytes { Self.down().xorStream($0, atPosition: position) }
            return zeros
        }
        #expect(stream(0, 48) == hex("f0046b4e6e0f41e543bf8c759ff079ed41308fc09ff16035f770303b75470812fff6158a13f9d8ca42ec24ca150012e4"))
        #expect(stream(0x25, 20) == hex("f9d8ca42ec24ca150012e49f391380f024b573fc"))
        #expect(stream((1 << 32) + 0x10, 32) == hex("ea58f2433cb8945a901dba03bc3f2d93107567d40abafba4f6a34931bdf3a5b7"))
        var plain = hex("4e619f945d4b8ebd2a154d036acd49569cc75ce3e700179a38d9695345f90cb58c05650f70")
        plain.withUnsafeMutableBytes { Self.up().xorStream($0, atPosition: 0x11) }
        #expect(plain == hex("055a8c62fae18809b51b7842dd979e4751bc014f81c68cfe0c8b26f911d037124999b3e2a3"))
    }

    // MARK: T3

    @Test func t3HandshakeDatagrams() throws {
        let cookie = TakionVec.cookie
        #expect(TakionWire.initiate(clientTag: 0x1234abcd) == hex("00000000000000000000000000010000141234abcd00019000006400641234abcd"))
        let initAck = hex("001234abcd0000000000000000020000345a5aa5a500019000006400645a5aa5a5c0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf")
        #expect(TakionWire.initAck(clientTag: 0x1234abcd, consoleTag: 0x5a5aa5a5, initialTSN: 0x5a5aa5a5, cookie: cookie) == initAck)
        #expect(TakionWire.cookie(consoleTag: 0x5a5aa5a5, cookie: cookie)
            == hex("005a5aa5a500000000000000000a000024c0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf"))
        #expect(TakionWire.cookieAck(clientTag: 0x1234abcd) == hex("001234abcd00000000000000000b000004"))
        let parsed = try #require(initAck.withUnsafeBytes { TakionInitAck.parse($0, clientTag: 0x1234abcd) })
        #expect(parsed.consoleTag == 0x5a5aa5a5 && parsed.advertisedWindow == 0x19000 && parsed.outboundStreams == 100)
        #expect(parsed.inboundStreams == 100 && parsed.initialTSN == 0x5a5aa5a5 && parsed.cookie == cookie)
    }

    // MARK: T4...T8 through the connection's own senders

    @Test func t4ClientDataChunk() throws {
        let h = MemoryHarness(version: 9)
        try h.handshake()
        h.console.secure()
        h.connection.enableCrypto(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey)
        for _ in 0..<5 { h.connection.sendMessage(channel: 1, [0]) }
        let before = h.transport.sent.count
        h.connection.overrideSendState(keyPos: 0x2a)
        h.connection.sendMessage(channel: 1, [0x08, 0x03])
        #expect(h.transport.sent[before] == hex("005a5aa5a5728e7fd20000002a0001000f1234abd200010000000803"))
        #expect(h.connection.nextKeyPos == 0x2e)
    }

    @Test func t5ClientDataAck() throws {
        let h = MemoryHarness(version: 9)
        try h.handshake()
        h.console.secure()
        h.connection.enableCrypto(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey)
        for tsn in 0..<3 { h.deliver(h.console.dataChunk(tsn: TakionVec.consoleTag + UInt32(tsn), message: [8, 1], keyPos: UInt64(tsn) * 0x10)) }
        h.connection.overrideSendState(keyPos: 0x2e)
        let before = h.transport.sent.count
        h.deliver(h.console.dataChunk(tsn: TakionVec.consoleTag + 3, message: [8, 1], keyPos: 0x40))
        #expect(h.transport.sent[before] == hex("005a5aa5a590cccf3b0000002e030000105a5aa5a80001900000000000"))
        #expect(h.connection.nextKeyPos == 0x58)
    }

    @Test func t6CongestionReport() throws {
        let h = MemoryHarness(version: 9)
        try h.handshake()
        h.connection.enableCrypto(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey)
        let source = FakeCongestionSource()
        source.set(CongestionInputs(videoReceived: 1234, videoLost: 5))
        h.connection.setCongestionSource(source)
        h.connection.overrideSendState(keyPos: 0x58)
        let before = h.transport.sent.count
        h.connection.transportWake(now: takionNow() + 1_000_000_000)
        let report = try #require(h.sent(after: before).first { $0[0] & 0x0f == 5 })
        #expect(report == hex("05000004d20005dc49472400000058"))
        #expect(h.connection.nextKeyPos == 0x76)
    }

    @Test func t7FeedbackState() throws {
        let body9 = hex("a02182aa7aff7f8e821599e07a1e79742d03e8f83080007fff")
        let body12 = hex("a02182aa7aff7f8e821599e07a1e79742d03e8f83080007fff000001")
        for (version, body, packet, next) in [
            (9, body9, "06000700000000763d746d715ea32215af0117aa44ef78a4aee799e0148f16582c24f2259a", UInt64(0xa8)),
            (12, body12, "06000700000000765d5f370b5ea32215af0117aa44ef78a4aee799e0148f16582c24f2259a8db46e", UInt64(0xae)),
        ] {
            let h = MemoryHarness(version: version)
            try h.handshake()
            h.connection.enableCrypto(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey)
            h.connection.overrideSendState(keyPos: 0x76, stateSequence: 7)
            let before = h.transport.sent.count
            #expect(h.connection.sendFeedbackState(body: body))
            #expect(h.transport.sent[before] == hex(packet))
            #expect(h.connection.nextKeyPos == next)
        }
    }

    @Test func t8FeedbackHistory() throws {
        let h = MemoryHarness(version: 12)
        try h.handshake()
        h.connection.enableCrypto(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey)
        h.connection.overrideSendState(keyPos: 0x9a, eventNumber: 0x0101)
        #expect(h.connection.sendFeedbackEvent(hex("d0033e81f4")))
        let before = h.transport.sent.count
        h.connection.overrideSendState(keyPos: 0x9a)
        #expect(h.connection.sendFeedbackEvent(hex("8088ff")))
        #expect(h.transport.sent[before] == hex("010102010000009a129d1363764121db8bb9061b"))
    }

    // MARK: T9...T11 console packets

    @Test func t9ConsoleVideoPacket() throws {
        let h = MemoryHarness(version: 12)
        try h.handshake()
        h.connection.enableCrypto(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey)
        h.deliver(hex("020100002000401c0103fbdbd50000012345036720fe5a29b383a50e557c13daccf19c6bda34c2dd681f3c0de029ad4b4617678e85"))
        // Unit 2 of 8 arrives first at queue start 0x100 - 2: it is held until the earlier units come or time passes.
        h.connection.transportWake(now: takionNow() + 100_000_000)
        let packet = try #require(h.delegate.av.first)
        #expect(packet.header.kind == .video && packet.header.packetIndex == 0x100 && packet.header.frameIndex == 0x20)
        #expect(packet.header.unitIndex == 2 && packet.header.totalUnits == 8 && packet.header.fecUnits == 1)
        #expect(packet.header.codec == 3 && packet.header.field18 == 0x0367 && packet.header.adaptiveStreamIndex == 1)
        #expect(packet.payload == hex("000000016742c01e95a80f0044101112131415161718191a1b1c1d1e1f202122"))
    }

    @Test func t10ConsoleAudioPackets() throws {
        let plain = hex("a0a1a2a3a4a5a6a7a8a9aaab")
        let h12 = MemoryHarness(version: 12)
        try h12.handshake()
        h12.connection.enableCrypto(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey)
        h12.deliver(hex("03000500070002502105f4333d50000020000002744a562bfb539e9d1e2dc630"))
        let haptics = try #require(h12.delegate.av.first)
        #expect(haptics.header.kind == .haptics && haptics.payload == plain && haptics.header.packetIndex == 5)
        #expect(haptics.header.frameIndex == 7 && haptics.header.unitIndex == 0 && haptics.header.totalUnits == 3)
        #expect(haptics.header.unitSize == 0x50 && haptics.header.fecUnits == 2 && haptics.header.sourceUnits == 1 && haptics.header.codec == 5)

        let h9 = MemoryHarness(version: 9)
        try h9.handshake()
        h9.connection.enableCrypto(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey)
        h9.deliver(hex("03000600080102502105c15fd70200002040000825619230ae3aa40edaae85"))
        let audio = try #require(h9.delegate.av.first)
        #expect(audio.header.kind == .audio && audio.payload == plain && audio.header.packetIndex == 6)
        #expect(audio.header.frameIndex == 8 && audio.header.unitIndex == 1 && audio.header.totalUnits == 3)
    }

    @Test func t11ConsoleDataChunk() throws {
        let h = MemoryHarness(version: 12)
        try h.handshake()
        h.connection.enableCrypto(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey)
        h.deliver(hex("001234abcdf2a6d179000000400001000f5a5aa5a500010000000801"))
        #expect(h.delegate.messages == [RecordingDelegate.Message(channel: 1, dataType: 0, bytes: [8, 1])])
    }

    // MARK: T12

    @Test func t12KeyPosReconstruction() {
        let cases: [(UInt64, UInt32, UInt64)] = [
            (0, 0x10, 0x10),
            (0xffff_fff0, 0x20, 0x1_0000_0020),
            (0x1_0000_0020, 0xffff_fff0, 0x0_ffff_fff0),
            (0x1_0000_0020, 0x8000_0020, 0x1_8000_0020),
            (0, 0xffff_fff0, 0xffff_fff0),
            (0x2_ffff_fff0, 0x40, 0x3_0000_0040),
        ]
        for (reference, low, expected) in cases { #expect(reconstructKeyPos(low: low, reference: reference) == expected) }
    }

    // MARK: T13 (the probe's datagram), T14

    @Test func t13ProbePing() {
        let ping = TakionProbe.ping(unit: 3, tag: 0xdeadbeef)
        #expect(ping.count == 548)
        #expect(Array(ping.prefix(26)) == hex("0300000000007ffc00ff000000000000000000000000deadbeef"))
        #expect(ping.dropFirst(26).allSatisfy { $0 == 0 })
    }

    @Test func t14GMACEpochs() {
        let cases: [(UInt64, String)] = [
            (45000, "05000004d2000550384da60000afc8"),
            (45001, "05000004d20005866990210000afc9"),
            (90001, "05000004d20005dc38665100015f91"),
            ((1 << 32) + 0x420, "05000004d200056449814600000420"),
        ]
        for (keyPos, expected) in cases {
            #expect(seal(TakionWire.congestion(received: 1234, lost: 5), layout: .congestion, keyPos: keyPos) == hex(expected))
        }
        #expect(GKCryptContext.epoch(of: (1 << 32) + 0x420) == 95443)
    }

    // MARK: T15

    @Test func t15EstimatorTrace() {
        var e = ReorderEstimator()
        e.holeFilled(lateness: 7000)
        #expect(e.wait == 20000)
        e.holeFilled(lateness: 7000)
        #expect(e.wait == 19000)
        e.holeFilled(lateness: 9000)
        #expect(e.wait == 18050)
        e.holeSkipped(begin: 100, count: 3, waitStart: 1_000_000, now: 1_010_000, queueFull: false)
        #expect(e.wait == 18050)
        let late = e.packetBeforeStart(101, now: 1_012_000)
        #expect(late)
        #expect(e.wait == 19999)
        let again = e.packetBeforeStart(101, now: 1_012_500)
        #expect(!again)
        e.holeSkipped(begin: 200, count: 2, waitStart: 1_100_000, now: 1_115_000, queueFull: false)
        e.expire(now: 1_215_000)
        #expect(e.wait == 19999)
        #expect(e.latePackets == 1 && e.holesLost == 1)
        e.holeSkipped(begin: 300, count: 300, waitStart: 1_300_000, now: 1_301_000, queueFull: true)
        let notKept = e.packetBeforeStart(300, now: 1_302_000)
        let kept = e.packetBeforeStart(344, now: 1_302_000)
        #expect(!notKept && kept)
        #expect(e.wait == 20000)
    }

    // MARK: T16

    @Test func t16CongestionNumbers() {
        // a: video 500 / 3 lost; 45 audio packets, highest frame 0x0005, previous interval's 0xffd0 (d = 53).
        var a = CongestionReporter(previousAudioPackets: 0, previousHighest: 0xffd0)
        let ra = a.report(CongestionInputs(videoReceived: 500, videoLost: 3, audioPacketsReceived: 45, audioHighestFrameIndex: 5), maxLoss: 0.05)
        #expect(ra.received == 545 && ra.lost == 11)
        // b: video 100 / 40, 10 audio packets, frames 1...10, previous 0: clamped to 5 % of 150.
        var b = CongestionReporter()
        let rb = b.report(CongestionInputs(videoReceived: 100, videoLost: 40, audioPacketsReceived: 10, audioHighestFrameIndex: 10), maxLoss: 0.05)
        #expect(rb.received == 143 && rb.lost == 7)
        // c: no video, 12 audio packets with duplicates, highest 10: never negative.
        var c = CongestionReporter()
        let rc = c.report(CongestionInputs(audioPacketsReceived: 12, audioHighestFrameIndex: 10), maxLoss: 0.05)
        #expect(rc.received == 12 && rc.lost == 0)
    }

    @Test func congestionAudioArithmeticAcrossIntervals() {
        var r = CongestionReporter()
        // Interval 1: 10 packets, frames up to 10. Interval 2 (cumulative 18 packets): 8 new, highest 20: 2 lost.
        _ = r.report(CongestionInputs(audioPacketsReceived: 10, audioHighestFrameIndex: 10), maxLoss: 1)
        let second = r.report(CongestionInputs(audioPacketsReceived: 18, audioHighestFrameIndex: 20), maxLoss: 1)
        #expect(second.received == 8 && second.lost == 2)
        // Wrap of the 16-bit index: from 20 to 5 is 65521 frames: lost is truncated to 16 bits, never negative.
        let wrap = r.report(CongestionInputs(audioPacketsReceived: 19, audioHighestFrameIndex: 0xfff0), maxLoss: 1)
        #expect(wrap.received == 1 && wrap.lost == UInt16(truncatingIfNeeded: 0xffdc - 1))
        // A counter that went backwards (the AV layer restarted) counts as zero packets, not a huge number.
        let reset = r.report(CongestionInputs(audioPacketsReceived: 0, audioHighestFrameIndex: 0xfff0), maxLoss: 1)
        #expect(reset.received == 0 && reset.lost == 0)
        // The ceiling leaves small losses alone and a zero total alone.
        var clamp = CongestionReporter()
        let none = clamp.report(CongestionInputs(), maxLoss: 0.05)
        #expect(none.received == 0 && none.lost == 0)
        let small = clamp.report(CongestionInputs(videoReceived: 99, videoLost: 1), maxLoss: 0.05)
        #expect(small.received == 99 && small.lost == 1)
    }
}
