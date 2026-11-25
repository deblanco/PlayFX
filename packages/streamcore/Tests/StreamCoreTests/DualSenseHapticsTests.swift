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

    @Test func theAudioHapticsReportIs48ZeroBytesAfterID2() {
        #expect(DualSenseModeReport.bytes.count == 48)
        #expect(DualSenseModeReport.bytes[0] == 0x02)
        #expect(DualSenseModeReport.bytes.dropFirst().allSatisfy { $0 == 0 }) // every "valid" flag clear: nothing else changes
    }

    @Test func describesTheOutputsForTheLog() {
        #expect(DualSenseHaptics.describe([speakers, interface]) == "MacBook Pro Speakers (2 ch), Studio Interface (8 ch)")
        #expect(DualSenseHaptics.describe([]) == "none")
        #expect(USBHapticsMode.describe(kIOReturnNotPermitted) == "IOReturn 0xe00002e2")
    }

    @Test func looksForAUSBPadWithoutWritingToIt() {
        // The hardware adapter's lookup, on whatever this Mac has (CI: nothing). Nothing is sent: a found pad is
        // only let go again.
        USBPadHID.find()?.close()
        #expect(USBPadHID.products == [0x0ce6, 0x0df2])
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
        let bluetooth = OSAllocatedUnfairLock<BluetoothPad?>(initialState: nil)
        let openedBluetooth = OSAllocatedUnfairLock<[StandInOutput]>(initialState: [])

        /// The USB pad's HID interface: records the reports written to it.
        final class StandInSink: PadReportSink {
            let result: IOReturn
            let reports = OSAllocatedUnfairLock<[[UInt8]]>(initialState: [])
            let closed = OSAllocatedUnfairLock(initialState: false)
            init(result: IOReturn) { self.result = result }
            func send(_ report: [UInt8]) -> IOReturn {
                reports.withLock { $0.append(report) }
                return result
            }
            func close() { closed.withLock { $0 = true } }
        }

        /// Whether a USB HID pad is found, and what writing to it returns.
        let hid = OSAllocatedUnfairLock<IOReturn?>(initialState: kIOReturnSuccess)
        let sinks = OSAllocatedUnfairLock<[StandInSink]>(initialState: [])
        var reports: [[UInt8]] { sinks.withLock { $0.flatMap { $0.reports.withLock { $0 } } } }

        func withStandIns(failOpen: Bool = false, _ body: () throws -> Void) rethrows {
            let (realDevices, realOpen) = (DualSenseHaptics.devices, DualSenseHaptics.open)
            let (realPad, realOpenBluetooth) = (DualSenseHaptics.bluetoothPad, DualSenseHaptics.openBluetooth)
            let realFindPad = USBHapticsMode.findPad
            defer {
                (DualSenseHaptics.devices, DualSenseHaptics.open) = (realDevices, realOpen)
                (DualSenseHaptics.bluetoothPad, DualSenseHaptics.openBluetooth) = (realPad, realOpenBluetooth)
                USBHapticsMode.findPad = realFindPad
            }
            USBHapticsMode.findPad = { [hid, sinks] in
                guard let result = hid.withLock({ $0 }) else { return nil }
                let sink = StandInSink(result: result)
                sinks.withLock { $0.append(sink) }
                return sink
            }
            DualSenseHaptics.bluetoothPad = { [bluetooth] in bluetooth.withLock { $0 } }
            DualSenseHaptics.openBluetooth = { [openedBluetooth] _, _ in
                if failOpen { return nil }
                let output = StandInOutput()
                openedBluetooth.withLock { $0.append(output) }
                return output
            }
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

        @Test func theProcessEndingStopsThemOnThePad() {
            withStandIns {
                defer { PadQuiet.ending.withLock { $0 = false } }
                let haptics = DualSenseHaptics()
                devices.withLock { $0 = [quad] }
                _ = push(haptics, at: 0)
                #expect(haptics.isPlaying)
                PadQuiet.now() // the app quitting, or a signal
                #expect(!haptics.isPlaying && opened.withLock { $0.last?.stopped.withLock { $0 } == true })
                #expect(!push(haptics, at: 100)) // and they don't start again
            }
        }

        @Test func sendsToAPadOnBluetoothWhenNoUSBPadCanPlay() {
            withStandIns {
                let haptics = DualSenseHaptics()
                bluetooth.withLock { $0 = BluetoothPad(name: "DualSense Wireless Controller", id: 42, device: nil) }
                _ = push(haptics, at: 0)
                #expect(haptics.isPlaying && openedBluetooth.withLock { $0.count } == 1)
                // The 3 kHz audio goes to the Bluetooth queue as it comes, not to the USB output's buffer.
                #expect(push(haptics, at: 0.5))
                #expect(haptics.bluetoothQueue.levels(now: 0.5).queued == 30 && haptics.buffer.bufferedFrames == 0)
                _ = push(haptics, at: 2)
                #expect(openedBluetooth.withLock { $0.count } == 1) // the same pad: kept open

                // A pad plugged in over USB (with 4 channels) takes over.
                devices.withLock { $0 = [quad] }
                _ = push(haptics, at: 4)
                #expect(opened.withLock { $0.count } == 1 && openedBluetooth.withLock { $0[0].stopped.withLock { $0 } })
                #expect(push(haptics, at: 4.5) && haptics.buffer.bufferedFrames > 0)

                // Unplugged, and the Bluetooth pad gone too: rumble.
                devices.withLock { $0 = [] }
                bluetooth.withLock { $0 = nil }
                _ = push(haptics, at: 7)
                #expect(!haptics.isPlaying)
            }
        }

        @Test func staysOnRumbleWhenTheBluetoothPadCantBeOpened() {
            withStandIns(failOpen: true) {
                let haptics = DualSenseHaptics()
                bluetooth.withLock { $0 = BluetoothPad(name: "DualSense", id: 1, device: nil) }
                _ = push(haptics, at: 0)
                _ = push(haptics, at: 2) // tried again, said once
                #expect(!haptics.isPlaying && !push(haptics, at: 2.5))
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

        /// The log entries mentioning `text` while `body` runs.
        func logged(_ text: String, _ body: () -> Void) -> [Log.Entry] {
            let entries = OSAllocatedUnfairLock<[Log.Entry]>(initialState: [])
            Log.configure(detailed: false) { entry in if entry.message.contains(text) { entries.withLock { $0.append(entry) } } }
            defer { Log.configure(detailed: false, sink: nil) }
            body()
            return entries.withLock { $0 }
        }

        @Test func switchesAUSBPadIntoAudioHapticsWhileTheyPlay() {
            withStandIns {
                let pad = DualSenseHaptics.Device(id: 9, name: "DualSense Pad For The Mode Test", outputChannels: 4)
                let log = logged("Pad For The Mode Test") {
                    let haptics = DualSenseHaptics()
                    devices.withLock { $0 = [pad] }
                    _ = push(haptics, at: 0) // haptics start on USB: the report goes at once
                    #expect(haptics.isPlaying && reports == [DualSenseModeReport.bytes])
                    #expect(push(haptics, at: 0.5) && reports.count == 1)
                    _ = push(haptics, at: 1) // about once a second while frames keep coming
                    #expect(reports.count == 2)
                    _ = push(haptics, at: 1.5)
                    _ = push(haptics, at: 2) // a device check too: the same pad, kept
                    #expect(reports.count == 3 && sinks.withLock { $0.count } == 1) // the HID device found once
                    #expect(reports.allSatisfy { $0 == DualSenseModeReport.bytes })

                    devices.withLock { $0 = [] } // unplugged: haptics stop, the HID device is let go
                    _ = push(haptics, at: 4)
                    #expect(!haptics.isPlaying && sinks.withLock { $0[0].closed.withLock { $0 } })
                    _ = push(haptics, at: 5.5)
                    #expect(reports.count == 3) // nothing more once they've stopped
                }
                #expect(log.map(\.message) == ["DualSense haptics: playing on DualSense Pad For The Mode Test (USB)",
                                               "DualSense haptics: audio haptics enabled on DualSense Pad For The Mode Test (USB)"])
                #expect(log.allSatisfy { $0.level == .info })
            }
        }

        @Test func sendsItAgainSoonAfterTheAppsOwnPadOutput() {
            withStandIns {
                let haptics = DualSenseHaptics()
                devices.withLock { $0 = [quad] }
                _ = push(haptics, at: 0)
                #expect(reports.count == 1)
                USBHapticsMode.padOutputSent() // e.g. a rumble or trigger effect through GameController
                _ = push(haptics, at: 0.05)
                #expect(reports.count == 1) // not on top of GameController's own report
                _ = push(haptics, at: 0.15)
                #expect(reports.count == 2) // shortly after it
                haptics.stop()
                haptics.waitUntilIdle()
                #expect(sinks.withLock { $0[0].closed.withLock { $0 } }) // the session ended: the HID device let go
            }
        }

        @Test func neverOnBluetoothNorWithoutAPad() {
            withStandIns {
                let haptics = DualSenseHaptics()
                for second in 0..<3 { _ = push(haptics, at: Double(second)) } // no pad at all
                bluetooth.withLock { $0 = BluetoothPad(name: "DualSense Wireless Controller", id: 42, device: nil) }
                for second in 3..<8 { _ = push(haptics, at: Double(second)) }
                #expect(haptics.isPlaying && openedBluetooth.withLock { $0.count } == 1) // played over Bluetooth
                #expect(sinks.withLock { $0.isEmpty } && reports.isEmpty) // and no USB HID device looked for
            }
        }

        @Test func aFailedReportIsLoggedOnceAndTheHapticsPlayOn() {
            withStandIns {
                hid.withLock { $0 = nil } // no HID device for the sound device
                let pad = DualSenseHaptics.Device(id: 10, name: "DualSense Pad Without HID", outputChannels: 4)
                let missing = logged("Pad Without HID") {
                    let haptics = DualSenseHaptics()
                    devices.withLock { $0 = [pad] }
                    for t in stride(from: 0.0, through: 3, by: 0.5) { #expect(push(haptics, at: t) || t == 0) }
                    #expect(haptics.isPlaying && haptics.buffer.bufferedFrames > 0)
                }
                #expect(missing.filter { $0.level == .warning }.map(\.message)
                    == ["DualSense haptics: couldn't enable audio haptics on DualSense Pad Without HID: no DualSense HID device on USB"])

                hid.withLock { $0 = kIOReturnNotPermitted } // found, but the write fails
                let refused = DualSenseHaptics.Device(id: 11, name: "DualSense Pad Refusing Reports", outputChannels: 4)
                let failed = logged("Pad Refusing Reports") {
                    let haptics = DualSenseHaptics()
                    devices.withLock { $0 = [refused] }
                    for t in stride(from: 0.0, through: 3, by: 0.5) { _ = push(haptics, at: t) }
                    #expect(haptics.isPlaying && push(haptics, at: 3.2))
                }
                #expect(failed.filter { $0.level == .warning }.map(\.message)
                    == ["DualSense haptics: couldn't enable audio haptics on DualSense Pad Refusing Reports: the HID report failed "
                        + "(IOReturn 0xe00002e2)"])
                // Each failure lets go of the device and looks again next time (it may have been replugged).
                #expect(sinks.withLock { $0.count } == 4 && sinks.withLock { $0.allSatisfy { $0.closed.withLock { $0 } } })
            }
        }

        @Test func saysOnceASessionWhenNoPadIsFoundWithTheMacsOutputs() {
            withStandIns {
                devices.withLock { $0 = [DualSenseHaptics.Device(id: 1, name: "Speakers Of The No-Pad Test", outputChannels: 2)] }
                let log = logged("Speakers Of The No-Pad Test") {
                    let haptics = DualSenseHaptics()
                    for second in 0..<5 { _ = push(haptics, at: Double(second)) }
                }
                #expect(log.map(\.message) == ["DualSense haptics: no DualSense sound device on USB and no DualSense on "
                    + "Bluetooth; playing them as rumble. The Mac's sound outputs: Speakers Of The No-Pad Test (2 ch)"])
                #expect(log.first?.level == .info)
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
