import Foundation

@testable import PlayFXProtocol

/// Shared inputs of stream.md section 15.
enum StreamInputs {
    static let handshakeKey = hex("404142434445464748494a4b4c4d4e4f")
    static let sessionID = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKL"
    static let privateA = hex("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")
    static let publicA = hex(
        "0484bf7562262bbd6940085748f3be6afa52ae317155181ece31b66351ccffa4b08cc43d63b2859d469fee15f31c9edb5324266e6fd0407e87382d60fc4511acd8")
    static let signatureA = hex("2fe2ebd67dac0d482eec54294c0e5df4408fbbce5404ded3215798fac833e53c")
    static let privateB = hex("8182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0")
    static let publicB = hex(
        "04a36b48691898f4c058cd18442495b9202f859f28c9400190be3b04f5f0655c94d0b245e8ed621cdb21d24fc8b6db2309fa38dcd8b1da0c5b11786e04fc66a526")
    static let signatureB = hex("f1cdeeb1a7b99337b684d4462b7fce83b07eb77a2bbc24d4327a0d992cf8bccc")
    static let secret = hex("0c1fbe7f56ae330d92c6b86cd82e0879addd6822fe20f2419176352093908297")

    static func ps5Crypt() throws -> RPCryptContext {
        try RPCryptContext(
            key: hex("598fa9a031d01820db25cab6e90bb19b"), seed: hex("ac7d50f394ea6588f0488f76e4170c8a"),
            hmacKey: RPCryptContext.hmacKey(for: .ps5v1))
    }

    static func ps4Crypt() throws -> RPCryptContext {
        try RPCryptContext(
            key: hex("f7e760687cea0ce70c1c129f67c087c8"), seed: hex("e978b89a1098296fb32415b9b5713be0"),
            hmacKey: RPCryptContext.hmacKey(for: .ps4v10))
    }

    /// The probe results of the vectors: 1454 / 1454, 1000 microseconds.
    static let probe = StreamProbeResult.fallback

    static let ps5Settings = StreamSettings(
        resolution: .p1080, frameRate: .fps60, bitrate: .preset, codec: .hevc, autoDowngrade: false)
    static let ps4Settings = StreamSettings(
        resolution: .p720, frameRate: .fps60, bitrate: .preset, codec: .h264, autoDowngrade: false)

    static func ps5Launch(codec: StreamCodec = .hevc) -> StreamLaunchRequest {
        StreamSettings(resolution: .p1080, frameRate: .fps60, bitrate: .preset, codec: codec)
            .launchRequest(target: .ps5v1, model: .ps5)
    }

    static func ps4Launch() -> StreamLaunchRequest {
        ps4Settings.launchRequest(target: .ps4v10, model: .ps4Pro)
    }
}

/// A key pair from the vectors.
func vectorKeyPair() throws -> StreamKeyPair { try StreamKeyPair(privateKey: StreamInputs.privateA) }

extension StreamMessage {
    var streamInfo: StreamInfoMessage? { if case .streamInfo(let info) = self { info } else { nil } }
}
