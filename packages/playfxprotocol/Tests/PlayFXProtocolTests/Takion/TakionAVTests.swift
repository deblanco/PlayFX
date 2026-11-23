import Foundation
import Testing

@testable import PlayFXProtocol

let ms: UInt64 = 1_000_000

extension MemoryHarness {
    /// Handshake done, keys on both sides.
    static func secured(version: Int = 12, tweak: (inout TakionConfiguration) -> Void = { _ in }) throws -> MemoryHarness {
        let h = MemoryHarness(version: version, tweak: tweak)
        try h.handshake()
        h.console.secure()
        h.connection.enableCrypto(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey)
        return h
    }

    var videoIndices: [UInt16] { delegate.av.filter { $0.header.isVideo }.map(\.header.packetIndex) }
}

/// AV packets, the reorder policy, the congestion reporter, feedback and microphone senders, the probe.
@Suite struct TakionAVTests {
    // MARK: Basics

    @Test func inOrderVideoIsDecryptedAndDeliveredWithItsTimestamp() throws {
        let h = try MemoryHarness.secured()
        let base = takionNow()
        for i in 0..<200 { h.deliver(h.console.video(index: UInt16(i), frame: UInt16(i / 4), unit: i % 4, total: 4), at: base + UInt64(i) * ms) }
        #expect(h.videoIndices == (0..<200).map { UInt16($0) })
        let first = try #require(h.delegate.av.first)
        #expect(first.payload == [0, 0, 0xaa, 0xbb, 0xcc])
        #expect(first.receivedAt == base)
        #expect(h.connection.stats.reorder.delivered == 200)
        #expect(h.connection.stats.videoPackets == 200)
    }

    @Test func audioAndHapticsAreNotReordered() throws {
        let h = try MemoryHarness.secured()
        let word: UInt32 = 0x0002_5021
        for (n, index) in [UInt16(9), 3, 7].enumerated() {
            h.deliver(h.console.av(video: false, packetIndex: index, frameIndex: index + 1, word: word, codec: 5,
                                   stream: n == 1 ? 2 : 0, payload: [UInt8(n)]))
        }
        #expect(h.delegate.av.map(\.header.packetIndex) == [9, 3, 7])
        #expect(h.delegate.av.map(\.header.kind) == [.audio, .haptics, .audio])
        #expect(h.delegate.av.map(\.payload) == [[0], [1], [2]])
        #expect(h.connection.stats.audioPackets == 3)
    }

    @Test func extensionFlagShiftsThePayload() throws {
        let v12 = try MemoryHarness.secured(version: 12)
        v12.deliver(v12.console.av(video: true, packetIndex: 0, frameIndex: 0, word: 0, ext: true, payload: [1, 2, 3, 4, 5, 6]))
        v12.deliver(v12.console.av(video: false, packetIndex: 1, frameIndex: 0, word: 0x0002_5021, codec: 5, ext: true, payload: [7, 8, 9]))
        #expect(v12.delegate.av.map(\.payload) == [[1, 2, 3, 4, 5, 6], [7, 8, 9]])
        let v9 = try MemoryHarness.secured(version: 9)
        v9.deliver(v9.console.av(video: false, version: 9, packetIndex: 1, frameIndex: 0, word: 0x0002_5021, codec: 5, ext: true, payload: [7, 8, 9]))
        v9.deliver(v9.console.av(video: false, version: 9, packetIndex: 2, frameIndex: 0, word: 0x0002_5021, codec: 5, payload: [4, 5]))
        #expect(v9.delegate.av.map(\.payload) == [[7, 8, 9], [4, 5]])
        #expect(v9.delegate.av.first?.header.extensionFlag == true)
    }

    @Test func videoVersion9UsesTheSameHeader() throws {
        let h = try MemoryHarness.secured(version: 9)
        h.deliver(h.console.video(index: 0, version: 9))
        #expect(h.delegate.av.count == 1)
    }

    @Test func badGMACAndTruncationAreDropped() throws {
        let h = try MemoryHarness.secured()
        h.deliver(h.console.av(video: true, packetIndex: 0, frameIndex: 0, word: 0, payload: [1, 2, 3, 4], goodGMAC: false))
        #expect(h.connection.stats.droppedBadGMAC == 1)
        let good = h.console.video(index: 0)
        for length in 0..<good.count where length < 25 {
            h.deliver(Array(good.prefix(length)))
        }
        #expect(h.delegate.av.isEmpty)
        // The truncated packets above fail the GMAC (or are too short to carry one).
        let stats = h.connection.stats
        #expect(stats.droppedTruncated + stats.droppedBadGMAC == 26)
        h.deliver(good)
        #expect(h.delegate.av.count == 1)
    }

    @Test func authenticPacketsThatAreTooShortAreDropped() throws {
        // Valid GMAC over a datagram that is too short for its header.
        let h = try MemoryHarness.secured()
        let down = RefCrypto(index: 3)
        var short: [UInt8] = [0x02, 0, 0, 0, 0, 0, 0, 0, 0, 3] + [0, 0, 0, 0] + be32(0x30) + [0x03, 0x67, 0x20]
        short = down.sealed(short, gmacAt: 10, keyPosAt: 14, zeroKeyPos: false, keyPos: 0x30)
        #expect(short.count == 21)
        h.deliver(short)
        #expect(h.connection.stats.droppedTruncated == 1)
        #expect(h.delegate.av.isEmpty)
    }

    @Test func badGMACDoesNotMoveTheKeyPositionReference() throws {
        let h = try MemoryHarness.secured()
        h.deliver(h.console.av(video: true, packetIndex: 0, frameIndex: 0, word: 0, payload: [1, 2, 3, 4], keyPos: 0x6000_0000, goodGMAC: false))
        h.deliver(h.console.video(index: 0))
        #expect(h.videoIndices == [0])
    }

    @Test func packetsBeforeTheKeysAreHeldThenChecked() throws {
        let h = MemoryHarness()
        try h.handshake()
        h.console.secure()
        // 34 secured packets arrive before the connection has keys: 32 are held.
        var packets: [[UInt8]] = []
        for i in 0..<34 { packets.append(h.console.video(index: UInt16(i), frame: UInt16(i), payload: [UInt8(i), 1, 2, 3, 4])) }
        var spoiled = h.console.video(index: 100, frame: 100)
        spoiled[10] ^= 0xff
        for p in packets.prefix(5) { h.deliver(p) }
        h.deliver(spoiled)
        for p in packets.dropFirst(5) { h.deliver(p) }
        let stats = h.connection.stats
        #expect(stats.avHeld == 32 && stats.avHeldOverflow == 3)
        #expect(h.delegate.av.isEmpty)
        h.connection.enableCrypto(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey)
        h.deliver(h.console.video(index: 34, frame: 34))
        // The first five, then up to 36 of the rest minus the spoiled one: the held ones come out in arrival order.
        let got = h.videoIndices
        #expect(got == (0...30).map { UInt16($0) })
        #expect(h.connection.stats.droppedBadGMAC == 1)
    }

    @Test func aPayloadBiggerThanASlotIsDroppedByTheQueue() {
        let queue = VideoReorderQueue()
        var big = [UInt8](repeating: 1, count: 3000)
        let header = TakionAVHeader(kind: .video, packetIndex: 2, frameIndex: 0, unitIndex: 0, totalUnits: 1, fecUnits: 0,
                                    sourceUnits: 0, unitSize: 0, codec: 0, field18: 0, adaptiveStreamIndex: 0,
                                    extensionFlag: false, keyPosLow: 0)
        var delivered = 0
        var first = header
        first.packetIndex = 0
        var small = [UInt8](repeating: 1, count: 10)
        small.withUnsafeMutableBytes { queue.insert(first, payload: $0, at: 1_000_000, deliver: { _, _, _ in delivered += 1 }) }
        #expect(delivered == 1)
        big.withUnsafeMutableBytes { queue.insert(header, payload: $0, at: 1_000_000, deliver: { _, _, _ in delivered += 1 }) }
        #expect(delivered == 1 && queue.stats.dropped == 1)
    }

    // MARK: Reorder policy (12.2)

    @Test func aHoleThatFillsInTimeIsDeliveredInOrder() throws {
        let h = try MemoryHarness.secured()
        let t = takionNow()
        for (i, at) in [(0, 0), (1, 1), (3, 2)] { h.deliver(h.console.video(index: UInt16(i)), at: t + UInt64(at) * ms) }
        #expect(h.videoIndices == [0, 1])
        #expect((h.connection.transportNextWake() ?? 0) >= t + 2 * ms + 16 * ms)
        h.deliver(h.console.video(index: 2), at: t + 7 * ms)
        #expect(h.videoIndices == [0, 1, 2, 3])
        let r = h.connection.stats.reorder
        #expect(r.holesFilled == 1 && r.timeoutSkips == 0)
        // First sample 5000 µs: floor at 95 % of 16000 beats the target of 15000.
        #expect(r.waitMicros == 15200)
    }

    @Test func aHoleIsSkippedWhenTheWaitRunsOutAndLatePacketsFeedTheEstimator() throws {
        let h = try MemoryHarness.secured()
        let t = takionNow()
        for (i, at) in [(0, 0), (1, 1), (3, 2)] { h.deliver(h.console.video(index: UInt16(i)), at: t + UInt64(at) * ms) }
        h.connection.transportWake(now: t + 10 * ms)
        #expect(h.videoIndices == [0, 1])
        h.connection.transportWake(now: t + 20 * ms)
        #expect(h.videoIndices == [0, 1, 3])
        #expect(h.connection.stats.reorder.timeoutSkips == 1)
        #expect(h.connection.transportNextWake().map { $0 > t + 20 * ms } ?? true)
        // Packet 2 shows up 25 ms after the wait started at t+2ms: late, dropped, and the wait grows.
        h.deliver(h.console.video(index: 2), at: t + 27 * ms)
        #expect(h.videoIndices == [0, 1, 3])
        let r = h.connection.stats.reorder
        #expect(r.latePackets == 1 && r.waitMicros == 20000)
        h.deliver(h.console.video(index: 2), at: t + 28 * ms)
        #expect(h.connection.stats.reorder.latePackets == 1)
    }

    @Test func aRunOfMissingPacketsPaysOneWait() throws {
        let h = try MemoryHarness.secured()
        let t = takionNow()
        h.deliver(h.console.video(index: 0), at: t)
        h.deliver(h.console.video(index: 5), at: t + ms)       // 1...4 missing: one run
        h.connection.transportWake(now: t + 30 * ms)
        #expect(h.videoIndices == [0, 5])
        #expect(h.connection.stats.reorder.timeoutSkips == 1)
        // Two separate holes each wait on their own, one after the other.
        h.deliver(h.console.video(index: 7), at: t + 31 * ms)  // 6 missing
        h.deliver(h.console.video(index: 9), at: t + 31 * ms)  // 8 missing
        h.connection.transportWake(now: t + 60 * ms)
        #expect(h.videoIndices == [0, 5, 7])
        h.connection.transportWake(now: t + 90 * ms)
        #expect(h.videoIndices == [0, 5, 7, 9])
        #expect(h.connection.stats.reorder.timeoutSkips == 3)
    }

    @Test func aFullQueueSkipsTheHoleButKeepsPackets() throws {
        let h = try MemoryHarness.secured()
        let t = takionNow()
        h.deliver(h.console.video(index: 0), at: t)
        for i in 2...300 { h.deliver(h.console.video(index: UInt16(i)), at: t + ms) }
        // Packet 256 needs room: hole 1 is skipped, and everything behind it is delivered, none thrown away.
        let got = h.videoIndices
        #expect(got.first == 0)
        #expect(got.dropFirst().first == 2)
        #expect(got.count == 300)
        #expect(got == [0] + (2...300).map { UInt16($0) })
        #expect(h.connection.stats.reorder.queueFullSkips == 1)
    }

    @Test func duplicatesAndAncientPacketsAreDropped() throws {
        let h = try MemoryHarness.secured()
        let t = takionNow()
        h.deliver(h.console.video(index: 0), at: t)
        h.deliver(h.console.video(index: 2), at: t)
        h.deliver(h.console.video(index: 2), at: t)
        #expect(h.connection.stats.reorder.duplicates == 1)
        h.deliver(h.console.video(index: 0), at: t)
        #expect(h.connection.stats.reorder.dropped == 1)
        #expect(h.videoIndices == [0])
    }

    @Test func theQueueStartsAtTheFramesFirstUnit() throws {
        let h = try MemoryHarness.secured()
        let t = takionNow()
        // The first packet seen is unit 3 of its frame (index 13): units 0 to 2 (10, 11, 12) are waited for.
        h.deliver(h.console.video(index: 13, unit: 3, total: 6), at: t)
        h.deliver(h.console.video(index: 10, unit: 0, total: 6), at: t + ms)
        #expect(h.videoIndices == [10])
        h.deliver(h.console.video(index: 12, unit: 2, total: 6), at: t + 2 * ms)
        h.deliver(h.console.video(index: 11, unit: 1, total: 6), at: t + 3 * ms)
        #expect(h.videoIndices == [10, 11, 12, 13])
    }

    @Test func indicesWrapAt16Bits() throws {
        let h = try MemoryHarness.secured()
        let t = takionNow()
        for i in [0xfffd, 0xfffe, 0, 0xffff, 1, 2] { h.deliver(h.console.video(index: UInt16(i)), at: t) }
        #expect(h.videoIndices == [0xfffd, 0xfffe, 0xffff, 0, 1, 2])
    }

    @Test func aFarJumpOnAnEmptyQueueSkipsTheGap() throws {
        let h = try MemoryHarness.secured()
        let t = takionNow()
        for i in 0..<3 { h.deliver(h.console.video(index: UInt16(i)), at: t) }
        h.deliver(h.console.video(index: 1000), at: t + ms)
        #expect(h.videoIndices == [0, 1, 2, 1000])
        #expect(h.connection.stats.reorder.queueFullSkips == 1)
        // A packet of the skipped gap that shows up later is late.
        h.deliver(h.console.video(index: 900), at: t + 5 * ms)
        #expect(h.connection.stats.reorder.latePackets == 1)
    }

    @Test func halfTheSequenceSpaceAwayIsAmbiguous() throws {
        let h = try MemoryHarness.secured()
        let t = takionNow()
        h.deliver(h.console.video(index: 0), at: t)
        // Empty queue: restarts at that packet.
        h.deliver(h.console.video(index: 0x8001), at: t)
        #expect(h.videoIndices == [0, 0x8001])
        // Non-empty queue: the ambiguous packet is dropped.
        h.deliver(h.console.video(index: 0x8003), at: t)
        h.deliver(h.console.video(index: 0x8003 &+ 0x8000), at: t)
        #expect(h.videoIndices == [0, 0x8001])
        #expect(h.connection.stats.reorder.dropped == 1)
    }

    @Test func wakeWithNothingWaitingDoesNothing() throws {
        let h = try MemoryHarness.secured()
        h.connection.transportWake(now: takionNow() + 1_000 * ms)
        #expect(h.delegate.av.isEmpty)
    }

    // MARK: Congestion report (8)

    func report(_ h: MemoryHarness) throws -> (received: UInt16, lost: UInt16, packet: ClientPacket) {
        h.clock += 400 * ms
        h.connection.transportWake(now: takionNow() + h.clock)
        h.pump()
        let p = try #require(h.console.packets(ofType: 5).last)
        return (readBE16(p.bytes, 3), readBE16(p.bytes, 5), p)
    }

    @Test func congestionReportsTakeTheirNumbersFromTheSource() throws {
        let h = try MemoryHarness.secured { $0.maxLoss = 0.5 }
        let source = FakeCongestionSource()
        h.connection.setCongestionSource(source)
        source.set(CongestionInputs(videoReceived: 7, videoLost: 1, audioPacketsReceived: 10, audioHighestFrameIndex: 10))
        let r = try report(h)
        #expect(r.packet.gmacOK == true && r.packet.bytes.count == 15)
        #expect(r.received == 17 && r.lost == 1)
        #expect(source.calls == 1)
        // The packets the connection delivered are not counted by Takion itself.
        for u in 0..<4 { h.deliver(h.console.video(index: UInt16(u), frame: 1, unit: u, total: 4), at: takionNow()) }
        h.deliver(h.console.av(video: false, packetIndex: 1, frameIndex: 1, word: 0x0002_5021, codec: 5, stream: 2, payload: [1]))
        let second = try report(h)
        #expect(second.received == 0 && second.lost == 0)
    }

    @Test func congestionIsClampedByMaxLoss() throws {
        let h = try MemoryHarness.secured()
        let source = FakeCongestionSource()
        h.connection.setCongestionSource(source)
        source.set(CongestionInputs(videoReceived: 50, videoLost: 50))
        let r = try report(h)
        #expect(r.received == 95 && r.lost == 5)
    }

    @Test func withoutASourceTheReportIsEmpty() throws {
        let h = try MemoryHarness.secured()
        let r = try report(h)
        #expect(r.received == 0 && r.lost == 0)
    }

    @Test func congestionReportsGoOutEvery200msFromTheStartEvenUnsecured() throws {
        let h = MemoryHarness()
        try h.connection.connect()
        let t = takionNow()
        h.connection.transportWake(now: t + 100 * ms)
        #expect(h.transport.sent.filter { $0[0] == 5 }.isEmpty)
        h.connection.transportWake(now: t + 250 * ms)
        let reports = h.transport.sent.filter { $0[0] == 5 }
        #expect(reports.count == 1)
        #expect(reports.first?.count == 15 && Array(reports[0][7..<15]) == [UInt8](repeating: 0, count: 8))
        h.connection.transportWake(now: t + 300 * ms)
        #expect(h.transport.sent.filter { $0[0] == 5 }.count == 1)
        h.connection.transportWake(now: t + 500 * ms)
        #expect(h.transport.sent.filter { $0[0] == 5 }.count == 2)
        #expect(h.connection.stats.congestionReports == 2)
    }

    // MARK: Feedback (9)

    @Test func feedbackStateIsSequencedEncryptedAndRepeated() throws {
        let h = try MemoryHarness.secured(version: 12)
        let body1 = (0..<28).map { UInt8($0) }
        let body2 = (0..<28).map { UInt8(100 + $0) }
        #expect(h.connection.sendFeedbackState(body: body1))
        #expect(!h.connection.sendFeedbackState(body: [1, 2, 3]))
        #expect(h.connection.sendFeedbackState(body: body2))
        let t = takionNow()
        h.connection.transportWake(now: t + 250 * ms)       // 200 ms with no change: the latest state again
        h.pump()
        let states = h.console.packets(ofType: 6)
        #expect(states.count == 3)
        #expect(states.map { readBE16($0.bytes, 1) } == [0, 1, 2])
        #expect(states.map(\.body) == [body1, body2, body2])
        #expect(states.allSatisfy { $0.gmacOK == true && $0.bytes[3] == 0 && $0.bytes.count == 40 })
        let step = keyPosAdvance(44)
        #expect(states.map(\.keyPos) == [0, step, 2 * step])
    }

    @Test func feedbackStateNeedsTheKeysAndTheRightSize() throws {
        let h = MemoryHarness(version: 9)
        try h.handshake()
        #expect(!h.connection.sendFeedbackState(body: [UInt8](repeating: 0, count: 25)))
        h.connection.enableCrypto(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey)
        #expect(!h.connection.sendFeedbackState(body: [UInt8](repeating: 0, count: 28)))
        #expect(h.connection.sendFeedbackState(body: [UInt8](repeating: 0, count: 25)))
        #expect(!h.connection.sendFeedbackEvent([]))
    }

    @Test func feedbackHistoryNumbersEventsAndRepeatsTheLastPacket() throws {
        let h = try MemoryHarness.secured(version: 12)
        let events: [[UInt8]] = [[0x80, 0x88, 0xff], [0x80, 0xac], [0xd0, 3, 0x3e, 0x81, 0xf4]]
        let t = takionNow()
        for e in events { #expect(h.connection.sendFeedbackEvent(e)) }
        h.pump()
        var history = h.console.packets(ofType: 1)
        #expect(history.count == 3)
        #expect(history.map { readBE16($0.bytes, 1) } == [0, 1, 2])
        #expect(history.map { $0.bytes[3] } == [0, 1, 2])
        #expect(history[0].body == events[0])
        #expect(history[1].body == events[1] + events[0])
        #expect(history[2].body == events[2] + events[1] + events[0])
        #expect(history.allSatisfy { $0.gmacOK == true })
        // Repeats of the last packet at 20, 50, 100 and 200 ms after it was first sent: unchanged apart from keyPos and GMAC.
        for offset in [10, 25, 60, 110, 250, 400] { h.connection.transportWake(now: t + UInt64(offset) * ms) }
        h.pump()
        history = h.console.packets(ofType: 1)
        #expect(history.count == 3 + 4)
        for repeated in history.dropFirst(3) {
            #expect(repeated.bytes[0..<4] == history[2].bytes[0..<4])
            #expect(repeated.body == history[2].body)
            #expect(repeated.gmacOK == true)
        }
        #expect(Set(history.map(\.keyPos)).count == 7)
        // A new event cancels the remaining repeats of the previous one.
        #expect(h.connection.sendFeedbackEvent([0x80, 0x8c]))
        let count = h.transport.sent.count
        h.connection.transportWake(now: takionNow() + 5 * ms)
        #expect(h.transport.sent.count == count)
    }

    @Test func historyKeepsAtMostNineEvents() throws {
        let h = try MemoryHarness.secured()
        for i in 0..<12 { h.connection.sendFeedbackEvent([0x80, UInt8(0x90 + i)]) }
        h.pump()
        let last = try #require(h.console.packets(ofType: 1).last)
        #expect(last.bytes[3] == 8)
        #expect(last.body.count == 18)
        #expect(Array(last.body.prefix(2)) == [0x80, 0x9b])
        #expect(readBE16(last.bytes, 1) == 11)
    }

    @Test func microphonePacketsAreEncryptedAndSealed() throws {
        for version in [9, 12] {
            let h = try MemoryHarness.secured(version: version)
            let payload = (0..<120).map { UInt8($0) }
            #expect(h.connection.sendMicrophone(packetIndex: 65535, payload: payload))
            h.pump()
            let p = try #require(h.console.packets(ofType: 3).first)
            let at = version == 12 ? 20 : 19
            #expect(p.bytes.count == at + 120)
            #expect(Array(p.bytes[0..<10]) == [0x03, 0xff, 0xff, 0x00, 0x00, 0x00, 0x02, 0x28, 0x21, 0x05])
            #expect(p.gmacOK == true && p.keyPos == 0)
            #expect(RefCrypto(index: 2).crypt(Array(p.bytes[at...]), keyPos: 0) == payload)
            #expect(h.connection.nextKeyPos == keyPosAdvance(136))
        }
        let unsecured = MemoryHarness()
        #expect(!unsecured.connection.sendMicrophone(packetIndex: 0, payload: [1]))
    }

    // MARK: Probe (version 7)

    @Test func theProbeConnectionPassesPacketsUpWithoutCryptoOrCongestion() throws {
        let h = MemoryHarness(version: 7) { $0.handshakeTimeout = 30 }
        try h.handshake()
        let tag: UInt32 = 0xdeadbeef
        // A pong: audio-type packet, version-7 layout (video unit word), data after 18 bytes.
        var pong = [UInt8](repeating: 0, count: 18) + [0, 0, 0, 0] + be32(tag) + [0, 0]
        pong[0] = 0x03
        pong.replaceSubrange(5..<9, with: be32(UInt32(3) << 21))
        h.deliver(pong)
        let got = try #require(h.delegate.av.first)
        #expect(got.header.kind == .audio && got.header.unitIndex == 3 && got.header.frameIndex == 0)
        #expect(got.payload.count == 10)
        #expect(pong.withUnsafeBytes { TakionProbe.isPong($0, unit: 3, tag: tag) })
        #expect(!pong.withUnsafeBytes { TakionProbe.isPong($0, unit: 4, tag: tag) })
        #expect(!pong.withUnsafeBytes { TakionProbe.isPong($0, unit: 3, tag: tag + 1) })
        // A video-type packet with payload at 21 (MTU test).
        var video = [UInt8](repeating: 0, count: 30)
        video[0] = 0x02
        video.replaceSubrange(3..<5, with: [0, 7])
        h.deliver(video)
        #expect(h.delegate.av.last?.header.frameIndex == 7 && h.delegate.av.last?.header.isVideo == true)
        #expect(h.delegate.av.last?.payload.count == 9)
        h.connection.transportWake(now: takionNow() + 1_000 * ms)
        #expect(h.transport.sent.filter { $0[0] == 5 }.isEmpty)
        #expect(h.connection.sendRaw(TakionProbe.ping(unit: 0, tag: 1)))
        #expect(h.transport.sent.last?.count == 548)
        #expect(h.connection.stats.audioPackets == 1 && h.connection.stats.videoPackets == 1)
    }

    @Test func pongMatchingHandlesExtensionAndShortPackets() {
        let tag: UInt32 = 0x01020304
        var d = [UInt8](repeating: 0, count: 21) + [0, 0, 0, 0] + be32(tag)
        d[0] = 0x13
        d.replaceSubrange(5..<9, with: be32(UInt32(9) << 21))
        #expect(d.withUnsafeBytes { TakionProbe.isPong($0, unit: 9, tag: tag) })
        #expect(!Array(d.prefix(20)).withUnsafeBytes { TakionProbe.isPong($0, unit: 9, tag: tag) })
        d[0] = 0x12
        #expect(!d.withUnsafeBytes { TakionProbe.isPong($0, unit: 9, tag: tag) })
        #expect(TakionProbe.ping(unit: 2, tag: 7, size: 100).count == 100)
        #expect(TakionProbe.ping(unit: 2, tag: 7, size: 5).count == 26)
    }
}
