import Foundation

/// The launch spec (stream.md section 7): app settings to values, the byte-exact JSON, and its encryption.

/// What the network probe measured (section 5.6), or the fallback when it was skipped or failed.
public struct StreamProbeResult: Sendable, Equatable {
    /// Mean round-trip time in microseconds.
    public private(set) var rttMicroseconds: Int
    public private(set) var mtuIn: Int
    public private(set) var mtuOut: Int

    /// The probe searches MTUs between 576 and 1454 (section 5.5): values outside are clamped into that
    /// range, and a round-trip time into 0 ... 10 s.
    public init(rttMicroseconds: Int, mtuIn: Int, mtuOut: Int) {
        self.rttMicroseconds = min(max(rttMicroseconds, 0), 10_000_000)
        self.mtuIn = min(max(mtuIn, 576), 1454)
        self.mtuOut = min(max(mtuOut, 576), 1454)
    }

    /// Probe skipped or failed: 1454 / 1454 bytes, 1 ms (section 5, client choice).
    public static let fallback = StreamProbeResult(rttMicroseconds: 1000, mtuIn: 1454, mtuOut: 1454)

    /// `{RTT}` of the launch spec: `floor(rtt / 1000)` milliseconds (0 is possible on a fast LAN).
    public var rttMilliseconds: Int { rttMicroseconds / 1000 }
}

/// The resolution setting (section 7.2 presets).
public enum StreamResolution: Int, Sendable, Equatable, CaseIterable {
    case p360 = 360, p540 = 540, p720 = 720, p1080 = 1080

    public var width: Int {
        switch self {
        case .p360: 640
        case .p540: 960
        case .p720: 1280
        case .p1080: 1920
        }
    }

    public var height: Int { rawValue }

    /// The preset's default bitrate in kbit/s.
    public var defaultBitrateKbps: Int {
        switch self {
        case .p360: 2000
        case .p540: 6000
        case .p720: 10000
        case .p1080: 15000
        }
    }
}

/// The frame-rate setting: 30 or 60.
public enum StreamFrameRate: Int, Sendable, Equatable, CaseIterable {
    case fps30 = 30, fps60 = 60
}

/// The codec setting. The PS5 announces it twice, on ctrl (`streamingType`) and in the launch spec.
public enum StreamCodec: Sendable, Equatable, CaseIterable {
    case h264, hevc, hevcHDR

    /// The ctrl `RP-StreamingType` that must agree with the launch spec.
    public var streamingType: StreamingType {
        switch self {
        case .h264: .h264
        case .hevc: .h265
        case .hevcHDR: .h265HDR
        }
    }
}

/// The bitrate setting.
public enum StreamBitrate: Sendable, Equatable {
    /// The resolution's default.
    case preset
    /// A user value in kbit/s; `launchRequest` clamps it to 100 ... 100000.
    case kbps(Int)
}

/// The values the launch spec carries, after the console-kind rules.
public struct StreamLaunchRequest: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var bitrateKbps: Int
    public var codec: StreamCodec
}

/// The app's stream settings.
public struct StreamSettings: Sendable, Equatable {
    public var resolution: StreamResolution
    public var frameRate: StreamFrameRate
    public var bitrate: StreamBitrate
    public var codec: StreamCodec
    public var autoDowngrade: Bool

    public init(
        resolution: StreamResolution, frameRate: StreamFrameRate, bitrate: StreamBitrate = .preset,
        codec: StreamCodec = .h264, autoDowngrade: Bool = true
    ) {
        self.resolution = resolution
        self.frameRate = frameRate
        self.bitrate = bitrate
        self.codec = codec
        self.autoDowngrade = autoDowngrade
    }

    /// Applies section 7.2, with `model` from ctrl (nil when `RP-Server-Type` was absent):
    /// - a base PS4 (`.ps4`) with 1080p and auto-downgrade asks for the 720p preset at the same frame rate,
    ///   so the bitrate becomes 10000 kbit/s even if the user set another;
    /// - any PS4 (the negotiated version, or the model `.ps4`/`.ps4Pro`) streams H.264.
    /// An absent model never triggers the downgrade (the spec names only the base PS4).
    public func launchRequest(target: RPTarget, model: ConsoleModel?) -> StreamLaunchRequest {
        var resolution = self.resolution
        var bitrate = self.bitrate
        if model == .ps4 && resolution == .p1080 && autoDowngrade {
            resolution = .p720
            bitrate = .preset
        }
        var codec = self.codec
        if !target.isPS5 || model == .ps4 || model == .ps4Pro { codec = .h264 }
        let kbps: Int
        switch bitrate {
        case .preset: kbps = resolution.defaultBitrateKbps
        case .kbps(let value): kbps = min(max(value, 100), 100_000)
        }
        return StreamLaunchRequest(
            width: resolution.width, height: resolution.height, fps: frameRate.rawValue, bitrateKbps: kbps,
            codec: codec)
    }
}

/// Builds the launch spec text and its encrypted base64 form.
public enum StreamLaunchSpec {
    /// The JSON text, byte-exact (section 7.1), without the terminating zero byte. The PS5 keys (adaptive
    /// mode, codec, dynamic range) are written only for a PS5 target.
    static func json(
        request: StreamLaunchRequest, target: RPTarget, probe: StreamProbeResult, handshakeKey: [UInt8]
    ) -> String {
        let adaptive = target.isPS5 ? #","adaptiveStreamMode": "resize""# : ""
        var codec = ""
        if target.isPS5 {
            let name = request.codec == .h264 ? "avc" : "hevc"
            let range = request.codec == .hevcHDR ? "HDR" : "SDR"
            codec = #""videoCodec":"\#(name)","dynamicRange":"\#(range)","#
        }
        let key = Data(handshakeKey).base64EncodedString()
        return #"{"sessionId":"sessionId4321","streamResolutions":[{"resolution":{"width":\#(request.width),"height":\#(request.height)},"maxFps":\#(request.fps),"score":10}],"network":{"bwKbpsSent":\#(request.bitrateKbps),"bwLoss":0.001000,"mtu":\#(probe.mtuIn),"rtt":\#(probe.rttMilliseconds),"ports":[53,2053]},"slotId":1,"appSpecification":{"minFps":30,"minBandwidth":0,"extTitleId":"ps3","version":1,"timeLimit":1,"startTimeout":100,"afkTimeout":100,"afkTimeoutDisconnect":100},"konan":{"ps3AccessToken":"accessToken","ps3RefreshToken":"refreshToken"},"requestGameSpecification":{"model":"bravia_tv","platform":"android","audioChannels":"5.1","language":"sp","acceptButton":"X","connectedControllers":["xinput","ds3","ds4"],"yuvCoefficient":"bt601","videoEncoderProfile":"hw4.1","audioEncoderProfile":"audio1"\#(adaptive)},"userProfile":{"onlineId":"psnId","npId":"npId","region":"US","languagesUsed":["en","jp"]},\#(codec)"handshakeKey":"\#(key)"}"#
    }

    /// The JSON bytes followed by one zero byte (section 7.3).
    static func plaintext(
        request: StreamLaunchRequest, target: RPTarget, probe: StreamProbeResult, handshakeKey: [UInt8]
    ) -> [UInt8] {
        Array(json(request: request, target: target, probe: probe, handshakeKey: handshakeKey).utf8) + [0]
    }

    /// The Hello's `launchSpec` field: the plaintext XOR the keystream-only form at counter 0 of the session
    /// context (`StreamHandoff.crypt`), base64 encoded.
    public static func encode(
        request: StreamLaunchRequest, target: RPTarget, probe: StreamProbeResult, handshakeKey: [UInt8],
        crypt: RPCryptContext
    ) throws -> String {
        var bytes = plaintext(request: request, target: target, probe: probe, handshakeKey: handshakeKey)
        try crypt.xorKeystream(&bytes)
        return Data(bytes).base64EncodedString()
    }
}
