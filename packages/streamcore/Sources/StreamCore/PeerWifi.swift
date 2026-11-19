import Darwin
import Foundation

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

    /// While this file exists the helper keeps AWDL off. Per process, so a crashed run's leftover can't
    /// make a later one think it's paused, and two copies of PlayFX can't stop each other's helper.
    /// Numeric parts only, so it can go into the root helper's command line as is.
    nonisolated(unsafe) static var markerPath = "/tmp/playfx-awdl-\(getuid())-\(getpid())"

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
        state(interfaceUp: interfaceUp(), markerExists: FileManager.default.fileExists(atPath: markerPath))
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
    /// Nothing to do when it's already off.
    public static func pause() -> Outcome {
        guard state == .active else { return .done }
        let marker = markerPath
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

    /// Lets AirDrop and Handoff back: the helper switches AWDL on and exits within half a second.
    public static func resume() {
        try? FileManager.default.removeItem(atPath: markerPath)
    }
}
