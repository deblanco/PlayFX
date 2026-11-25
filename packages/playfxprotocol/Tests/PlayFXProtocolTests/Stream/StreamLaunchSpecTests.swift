import CryptoKit
import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

@Suite struct StreamLaunchSpecTests {
    // MARK: V-ST2 and V-ST3

    @Test func ps5JSONIsByteExact() {
        let json = StreamLaunchSpec.json(
            request: StreamInputs.ps5Launch(), target: .ps5v1, probe: StreamInputs.probe,
            handshakeKey: StreamInputs.handshakeKey)
        #expect(json == StreamVectors.ps5JSON)
        #expect(json.utf8.count == 911)
        let plain = StreamLaunchSpec.plaintext(
            request: StreamInputs.ps5Launch(), target: .ps5v1, probe: StreamInputs.probe,
            handshakeKey: StreamInputs.handshakeKey)
        #expect(plain.count == 912 && plain.last == 0)
        #expect(sha256Hex(plain) == "c06eab387caf8716f15376fd51658aff59c5cafc9e7f957b2e47384845b13b7c")
    }

    @Test func ps5EncryptionMatchesV_ST2() throws {
        let b64 = try StreamLaunchSpec.encode(
            request: StreamInputs.ps5Launch(), target: .ps5v1, probe: StreamInputs.probe,
            handshakeKey: StreamInputs.handshakeKey, crypt: StreamInputs.ps5Crypt())
        #expect(b64.count == 1216)
        #expect(b64.hasPrefix("Sc4l80f/XE7xAWzagSwqj3c69I0QN79abaVUNg3hbQt9dx1g+xV6yvfIL7BqtP6K"))
        #expect(b64.hasSuffix("vVe8wrnOWkaLMbWeuGsl5cDi2/7cXp+JTpfvkOukOZaLFwOucoYbNvNNPzc6ad+H"))
        let cipher = [UInt8](try #require(Data(base64Encoded: b64)))
        #expect(cipher.count == 912)
        #expect(Array(cipher.prefix(32)) == hex("49ce25f347ff5c4ef1016cda812c2a8f773af48d1037bf5a6da554360de16d0b"))
        #expect(sha256Hex(cipher) == "527d0e8e65b7cd238c50de738da8909f452b050ca89d3f2182ddc4b2a849d9f5")
    }

    @Test func hdrDiffersOnlyInTheRange() {
        let sdr = StreamLaunchSpec.json(
            request: StreamInputs.ps5Launch(), target: .ps5v1, probe: StreamInputs.probe,
            handshakeKey: StreamInputs.handshakeKey)
        let hdr = StreamLaunchSpec.json(
            request: StreamInputs.ps5Launch(codec: .hevcHDR), target: .ps5v1, probe: StreamInputs.probe,
            handshakeKey: StreamInputs.handshakeKey)
        #expect(hdr == sdr.replacingOccurrences(of: #""dynamicRange":"SDR""#, with: #""dynamicRange":"HDR""#))
        let avc = StreamLaunchSpec.json(
            request: StreamInputs.ps5Launch(codec: .h264), target: .ps5v1, probe: StreamInputs.probe,
            handshakeKey: StreamInputs.handshakeKey)
        #expect(avc.contains(#""videoCodec":"avc","dynamicRange":"SDR","#))
    }

    @Test func ps4JSONAndEncryptionMatchV_ST3() throws {
        let json = StreamLaunchSpec.json(
            request: StreamInputs.ps4Launch(), target: .ps4v10, probe: StreamInputs.probe,
            handshakeKey: StreamInputs.handshakeKey)
        #expect(json == StreamVectors.ps4JSON)
        #expect(json.utf8.count == 838)
        #expect(!json.contains("adaptiveStreamMode") && !json.contains("videoCodec") && !json.contains("dynamicRange"))
        let b64 = try StreamLaunchSpec.encode(
            request: StreamInputs.ps4Launch(), target: .ps4v10, probe: StreamInputs.probe,
            handshakeKey: StreamInputs.handshakeKey, crypt: StreamInputs.ps4Crypt())
        #expect(b64 == StreamVectors.ps4LaunchSpecBase64)
        #expect(b64.count == 1120)
    }

    @Test func probeValuesGoIn() {
        let probe = StreamProbeResult(rttMicroseconds: 2999, mtuIn: 1200, mtuOut: 1300)
        let json = StreamLaunchSpec.json(
            request: StreamInputs.ps5Launch(), target: .ps5v1, probe: probe, handshakeKey: StreamInputs.handshakeKey)
        #expect(json.contains(#""mtu":1200,"rtt":2,"#))
        #expect(StreamProbeResult(rttMicroseconds: 400, mtuIn: 1454, mtuOut: 1454).rttMilliseconds == 0)
        #expect(StreamProbeResult(rttMicroseconds: -5, mtuIn: 1454, mtuOut: 1454).rttMilliseconds == 0)
        #expect(StreamProbeResult.fallback.rttMilliseconds == 1)
    }

    @Test func inputsAreClamped() {
        let wild = StreamProbeResult(rttMicroseconds: Int.max, mtuIn: Int.max, mtuOut: Int.min)
        #expect((wild.rttMicroseconds, wild.mtuIn, wild.mtuOut) == (10_000_000, 1454, 576))
        let negative = StreamProbeResult(rttMicroseconds: -5, mtuIn: -1, mtuOut: 0)
        #expect((negative.rttMicroseconds, negative.mtuIn, negative.mtuOut) == (0, 576, 576))
        func kbps(_ value: Int) -> Int {
            StreamSettings(resolution: .p720, frameRate: .fps30, bitrate: .kbps(value))
                .launchRequest(target: .ps5v1, model: .ps5).bitrateKbps
        }
        #expect(kbps(-4) == 100 && kbps(0) == 100 && kbps(5000) == 5000 && kbps(Int.max) == 100_000)
        #expect(StreamMessageSplit.budget(mtuIn: Int.min, mtuOut: Int.max) == -50)
        #expect(StreamMessageSplit.split([1, 2, 3], mtuIn: Int.min, mtuOut: Int.min).flatMap(\.bytes) == [1, 2, 3])
    }

    // MARK: Settings mapping

    @Test func presets() {
        let expected: [(StreamResolution, Int, Int, Int)] = [
            (.p360, 640, 360, 2000), (.p540, 960, 540, 6000), (.p720, 1280, 720, 10000), (.p1080, 1920, 1080, 15000),
        ]
        for (resolution, w, h, kbps) in expected {
            let r = StreamSettings(resolution: resolution, frameRate: .fps30).launchRequest(target: .ps5v1, model: .ps5)
            #expect((r.width, r.height, r.bitrateKbps, r.fps) == (w, h, kbps, 30))
        }
        #expect(StreamResolution.allCases.count == 4 && StreamFrameRate.allCases.count == 2)
    }

    @Test func userBitrateReplacesThePreset() {
        let r = StreamSettings(resolution: .p1080, frameRate: .fps60, bitrate: .kbps(22000), codec: .hevc)
            .launchRequest(target: .ps5v1, model: .ps5)
        #expect(r.bitrateKbps == 22000 && r.codec == .hevc)
    }

    @Test func basePS4DowngradesTo720AndResetsTheBitrate() {
        let settings = StreamSettings(
            resolution: .p1080, frameRate: .fps60, bitrate: .kbps(20000), codec: .hevcHDR, autoDowngrade: true)
        let r = settings.launchRequest(target: .ps4v10, model: .ps4)
        #expect((r.width, r.height, r.fps, r.bitrateKbps, r.codec) == (1280, 720, 60, 10000, .h264))
        // Pro, absent model, and downgrade off keep 1080p; every PS4 gets H.264.
        let pro = settings.launchRequest(target: .ps4v10, model: .ps4Pro)
        #expect((pro.height, pro.bitrateKbps, pro.codec) == (1080, 20000, .h264))
        #expect(settings.launchRequest(target: .ps4v9, model: nil).height == 1080)
        var off = settings
        off.autoDowngrade = false
        #expect(off.launchRequest(target: .ps4v10, model: .ps4).height == 1080)
        // 720p is untouched by the downgrade.
        let p720 = StreamSettings(resolution: .p720, frameRate: .fps30, bitrate: .kbps(7000))
        #expect(p720.launchRequest(target: .ps4v10, model: .ps4).bitrateKbps == 7000)
    }

    @Test func codecsAgreeWithCtrlStreamingTypes() {
        #expect(StreamCodec.h264.streamingType == .h264)
        #expect(StreamCodec.hevc.streamingType == .h265)
        #expect(StreamCodec.hevcHDR.streamingType == .h265HDR)
        let ps5 = StreamSettings(resolution: .p720, frameRate: .fps30, codec: .hevcHDR)
        #expect(ps5.launchRequest(target: .ps5v1, model: .ps5).codec == .hevcHDR)
    }
}
