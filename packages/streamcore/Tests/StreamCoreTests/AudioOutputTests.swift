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
