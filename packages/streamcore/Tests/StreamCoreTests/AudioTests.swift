import AVFoundation
import Testing
@testable import StreamCore

@Suite struct AudioRingTests {
    /// Renders `frames` frames into `channels` output buffers and returns them.
    func render(_ ring: inout AudioRing, frames: Int, channels: Int) -> [[Float]] {
        let buffers = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
        defer { buffers.forEach { $0.deallocate() } }
        buffers.forEach { $0.initialize(repeating: -9, count: frames) }
        ring.render(frames: frames, into: buffers.map(Optional.some))
        return buffers.map { Array(UnsafeBufferPointer(start: $0, count: frames)) }
    }

    func push(_ ring: inout AudioRing, _ samples: [Int16]) {
        samples.withUnsafeBufferPointer { ring.push($0.baseAddress!, frames: samples.count / ring.channels) }
    }

    @Test func unconfiguredRingIgnoresInputAndRendersSilence() {
        var ring = AudioRing()
        push(&ring, [1000, 2000])
        #expect(ring.count == 0)
        #expect(render(&ring, frames: 4, channels: 2) == [[0, 0, 0, 0], [0, 0, 0, 0]])
    }

    @Test func sizesFromSampleRate() {
        let ring = AudioRing(channels: 0, sampleRate: 1000)
        #expect(ring.channels == 1)
        #expect(ring.prebuffer == 30)
        #expect(ring.maxBuffered == 120)
        #expect(ring.storage.count == 1000)
    }

    @Test func waitsForPrebufferThenDeinterleaves() {
        var ring = AudioRing(channels: 2, sampleRate: 1000) // prebuffer 30 frames
        push(&ring, [Int16](repeating: 16384, count: 20))   // 10 frames
        #expect(render(&ring, frames: 5, channels: 2) == [[0, 0, 0, 0, 0], [0, 0, 0, 0, 0]])
        #expect(ring.count == 20)
        #expect(!ring.started)

        // 30 more frames: left = +0.5, right = -0.25.
        push(&ring, (0..<30).flatMap { _ in [Int16(16384), Int16(-8192)] })
        // Read past the first 10 frames (16384 on both channels) into the split ones, so a wrong channel
        // offset or stride shows up as the left sample on the right channel.
        let out = render(&ring, frames: 14, channels: 2)
        #expect(ring.started)
        #expect(out[0] == [Float](repeating: 0.5, count: 14))
        #expect(out[1] == [Float](repeating: 0.5, count: 10) + [Float](repeating: -0.25, count: 4))
        #expect(ring.count == 80 - 28)
    }

    @Test func underrunPadsWithSilenceAndRebuffers() {
        var ring = AudioRing(channels: 1, sampleRate: 100) // prebuffer 3 frames
        push(&ring, [3277, 3277, 3277, 3277])
        let out = render(&ring, frames: 6, channels: 1)[0]
        #expect(out.prefix(4).allSatisfy { abs($0 - 0.1) < 0.001 })
        #expect(out.suffix(2) == [0, 0])
        #expect(!ring.started)
        #expect(ring.count == 0)
    }

    @Test func dropsOldestAudioBeyondLatencyCap() {
        var ring = AudioRing(channels: 1, sampleRate: 100) // capacity 100 samples, cap 12 frames
        push(&ring, (0..<150).map { Int16($0) })              // wraps the ring, then trims to 12
        #expect(ring.count == 12)
        let out = render(&ring, frames: 12, channels: 1)[0]
        #expect(out == (138..<150).map { Float($0) / 32768 })
    }

    @Test func skipsMissingBuffersAndSilencesExtraChannels() {
        var ring = AudioRing(channels: 1, sampleRate: 100)
        push(&ring, [Int16](repeating: 32767, count: 5))
        let extra = UnsafeMutablePointer<Float>.allocate(capacity: 3)
        defer { extra.deallocate() }
        extra.initialize(repeating: 5, count: 3)
        ring.render(frames: 3, into: [nil, extra])
        #expect(Array(UnsafeBufferPointer(start: extra, count: 3)) == [0, 0, 0])
        #expect(ring.count == 2)
    }
}

@Suite struct AudioPlayerTests {
    @Test func pushAndRenderThroughTheEngineCallback() {
        let player = AudioPlayer()
        var pcm = [Int16](repeating: 16384, count: 48 * 2 * 40) // 40 ms stereo at 48 kHz
        player.push(&pcm, frames: 10) // before configure: ignored
        player.configure(channels: 2, sampleRate: 48000)
        pcm.withUnsafeBufferPointer { player.push($0.baseAddress!, frames: 48 * 40) }

        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        let frames = 64
        let storage = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
        defer { storage.forEach { $0.deallocate() } }
        for (i, p) in storage.enumerated() {
            list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: p)
        }
        player.render(frames: frames, into: list)
        // The engine may have consumed some audio already; whatever was rendered is either the tone or silence.
        #expect(storage.allSatisfy { p in (0..<frames).allSatisfy { p[$0] == 0.5 || p[$0] == 0 } })
        player.stop()
        player.stop()
    }
}
