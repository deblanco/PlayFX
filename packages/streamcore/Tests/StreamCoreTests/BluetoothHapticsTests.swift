import Foundation
import Testing
@testable import StreamCore

@Suite struct BluetoothHapticsTests {
    @Test func buildsReport0x32() {
        let samples = (0..<64).map { Int16(truncatingIfNeeded: $0 * 300 - 9000) }
        let report = DualSenseHapticsReport.build(samples, sequence: 0x13, counter: 7)
        #expect(report.count == 142)
        #expect(Array(report[0..<5]) == [0x32, 0x30, 0x91, 7, 0xfe])
        #expect(report[9] == 0x40 && report[10] == 7)
        #expect(report[11] == 0x92 && report[12] == 64)
        // Each sample narrowed to 8 bits, in order.
        #expect(report[13] == UInt8(bitPattern: DualSenseHapticsReport.narrow(samples[0])))
        #expect(report[76] == UInt8(bitPattern: DualSenseHapticsReport.narrow(samples[63])))
        #expect(report[77..<138].allSatisfy { $0 == 0 })
        // The CRC, as zlib.crc32(b"\xa2" + report[:138]) computes it (checked apart from this code).
        let crc = UInt32(report[138]) | UInt32(report[139]) << 8 | UInt32(report[140]) << 16 | UInt32(report[141]) << 24
        #expect(crc == ~DualSenseHapticsReport.crc32(0xffff_ffff, [0xa2] + report[0..<138]))
        // The standard check value of CRC-32: "123456789" → 0xCBF43926.
        #expect(~DualSenseHapticsReport.crc32(0xffff_ffff, Array("123456789".utf8)) == 0xcbf4_3926)
    }

    @Test func narrowsWithRoundingAndKnowsWhatIsAudible() {
        #expect(DualSenseHapticsReport.narrow(0) == 0)
        #expect(DualSenseHapticsReport.narrow(128) == 1 && DualSenseHapticsReport.narrow(127) == 0) // rounded, not cut
        #expect(DualSenseHapticsReport.narrow(-128) == -1)
        #expect(DualSenseHapticsReport.narrow(.max) == 127 && DualSenseHapticsReport.narrow(.min) == -128)
        #expect(!DualSenseHapticsReport.audible(300) && DualSenseHapticsReport.audible(600)) // one step is the floor
    }

    @Test func fitsAudioIntoBlocks() {
        let ramp = (0..<66).map { Int16($0 / 2 * 100) } // 33 frames, both channels the same ramp
        let squeezed = DualSenseHapticsReport.fit(ramp[...])
        #expect(squeezed.count == 64 && squeezed.first == 0 && squeezed.last == 3200) // ends kept
        let stretched = DualSenseHapticsReport.fit(ramp.prefix(62))
        #expect(stretched.count == 64 && stretched.first == 0 && stretched.last == 3000)
        #expect(DualSenseHapticsReport.fit(ramp.prefix(64)) == Array(ramp.prefix(64))) // 32: copied
        let tail = DualSenseHapticsReport.fit(ramp.prefix(20)) // the end of an effect: padded with silence
        #expect(tail.count == 64 && tail.suffix(44).allSatisfy { $0 == 0 })
    }

    @Test func pacesWithAReserve() {
        var pacer = HapticsPacer()
        // A stream doesn't start until there's a reserve, while audio is still coming.
        #expect(pacer.next(queued: 0, sinceAudio: 0, waited: 0) == .idle)
        #expect(pacer.next(queued: 60, sinceAudio: 0.005, waited: 0.02) == .idle)
        #expect(pacer.next(queued: 96, sinceAudio: 0.005, waited: 0.03) == .send(32))
        // Short of a block while audio still arrives: wait.
        #expect(pacer.next(queued: 20, sinceAudio: 0.01, waited: 0) == .wait)
        // The audio stopped: the rest goes out, then the effect is over.
        #expect(pacer.next(queued: 20, sinceAudio: 0.05, waited: 0) == .send(20))
        #expect(pacer.next(queued: 0, sinceAudio: 0.06, waited: 0) == .idle)
        // A short effect that has stopped arriving starts without the full reserve.
        pacer.reset()
        #expect(pacer.next(queued: 10, sinceAudio: 0.03, waited: 0.01) == .send(10))
    }

    @Test func keepsTheReserveByStretchingAndSqueezing() {
        var pacer = HapticsPacer()
        _ = pacer.next(queued: 96, sinceAudio: 0, waited: 0)
        // A reserve that stays low: blocks take 31 frames (stretched), building it back.
        for _ in 0..<20 { _ = pacer.next(queued: 40, sinceAudio: 0, waited: 0) }
        #expect(pacer.mode == -1 && pacer.next(queued: 40, sinceAudio: 0, waited: 0) == .send(31))
        for _ in 0..<20 { _ = pacer.next(queued: 90, sinceAudio: 0, waited: 0) }
        #expect(pacer.mode == 0)
        // One that stays high: 33 (squeezed), until it's back down.
        for _ in 0..<70 { _ = pacer.next(queued: 260, sinceAudio: 0, waited: 0) }
        #expect(pacer.mode == 1 && pacer.next(queued: 260, sinceAudio: 0, waited: 0) == .send(33))
        for _ in 0..<20 { _ = pacer.next(queued: 120, sinceAudio: 0, waited: 0) }
        #expect(pacer.mode == 0)
    }

    @Test func queuesAndMakesReports() {
        let queue = BluetoothHapticsQueue()
        var maker = HapticsReportMaker()
        let chunk = [Int16](repeating: 2000, count: 60) // 30 frames, 10 ms
        #expect(maker.next(queue, now: 0) == nil) // nothing queued
        for i in 0..<4 { chunk.withUnsafeBufferPointer { queue.append($0, now: Double(i) * 0.01) } }
        #expect(queue.levels(now: 0.04).queued == 120)
        let report = maker.next(queue, now: 0.04)
        #expect(report?.count == 142 && report?[1] == 0x00)
        #expect(queue.levels(now: 0.04).queued == 88)
        #expect(maker.next(queue, now: 0.05)?[1] == 0x10) // the sequence counts on
        // At most 600 frames are kept: the oldest audio goes.
        for i in 0..<30 { chunk.withUnsafeBufferPointer { queue.append($0, now: 1 + Double(i) * 0.001) } }
        #expect(queue.levels(now: 1.1).queued == BluetoothHapticsQueue.capacity)
        queue.clear()
        #expect(queue.levels(now: 1.1).queued == 0)
    }

    @Test func aStandInPadCantBeOpened() {
        #expect(BluetoothHapticsSender(pad: BluetoothPad(name: "DualSense", id: 1, device: nil), queue: BluetoothHapticsQueue()) == nil)
        #expect(BluetoothPad(name: "a", id: 1, device: nil) != BluetoothPad(name: "a", id: 2, device: nil))
    }

    @Test func choosesUSBThenBluetooth() {
        let pad = BluetoothPad(name: "DualSense", id: 3, device: nil)
        let quad = DualSenseHaptics.Device(id: 1, name: "DualSense Wireless Controller", outputChannels: 4)
        let stereo = DualSenseHaptics.Device(id: 2, name: "DualSense Wireless Controller", outputChannels: 2)
        #expect(DualSenseHaptics.choose([quad], bluetooth: pad) == .play(quad))
        #expect(DualSenseHaptics.choose([stereo], bluetooth: pad) == .stereoOnly(stereo))
        #expect(DualSenseHaptics.choose([], bluetooth: pad) == .bluetooth(pad))
        #expect(DualSenseHaptics.choose([], bluetooth: nil) == .none)
    }
}
