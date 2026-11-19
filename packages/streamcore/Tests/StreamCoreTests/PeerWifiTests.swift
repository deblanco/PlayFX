import Foundation
import Testing
@testable import StreamCore

extension Serial {
    /// PeerWifi's hooks are global, so these run one at a time.
    @Suite struct PeerWifiTests {
        /// Fakes the interface and the AppleScript runner, with a marker in a temporary folder.
        final class Fixture {
            var up: Bool? = true
            var scripts: [String] = []
            var reply: (status: Int32, error: String) = (0, "")
            /// What `state` said while the password prompt was open.
            var stateDuringPrompt: PeerWifi.State?
            var waits = 0
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent("playfx-awdl-test-\(UUID().uuidString)").path
            private let saved = (PeerWifi.interfaceUp, PeerWifi.runAppleScript, PeerWifi.markerPath, PeerWifi.wait)

            init() {
                PeerWifi.markerPath = marker
                PeerWifi.interfaceUp = { [unowned self] in up }
                PeerWifi.runAppleScript = { [unowned self] script in
                    scripts.append(script)
                    stateDuringPrompt = PeerWifi.state
                    return reply
                }
                PeerWifi.wait = { [unowned self] _ in waits += 1 }
            }

            deinit {
                try? FileManager.default.removeItem(atPath: marker)
                (PeerWifi.interfaceUp, PeerWifi.runAppleScript, PeerWifi.markerPath, PeerWifi.wait) = saved
            }

            var markerExists: Bool { FileManager.default.fileExists(atPath: marker) }
        }

        @Test func tellsTheStatesApart() {
            #expect(PeerWifi.state(interfaceUp: nil, markerExists: false) == .absent)
            #expect(PeerWifi.state(interfaceUp: nil, markerExists: true) == .absent)
            #expect(PeerWifi.state(interfaceUp: true, markerExists: false) == .active)
            #expect(PeerWifi.state(interfaceUp: false, markerExists: false) == .off)
            #expect(PeerWifi.state(interfaceUp: false, markerExists: true) == .paused)
            // macOS switched it back on and the helper hasn't noticed yet: still ours, still paused.
            #expect(PeerWifi.state(interfaceUp: true, markerExists: true) == .paused)
        }

        @Test func readsTheRealInterface() {
            // Whatever this Mac has, reading it works and gives a state.
            let saved = PeerWifi.interfaceUp
            defer { PeerWifi.interfaceUp = saved }
            _ = PeerWifi.interfaceUp()
            #expect(PeerWifi.State(rawValue: PeerWifi.state.rawValue) != nil)
        }

        @Test func asksOnceAndStartsTheHelperAsRoot() {
            let fixture = Fixture()
            #expect(PeerWifi.pause() == .done)
            // While the prompt was open nothing was paused yet, though the marker already existed.
            #expect(fixture.stateDuringPrompt == .active)
            #expect(fixture.markerExists)
            #expect(PeerWifi.state == .paused)
            let script = fixture.scripts.first ?? ""
            #expect(fixture.scripts.count == 1)
            #expect(script.hasSuffix("with administrator privileges"))
            #expect(script.contains("with prompt \"PlayFX wants to pause AirDrop and Handoff"))
            #expect(script.contains("[ -e \(fixture.marker) ]"))
            #expect(script.contains("/bin/kill -0 \(getpid())"))
            #expect(script.contains("> /dev/null 2>&1 &\"")) // in the background, so the prompt returns
            // Already paused: no second prompt.
            #expect(PeerWifi.pause() == .done)
            #expect(fixture.scripts.count == 1)
            #expect(PeerWifi.resume() == .active)
            #expect(!fixture.markerExists)
            #expect(PeerWifi.state == .active)
        }

        @Test func resumingWaitsUntilAWDLIsBack() {
            let fixture = Fixture()
            #expect(PeerWifi.pause() == .done)
            fixture.up = false // held down by the helper
            // The helper switches it back on a few checks after the marker goes.
            var checks = 0
            PeerWifi.interfaceUp = {
                checks += 1
                return checks > 3
            }
            #expect(PeerWifi.resume() == .active) // not "off", the moment in between
            #expect(fixture.waits == 3)
            // A helper that never brings it back: give up after 1.5 s and say what's true.
            PeerWifi.interfaceUp = { false }
            FileManager.default.createFile(atPath: fixture.marker, contents: nil)
            #expect(PeerWifi.resume() == .off)
            #expect(fixture.waits == 3 + 15)
            // Nothing of ours to resume: no waiting.
            #expect(PeerWifi.resume() == .off)
            #expect(fixture.waits == 18)
        }

        @Test func onlyPlainPathsReachTheRootCommand() {
            #expect(PeerWifi.isPlainPath("/var/folders/7h/x_y-1/T/playfx-awdl-42"))
            #expect(!PeerWifi.isPlainPath("relative/path"))
            #expect(!PeerWifi.isPlainPath("/tmp/a b"))
            #expect(!PeerWifi.isPlainPath("/tmp/a';rm -rf /;'"))
            #expect(!PeerWifi.isPlainPath("/tmp/ä"))
            let fixture = Fixture()
            PeerWifi.markerPath = "/tmp/has space"
            #expect(PeerWifi.pause() == .failed("Unexpected temporary folder /tmp/has space"))
            #expect(fixture.scripts.isEmpty)
        }

        @Test func aDismissedPromptChangesNothing() {
            let fixture = Fixture()
            fixture.reply = (1, "execution error: User canceled. (-128)\n")
            #expect(PeerWifi.pause() == .cancelled)
            #expect(!fixture.markerExists)
            #expect(PeerWifi.state == .active)
        }

        @Test func reportsFailures() {
            let fixture = Fixture()
            fixture.reply = (1, "  execution error: something else (-1)\n")
            #expect(PeerWifi.pause() == .failed("execution error: something else (-1)"))
            #expect(!fixture.markerExists)
            fixture.reply = (2, "")
            #expect(PeerWifi.pause() == .failed("osascript exited with 2"))
            PeerWifi.markerPath = "/nonexistent-folder/marker"
            #expect(PeerWifi.pause() == .failed("Couldn't create /nonexistent-folder/marker"))
        }

        @Test func pausesEvenWhenMacOSHasItOffForAMoment() {
            // macOS switches AWDL off and on by itself: asked to pause, keep it off from now on.
            let fixture = Fixture()
            fixture.up = false
            #expect(PeerWifi.pause() == .done)
            #expect(fixture.scripts.count == 1)
            #expect(PeerWifi.state == .paused)
        }

        @Test func leavesItAloneWithoutAWDL() {
            let fixture = Fixture()
            fixture.up = nil
            #expect(PeerWifi.pause() == .done)
            #expect(fixture.scripts.isEmpty)
            #expect(PeerWifi.state == .absent)
        }

        @Test func theHelperStopsOnceTheMarkerIsGone() throws {
            // The real helper, without root: ifconfig refuses, which is harmless here; what matters is
            // that the loop ends when the marker goes.
            let fixture = Fixture()
            FileManager.default.createFile(atPath: fixture.marker, contents: nil)
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = ["-c", PeerWifi.helperCommand(marker: fixture.marker, pid: getpid())]
            helper.standardError = FileHandle.nullDevice
            helper.standardOutput = FileHandle.nullDevice
            try helper.run()
            Thread.sleep(forTimeInterval: 0.3)
            #expect(helper.isRunning) // keeping it off
            try FileManager.default.removeItem(atPath: fixture.marker)
            let deadline = Date().addingTimeInterval(2)
            while helper.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            #expect(!helper.isRunning)
            if helper.isRunning { helper.terminate() }
        }

        @Test func theHelperStopsWhenPlayFXIsGone() throws {
            let fixture = Fixture()
            FileManager.default.createFile(atPath: fixture.marker, contents: nil)
            // A process that has already ended stands in for PlayFX after a quit or a crash.
            let ended = Process()
            ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try ended.run()
            ended.waitUntilExit()
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = ["-c", PeerWifi.helperCommand(marker: fixture.marker, pid: ended.processIdentifier)]
            helper.standardError = FileHandle.nullDevice
            helper.standardOutput = FileHandle.nullDevice
            try helper.run()
            let deadline = Date().addingTimeInterval(2)
            while helper.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            #expect(!helper.isRunning)
            if helper.isRunning { helper.terminate() }
        }

        @Test func bridgeReportsAndToggles() throws {
            let fixture = Fixture()
            func object(_ p: UnsafeMutablePointer<CChar>) throws -> [String: Any] {
                defer { sc_free(p) }
                return try #require(try JSONSerialization.jsonObject(with: Data(String(cString: p).utf8)) as? [String: Any])
            }
            #expect(try object(sc_peer_wifi_status())["state"] as? String == "active")
            let paused = try object(sc_peer_wifi_set_paused(true))
            #expect(paused["state"] as? String == "paused" && paused["outcome"] as? String == "done")
            let resumed = try object(sc_peer_wifi_set_paused(false))
            #expect(resumed["state"] as? String == "active" && resumed["outcome"] as? String == "done")
            fixture.reply = (1, "User canceled. (-128)")
            #expect(try object(sc_peer_wifi_set_paused(true))["outcome"] as? String == "cancelled")
            fixture.reply = (1, "boom")
            #expect(try object(sc_peer_wifi_set_paused(true))["error"] as? String == "Couldn't pause AirDrop and Handoff: boom")
        }
    }
}
