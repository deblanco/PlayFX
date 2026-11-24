import Foundation
import IOKit.hid
import os

// A DualSense on USB is a 4-channel sound device whose channels 3 and 4 drive its haptic actuators, but on macOS
// audio on them does nothing until the pad is switched into audio-haptics mode. One HID output report 0x02 with
// every byte after the ID zero does it: all its "valid" flags are clear, so rumble, light bar, triggers and volumes
// stay as they are. Found on a real pad (2026-11-24): before the report nothing was felt, after it the audio was; a
// report with only the "haptics select" flag set didn't do it. The pad forgets it when unplugged, and GameController's
// own output reports (rumble, triggers, light bar) may switch it back to rumble emulation, so the report is sent again
// while the haptics play.

/// HID output report 0x02 (USB) with nothing in it.
enum DualSenseModeReport {
    static let id: UInt8 = 0x02
    /// The pad's kIOHIDMaxOutputReportSizeKey on USB, the ID included.
    static let size = 48
    static let bytes: [UInt8] = [id] + [UInt8](repeating: 0, count: size - 1)
}

/// A DualSense's HID interface on USB, where the report is written (stand-ins in tests).
protocol PadReportSink: AnyObject {
    /// Writes an output report (its first byte is the ID).
    func send(_ report: [UInt8]) -> IOReturn
    func close()
}

/// Keeps a pad on USB in audio-haptics mode while its haptics play: `DualSenseHaptics` calls `enable` when they start
/// on USB and about once a second after, and `reset` when they stop. Only on DualSenseHaptics' queue.
final class USBHapticsMode: @unchecked Sendable {
    /// How often the report is sent again while haptics play.
    static let resendInterval: TimeInterval = 1
    /// How long after the app's own rumble, trigger or light bar output the report is sent again.
    static let afterPadOutput: TimeInterval = 0.1

    /// The first DualSense on USB, if any (replaced in tests; none in a test run, see `PadHardware`).
    nonisolated(unsafe) static var findPad: () -> PadReportSink? = { PadHardware.allowed ? USBPadHID.find() : nil }

    /// Counts the times the app drove a pad through GameController (whose reports may switch the pad back to rumble
    /// emulation); each `DualSenseHaptics` compares it with the count it saw last.
    private static let padOutputs = OSAllocatedUnfairLock(initialState: UInt64(0))

    /// The app's rumble, trigger or light bar output went to the pads. Thread-safe and cheap.
    static func padOutputSent() { padOutputs.withLock { $0 &+= 1 } }

    static var padOutputCount: UInt64 { padOutputs.withLock { $0 } }

    private var sink: PadReportSink?
    private var loggedEnabled = false
    private var loggedFailure = false

    /// Sends the report to the pad whose sound device is `name` (for the log). Failures are logged once and only
    /// leave the pad as it was: the haptics audio plays on either way.
    @discardableResult func enable(_ name: String) -> Bool {
        if sink == nil { sink = Self.findPad() }
        guard let sink else {
            failed("couldn't enable audio haptics on \(name): no DualSense HID device on USB")
            return false
        }
        let result = sink.send(DualSenseModeReport.bytes)
        guard result == kIOReturnSuccess else {
            reset() // looked for again next time: it may have been unplugged and plugged back
            failed("couldn't enable audio haptics on \(name): the HID report failed (\(Self.describe(result)))")
            return false
        }
        if !loggedEnabled {
            loggedEnabled = true
            Log.info(.input, "DualSense haptics: audio haptics enabled on \(name) (USB)")
        }
        return true
    }

    /// The haptics stopped on USB: lets go of the pad's HID device.
    func reset() {
        sink?.close()
        sink = nil
    }

    private func failed(_ message: String) {
        guard !loggedFailure else { return }
        loggedFailure = true
        Log.warning(.input, "DualSense haptics: \(message)")
    }

    static func describe(_ result: IOReturn) -> String { String(format: "IOReturn 0x%08x", UInt32(bitPattern: result)) }
}

/// The first DualSense (054C:0CE6) or DualSense Edge (054C:0DF2) on USB. Thin: needs a real pad.
final class USBPadHID: PadReportSink {
    static let products = [0x0ce6, 0x0df2]
    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private var opened = false

    private init(manager: IOHIDManager, device: IOHIDDevice) {
        self.manager = manager
        self.device = device
    }

    static func find() -> USBPadHID? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, products.map { product in
            [kIOHIDVendorIDKey: 0x054c, kIOHIDProductIDKey: product, kIOHIDTransportKey: "USB"] as CFDictionary
        } as CFArray)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = devices.first else { return nil }
        return USBPadHID(manager: manager, device: device)
    }

    /// Opens the device (not exclusively: GameController keeps it) on the first write.
    func send(_ report: [UInt8]) -> IOReturn {
        let open = opened ? kIOReturnSuccess : IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        opened = open == kIOReturnSuccess
        guard opened else { return open }
        return report.withUnsafeBufferPointer { IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex($0[0]), $0.baseAddress!, $0.count) }
    }

    func close() {
        if opened { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        opened = false
    }

    deinit { close() }
}
