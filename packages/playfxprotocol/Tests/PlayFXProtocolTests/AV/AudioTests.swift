import Foundation
import Testing

@testable import PlayFXProtocol

@Suite("AV: audio, haptics and microphone")
struct AudioTests {
    /// The payload of a packet with `s` source and `r` redundant units, each unit filled with its frame number.
    func payload(frame f: UInt16, s: Int, r: Int, size: Int = 4) -> [UInt8] {
        var out: [UInt8] = []
        for i in 0..<(s + r) {
            let frame = i < s ? f &+ UInt16(i) : f &- UInt16(r) &+ UInt16(i - s)
            out += [UInt8](repeating: UInt8(truncatingIfNeeded: frame), count: size)
        }
        return out
    }

    func feed(
        _ receiver: AudioReceiver, frame f: UInt16, s: Int = 1, r: Int = 2, size: Int = 4, codec: UInt8 = 5
    ) {
        let bytes = payload(frame: f, s: s, r: r, size: size)
        bytes.withUnsafeBytes {
            receiver.receive(
                AVUnit(
                    kind: .audio, frameIndex: f, unitWord: audioWord(total: s + r, unitSize: size, redundant: r, source: s),
                    codec: codec, payload: $0))
        }
    }

    final class Events {
        var items: [String] = []
        func receiver() -> AudioReceiver {
            AudioReceiver { [self] event in
                switch event {
                case .packet(let f, let bytes): items.append("\(f):\(bytes.first ?? 0)x\(bytes.count)")
                case .lost(let f): items.append("lost\(f)")
                case .skipped(let f, let n): items.append("skip\(f)x\(n)")
                }
            }
        }
    }

    @Test("V-AV8: header words")
    func headerWords() {
        let video = AVUnit.VideoWord(0x00c0_1c01)
        #expect((video.unitIndex, video.unitsTotal, video.fecUnits) == (6, 8, 1))
        let a = AVUnit.AudioWord(0x0002_2821)
        #expect((a.unitIndex, a.unitsTotal, a.unitSize, a.redundantUnits, a.sourceUnits) == (0, 3, 40, 2, 1))
        let bad = AVUnit.AudioWord(0x0002_2811)
        #expect(bad.sourceUnits + bad.redundantUnits != bad.unitsTotal)
        #expect(audioWord(total: 3, unitSize: 40, redundant: 2, source: 1) == 0x0002_2821)
        #expect(videoWord(index: 6, total: 8, fec: 1) == 0x00c0_1c01)
        #expect(videoWord(index: 2, total: 8, fec: 1) == 0x0040_1c01)  // takion.md T9
    }

    @Test("V-AV9: frame index of each unit and the start-up rule")
    func frameIndices() {
        func map(_ f: UInt16, passedBefore: Bool = false) -> [String] {
            let bytes = [UInt8](repeating: 0, count: 120)
            return bytes.withUnsafeBytes { raw in
                let unit = AVUnit(kind: .audio, frameIndex: f, unitWord: 0x0002_2821, codec: 5, payload: raw)
                guard let layout = AudioPacketLayout(unit) else { return ["invalid"] }
                var startUp = AudioStartUp()
                if passedBefore { _ = startUp.skips(AudioPacketLayout(AVUnit(kind: .audio, frameIndex: 40000, unitWord: 0x0002_2821, codec: 5, payload: raw))!, unit: 0) }
                return (0..<3).map { startUp.skips(layout, unit: $0) ? "skipped" : "\(layout.frame(ofUnit: $0))" }
            }
        }
        #expect(map(1000) == ["1000", "998", "999"])
        #expect(map(1) == ["1", "skipped", "skipped"])
        #expect(map(2) == ["2", "skipped", "1"])
        #expect(map(3) == ["3", "1", "2"])
        #expect(map(0, passedBefore: true) == ["0", "65534", "65535"])
        #expect(map(40000) == ["40000", "39998", "39999"])
    }

    @Test("packets that fail the checks are dropped")
    func packetChecks() {
        let events = Events()
        let r = events.receiver()
        feed(r, frame: 1, codec: 4)
        // s + r != n
        [UInt8](repeating: 1, count: 12).withUnsafeBytes {
            r.receive(AVUnit(kind: .audio, frameIndex: 1, unitWord: 0x0002_0411, codec: 5, payload: $0))
        }
        // wrong payload length
        [UInt8](repeating: 1, count: 11).withUnsafeBytes {
            r.receive(AVUnit(kind: .audio, frameIndex: 1, unitWord: audioWord(total: 3, unitSize: 4, redundant: 2, source: 1), codec: 5, payload: $0))
        }
        // empty payload
        r.receive(AVUnit(kind: .audio, frameIndex: 1, unitWord: 0, codec: 5, payload: UnsafeRawBufferPointer(start: nil, count: 0)))
        // video kind is ignored
        [UInt8](repeating: 1, count: 4).withUnsafeBytes {
            r.receive(AVUnit(kind: .video, frameIndex: 1, unitWord: 0, codec: 5, payload: $0))
        }
        for f: UInt16 in 1...5 { feed(r, frame: 100 &+ f) }
        // F = 101 carries frames 101, 99, 100: three frames buffered, playback starts at the oldest.
        #expect(events.items == (99...105).map { "\($0):\($0)x4" })
        #expect(r.packetsReceived == 9)  // the video-kind unit isn't an audio packet
        #expect(r.framesConcealed == 0)
    }

    @Test("in-order stream: playback starts after 3 frames, then each frame plays at once")
    func inOrder() {
        let events = Events()
        let r = events.receiver()
        feed(r, frame: 1)
        feed(r, frame: 2)
        #expect(events.items.isEmpty)
        feed(r, frame: 3)
        #expect(events.items == ["1:1x4", "2:2x4", "3:3x4"])
        feed(r, frame: 4)
        feed(r, frame: 5)
        #expect(events.items.suffix(2) == ["4:4x4", "5:5x4"])
        #expect(r.highestFrameIndex == 5)
        #expect(r.framesConcealed == 0)
    }

    @Test("one lost packet is covered by the repeat in the next one: no concealment")
    func oneLost() {
        let events = Events()
        let r = events.receiver()
        for f: UInt16 in [1, 2, 3, 4, 6, 7] { feed(r, frame: f) }
        // Frame 5 was in packet 5 (lost); packet 6 carries it again.
        #expect(events.items == ["1:1x4", "2:2x4", "3:3x4", "4:4x4", "5:5x4", "6:6x4", "7:7x4"])
        #expect(r.framesConcealed == 0)
    }

    @Test("two lost packets are covered by the two repeated frames")
    func twoLost() {
        let events = Events()
        let r = events.receiver()
        for f: UInt16 in [1, 2, 3, 4, 7] { feed(r, frame: f) }
        #expect(events.items == (1...7).map { "\($0):\($0)x4" })
        #expect(r.framesConcealed == 0)
    }

    @Test("three lost packets: the oldest gap is concealed")
    func threeLost() {
        let events = Events()
        let r = events.receiver()
        for f: UInt16 in [1, 2, 3, 4, 8] { feed(r, frame: f) }
        #expect(events.items == ["1:1x4", "2:2x4", "3:3x4", "4:4x4", "lost5", "6:6x4", "7:7x4", "8:8x4"])
        #expect(r.framesConcealed == 1)
    }

    @Test("a long gap conceals up to the cap, then reports the rest in one event")
    func longGap() {
        let events = Events()
        let r = events.receiver()
        for f: UInt16 in [1, 2, 3] { feed(r, frame: f) }
        feed(r, frame: 1000)  // frames 4...997 are missing; 998, 999, 1000 arrive together
        let cap = r.maxConcealedFrames
        #expect(cap == 64)
        let expected =
            ["1:1x4", "2:2x4", "3:3x4"] + (4..<(4 + cap)).map { "lost\($0)" } + ["skip\(4 + cap)x\(998 - 4 - cap)"]
            + ["998:230x4", "999:231x4", "1000:232x4"]
        #expect(events.items == expected)
        #expect(r.framesConcealed == cap)
    }

    @Test("the cap is at least 500 ms of frames at the header's rate")
    func concealmentCap() {
        let r = AudioReceiver { _ in }
        #expect(r.maxConcealedFrames == AudioReceiver.minConcealedFrames)
        r.setHeader(AudioHeader(channels: 2, bitsPerSample: 16, sampleRate: 48000, frameSize: 480))
        #expect(r.maxConcealedFrames == 64)  // 50 frames are 500 ms; the floor is 64
        r.setHeader(AudioHeader(channels: 2, bitsPerSample: 16, sampleRate: 48000, frameSize: 48))
        #expect(r.maxConcealedFrames == 500)  // 1 ms frames
        r.setHeader(AudioHeader(channels: 2, bitsPerSample: 16, sampleRate: 48000, frameSize: 0))
        #expect(r.maxConcealedFrames == 64)
    }

    @Test("a gap just over the cap and one just under it")
    func gapAroundCap() {
        func run(gap: Int) -> [String] {
            let events = Events()
            let r = events.receiver()
            for f: UInt16 in [1, 2, 3] { feed(r, frame: f, s: 1, r: 0) }
            feed(r, frame: UInt16(4 + gap), s: 1, r: 0)  // frames 4 ..< 4 + gap are missing
            return Array(events.items.dropFirst(3))
        }
        #expect(run(gap: 64) == (4..<68).map { "lost\($0)" } + ["68:68x4"])
        #expect(run(gap: 65) == (4..<68).map { "lost\($0)" } + ["skip68x1", "69:69x4"])
    }

    @Test("a short gap with a single source unit per packet conceals what the repeats can't fill")
    func noRedundancy() {
        let events = Events()
        let r = events.receiver()
        for f: UInt16 in [1, 2, 3] { feed(r, frame: f, s: 1, r: 0) }
        feed(r, frame: 6, s: 1, r: 0)
        feed(r, frame: 7, s: 1, r: 0)
        // 4 and 5 are missing and fewer than 3 frames are buffered: concealed at once.
        #expect(events.items == ["1:1x4", "2:2x4", "3:3x4", "lost4", "lost5", "6:6x4", "7:7x4"])
        #expect(r.framesConcealed == 2)
    }

    @Test("duplicates, late frames and reordering are handled")
    func duplicatesAndReorder() {
        let events = Events()
        let r = events.receiver()
        for f: UInt16 in [1, 2, 3, 4] { feed(r, frame: f) }
        let before = events.items.count
        feed(r, frame: 4)  // duplicate of something already played: older than next
        feed(r, frame: 2)
        #expect(events.items.count == before)
        // Reordered: 7 arrives before 5 and 6. Fewer than 3 frames are buffered, so 5 and 6 are concealed
        // at once, and the late 6 is older than the next frame to play and dropped.
        feed(r, frame: 7, s: 1, r: 0)
        #expect(Array(events.items.suffix(3)) == ["lost5", "lost6", "7:7x4"])
        feed(r, frame: 6, s: 1, r: 0)
        #expect(events.items.count == before + 3)
        #expect(r.framesConcealed == 2)
    }

    @Test("fewer than 3 buffered frames: a missing frame is concealed at once")
    func fewBuffered() {
        let events = Events()
        let r = events.receiver()
        feed(r, frame: 10, s: 1, r: 0)
        feed(r, frame: 12, s: 1, r: 0)
        feed(r, frame: 13, s: 1, r: 0)  // starts at 10; 11 is missing with only two newer frames buffered
        #expect(events.items == ["10:10x4", "lost11", "12:12x4", "13:13x4"])
    }

    @Test("a full jitter buffer behaves: older replaces newest, newer is dropped")
    func fullBufferDirect() {
        let events = Events()
        let r = events.receiver()
        // Playback not started yet (fewer than 3 buffered is impossible with 8 slots), so fill via the
        // redundancy path: 8 distinct frames with s = 8 in one packet start playback, so use a started stream
        // with a hole: next = 5 is missing and the others sit within 2 ahead only if few; fill 8 slots using
        // 7 frames ahead of the hole by big s.
        feed(r, frame: 1, s: 3, r: 0)  // frames 1, 2, 3: starts, plays all
        #expect(events.items.count == 3)
        feed(r, frame: 5, s: 8, r: 0)  // 4 missing; frames 5...12 fill the buffer; 4 is concealed since far behind
        #expect(events.items.contains("lost4"))
        #expect(r.framesConcealed == 1)
        // 8 more frames: buffer full then older replaces newest / newer dropped (no crash, order kept).
        feed(r, frame: 13, s: 8, r: 0)
        feed(r, frame: 13, s: 8, r: 0)
        #expect(events.items.filter { !$0.hasPrefix("lost") }.count == 3 + 8 + 8)
    }

    @Test("full buffer: an older frame replaces the newest, a newer one is dropped")
    func fullBufferBranches() {
        let replace = Events()
        let r1 = replace.receiver()
        feed(r1, frame: 100, s: 1, r: 15)  // 100 first, then 85...99: the 9th unit (92) replaces 100
        #expect(replace.items == (85...92).map { "\($0):\($0)x4" })
        let drop = Events()
        let r2 = drop.receiver()
        feed(r2, frame: 1, s: 12, r: 0)  // 1...12: only the first 8 fit
        #expect(drop.items == (1...8).map { "\($0):\($0)x4" })
    }

    @Test("a new audio header resets the receiver")
    func headerResets() {
        let events = Events()
        let r = events.receiver()
        for f: UInt16 in [1, 2, 3] { feed(r, frame: f) }
        r.setHeader(AudioHeader(channels: 2, bitsPerSample: 16, sampleRate: 48000, frameSize: 480))
        #expect(r.header?.frameSize == 480)
        feed(r, frame: 1)
        feed(r, frame: 2)
        feed(r, frame: 3)
        #expect(events.items.count == 6)
    }

    @Test("audio header encode and decode")
    func audioHeader() throws {
        let bytes = hex("02 10 0000bb80 000001e0 00000001")
        let h = try #require(AudioHeader(bytes))
        #expect(h == AudioHeader(channels: 2, bitsPerSample: 16, sampleRate: 48000, frameSize: 480, unknown: 1))
        #expect(h.bytes == bytes)
        #expect(AudioHeader(Array(bytes.dropLast())) == nil)
        #expect(AudioHeader(bytes + [0]) == nil)
        #expect(MicrophoneSettings.announcedHeader.bytes == hex("01 10 0000bb80 000001e0 00000001"))
    }

    @Test("hostile audio: huge frame gaps, wrap-around and unit sizes never trap, and what plays is intact")
    func hostileAudio() {
        var rng = SeededRandom(5)
        let order = Locked<(last: UInt16?, ordered: Bool, intact: Bool, lost: Int)>((nil, true, true, 0))
        let r = AudioReceiver { event in
            order.with { o in
                switch event {
                case .packet(let f, let bytes):
                    // every unit is filled with its frame number's low byte
                    if bytes.isEmpty || !bytes.allSatisfy({ $0 == UInt8(truncatingIfNeeded: f) }) { o.intact = false }
                    if let l = o.last, !Serial16.isNewer(f, than: l) { o.ordered = false }
                    o.last = f
                case .lost(let f):
                    if let l = o.last, !Serial16.isNewer(f, than: l) { o.ordered = false }
                    o.last = f
                    o.lost += 1
                case .skipped(let f, let n):
                    if let l = o.last, !Serial16.isNewer(f, than: l) || n <= 0 { o.ordered = false }
                    o.last = f &+ UInt16(truncatingIfNeeded: n) &- 1
                }
            }
        }
        for _ in 0..<5000 {
            let s = Int.random(in: 0...15, using: &rng)
            let red = Int.random(in: 0...15, using: &rng)
            let size = Int.random(in: 0...255, using: &rng)
            let f = UInt16.random(in: 0...UInt16.max, using: &rng)
            feed(r, frame: f, s: s, r: red, size: size)
        }
        let result = order.with { $0 }
        #expect(r.packetsReceived == 5000)
        #expect(result.intact)
        #expect(result.ordered)
        #expect(r.framesConcealed == result.lost)
    }

    @Test("audio statistics can be read from another thread while packets arrive")
    func concurrentStatistics() {
        final class Box: @unchecked Sendable {
            let receiver: AudioReceiver
            init(_ r: AudioReceiver) { receiver = r }
        }
        let r = AudioReceiver { _ in }
        let box = Box(r)
        let done = Locked(false)
        let highest = Locked<(Int, Int)>((0, 0))
        let reader = Thread {
            while !done.with({ $0 }) {
                let stats = box.receiver.statistics
                highest.with { $0 = (max($0.0, stats.packetsReceived), max($0.1, Int(stats.highestFrameIndex))) }
            }
        }
        reader.start()
        for f in 1...5000 { feed(r, frame: UInt16(f), s: 1, r: 0) }
        done.with { $0 = true }
        while !reader.isFinished { Thread.sleep(forTimeInterval: 0.001) }
        #expect(r.statistics == AudioStatistics(packetsReceived: 5000, highestFrameIndex: 5000, framesConcealed: 0))
        #expect(highest.with { $0.0 } <= 5000)
    }

    // MARK: Haptics

    @Test("haptics: PCM units in payload order, little-endian by default, only newer frames")
    func haptics() {
        let got = Locked<[(UInt16, [Int16])]>([])
        let h = HapticsReceiver { f, samples in got.with { $0.append((f, Array(samples))) } }
        func send(_ f: UInt16, _ unit: [UInt8], s: Int = 1, r: Int = 0, codec: UInt8 = 5) {
            unit.withUnsafeBytes {
                h.receive(
                    AVUnit(
                        kind: .audio, frameIndex: f,
                        unitWord: audioWord(total: s + r, unitSize: unit.count / (s + r), redundant: r, source: s),
                        codec: codec, streamByte: 0x02, payload: $0))
            }
        }
        send(10, [0x01, 0x80, 0xff, 0x7f, 0x00, 0x01, 0xfe, 0xff])
        #expect(got.with { $0 }.map(\.0) == [10])
        #expect(got.with { $0 }[0].1 == [Int16(bitPattern: 0x8001), 0x7fff, 0x0100, -2])
        // A source unit and two repeats: the source (frame 12) plays; the older repeats don't.
        send(12, [UInt8](repeating: 3, count: 12), s: 1, r: 2)
        #expect(got.with { $0 }.map(\.0) == [10, 12])
        // Two source units: both are newer, in order.
        send(13, [UInt8](repeating: 4, count: 8), s: 2, r: 0)
        #expect(got.with { $0 }.map(\.0) == [10, 12, 13, 14])
        send(14, [UInt8](repeating: 4, count: 4))  // not newer than 14
        #expect(got.with { $0 }.count == 4)
        send(20, [UInt8](repeating: 4, count: 4), codec: 4)  // wrong codec
        send(21, [UInt8](repeating: 4, count: 3))  // less than one stereo sample
        #expect(got.with { $0 }.count == 4)
        // "Last used" starts at 0 and is never reset: frame 0 is not usable, a lower index is not newer.
        let fresh = Locked<Int>(0)
        let h0 = HapticsReceiver { _, _ in fresh.with { $0 += 1 } }
        [UInt8](repeating: 4, count: 4).withUnsafeBytes {
            h0.receive(AVUnit(kind: .audio, frameIndex: 0, unitWord: audioWord(total: 1, unitSize: 4, redundant: 0, source: 1), codec: 5, streamByte: 2, payload: $0))
            h0.receive(AVUnit(kind: .audio, frameIndex: 1, unitWord: audioWord(total: 1, unitSize: 4, redundant: 0, source: 1), codec: 5, streamByte: 2, payload: $0))
        }
        #expect(fresh.with { $0 } == 1)
        #expect(HapticsReceiver.sampleRate == 3000)
        #expect(HapticsReceiver.channels == 2)
    }

    @Test("haptics: the byte order is one switch")
    func hapticsByteOrder() {
        let got = Locked<[Int16]>([])
        let h = HapticsReceiver(byteOrder: .bigEndian) { _, samples in got.with { $0 += samples } }
        [UInt8]([0x01, 0x80, 0xff, 0x7f]).withUnsafeBytes {
            h.receive(AVUnit(kind: .audio, frameIndex: 1, unitWord: audioWord(total: 1, unitSize: 4, redundant: 0, source: 1), codec: 5, streamByte: 2, payload: $0))
        }
        #expect(got.with { $0 } == [0x0180, -129])
        #expect(HapticsReceiver.defaultByteOrder == .littleEndian)
    }

    @Test("haptics: a 120-byte unit is 30 stereo samples, and the start-up rule applies")
    func hapticsUnit() {
        let counts = Locked<[Int]>([])
        let h = HapticsReceiver { _, samples in counts.with { $0.append(samples.count) } }
        [UInt8](repeating: 0, count: 360).withUnsafeBytes {
            h.receive(AVUnit(kind: .audio, frameIndex: 1, unitWord: audioWord(total: 3, unitSize: 120, redundant: 2, source: 1), codec: 5, streamByte: 2, payload: $0))
        }
        #expect(counts.with { $0 } == [60])  // the two repeats name frames before the start
    }

    // MARK: Microphone

    @Test("microphone: packet layout, history, counter wrap and the 40-byte rule")
    func microphone() {
        var mic = MicrophonePacketizer()
        func frame(_ n: UInt8) -> [UInt8] { [UInt8](repeating: n, count: 40) }
        #expect(mic.packet(opusFrame: [UInt8](repeating: 0, count: 39)) == nil)
        let p0 = mic.packet(opusFrame: frame(1))!
        #expect(p0.packetIndex == 0)
        #expect(p0.frameIndex == 1)
        #expect(p0.unitWord == 0x0002_2821)
        #expect(p0.codec == 5)
        #expect(p0.payload == frame(1) + frame(1) + frame(1))
        #expect(mic.packet(opusFrame: frame(2))!.payload == frame(2) + frame(1) + frame(1))
        #expect(mic.packet(opusFrame: frame(3))!.payload == frame(3) + frame(1) + frame(2))
        #expect(mic.packet(opusFrame: [1, 2, 3]) == nil)
        let p3 = mic.packet(opusFrame: frame(4))!
        #expect(p3.packetIndex == 3)
        #expect(p3.payload == frame(4) + frame(2) + frame(3))
        #expect(p3.payload.count == 120)
        #expect(MicrophoneSettings.pcmValuesPerFrame == 960)
        #expect(MicrophoneSettings.bitrate == 32000)
        #expect(!MicrophoneSettings.variableBitrate)
    }

    @Test("microphone: the counter wraps to 0 and the frame index to 0 after 65535")
    func microphoneWrap() {
        var mic = MicrophonePacketizer()
        var last: MicrophonePacket?
        for _ in 0..<65537 { last = mic.packet(opusFrame: [UInt8](repeating: 9, count: 40)) }
        #expect(last?.packetIndex == 0)
        #expect(last?.frameIndex == 1)
    }
}
