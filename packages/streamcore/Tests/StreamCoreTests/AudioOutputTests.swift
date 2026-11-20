import CoreAudio
import Foundation
import Testing
@testable import StreamCore

@Suite struct AudioOutputTests {
    @Test func listsOutputsAndClampsVolume() {
        let devices = AudioOutput.devices()
        #expect(devices.allSatisfy { !$0.uid.isEmpty && !$0.name.isEmpty })
        if let first = devices.first { #expect(AudioOutput.deviceID(uid: first.uid) != nil) }
        #expect(AudioOutput.deviceID(uid: "no-such-device") == nil)
        #expect(AudioOutput(volume: 2).volume == 1 && AudioOutput(volume: -1).volume == 0)
    }

    @Test func playerAppliesVolumeAndFallsBackForMissingDevices() {
        let player = AudioPlayer()
        player.configure(channels: 2, sampleRate: 48000)
        player.apply(AudioOutput(volume: 0.25, deviceUID: "unplugged-headphones")) // unknown: system default
        player.apply(AudioOutput(volume: 0.5))
        player.stop()
    }

    /// "System default" follows macOS when the user switches its output, even after a chosen device (setting
    /// the default's device then pinned the output to it); a chosen device stays put.
    @Test func systemDefaultFollowsMacOSAndAChosenDeviceStays() {
        var route = OutputRoute()
        let headphones: AudioDeviceID = 5
        var macDefault: AudioDeviceID = 1
        let systemDefault = { macDefault }

        #expect(route.choose(nil, systemDefault: systemDefault) == nil) // never set: the output follows on its own
        #expect(route.choose(headphones, systemDefault: systemDefault) == headphones)
        route.didSet(headphones)
        macDefault = 2
        #expect(route.defaultChanged(playing: true, systemDefault: systemDefault) == nil) // the chosen device stays

        #expect(route.choose(nil, systemDefault: systemDefault) == 2) // back to the default: set to today's
        route.didSet(nil)
        macDefault = 3 // the user picks another output in macOS
        #expect(route.defaultChanged(playing: true, systemDefault: systemDefault) == 3)
        #expect(route.defaultChanged(playing: false, systemDefault: systemDefault) == nil) // nothing playing
    }

    @Test func setsADeviceOnlyWhenTheChoiceChanges() {
        var route = OutputRoute()
        #expect(route.choose(7, systemDefault: { 1 }) == 7)
        #expect(route.choose(7, systemDefault: { 1 }) == 7) // the first set failed: tried again
        route.didSet(7)
        #expect(route.choose(7, systemDefault: { 1 }) == nil)
        #expect(route.appliedDevice == 7 && !route.followingDefault)
    }

    /// The player listens for macOS's default output changes for as long as it lives, through a stand-in for
    /// CoreAudio: no real output is switched.
    @Test func playerWatchesTheDefaultOutputWhileItLives() {
        final class Fake {
            var watching = 0
            var changed: (() -> Void)?
            var asked = 0
        }
        let fake = Fake()
        let devices = OutputDevices(
            systemDefault: { fake.asked += 1; return 1 },
            watchDefault: { changed in
                fake.watching += 1
                fake.changed = changed
                return { fake.watching -= 1 }
            },
            setDevice: { _, _ in noErr })
        var player: AudioPlayer? = AudioPlayer(devices: devices)
        #expect(fake.watching == 1)
        fake.changed?() // not playing: nothing to follow
        #expect(fake.asked == 0)
        player = nil
        #expect(player == nil && fake.watching == 0)
        fake.changed?() // a late notice after it's gone does nothing
    }

    /// While playing on the system default, the player points its output at the device macOS switches to; once
    /// stopped it leaves it. A stand-in takes the switch, so no real output is changed.
    @Test func playerFollowsTheDefaultOutputWhilePlaying() {
        final class Fake {
            var macDefault: AudioDeviceID = 1
            var changed: (() -> Void)?
            var set: [AudioDeviceID] = []
        }
        let fake = Fake()
        let player = AudioPlayer(devices: OutputDevices(
            systemDefault: { fake.macDefault },
            watchDefault: { changed in fake.changed = changed; return {} },
            setDevice: { _, device in fake.set.append(device); return noErr }))
        player.configure(channels: 2, sampleRate: 48000) // playing, on the system default: nothing to set
        #expect(fake.set.isEmpty)
        fake.macDefault = 2 // the user picks another output in macOS
        fake.changed?()
        #expect(fake.set == [2])
        player.stop()
        fake.macDefault = 3
        fake.changed?() // stopped: nothing to follow
        #expect(fake.set == [2])
    }
}

extension Serial {
    @Suite struct AudioBridgeTests {
        @Test func bridgeListsDevicesAndStoresTheChoice() throws {
            let previous = AudioOutput.current
            defer { AudioOutput.current = previous }
            func reply(_ p: UnsafeMutablePointer<CChar>) -> String { defer { sc_free(p) }; return String(cString: p) }
            let list = try JSONSerialization.jsonObject(with: Data(reply(sc_audio_devices()).utf8)) as? [[String: String]]
            #expect(list != nil)
            #expect(reply(#"{"volume":0.4,"deviceUID":"x"}"#.withCString(sc_set_audio_output)) == #"{"ok":true}"#)
            #expect(AudioOutput.current == AudioOutput(volume: 0.4, deviceUID: "x"))
            #expect(reply("not json".withCString(sc_set_audio_output)).contains("error"))
        }
    }
}
