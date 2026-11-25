import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

/// A small deterministic generator, so a failure can be replayed.
struct LCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state ^ (state >> 29)
    }
}

/// Truncated, corrupted and absurd input must never trap, and must not get through.
@Suite struct TakionHostileTests {
    /// One valid packet of every kind the client can receive or is able to parse, for a connected, secured client.
    func samples(_ console: FakeTakionConsole) -> [[UInt8]] {
        [
            console.initAck(), console.cookieAck(),
            console.dataChunk(message: [1, 2, 3], keyPos: 0x40), console.dataChunk(dataType: nil, flags: 0, message: [1, 2], keyPos: 0x80),
            console.dataAck(cumulative: TakionVec.clientTag, keyPos: 0xc0),
            console.dataAck(cumulative: TakionVec.clientTag, gaps: [(1, 2), (3, 4)], keyPos: 0x100),
            console.video(index: 0, payload: [1, 2, 3, 4, 5]), console.video(index: 1, payload: [1, 2, 3, 4], version: 9),
            console.av(video: false, packetIndex: 3, frameIndex: 3, word: 0x0002_5021, codec: 5, stream: 2, payload: [1, 2, 3]),
            console.av(video: false, version: 9, packetIndex: 4, frameIndex: 4, word: 0x0002_5021, codec: 5, payload: [1, 2, 3]),
            console.av(video: true, packetIndex: 5, frameIndex: 5, word: 0, ext: true, payload: [1, 2, 3, 4, 5]),
            TakionWire.congestion(received: 1, lost: 2), [0x06, 0, 1, 0] + [UInt8](repeating: 0, count: 20),
        ]
    }

    func connected(secured: Bool, version: Int = 12) throws -> MemoryHarness {
        let h = MemoryHarness(version: version)
        try h.handshake()
        if secured {
            h.console.secure()
            h.connection.enableCrypto(ecdhSecret: TakionVec.secret, handshakeKey: TakionVec.handshakeKey)
        }
        return h
    }

    @Test(arguments: [(false, 12), (true, 12), (true, 9), (true, 7)])
    func everyTruncationOfEveryPacketIsDropped(secured: Bool, version: Int) throws {
        let h = try connected(secured: secured, version: version)
        let packets = samples(h.console)
        for p in packets {
            for length in 0..<min(p.count, 48) { h.deliver(Array(p.prefix(length))) }
        }
        #expect(h.connection.isConnected || !secured)
        // Nothing that was cut short produced a message or a video packet.
        #expect(h.delegate.messages.isEmpty)
        // The probe (version 7) has no GMAC: a video packet cut after its header is still a packet there.
        if version != 7 { #expect(h.delegate.av.filter { $0.header.isVideo }.isEmpty) }
    }

    @Test func everySingleByteCorruptionOfASecuredPacketFailsTheGMAC() throws {
        let h = try connected(secured: true)
        let valid = [
            h.console.dataChunk(message: [1, 2, 3], keyPos: 0x40),
            h.console.video(index: 0, payload: [1, 2, 3, 4, 5]),
            h.console.av(video: false, packetIndex: 3, frameIndex: 3, word: 0x0002_5021, codec: 5, stream: 2, payload: [1, 2, 3]),
        ]
        for p in valid {
            for at in 0..<p.count {
                // A control packet's `keyPos` field (bytes 9...12) is zeroed for its GMAC and only `keyPos / 16` and
                // the epoch matter, so a flip of its low bits is not detectable (and harmless).
                if p[0] & 0x0f == 0 && (9..<13).contains(at) { continue }
                var bad = p
                bad[at] ^= 0x01
                h.deliver(bad)
            }
        }
        // The only packets that may get through are those whose flipped bit the GMAC doesn't cover (none: it covers
        // everything but its own 4 bytes, and a flipped GMAC bit mismatches too), or that were dropped earlier.
        #expect(h.delegate.messages.isEmpty)
        #expect(h.delegate.av.isEmpty)
        #expect(h.connection.stats.droppedBadGMAC > 50)
        // And the real ones still work afterwards.
        h.deliver(valid[0])
        h.deliver(valid[1])
        #expect(h.delegate.messages.count == 1 && h.delegate.av.count == 1)
    }

    @Test func randomDatagramsNeverTrap() throws {
        var rng = LCG(state: 42)
        for secured in [false, true] {
            let h = try connected(secured: secured)
            let count = secured ? 150 : 5000
            for _ in 0..<count {
                let length = Int.random(in: 0...(secured ? 400 : 2048), using: &rng)
                var d = (0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) }
                if !d.isEmpty && Bool.random(using: &rng) { d[0] = UInt8.random(in: 0...6, using: &rng) }
                h.deliver(d)
            }
            #expect(h.delegate.messages.isEmpty && h.delegate.av.isEmpty)
        }
    }

    @Test func randomDatagramsAtTheHandshakeNeverTrap() throws {
        var rng = LCG(state: 7)
        let h = MemoryHarness()
        try h.connection.connect()
        let template = h.console.initAck()
        for _ in 0..<3000 {
            var d = template
            for _ in 0..<Int.random(in: 1...4, using: &rng) { d[Int.random(in: 0..<d.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            if Bool.random(using: &rng) { d.removeLast(Int.random(in: 0..<d.count, using: &rng)) }
            h.deliver(d)
            if h.delegate.connected { break }
        }
        // Whatever happened, the connection is in a sane state and a good INIT_ACK still works or already did.
        h.deliver(h.console.initAck())
        h.deliver(h.console.cookieAck())
        #expect(h.delegate.connected)
    }

    @Test func absurdLengthsAndCountsAreHandled() throws {
        let h = try connected(secured: false)
        // Chunk length fields that disagree with the datagram.
        for length: UInt16 in [0, 3, 4, 12, 0xffff, 0x8000] {
            var d = h.console.dataChunk(message: [1])
            d.replaceSubrange(15..<17, with: be16(length))
            h.deliver(d)
        }
        // A DATA_ACK claiming 65535 gap blocks and one claiming duplicates.
        var ack = h.console.dataAck(cumulative: TakionVec.clientTag)
        ack.replaceSubrange(25..<27, with: be16(0xffff))
        h.deliver(ack)
        #expect(h.delegate.messages.isEmpty)
        #expect(h.connection.stats.droppedMalformed >= 6)
    }

    /// Unit index and totals at their extremes, with valid GMACs so that they reach parsing and the reorder queue.
    @Test func extremeUnitFieldsReachTheQueueWithValidGMACs() throws {
        let h = try connected(secured: true)
        let t = takionNow()
        // First packet is unit 2047 of 2048: its frame starts 2047 packets earlier, which the 256-slot queue can't
        // wait for, so the gap is skipped and the packet delivered.
        h.deliver(h.console.video(index: 100, unit: 2047, total: 2048, fec: 1023), at: t)
        #expect(h.delegate.av.count == 1)
        #expect(h.connection.stats.reorder.queueFullSkips == 1)
        #expect(h.delegate.av[0].header.unitIndex == 2047 && h.delegate.av[0].header.totalUnits == 2048)
        #expect(h.delegate.av[0].header.fecUnits == 1023)
        // A frame index and unit that wrap, a zero-length payload, every audio field at 0xff / 0xf.
        h.deliver(h.console.video(index: 101, frame: 0xffff, unit: 0, total: 1, payload: []), at: t + 60_000_000)
        h.deliver(h.console.av(video: false, packetIndex: 0xffff, frameIndex: 0xffff, word: 0xffff_ffff, codec: 0xff, stream: 2, payload: []))
        h.deliver(h.console.av(video: true, packetIndex: 102, frameIndex: 1, word: 0xffff_ffff, codec: 0xff, field18: 0xffff, byte20: 0xff, ext: true, payload: [7]), at: t + 70_000_000)
        h.connection.transportWake(now: t + 120_000_000)
        let av = h.delegate.av
        // The empty video and audio payloads are shorter than the minimum and dropped; packet 101 never arrives, so
        // 102 waits out the reorder wait.
        #expect(av.count == 2)
        #expect(h.connection.stats.droppedTruncated == 2)
        if let last = av.last {
            #expect(last.header.unitIndex == 2047 && last.header.totalUnits == 2048)
            #expect(last.header.fecUnits == 1023 && last.header.adaptiveStreamIndex == 7)
        }
        #expect(h.connection.stats.droppedBadGMAC == 0)
    }

    /// Valid GMACs over random headers and bodies: parsing and the queue see everything and trap on nothing.
    @Test func authenticatedRandomPacketsNeverTrap() throws {
        var rng = LCG(state: 5)
        for version in [12, 9] {
            let h = try connected(secured: true, version: version)
            var time = takionNow()
            for n in 0..<600 {
                let payload = (0..<Int.random(in: 0...200, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
                time += UInt64.random(in: 0...40_000_000, using: &rng)
                let word = UInt32.random(in: 0...UInt32.max, using: &rng)
                switch n % 4 {
                case 0, 1:
                    h.deliver(h.console.av(video: true, version: version, packetIndex: UInt16.random(in: 0...UInt16.max, using: &rng),
                                           frameIndex: UInt16.random(in: 0...UInt16.max, using: &rng), word: word,
                                           codec: UInt8.random(in: 0...255, using: &rng), field18: UInt16.random(in: 0...UInt16.max, using: &rng),
                                           byte20: UInt8.random(in: 0...255, using: &rng), ext: Bool.random(using: &rng), payload: payload), at: time)
                case 2:
                    h.deliver(h.console.av(video: false, version: version, packetIndex: UInt16.random(in: 0...UInt16.max, using: &rng),
                                           frameIndex: UInt16.random(in: 0...UInt16.max, using: &rng), word: word,
                                           codec: UInt8.random(in: 0...255, using: &rng), stream: UInt8.random(in: 0...3, using: &rng),
                                           ext: Bool.random(using: &rng), payload: payload), at: time)
                default:
                    h.deliver(h.console.dataChunk(tsn: TakionVec.consoleTag &+ UInt32.random(in: 0...20, using: &rng),
                                                  channel: UInt16.random(in: 0...UInt16.max, using: &rng),
                                                  dataType: Bool.random(using: &rng) ? UInt8.random(in: 0...255, using: &rng) : nil,
                                                  flags: UInt8.random(in: 0...3, using: &rng), message: payload), at: time)
                }
                if n % 25 == 0 { h.connection.transportWake(now: time + 30_000_000) }
            }
            #expect(h.connection.stats.droppedBadGMAC == 0)
            #expect(h.connection.stats.videoPackets > 100)
        }
    }

    @Test func unknownAndClientOnlyTypesAreDropped() throws {
        let h = try connected(secured: false)
        for type: UInt8 in [1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15] {
            h.deliver([type] + [UInt8](repeating: 0x55, count: 40))
            h.deliver([type | 0xf0] + [UInt8](repeating: 0x55, count: 40))
        }
        #expect(h.connection.stats.droppedUnknownType == 26)
        #expect(h.delegate.messages.isEmpty && h.delegate.av.isEmpty)
        // Control chunk types the console never sends us.
        for chunk: UInt8 in [0x01, 0x04, 0x05, 0x0a, 0x0c, 0xff] {
            var d = h.console.cookieAck()
            d[13] = chunk
            h.deliver(d)
        }
        #expect(h.connection.isConnected)
    }

    @Test func wildPacketIndicesKeepTheQueueBounded() throws {
        var rng = LCG(state: 99)
        let h = try connected(secured: true)
        let ordered = (0..<40).map { h.console.video(index: UInt16($0 * 3), frame: UInt16($0)) }
        // Same authentic packets, replayed in random order many times with random clock jumps in between.
        var time = takionNow()
        for round in 0..<30 {
            for p in ordered.shuffled(using: &rng) {
                h.deliver(p, at: time)
                time += UInt64.random(in: 0...30_000_000, using: &rng)
            }
            if round % 3 == 0 { h.connection.transportWake(now: time + 50_000_000) }
        }
        let stats = h.connection.stats.reorder
        #expect(stats.delivered <= 40 * 30)
        #expect(stats.delivered > 0)
    }

    @Test func hugeKeyPositionsAndTagsAreRejected() throws {
        let h = try connected(secured: true)
        for k: UInt32 in [1, 0x7fff_ffff, 0x8000_0000, 0xffff_ffff] {
            var d = h.console.video(index: 0)
            d.replaceSubrange(14..<18, with: be32(k))
            h.deliver(d)
        }
        #expect(h.delegate.av.isEmpty)
        #expect(h.connection.stats.droppedBadGMAC == 4)
    }

    @Test func packetsBeforeAnyHandshakeAreIgnored() throws {
        let h = MemoryHarness()
        for p in samples(h.console) { h.deliver(p) }
        #expect(h.delegate.messages.isEmpty)
        #expect(!h.delegate.connected)
        #expect(h.transport.sent.isEmpty)
    }

    @Test func parsersRejectShortInput() {
        for length in 0..<70 {
            let bytes = [UInt8](repeating: 0, count: length)
            bytes.withUnsafeBytes {
                _ = TakionControlHeader.parse($0)
                _ = TakionInitAck.parse($0, clientTag: 0)
                _ = TakionDataChunk.parse($0)
                _ = TakionDataAck.parse($0)
                for v in [7, 9, 12] { _ = TakionAV.parse($0, version: v) }
                #expect(!TakionProbe.isPong($0, unit: 0, tag: 0) || length >= 26)
            }
        }
        for type: UInt8 in [2, 3] {
            for version in [7, 9, 12] {
                for ext in [UInt8(0), 0x10] {
                    for length in 0..<26 {
                        var d = [UInt8](repeating: 0, count: length)
                        if !d.isEmpty { d[0] = type | ext }
                        d.withUnsafeBytes { _ = TakionAV.parse($0, version: version) }
                    }
                }
            }
        }
    }
}
