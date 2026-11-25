import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

@Suite("AV: video frame assembly")
struct VideoReceiverTests {
    // V-AV6: n = 5, m = 2 (k = 3), S = 16.
    static let units = [
        hex("000000000001419a0102030405060708"),
        hex("0005090a0b0c0d0e0f1011"),
        hex("000a12131415"),
        hex("008f8dcbf7c85ebc8bfa80028c038d04"),
        hex("008e7b538f51b7717dfd87f70302f6f3"),
    ]
    static let accessUnit = hex("00000001419a0102030405060708090a0b0c0d0e0f101112131415")

    func send(_ r: VideoReceiver, frame: UInt16, units order: [Int]) {
        for u in order { r.feed(frame: frame, index: u, total: 5, fec: 2, payload: Self.units[u]) }
    }

    /// A frame of one unit and no parity carrying `content`.
    func single(_ r: VideoReceiver, _ frame: UInt16, _ content: [UInt8] = [0, 0, 0, 1, 0x41]) {
        r.feed(frame: frame, index: 0, total: 1, fec: 0, payload: [0, 0] + content)
    }

    @Test("V-AV6: complete without FEC")
    func completeWithoutFEC() {
        let log = VideoLog()
        let r = log.makeReceiver()
        send(r, frame: 1, units: [0, 1, 2])
        #expect(log.frames.count == 1)
        #expect(log.frames[0].bytes == Self.accessUnit)
        #expect(log.frames[0].info.fecRecovered == false)
        #expect(log.frames[0].info.framesLost == 0)
        #expect(log.corrupt.isEmpty)
        #expect(log.parameterSets == [0])
    }

    @Test("V-AV6: units 1, 3, 4 recover units 0 and 2; S comes from a source unit")
    func recoverFromSource() {
        let log = VideoLog()
        let r = log.makeReceiver()
        send(r, frame: 1, units: [1, 3, 4])
        #expect(log.frames.map(\.bytes) == [Self.accessUnit])
        #expect(log.frames[0].info.fecRecovered)
        #expect(r.statistics.framesRecoveredByFEC == 1)
    }

    @Test("V-AV6: units 3, 0, 2 recover unit 1; S comes from a parity unit")
    func recoverFromParity() {
        let log = VideoLog()
        let r = log.makeReceiver()
        send(r, frame: 1, units: [3, 0, 2])
        #expect(log.frames.map(\.bytes) == [Self.accessUnit])
    }

    @Test("V-AV6: units 4, 0, 2 fail: unit 4 (n - 1) finishes the frame on arrival, 0 and 2 are too late")
    func lastUnitFirstFails() {
        let log = VideoLog()
        let r = log.makeReceiver()
        send(r, frame: 1, units: [4, 0, 2])
        #expect(log.frames.isEmpty)
        #expect(log.corrupt == [[1, 1]])
        #expect(log.idr == [.fecFailed])
    }

    @Test("V-AV6: units 1, 3 only fail, and the failure is reported when the next frame starts")
    func failure() {
        let log = VideoLog()
        let r = log.makeReceiver()
        send(r, frame: 1, units: [1, 3])
        #expect(log.frames.isEmpty)
        #expect(log.corrupt.isEmpty)
        single(r, 2)
        // Once for the failure, and again as the gap before frame 2 (av.md 4.3, both steps apply).
        #expect(log.corrupt == [[1, 1], [1, 1]])
        #expect(log.idr == [.fecFailed])
        #expect(r.statistics.framesFECFailed == 1)
        // Frame 2 still goes through: it's an unparsed stream, so there is no IDR or reference logic.
        #expect(log.frames.count == 1)
        #expect(log.frames[0].info.framesLost == 0)
    }

    @Test("a frame is finished by its last unit even when too few units came")
    func lastUnitFinishes() {
        let log = VideoLog()
        let r = log.makeReceiver()
        r.feed(frame: 1, index: 0, total: 3, fec: 0, payload: [0, 0, 1, 2])
        r.feed(frame: 1, index: 2, total: 3, fec: 0, payload: [0, 0, 3, 4])
        #expect(log.frames.isEmpty)
        #expect(log.corrupt == [[1, 1]])
    }

    @Test("the last unit finishes the frame even when rejected (zero length)")
    func rejectedLastUnitFinishes() {
        let log = VideoLog()
        let r = log.makeReceiver()
        r.feed(frame: 1, index: 0, total: 3, fec: 0, payload: [0, 0, 1])
        r.feed(frame: 1, index: 2, total: 3, fec: 0, payload: [])
        #expect(log.corrupt == [[1, 1]])
    }

    @Test("the pad prefix and the padding are removed; a unit of 2 bytes contributes nothing")
    func padAndPrefix() {
        let log = VideoLog()
        let r = log.makeReceiver()
        // S = 6 + 0 for unit 0; unit 1 is 4 bytes + pad 2; unit 2 is just a prefix with pad 6.
        r.feed(frame: 1, index: 0, total: 3, fec: 0, payload: [0, 0, 1, 2, 3, 4])
        r.feed(frame: 1, index: 1, total: 3, fec: 0, payload: [0, 2, 5, 6])
        r.feed(frame: 1, index: 2, total: 3, fec: 0, payload: [0, 6])
        #expect(log.frames.map(\.bytes) == [[1, 2, 3, 4, 5, 6]])
    }

    @Test("zero parity still keeps an empty slot: a missing source unit loses the frame")
    func noParity() {
        let log = VideoLog()
        let r = log.makeReceiver()
        r.feed(frame: 1, index: 0, total: 2, fec: 0, payload: [0, 0, 1])
        single(r, 2)
        #expect(log.corrupt == [[1, 1], [1, 1]])
        #expect(log.frames.count == 1)
    }

    @Test("frames lost: V-AV10 numbers")
    func framesLost() {
        let cases: [(UInt16, UInt16, Int)] = [(5, 6, 0), (5, 9, 3), (65534, 1, 2), (65535, 0, 0)]
        for (previous, current, expected) in cases {
            let log = VideoLog()
            let r = log.makeReceiver()
            single(r, previous)
            single(r, current)
            #expect(log.frames.map(\.info.framesLost) == [0, expected], "\(previous) -> \(current)")
        }
        let log = VideoLog()
        let r = log.makeReceiver()
        single(r, 7)
        #expect(log.frames.map(\.info.framesLost) == [0])
        single(r, 7)  // the same frame again: dropped
        #expect(log.frames.count == 1)
        single(r, 9)
        single(r, 12)
        #expect(r.statistics.framesLost == 1 + 2)
        #expect(r.statistics.framesHandedOver == 3)
    }

    @Test("V-AV10: serial comparison")
    func serialComparison() {
        let rows: [(UInt16, UInt16, Bool, Bool)] = [
            (1, 0, true, false), (0, 65535, true, false), (65535, 0, false, true), (0, 32768, false, false),
            (32768, 0, false, false), (100, 32867, false, true), (100, 32869, true, false),
        ]
        for (a, b, newer, older) in rows {
            #expect(Serial16.isNewer(a, than: b) == newer, "\(a) \(b)")
            #expect(Serial16.isOlder(a, than: b) == older, "\(a) \(b)")
        }
        #expect(!Serial16.isNewer(5, than: 5))
        #expect(!Serial16.isOlder(5, than: 5))
    }

    @Test("a gap before a new frame sends a corrupt-frame report for the missing frames")
    func gapReport() {
        let log = VideoLog()
        let r = log.makeReceiver()
        single(r, 1)
        single(r, 2)
        #expect(log.corrupt.isEmpty)
        single(r, 5)
        #expect(log.corrupt == [[3, 4]])
        #expect(log.frames.map(\.info.framesLost) == [0, 0, 2])
    }

    @Test("an older frame, and one 32768 away, are dropped")
    func olderFramesDropped() {
        let log = VideoLog()
        let r = log.makeReceiver()
        single(r, 10)
        single(r, 9)
        single(r, 10 &+ 32768)
        #expect(log.frames.count == 1)
    }

    @Test("IDR requests repeat only after a second")
    func idrRepeat() {
        let log = VideoLog()
        let r = log.makeReceiver()
        // Three frames that each fail: only one unit of a two-unit frame arrives.
        for f: UInt16 in 1...3 {
            r.feed(frame: f, index: 0, total: 2, fec: 0, payload: [0, 0, 1])
            log.now += 0.4
        }
        r.feed(frame: 4, index: 0, total: 2, fec: 0, payload: [0, 0, 1])
        // Frames 1, 2, 3 failed at t = 0.4, 0.8, 1.2: one request (0.4 s and 0.8 s later: not yet).
        #expect(log.idr == [.fecFailed])
        let first = log.idr.count
        log.now += 1.1
        r.feed(frame: 5, index: 0, total: 2, fec: 0, payload: [0, 0, 1])
        r.feed(frame: 6, index: 0, total: 1, fec: 0, payload: [0, 0, 1])
        #expect(log.idr.count == first + 1)
    }

    @Test("a decoder that rejects a frame leaves lastGood alone and sends no IDR request")
    func decoderRejects() {
        let log = VideoLog()
        let r = log.makeReceiver()
        single(r, 1)
        log.accept = false
        single(r, 2)
        #expect(log.idr.isEmpty)
        log.accept = true
        single(r, 3)
        // lastGood is still 1, so frame 3 reports 2 as corrupt.
        #expect(log.corrupt == [[2, 2]])
        #expect(log.frames.map(\.info.framesLost) == [0, 0, 0])
    }

    @Test("a decoder that rejects every frame produces no IDR requests, only a throttled labelled event")
    func rejectionStorm() {
        let log = VideoLog()
        log.accept = false
        let r = log.makeReceiver()
        for f in 1...20 {
            single(r, UInt16(f))
            log.now += 0.1
        }
        #expect(log.idr.isEmpty)
        // Frames at t = 0.0 ... 1.9: the 5th rejection (t = 0.4) and the 15th (t = 1.4, a second later).
        #expect(log.rejecting == [5, 15])
        #expect(log.frames.count == 20)
    }

    @Test("rejecting a frame doesn't set waitingForIdr: a later non-I slice is still handed over")
    func rejectionDoesNotWait() {
        let (log, r) = h264Log()
        frame(r, 1, nal: StreamFixtures.h264Slice(idr: true, sliceType: 7))
        log.accept = false
        frame(r, 2, nal: StreamFixtures.h264Slice(idr: false, sliceType: 1))  // B: "neither", rejected
        log.accept = true
        frame(r, 3, nal: StreamFixtures.h264Slice(idr: false, sliceType: 1))
        #expect(log.frames.map(\.info.frameIndex) == [1, 2, 3])
        #expect(log.idr.isEmpty)
        #expect(r.statistics.framesDropped == 0)
    }

    @Test("a rejected key frame still clears the IDR wait, and nothing is requested")
    func rejectedKeyFrame() {
        let (log, r) = h264Log()
        frame(r, 1, nal: StreamFixtures.h264Slice(idr: true, sliceType: 7))
        r.feed(frame: 2, index: 0, total: 2, fec: 0, payload: [0, 0, 1])  // FEC failure: waiting
        log.accept = false
        frame(r, 3, nal: StreamFixtures.h264Slice(idr: true, sliceType: 7))
        frame(r, 4, nal: StreamFixtures.h264Slice(idr: true, sliceType: 7))
        #expect(log.idr == [.fecFailed])
    }

    @Test("a frame with k = 0 (n == m) is invalid and starts nothing")
    func zeroSourceUnits() {
        let log = VideoLog()
        let r = log.makeReceiver()
        r.feed(frame: 1, index: 0, total: 2, fec: 2, payload: [0, 0, 1])
        r.feed(frame: 1, index: 1, total: 2, fec: 2, payload: [0, 0, 1])
        r.feed(frame: 5, index: 0, total: 1, fec: 1, payload: [0, 0, 1])
        #expect(log.frames.isEmpty)
        #expect(log.corrupt.isEmpty)
        #expect(log.parameterSets.isEmpty)
        single(r, 6)
        #expect(log.frames.count == 1)
    }

    @Test("an access unit that comes out empty is a failed frame: not handed over, not lastGood, not a reference")
    func emptyAccessUnit() {
        let (log, r) = h264Log()
        frame(r, 1, nal: StreamFixtures.h264Slice(idr: true, sliceType: 7))
        // Prefix only: pad 2 on a 2-byte unit, so S = 4 and the content length is 0.
        r.feed(frame: 2, index: 0, total: 1, fec: 0, payload: [0, 2])
        #expect(log.frames.count == 1)
        #expect(log.corrupt == [[2, 2]])
        #expect(log.idr == [.fecFailed])
        #expect(r.statistics.framesFECFailed == 1)
        // Frame 3 refers to frame 2 (d = 0), which isn't a reference: dropped.
        frame(r, 3, nal: StreamFixtures.h264Slice(idr: false, sliceType: 5, frameNum: 2))
        #expect(log.frames.count == 1)
    }

    @Test("late units are validated like others: one longer than S isn't counted")
    func lateUnitTooLong() {
        let log = VideoLog()
        let r = log.makeReceiver()
        send(r, frame: 1, units: [0, 1, 2])  // finished with S = 16
        r.feed(frame: 1, index: 3, total: 5, fec: 2, payload: [UInt8](repeating: 0, count: 17))
        r.feed(frame: 1, index: 4, total: 5, fec: 2, payload: Self.units[4])
        single(r, 2)
        let c = r.takeCongestionCounters()
        #expect(c.received == 4)
        #expect(c.lost == 1)
    }

    @Test("the counters can be read from another thread while units arrive")
    func concurrentReads() {
        let log = VideoLog()
        let r = log.makeReceiver()
        final class Box: @unchecked Sendable {
            let receiver: VideoReceiver
            init(_ r: VideoReceiver) { receiver = r }
        }
        let box = Box(r)
        let done = Locked(false)
        let taken = Locked((received: 0, lost: 0))
        let reader = Thread {
            while !done.with({ $0 }) {
                let c = box.receiver.takeCongestionCounters()
                taken.with { $0 = ($0.received + c.received, $0.lost + c.lost) }
            }
        }
        reader.start()
        for f in 1...5000 { single(r, UInt16(f)) }
        done.with { $0 = true }
        while !reader.isFinished { Thread.sleep(forTimeInterval: 0.001) }
        let rest = r.takeCongestionCounters()
        let total = taken.with { ($0.received + rest.received, $0.lost + rest.lost) }
        // 4999 frames were closed by a newer one: each received 1 of its 2 slots.
        #expect(total.0 == 4999)
        #expect(total.1 == 4999)
    }

    @Test("late units after a frame finished are counted for statistics but ignored")
    func lateUnits() {
        let log = VideoLog()
        let r = log.makeReceiver()
        send(r, frame: 1, units: [0, 1, 2])
        send(r, frame: 1, units: [3, 4, 3])
        #expect(log.frames.count == 1)
        single(r, 2)
        // Frame 1: 5 units counted (0, 1, 2, 3, 4) of 5 slots, none missing.
        let counters = r.takeCongestionCounters()
        #expect(counters.received == 5)
        #expect(counters.lost == 0)
        #expect(r.takeCongestionCounters().received == 0)
        single(r, 3)  // frame 2: k = 1, m = 0: 1 received of k + max(m, 1) = 2, so one counts as lost
        let second = r.takeCongestionCounters()
        #expect(second.received == 1)
        #expect(second.lost == 1)
    }

    @Test("missing units count as lost")
    func missingCounted() {
        let log = VideoLog()
        let r = log.makeReceiver()
        send(r, frame: 1, units: [1, 3, 4])
        single(r, 2)
        let c = r.takeCongestionCounters()
        #expect(c.received == 3)
        #expect(c.lost == 2)
    }

    @Test("profiles: parameter sets are given on the first frame and on a switch; unknown profile drops")
    func profileSwitching() {
        let log = VideoLog()
        let profiles = [
            VideoProfile(width: 1920, height: 1080, header: StreamFixtures.h264Header()),
            VideoProfile(width: 1280, height: 720, header: StreamFixtures.h264Header()),
        ]
        let r = log.makeReceiver(profiles: profiles)
        let idr = [0, 0] + annexB(StreamFixtures.h264Slice(idr: true, sliceType: 7))
        r.feed(frame: 1, index: 0, total: 1, fec: 0, payload: idr)
        #expect(log.parameterSets == [0])
        r.feed(frame: 2, index: 0, total: 1, fec: 0, payload: idr, profile: 2)
        #expect(log.frames.count == 1)  // dropped: no profile 2
        r.feed(frame: 2, index: 0, total: 1, fec: 0, payload: idr, profile: 1)
        #expect(log.parameterSets == [0, 1])
        #expect(log.frames.count == 2)
        #expect(log.frames[1].info.profileIndex == 1)
        // No stream info at all: nothing is accepted.
        let empty = VideoLog()
        let e = empty.makeReceiver(profiles: [])
        single(e, 1)
        #expect(empty.frames.isEmpty)
    }

    @Test("hostile headers and payloads are dropped without a trap")
    func hostile() {
        let log = VideoLog()
        let r = log.makeReceiver()
        // n < m
        r.feed(frame: 1, index: 0, total: 2, fec: 3, payload: [0, 0, 1])
        // too many units in a frame
        r.feed(frame: 1, index: 0, total: 600, fec: 0, payload: [0, 0, 1])
        r.feed(frame: 1, index: 0, total: 513, fec: 1, payload: [0, 0, 1])
        // kind is audio
        [UInt8](arrayLiteral: 1, 2, 3).withUnsafeBytes {
            r.receive(AVUnit(kind: .audio, frameIndex: 1, unitWord: 0, codec: 5, payload: $0))
        }
        #expect(log.frames.isEmpty)
        #expect(log.corrupt.isEmpty)
        // unit index past the total, zero length, one-byte source unit, S too large, wireLen > S, duplicates.
        r.feed(frame: 1, index: 5, total: 3, fec: 0, payload: [0, 0, 1])
        r.feed(frame: 1, index: 0, total: 3, fec: 0, payload: [])
        r.feed(frame: 1, index: 0, total: 3, fec: 0, payload: [7])
        r.feed(frame: 1, index: 0, total: 3, fec: 0, payload: [0xff, 0xff, 1])  // S = 65538
        r.feed(frame: 1, index: 0, total: 3, fec: 0, payload: [0, 0, 1, 2])  // S = 4
        r.feed(frame: 1, index: 1, total: 3, fec: 0, payload: [0, 0, 1, 2, 3, 4, 5])  // 7 > 4
        r.feed(frame: 1, index: 0, total: 3, fec: 0, payload: [0, 0, 9, 9])  // duplicate
        r.feed(frame: 1, index: 1, total: 3, fec: 1, payload: [0, 0, 1, 2])  // different m
        r.feed(frame: 1, index: 1, total: 4, fec: 0, payload: [0, 0, 1, 2])  // different n
        r.feed(frame: 1, index: 2, total: 3, fec: 0, payload: [0, 0, 5, 6])
        #expect(log.frames.isEmpty)  // unit 1 never arrived; unit 2 ended the frame
        #expect(log.corrupt == [[1, 1]])
    }

    @Test("a frame bigger than 256 units can't use FEC but still assembles when complete")
    func overTwoFiftySix() {
        let log = VideoLog()
        let r = log.makeReceiver()
        for i in 0..<300 { r.feed(frame: 1, index: i, total: 301, fec: 1, payload: [0, 0, UInt8(i & 0xff)]) }
        #expect(log.frames.count == 1)
        #expect(log.frames[0].bytes.count == 300)
        // One missing: FEC isn't possible with k + m > 256.
        for i in 0..<300 where i != 4 { r.feed(frame: 2, index: i, total: 301, fec: 1, payload: [0, 0, 1]) }
        r.feed(frame: 2, index: 300, total: 301, fec: 1, payload: [0, 0, 1])
        single(r, 3)
        #expect(log.frames.count == 2)
        #expect(log.corrupt == [[2, 2], [2, 2]])
    }

    @Test("a rebuilt unit whose pad prefix is nonsense fails the frame")
    func nonsenseRecovery() {
        let log = VideoLog()
        let r = log.makeReceiver()
        // k = 2, m = 1, S = 4. Parity is for unit 0 = 0xffff....: pad 65535 >= S. Source 1 is received.
        let d0: [UInt8] = [0xff, 0xff, 1, 2]
        let d1: [UInt8] = [0, 0, 3, 4]
        let parity = ReferenceFEC.encode(source: [d0, d1], m: 1)[0]
        r.feed(frame: 1, index: 1, total: 3, fec: 1, payload: d1)
        r.feed(frame: 1, index: 2, total: 3, fec: 1, payload: parity)
        #expect(log.frames.isEmpty)
        single(r, 2)
        #expect(log.corrupt == [[1, 1], [1, 1]])
    }

    @Test("fuzz: random headers and payloads never trap")
    func fuzz() {
        var rng = SeededRandom(77)
        let log = VideoLog()
        let r = log.makeReceiver(profiles: [
            VideoProfile(width: 1, height: 1, header: StreamFixtures.h264Header()),
            VideoProfile(width: 1, height: 1, header: StreamFixtures.hevcHeader()),
        ])
        for _ in 0..<20000 {
            let count = Int.random(in: 0...60, using: &rng)
            let payload = (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }
            let word = UInt32.random(in: 0...UInt32.max, using: &rng)
            let narrowed = Bool.random(using: &rng) ? (word & 0x001f_fc07) | (UInt32.random(in: 0...3, using: &rng) << 21) : word
            let frame = UInt16.random(in: 0...6, using: &rng)
            payload.withUnsafeBytes {
                r.receive(
                    AVUnit(
                        kind: .video, frameIndex: frame, unitWord: narrowed, codec: 3,
                        adaptiveStreamIndex: UInt8.random(in: 0...3, using: &rng), payload: $0))
            }
        }
        #expect(r.statistics.framesHandedOver == log.frames.count)
        #expect(log.frames.allSatisfy { !$0.bytes.isEmpty })
    }

    // MARK: Slice-aware rules

    /// Sends access unit `nal` (a single NAL unit) as one frame.
    func frame(_ r: VideoReceiver, _ f: UInt16, nal: [UInt8]) {
        r.feed(frame: f, index: 0, total: 1, fec: 0, payload: [0, 0] + annexB(nal))
    }

    func h264Log() -> (VideoLog, VideoReceiver) {
        let log = VideoLog()
        return (log, log.makeReceiver(profiles: [VideoProfile(width: 1, height: 1, header: StreamFixtures.h264Header())]))
    }

    func hevcLog() -> (VideoLog, VideoReceiver) {
        let log = VideoLog()
        return (log, log.makeReceiver(profiles: [VideoProfile(width: 1, height: 1, header: StreamFixtures.hevcHeader())]))
    }

    @Test("H.264: a P frame whose reference is missing is dropped, then the stream waits for an IDR")
    func h264MissingReference() {
        let (log, r) = h264Log()
        frame(r, 1, nal: StreamFixtures.h264Slice(idr: true, sliceType: 7))
        frame(r, 2, nal: StreamFixtures.h264Slice(idr: false, sliceType: 5, frameNum: 1))
        #expect(log.frames.map(\.info.isKeyFrame) == [true, false])
        // Frame 3 never arrives; frame 4 refers to it (distance 0).
        frame(r, 4, nal: StreamFixtures.h264Slice(idr: false, sliceType: 5, frameNum: 3))
        #expect(log.frames.count == 2)
        // No IDR request and no waiting state: the corrupt-frame report of the next frame covers it.
        #expect(log.idr.isEmpty)
        #expect(log.corrupt == [[3, 3]])  // the gap before frame 4
        frame(r, 5, nal: StreamFixtures.h264Slice(idr: false, sliceType: 5, frameNum: 4))
        #expect(log.corrupt == [[3, 3], [3, 4]])
        #expect(log.frames.count == 2)
        #expect(log.idr.isEmpty)
        // An IDR gets the stream going again, and the frame after it refers to the IDR.
        frame(r, 7, nal: StreamFixtures.h264Slice(idr: true, sliceType: 7))
        frame(r, 8, nal: StreamFixtures.h264Slice(idr: false, sliceType: 5, frameNum: 1))
        #expect(log.frames.map(\.info.frameIndex) == [1, 2, 7, 8])
        #expect(log.frames[2].info.framesLost == 4)
        #expect(r.statistics.framesDropped == 2)
    }

    @Test("the default-off option asks for a key frame on a missing reference, then waits for it")
    func missingReferenceOption() {
        let log = VideoLog()
        let r = VideoReceiver(
            callbacks: VideoCallbacks(
                accessUnit: { b, i in
                    log.frames.append(.init(bytes: Array(b), info: i))
                    return true
                },
                parameterSets: { _, _, _ in }, corruptFrames: { _, _ in }, needsIDR: { log.idr.append($0) }),
            idrOnMissingReference: true, clock: { log.now })
        r.setProfiles([VideoProfile(width: 1, height: 1, header: StreamFixtures.h264Header())])
        frame(r, 1, nal: StreamFixtures.h264Slice(idr: true, sliceType: 7))
        frame(r, 3, nal: StreamFixtures.h264Slice(idr: false, sliceType: 5, frameNum: 2))
        #expect(log.idr == [.missingReference])
        frame(r, 4, nal: StreamFixtures.h264Slice(idr: false, sliceType: 5, frameNum: 3))
        #expect(log.frames.count == 1)
    }

    @Test("H.264: a P frame referring several frames back through the modification list")
    func h264LongReference() {
        let (log, r) = h264Log()
        frame(r, 1, nal: StreamFixtures.h264Slice(idr: true, sliceType: 7))
        for f in 2...7 { frame(r, UInt16(f), nal: StreamFixtures.h264Slice(idr: false, sliceType: 5, frameNum: f - 1, distance: 0)) }
        frame(r, 8, nal: StreamFixtures.h264Slice(idr: false, sliceType: 5, frameNum: 7, distance: 5))  // frame 2
        #expect(log.frames.count == 8)
        frame(r, 9, nal: StreamFixtures.h264Slice(idr: false, sliceType: 5, frameNum: 8, distance: 20))  // not in refs
        #expect(log.frames.count == 8)
    }

    @Test("HEVC: a missing reference is rewritten to the nearest older one, and flagged recovered")
    func hevcRewrite() {
        let (log, r) = hevcLog()
        frame(r, 1, nal: StreamFixtures.hevcSlice(type: 20, sliceType: 2))
        frame(r, 2, nal: StreamFixtures.hevcSlice(type: 1, sliceType: 1, pocLsb: 2, negatives: 4, used: 0))
        #expect(log.frames.map(\.info.recovered) == [false, false])
        // Frame 3 is lost; frame 4 points at it (d = 0). Frame 2 is d' = 1.
        let nal = StreamFixtures.hevcSlice(type: 1, sliceType: 1, pocLsb: 4, negatives: 4, used: 0)
        frame(r, 4, nal: nal)
        #expect(log.frames.count == 3)
        guard log.frames.count == 3 else { return }
        #expect(log.frames[2].info.recovered)
        #expect(log.frames[2].info.framesLost == 1)
        #expect(r.statistics.framesRewritten == 1)
        let parser = SliceParser()
        let params = VideoProfileInfo(header: StreamFixtures.hevcHeader()).hevc
        let rewritten = withBytes(log.frames[2].bytes) { parser.firstSlice(in: $0, codec: .hevc, h264: nil, hevc: params) }
        #expect(rewritten?.referenceDistance == 1)
        // Frame 5 refers to frame 4 (d = 0), which was handed over.
        frame(r, 5, nal: StreamFixtures.hevcSlice(type: 1, sliceType: 1, pocLsb: 5, negatives: 4, used: 0))
        #expect(log.frames.count == 4)
        #expect(!log.frames[3].info.recovered)
        #expect(log.idr.isEmpty)
    }

    @Test("HEVC: no usable older reference, or too few negative pictures, drops the frame")
    func hevcNoRewrite() {
        let (log, r) = hevcLog()
        frame(r, 1, nal: StreamFixtures.hevcSlice(type: 20, sliceType: 2))
        // Frame 10 refers to 9 (missing); older candidates 8..: none are references except frame 1 at d' = 8.
        frame(r, 10, nal: StreamFixtures.hevcSlice(type: 1, sliceType: 1, negatives: 4, used: 0))
        #expect(log.frames.count == 1)  // d' = 8 would be needed, but only 4 negatives exist: rewrite fails
        #expect(log.idr.isEmpty)
        // Past the 15-picture reach.
        let (log2, r2) = hevcLog()
        frame(r2, 1, nal: StreamFixtures.hevcSlice(type: 20, sliceType: 2))
        frame(r2, 30, nal: StreamFixtures.hevcSlice(type: 1, sliceType: 1, negatives: 16, used: 0))
        #expect(log2.frames.count == 1)
        frame(r2, 31, nal: StreamFixtures.hevcSlice(type: 1, sliceType: 1, negatives: 16, used: 15))
        #expect(log2.frames.count == 1)
    }

    @Test("HEVC: a P slice with an unknown reference is handed over unchecked")
    func hevcUnknownReference() {
        let (log, r) = hevcLog()
        frame(r, 1, nal: StreamFixtures.hevcSlice(type: 1, sliceType: 1, negatives: 2, used: nil))
        #expect(log.frames.count == 1)
    }

    @Test("a frame whose first NAL isn't a slice is handed over without IDR or reference logic")
    func nonSliceFrame() {
        let (log, r) = h264Log()
        frame(r, 1, nal: [0x67, 1, 2, 3])
        #expect(log.frames.count == 1)
        #expect(log.frames[0].info.isKeyFrame == nil)
    }

    @Test("an IDR request that is outstanding is cleared by an I slice after FEC failure")
    func idrClearsAfterFECFailure() {
        let (log, r) = h264Log()
        frame(r, 1, nal: StreamFixtures.h264Slice(idr: true, sliceType: 7))
        r.feed(frame: 2, index: 0, total: 2, fec: 0, payload: [0, 0, 1])
        frame(r, 3, nal: StreamFixtures.h264Slice(idr: false, sliceType: 5, frameNum: 2))
        #expect(log.idr == [.fecFailed])
        #expect(log.frames.count == 1)
        frame(r, 4, nal: StreamFixtures.h264Slice(idr: true, sliceType: 7))
        #expect(log.frames.count == 2)
        frame(r, 5, nal: StreamFixtures.h264Slice(idr: false, sliceType: 5, frameNum: 1))
        #expect(log.frames.count == 3)
    }

    @Test("setProfiles starts a new stream")
    func restart() {
        let (log, r) = h264Log()
        frame(r, 1, nal: StreamFixtures.h264Slice(idr: true, sliceType: 7))
        r.setProfiles([VideoProfile(width: 1, height: 1, header: StreamFixtures.h264Header())])
        frame(r, 1, nal: StreamFixtures.h264Slice(idr: true, sliceType: 7))
        #expect(log.frames.count == 2)
        #expect(log.parameterSets == [0, 0])
        #expect(log.frames[1].info.framesLost == 0)
    }

    @Test("a frame with a recovered unit needs no allocation of its own: buffers are reused")
    func manyFramesReuseBuffers() {
        let log = VideoLog()
        let r = log.makeReceiver()
        for f in 1...200 { send(r, frame: UInt16(f), units: [1, 3, 4]) }
        #expect(log.frames.count == 200)
        #expect(log.frames.allSatisfy { $0.bytes == Self.accessUnit })
    }

    @Test("AVReceiver routes video, audio and haptics and rejects a bad audio header")
    func router() {
        let log = VideoLog()
        let audio = Locked<[String]>([])
        let haptics = Locked<[UInt16]>([])
        let av = AVReceiver(
            video: VideoCallbacks(
                accessUnit: { b, i in
                    log.frames.append(.init(bytes: Array(b), info: i))
                    return true
                },
                parameterSets: { _, _, _ in }, corruptFrames: { _, _ in }, needsIDR: { _ in }),
            audio: { event in
                if case .packet(let f, _) = event { audio.with { $0.append("p\(f)") } }
            },
            haptics: { f, _ in haptics.with { $0.append(f) } })
        #expect(!av.setStreamInfo(profiles: [VideoProfile(width: 1, height: 1, header: [])], audioHeader: [1, 2]))
        #expect(av.setStreamInfo(profiles: [VideoProfile(width: 1, height: 1, header: [])], audioHeader: AudioHeader(channels: 2, bitsPerSample: 16, sampleRate: 48000, frameSize: 480).bytes))
        [UInt8]([0, 0, 1, 2]).withUnsafeBytes {
            av.receive(AVUnit(kind: .video, frameIndex: 1, unitWord: videoWord(index: 0, total: 1, fec: 0), codec: 3, payload: $0))
        }
        #expect(log.frames.count == 1)
        let word = audioWord(total: 1, unitSize: 4, redundant: 0, source: 1)
        [UInt8](repeating: 1, count: 4).withUnsafeBytes {
            av.receive(AVUnit(kind: .audio, frameIndex: 5, unitWord: word, codec: 5, streamByte: 0x02, payload: $0))
            av.receive(AVUnit(kind: .audio, frameIndex: 5, unitWord: word, codec: 5, streamByte: 0x00, payload: $0))
            av.receive(AVUnit(kind: .audio, frameIndex: 5, unitWord: word, codec: 5, payload: $0))
        }
        #expect(haptics.with { $0 } == [5])
        #expect(av.audio.packetsReceived == 2)
    }
}
