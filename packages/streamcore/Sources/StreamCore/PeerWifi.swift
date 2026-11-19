import Darwin
import Foundation
import os

/// AWDL, the peer-to-peer Wi-Fi behind AirDrop, Handoff, Universal Control and wireless Sidecar.
///
/// The Mac has one Wi-Fi radio. To listen for nearby Apple devices it leaves the network's channel about
/// once a second, for around 90 ms, and a stream feels each of those as a stall. PlayFX can pause it while
/// it's open. Switching it off needs administrator rights, and macOS switches it back on by itself, so a
/// small helper running as root keeps it off: it stops, and switches AWDL back on, as soon as the marker
/// file is gone (the user turned it back on) or PlayFX's process has ended (quit or crash). One password
/// prompt per pause; none to resume. See docs/NETWORK.md.
public enum PeerWifi {
    public enum State: String, Codable, Sendable {
        /// No AWDL interface on this Mac.
        case absent
        /// On: the radio leaves the network's channel once a second.
        case active
        /// Off, but not by PlayFX.
        case off
        /// Kept off by PlayFX's helper.
        case paused
    }

    public enum Outcome: Equatable, Sendable {
        case done
        /// The password prompt was dismissed.
        case cancelled
        case failed(String)
    }

    /// The interface's name.
    static let interface = "awdl0"

    /// While this file exists the helper keeps AWDL off. In the user's own temporary folder (not the shared
    /// /tmp, where another account could create or hold the name), and per process, so a crashed run's
    /// leftover can't make a later one think it's paused. Removed when PlayFX exits.
    nonisolated(unsafe) static var markerPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("playfx-awdl-\(getpid())")

    /// Waits between checks while the helper brings AWDL back. Replaced in tests.
    nonisolated(unsafe) static var wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    /// True while the password prompt is open: the marker already exists (the helper needs it from its
    /// first check) but nothing is paused yet.
    private static let pausing = OSAllocatedUnfairLock(initialState: false)

    /// One change at a time: a second pause while the first prompt is open (a double click) waits for it and
    /// then finds AWDL paused, instead of opening a second prompt whose cancel would remove the marker the
    /// first helper is watching.
    private static let changing = NSLock()

    /// Removes the marker when PlayFX exits normally (the helper also stops on its own once PlayFX is gone).
    private static let removeMarkerOnExit: Void = {
        atexit { try? FileManager.default.removeItem(atPath: PeerWifi.markerPath) }
    }()

    /// Whether a path can go into the root helper's command line as is: no spaces, quotes or shell syntax.
    static func isPlainPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/._-".contains($0)) }
    }

    /// Runs an AppleScript (`osascript -e`); returns its exit status and error output. Replaced in tests.
    nonisolated(unsafe) static var runAppleScript: (String) -> (status: Int32, error: String) = { script in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        process.waitUntilExit()
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, text)
    }

    /// Whether the interface is up; nil when there is none. Replaced in tests.
    nonisolated(unsafe) static var interfaceUp: () -> Bool? = {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) where String(cString: entry.pointee.ifa_name) == interface {
            return entry.pointee.ifa_flags & UInt32(IFF_UP) != 0
        }
        return nil
    }

    /// The state now.
    public static var state: State {
        let ours = FileManager.default.fileExists(atPath: markerPath) && !pausing.withLock { $0 }
        return state(interfaceUp: interfaceUp(), markerExists: ours)
    }

    /// The state from the interface's flags and our marker. While the marker exists the helper is keeping
    /// AWDL off, even in the half second after macOS switches it back on and before the helper notices.
    static func state(interfaceUp: Bool?, markerExists: Bool) -> State {
        guard let up = interfaceUp else { return .absent }
        if markerExists { return .paused }
        return up ? .active : .off
    }

    /// What the root helper runs: keep AWDL off while the marker exists and PlayFX (`pid`) is alive, then
    /// switch it back on.
    static func helperCommand(marker: String, pid: Int32) -> String {
        "while [ -e \(marker) ] && /bin/kill -0 \(pid) 2>/dev/null; do /sbin/ifconfig \(interface) down; /bin/sleep 0.5; done; "
            + "/sbin/ifconfig \(interface) up"
    }

    /// The AppleScript that asks for the password and starts the helper in the background as root.
    static func pauseScript(marker: String, pid: Int32) -> String {
        let helper = helperCommand(marker: marker, pid: pid)
        let prompt = "PlayFX wants to pause AirDrop and Handoff while it's open, so your Wi-Fi stops stalling "
            + "once a second. They come back when you turn this off or quit PlayFX."
        return "do shell script \"/bin/sh -c '\(helper)' > /dev/null 2>&1 &\" with prompt \"\(prompt)\" with administrator privileges"
    }

    /// Pauses AWDL until `resume()` or PlayFX quits. Asks for the administrator password (or Touch ID).
    /// Also when it reads as off at this instant: macOS switches it off and on by itself, so it would
    /// come back unwatched. Nothing to do without AWDL, or when it's paused already.
    public static func pause() -> Outcome {
        changing.lock()
        defer { changing.unlock() }
        guard [.active, .off].contains(state) else { return .done }
        let marker = markerPath
        guard isPlainPath(marker) else { return .failed("Unexpected temporary folder \(marker)") }
        _ = removeMarkerOnExit
        pausing.withLock { $0 = true }
        defer { pausing.withLock { $0 = false } }
        guard FileManager.default.createFile(atPath: marker, contents: nil) else {
            return .failed("Couldn't create \(marker)")
        }
        let result = runAppleScript(pauseScript(marker: marker, pid: getpid()))
        guard result.status == 0 else {
            try? FileManager.default.removeItem(atPath: marker)
            // osascript reports the dismissed prompt as error -128 ("User canceled.").
            if result.error.contains("-128") { return .cancelled }
            let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(message.isEmpty ? "osascript exited with \(result.status)" : message)
        }
        return .done
    }

    /// Lets AirDrop and Handoff back: the helper switches AWDL on and exits within half a second. Waits
    /// (up to 1.5 s) until it has, so the state returned is what follows, not the moment in between.
    @discardableResult
    public static func resume() -> State {
        changing.lock()
        defer { changing.unlock() }
        guard FileManager.default.fileExists(atPath: markerPath) else { return state }
        try? FileManager.default.removeItem(atPath: markerPath)
        var checks = 0
        while interfaceUp() == false, checks < 15 {
            wait(0.1)
            checks += 1
        }
        return state
    }
}
