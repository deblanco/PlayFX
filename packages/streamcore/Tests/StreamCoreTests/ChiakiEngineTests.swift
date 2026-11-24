import CChiaki
import Foundation
import Testing
@testable import StreamCore

extension Serial {
    /// The libchiaki engine itself, on a session to a console that isn't there.
    @Suite struct ChiakiEngineTests {
        final class RecordingSink: StreamEngineSink, @unchecked Sendable {
            let events = LockedLines()
            func handleVideo(_ accessUnit: UnsafeRawBufferPointer, framesLost: Int) -> Bool { true }
            func handleAudioFormat(channels: Int, sampleRate: Int) {}
            func handleAudio(_ samples: UnsafePointer<Int16>, frames: Int) {}
            func handleHaptics(_ samples: UnsafeBufferPointer<Int16>) -> Bool { false }
            func handleTriggerEffects(_ leftMode: UInt8, _ left: [UInt8], _ rightMode: UInt8, _ right: [UInt8]) {}
            func deliver(_ event: StreamSession.Event) { events.append(label(event)) }
        }

        func config(host: String = "127.0.0.1") -> StreamEngineConfig {
            StreamEngineConfig(host: host, ps5: false, registKey: Data(repeating: 0x30, count: 16), rpKey: Data(repeating: 7, count: 16),
                               accountID: Data(repeating: 1, count: 8), height: 540, fps: 30, codec: .h264, bitrateKbps: 0,
                               autoDowngrade: true, remote: nil)
        }

        @Test func endsWithAQuitAndDoesNothingOnceStopped() async throws {
            let sink = RecordingSink()
            var engine: ChiakiEngine? = try ChiakiEngine(config: config(), sink: sink)
            engine?.setController(ControllerState())
            let silence = [Int16](repeating: 0, count: 960)
            silence.withUnsafeBufferPointer { engine?.sendMicrophoneFrame($0) } // the microphone is off: dropped
            #expect(engine?.stats().rttMicros == 0)
            // Nobody listens on loopback's Remote Play port: the session request fails and the session quits.
            #expect(await waitUntil { sink.events.lines.contains { $0.hasPrefix("quit") } })
            engine?.stop()
            engine?.stop()
            #expect(engine?.stats() == StreamEngineStats())
            engine?.setController(ControllerState())
            engine?.setLoginPin("1234")
            engine?.setMicrophone(true)
            engine?.setKeyboardText("x")
            engine?.finishKeyboard(accept: false)
            engine?.requestKeyFrame()
            engine?.goToBed()
            let quits = sink.events.lines.filter { $0.hasPrefix("quit") }
            engine = nil // deinit: already stopped
            #expect(quits.count == 1 && sink.events.lines.filter { $0.hasPrefix("quit") } == quits)
        }
    }
}

/// The contract's numbers (StreamEngine.swift) are the shim's.
@Suite struct StreamEngineContractTests {
    @Test func theDocumentedNumbersAreTheShims() {
        #expect(StreamEngineConfig.registKeySize == Int(PSRP_REGIST_KEY_SIZE) && StreamEngineConfig.rpKeySize == Int(PSRP_RP_KEY_SIZE)
            && StreamEngineConfig.accountIDSize == Int(PSRP_ACCOUNT_ID_SIZE))
        let documented: [String: UInt32] = [
            "cross": 1 << 0, "circle": 1 << 1, "square": 1 << 2, "triangle": 1 << 3, "left": 1 << 4, "right": 1 << 5,
            "up": 1 << 6, "down": 1 << 7, "l1": 1 << 8, "r1": 1 << 9, "l3": 1 << 10, "r3": 1 << 11, "options": 1 << 12,
            "share": 1 << 13, "touchpad": 1 << 14, "ps": 1 << 15,
        ]
        #expect(ControllerState.buttonNames == documented)
        #expect(ControllerState.touchpadButton == UInt32(PSRP_BTN_TOUCHPAD.rawValue))
        #expect(PSRP_MIC_SAMPLE_RATE == 48000 && PSRP_MIC_FRAME_SAMPLES == 480 && MicFramer.frameValues == 960)
        #expect(PSRP_HAPTICS_SAMPLE_RATE == 3000)
    }

    @Test func takesTheShimsStats() {
        let reorder = PsrpReorderStats(wait_us: 7500, holes_filled: 1, late_packets: 2, holes_lost: 3, queue_full_skips: 4)
        #expect(ChiakiEngine.stats(rttMicros: 2500, targetBitrate: 15_000_000, reorder: reorder) == StreamEngineStats(
            rttMicros: 2500, targetBitrate: 15_000_000,
            reorder: .init(waitMicros: 7500, holesFilled: 1, latePackets: 2, holesLost: 3, queueFullSkips: 4)))
    }
}
