import AudioToolbox
import CoreAudio
import Foundation
import os
import Testing
@testable import StreamCore

@Suite struct HapticsLogicTests {
    typealias Device = DualSenseHaptics.Device
    let quad = Device(id: 7, name: "DualSense Wireless Controller", outputChannels: 4)
    let stereo = Device(id: 8, name: "DualSense Wireless Controller", outputChannels: 2)
    let speakers = Device(id: 1, name: "MacBook Pro Speakers", outputChannels: 2)
    let interface = Device(id: 2, name: "Studio Interface", outputChannels: 8)

    @Test func choosesAFourChannelDualSense() {
        #expect(DualSenseHaptics.choose([speakers, interface, quad]) == .play(quad))
        #expect(DualSenseHaptics.choose([speakers, stereo]) == .stereoOnly(stereo)) // the motors aren't reachable
        #expect(DualSenseHaptics.choose([stereo, quad]) == .play(quad))
        #expect(DualSenseHaptics.choose([speakers, interface]) == .none) // 4+ channels, but no pad
        #expect(DualSenseHaptics.choose([]) == .none)
    }

    @Test func upsamplesTo48kHzContinuously() {
        var upsampler = HapticsUpsampler()
        let first = [Int16]([16384, -16384, 16384, -16384]).withUnsafeBufferPointer { upsampler.upsample($0) }
        #expect(first.count == 2 * 16 * 2) // two frames in, 32 out, stereo
        // From silence up to the first sample (a ramp, not a click), then flat.
        #expect(abs(first[0] - 0.5 / 16) < 1e-6 && abs(first[1] + 0.5 / 16) < 1e-6)
        #expect(first[30] == 0.5 && first[31] == -0.5)
        #expect(first[32...].enumerated().allSatisfy { i, v in v == (i.isMultiple(of: 2) ? 0.5 : -0.5) })
        // The next frame starts where this one ended.
        let next = [Int16]([0, 0]).withUnsafeBufferPointer { upsampler.upsample($0) }
        #expect(abs(next[0] - 0.5 * 15 / 16) < 1e-6 && next[30] == 0 && next[31] == 0)
        #expect([Int16]([1]).withUnsafeBufferPointer { upsampler.upsample($0) }.isEmpty) // no whole frame
    }

    @Test func buffersAtMost60ms() {
        let buffer = HapticsBuffer()
        buffer.append([Float](repeating: 0.1, count: 2000 * 2))
        #expect(buffer.bufferedFrames == 2000)
        buffer.append([Float](repeating: 0.2, count: 2000 * 2))
        #expect(buffer.bufferedFrames == HapticsBuffer.maxFrames) // the oldest dropped: the motors keep up with the game
    }

    @Test func rendersTheMotorsOnChannelsThreeAndFour() {
        let buffer = HapticsBuffer()
        buffer.append([0.25, -0.25, 0.5, -0.5])
        let (list, release) = audioBuffers(channels: 4, frames: 4, filledWith: 9)
        defer { release() }
        buffer.render(frames: 4, into: list)
        #expect(samples(list[0]) == [0, 0, 0, 0] && samples(list[1]) == [0, 0, 0, 0]) // the pad's speaker: silent
        #expect(samples(list[2]) == [0.25, 0.5, 0, 0]) // left motor, then silence once the buffer runs out
        #expect(samples(list[3]) == [-0.25, -0.5, 0, 0])
        #expect(buffer.bufferedFrames == 0)

        buffer.append([1, 1])
        let (two, releaseTwo) = audioBuffers(channels: 2, frames: 2, filledWith: 9)
        defer { releaseTwo() }
        buffer.render(frames: 2, into: two) // no motor channels: silence, nothing taken
        #expect(samples(two[0]) == [0, 0] && buffer.bufferedFrames == 1)
    }

    @Test func listsTheMacsOutputs() {
        // Whatever this Mac (or CI's VM) has: every entry is a named output.
        #expect(HapticsDevices.all().allSatisfy { !$0.name.isEmpty && $0.outputChannels > 0 })
    }

    @Test func opensAnOutputUnitOnARealDevice() throws {
        // The hardware adapter, on whatever output exists (the pad's 4 channels aren't needed to open it).
        guard let device = HapticsDevices.all().first else { return } // CI's VM may have none
        let buffer = HapticsBuffer()
        buffer.append([Float](repeating: 0, count: 960))
        let output = try #require(HapticsOutputUnit(device: device, buffer: buffer))
        output.stop()
        let gone = HapticsOutputUnit(device: Device(id: 0xDEAD_BEEF, name: "gone", outputChannels: 4), buffer: buffer)
        gone?.stop()
        #expect(gone == nil) // a device that isn't there
    }
}

/// `channels` non-interleaved float buffers of `frames` each, set to `value`.
private func audioBuffers(channels: Int, frames: Int, filledWith value: Float) -> (UnsafeMutableAudioBufferListPointer, () -> Void) {
    let list = AudioBufferList.allocate(maximumBuffers: channels)
    for i in 0..<channels {
        let data = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        data.initialize(repeating: value, count: frames)
        list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: data)
    }
    return (list, {
        for buffer in list { buffer.mData?.deallocate() }
        list.unsafeMutablePointer.deallocate()
    })
}

private func samples(_ buffer: AudioBuffer) -> [Float] {
    Array(UnsafeBufferPointer(start: buffer.mData?.assumingMemoryBound(to: Float.self), count: Int(buffer.mDataByteSize) / 4))
}

extension Serial {
    /// Swaps the device list and the output for stand-ins (process-wide statics).
    @Suite struct DualSenseHapticsTests {
        final class StandInOutput: DualSenseHaptics.Output {
            let stopped = OSAllocatedUnfairLock(initialState: false)
            func stop() { stopped.withLock { $0 = true } }
        }

        let quad = DualSenseHaptics.Device(id: 7, name: "DualSense Wireless Controller", outputChannels: 4)
        let devices = OSAllocatedUnfairLock<[DualSenseHaptics.Device]>(initialState: [])
        let opened = OSAllocatedUnfairLock<[StandInOutput]>(initialState: [])

        func withStandIns(failOpen: Bool = false, _ body: () throws -> Void) rethrows {
            let (realDevices, realOpen) = (DualSenseHaptics.devices, DualSenseHaptics.open)
            defer { (DualSenseHaptics.devices, DualSenseHaptics.open) = (realDevices, realOpen) }
            DualSenseHaptics.devices = { [devices] in devices.withLock { $0 } }
            DualSenseHaptics.open = { [opened] _, _ in
                if failOpen { return nil }
                let output = StandInOutput()
                opened.withLock { $0.append(output) }
                return output
            }
            try body()
        }

        func push(_ haptics: DualSenseHaptics, at now: TimeInterval) -> Bool {
            let played = [Int16](repeating: 1000, count: 60).withUnsafeBufferPointer { haptics.push($0, now: now) }
            haptics.waitUntilIdle()
            return played
        }

        @Test func playsOnAPadPluggedInAndFallsBackWhenItGoes() {
            withStandIns {
                let haptics = DualSenseHaptics()
                #expect(!push(haptics, at: 0)) // no pad: rumble
                devices.withLock { $0 = [quad] }
                #expect(!push(haptics, at: 1)) // not looked at again yet
                #expect(!push(haptics, at: 2)) // looked at (off the receive thread): this frame still rumbles
                #expect(haptics.isPlaying && push(haptics, at: 2.5))
                #expect(haptics.buffer.bufferedFrames > 0)
                #expect(push(haptics, at: 4.5) && opened.withLock { $0.count } == 1) // the same pad: kept open

                devices.withLock { $0 = [] } // unplugged
                _ = push(haptics, at: 7)
                #expect(!haptics.isPlaying && opened.withLock { $0[0].stopped.withLock { $0 } })
                #expect(!push(haptics, at: 7.5))
            }
        }

        @Test func waitsForFourChannelSoundAndStopsWithTheSession() {
            withStandIns {
                let haptics = DualSenseHaptics()
                devices.withLock { $0 = [DualSenseHaptics.Device(id: 8, name: "DualSense Wireless Controller", outputChannels: 2)] }
                _ = push(haptics, at: 0)
                #expect(!haptics.isPlaying) // set to 2 channels: rumble, and a hint in the log
                devices.withLock { $0 = [quad] }
                _ = push(haptics, at: 2)
                #expect(haptics.isPlaying)
                devices.withLock { $0 = [DualSenseHaptics.Device(id: 8, name: "DualSense Wireless Controller", outputChannels: 2)] }
                _ = push(haptics, at: 4)
                #expect(!haptics.isPlaying) // back to 2 channels

                devices.withLock { $0 = [quad] }
                _ = push(haptics, at: 6)
                #expect(haptics.isPlaying)
                haptics.stop()
                #expect(!haptics.isPlaying && opened.withLock { $0.last?.stopped.withLock { $0 } == true })
                #expect(!push(haptics, at: 100)) // a stopped session never opens the pad again
                #expect(!haptics.isPlaying)
            }
        }

        @Test func staysOnRumbleWhenThePadCantBeOpened() {
            withStandIns(failOpen: true) {
                let haptics = DualSenseHaptics()
                devices.withLock { $0 = [quad] }
                _ = push(haptics, at: 0)
                #expect(!haptics.isPlaying && !push(haptics, at: 0.5))
            }
        }

        @Test func aSessionPlaysHapticsOnThePadInsteadOfRumble() throws {
            try withStandIns {
                var options = StreamSession.Options()
                options.audio = false
                let session = try StreamSession(credentials: fakeCredentials(address: "192.0.2.1"), options: options)
                defer { session.stop() }
                let frame = [Int16](repeating: 500, count: 60)
                // No pad: not played, so the shim makes rumble from it (the pad's own path is tested above).
                #expect(!frame.withUnsafeBufferPointer { session.handleHaptics($0) })
            }
        }
    }
}
