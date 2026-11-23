/// The payload messages of stream.md section 4, each with `write(to:)` (fields in ascending order, every
/// required field written) and a tolerant decoder (any field order, unknown fields skipped).

/// One protobuf message body.
public protocol StreamPayload: Sendable, Equatable {
    init(fields: [ProtobufField]) throws
    func write(to writer: inout ProtobufWriter)
}

extension StreamPayload {
    /// Decodes the message from its body bytes.
    public init(decoding bytes: [UInt8]) throws { try self.init(fields: ProtobufReader.fields(of: bytes)) }

    /// The body bytes.
    public var encoded: [UInt8] {
        var writer = ProtobufWriter()
        write(to: &writer)
        return writer.encoded
    }
}

extension ProtobufWriter {
    /// A nested message.
    public mutating func payload<P: StreamPayload>(_ field: Int, _ value: P) { bytes(field, value.encoded) }
}

// MARK: Used messages (4.1)

/// Hello (wrapper payload field 2), client to console.
public struct HelloMessage: StreamPayload, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var clientVersion: UInt32
    /// The ctrl `sessionId`; empty on the probe.
    public var sessionKey: String
    /// The base64 launch spec; empty on the probe.
    public var launchSpec: String
    /// Stream: four zero bytes. Probe: empty.
    public var encryptedKey: [UInt8]
    public var ecdhPublicKey: [UInt8]?
    public var ecdhSignature: [UInt8]?

    public init(
        clientVersion: UInt32, sessionKey: String, launchSpec: String, encryptedKey: [UInt8],
        ecdhPublicKey: [UInt8]? = nil, ecdhSignature: [UInt8]? = nil
    ) {
        self.clientVersion = clientVersion
        self.sessionKey = sessionKey
        self.launchSpec = launchSpec
        self.encryptedKey = encryptedKey
        self.ecdhPublicKey = ecdhPublicKey
        self.ecdhSignature = ecdhSignature
    }

    /// The session ID and launch spec stay out of logs and `dump`.
    public var description: String { "HelloMessage(version \(clientVersion), session ID and launch spec hidden)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["clientVersion": clientVersion]) }

    /// The Hello of the network probe (section 5.3): version 9, everything else empty.
    public static let probe = HelloMessage(clientVersion: 9, sessionKey: "", launchSpec: "", encryptedKey: [])

    public init(fields f: [ProtobufField]) throws {
        clientVersion = try f.requiredUInt32(1, "clientVersion")
        sessionKey = try f.requiredString(2, "sessionKey")
        launchSpec = try f.requiredString(3, "launchSpec")
        encryptedKey = try f.requiredBytes(4, "encryptedKey")
        ecdhPublicKey = f.optionalBytes(5)
        ecdhSignature = f.optionalBytes(6)
    }

    public func write(to w: inout ProtobufWriter) {
        w.varint(1, UInt64(clientVersion))
        w.string(2, sessionKey)
        w.string(3, launchSpec)
        w.bytes(4, encryptedKey)
        if let ecdhPublicKey { w.bytes(5, ecdhPublicKey) }
        if let ecdhSignature { w.bytes(6, ecdhSignature) }
    }
}

/// StreamEventInfo (inside HelloReply and Disconnect).
public struct StreamEventInfo: StreamPayload {
    public var code: String
    public var name: String?
    public var description: String?

    public init(code: String, name: String? = nil, description: String? = nil) {
        self.code = code
        self.name = name
        self.description = description
    }

    public init(fields f: [ProtobufField]) throws {
        code = try f.requiredString(1, "code")
        name = f.optionalString(2)
        description = f.optionalString(3)
    }

    public func write(to w: inout ProtobufWriter) {
        w.string(1, code)
        if let name { w.string(2, name) }
        if let description { w.string(3, description) }
    }
}

/// HelloReply (wrapper payload field 3), console to client.
public struct HelloReplyMessage: StreamPayload {
    /// Not used by clients, so optional here: only `keyAccepted` and `versionAccepted` are enforced.
    public var serverVersion: UInt32?
    public var token: UInt32?
    public var keyAccepted: Bool
    public var versionAccepted: Bool
    public var sessionKey: String?
    public var extendedInfo: StreamEventInfo?
    public var serverVersionText: String?
    public var ecdhPublicKey: [UInt8]?
    public var ecdhSignature: [UInt8]?

    public init(
        serverVersion: UInt32? = nil, token: UInt32? = nil, keyAccepted: Bool, versionAccepted: Bool,
        sessionKey: String? = nil,
        extendedInfo: StreamEventInfo? = nil, serverVersionText: String? = nil, ecdhPublicKey: [UInt8]? = nil,
        ecdhSignature: [UInt8]? = nil
    ) {
        self.serverVersion = serverVersion
        self.token = token
        self.keyAccepted = keyAccepted
        self.versionAccepted = versionAccepted
        self.sessionKey = sessionKey
        self.extendedInfo = extendedInfo
        self.serverVersionText = serverVersionText
        self.ecdhPublicKey = ecdhPublicKey
        self.ecdhSignature = ecdhSignature
    }

    public init(fields f: [ProtobufField]) throws {
        serverVersion = f.optionalUInt32(1)
        token = f.optionalUInt32(2)
        keyAccepted = try f.requiredBool(3, "keyAccepted")
        versionAccepted = try f.requiredBool(4, "versionAccepted")
        sessionKey = f.optionalString(5)
        extendedInfo = try f.optionalBytes(6).map { try StreamEventInfo(decoding: $0) }
        serverVersionText = f.optionalString(7)
        ecdhPublicKey = f.optionalBytes(8)
        ecdhSignature = f.optionalBytes(9)
    }

    public func write(to w: inout ProtobufWriter) {
        if let serverVersion { w.varint(1, UInt64(serverVersion)) }
        if let token { w.varint(2, UInt64(token)) }
        w.bool(3, keyAccepted)
        w.bool(4, versionAccepted)
        if let sessionKey { w.string(5, sessionKey) }
        if let extendedInfo { w.payload(6, extendedInfo) }
        if let serverVersionText { w.string(7, serverVersionText) }
        if let ecdhPublicKey { w.bytes(8, ecdhPublicKey) }
        if let ecdhSignature { w.bytes(9, ecdhSignature) }
    }
}

/// Disconnect (wrapper payload field 10), both directions.
public struct DisconnectMessage: StreamPayload {
    /// What the client sends when it ends a stream or the probe (section 11.1).
    public static let clientReason = "Client Disconnecting"
    /// The console's reason text when it shuts down or goes to rest mode.
    public static let serverShuttingDownReason = "Server shutting down"

    /// Nil when the console's Disconnect carried no `reason` (it is a required field, but a Disconnect
    /// still ends the stream). Written as an empty string when nil.
    public var reason: String?
    public var extendedInfo: StreamEventInfo?

    public init(reason: String?, extendedInfo: StreamEventInfo? = nil) {
        self.reason = reason
        self.extendedInfo = extendedInfo
    }

    public static let client = DisconnectMessage(reason: clientReason)

    public init(fields f: [ProtobufField]) throws {
        reason = f.optionalString(1)
        extendedInfo = try f.optionalBytes(2).map { try StreamEventInfo(decoding: $0) }
    }

    public func write(to w: inout ProtobufWriter) {
        w.string(1, reason ?? "")
        if let extendedInfo { w.payload(2, extendedInfo) }
    }
}

/// CorruptFrame (wrapper payload field 6): frame indices are av.md's 16-bit frame counter.
public struct CorruptFrameMessage: StreamPayload {
    public var firstFrame: UInt32
    public var lastFrame: UInt32

    public init(firstFrame: UInt16, lastFrame: UInt16) {
        self.firstFrame = UInt32(firstFrame)
        self.lastFrame = UInt32(lastFrame)
    }

    public init(fields f: [ProtobufField]) throws {
        firstFrame = try f.requiredUInt32(1, "firstFrame")
        lastFrame = try f.requiredUInt32(2, "lastFrame")
    }

    public func write(to w: inout ProtobufWriter) {
        w.varint(1, UInt64(firstFrame))
        w.varint(2, UInt64(lastFrame))
    }
}

/// StreamAudioChannel (inside StreamInfo field 7); not used by clients.
public struct StreamAudioChannel: StreamPayload {
    public var channelType: UInt32
    public var audioHeader: [UInt8]
    public var rawPcm: Bool?

    public init(channelType: UInt32, audioHeader: [UInt8], rawPcm: Bool? = nil) {
        self.channelType = channelType
        self.audioHeader = audioHeader
        self.rawPcm = rawPcm
    }

    public init(fields f: [ProtobufField]) throws {
        channelType = try f.requiredUInt32(1, "channelType")
        audioHeader = try f.requiredBytes(2, "audioHeader")
        rawPcm = f.optionalBool(3)
    }

    public func write(to w: inout ProtobufWriter) {
        w.varint(1, UInt64(channelType))
        w.bytes(2, audioHeader)
        if let rawPcm { w.bool(3, rawPcm) }
    }
}

/// StreamInfo (wrapper payload field 15), both directions: the console's profiles and audio header, and the
/// client's microphone announcement.
public struct StreamInfoMessage: StreamPayload {
    /// Existing clients keep at most this many profiles (section 6.6).
    public static let maximumProfiles = 8

    /// The console's profiles as the AV layer's `VideoProfile` (width, height, codec header).
    public var videoProfiles: [VideoProfile]
    public var audioHeader: [UInt8]
    public var startTimeout: UInt32?
    public var idleTimeout: UInt32?
    public var idleTimeoutDisconnect: UInt32?
    public var congestionInterval: UInt32?
    public var audioChannels: [StreamAudioChannel]

    public init(
        videoProfiles: [VideoProfile] = [], audioHeader: [UInt8], startTimeout: UInt32? = nil,
        idleTimeout: UInt32? = nil, idleTimeoutDisconnect: UInt32? = nil, congestionInterval: UInt32? = nil,
        audioChannels: [StreamAudioChannel] = []
    ) {
        self.videoProfiles = videoProfiles
        self.audioHeader = audioHeader
        self.startTimeout = startTimeout
        self.idleTimeout = idleTimeout
        self.idleTimeoutDisconnect = idleTimeoutDisconnect
        self.congestionInterval = congestionInterval
        self.audioChannels = audioChannels
    }

    /// The client's microphone StreamInfo (sections 6.7 and 9.10): no profiles, the microphone audio header.
    public static let microphone = StreamInfoMessage(audioHeader: MicrophoneSettings.announcedHeader.bytes)

    /// The audio header, or nil unless it is exactly 14 bytes (then the session fails, section 6.6).
    public var parsedAudioHeader: AudioHeader? { AudioHeader(audioHeader) }

    /// The profiles a client uses: the first `maximumProfiles`, in order (list index 0, 1, ...).
    public var usableProfiles: [VideoProfile] { Array(videoProfiles.prefix(Self.maximumProfiles)) }

    public init(fields f: [ProtobufField]) throws {
        videoProfiles = try f.allBytes(1).map(Self.decodeProfile)
        audioHeader = try f.requiredBytes(2, "audioHeader")
        startTimeout = f.optionalUInt32(3)
        idleTimeout = f.optionalUInt32(4)
        idleTimeoutDisconnect = f.optionalUInt32(5)
        congestionInterval = f.optionalUInt32(6)
        audioChannels = try f.allBytes(7).map { try StreamAudioChannel(decoding: $0) }
    }

    private static func decodeProfile(_ body: [UInt8]) throws -> VideoProfile {
        let f = try ProtobufReader.fields(of: body)
        return VideoProfile(
            width: Int(try f.requiredUInt32(1, "width")), height: Int(try f.requiredUInt32(2, "height")),
            header: try f.requiredBytes(3, "videoHeader"))
    }

    private static func encodeProfile(_ profile: VideoProfile) -> [UInt8] {
        var w = ProtobufWriter()
        w.varint(1, UInt64(UInt32(clamping: profile.width)))
        w.varint(2, UInt64(UInt32(clamping: profile.height)))
        w.bytes(3, profile.header)
        return w.encoded
    }

    public func write(to w: inout ProtobufWriter) {
        for profile in videoProfiles { w.bytes(1, Self.encodeProfile(profile)) }
        w.bytes(2, audioHeader)
        if let startTimeout { w.varint(3, UInt64(startTimeout)) }
        if let idleTimeout { w.varint(4, UInt64(idleTimeout)) }
        if let idleTimeoutDisconnect { w.varint(5, UInt64(idleTimeoutDisconnect)) }
        if let congestionInterval { w.varint(6, UInt64(congestionInterval)) }
        for channel in audioChannels { w.payload(7, channel) }
    }
}

/// ConnectionQuality (wrapper payload field 17), console to client. The unit of `targetBitrate` is
/// unconfirmed (open question 6).
public struct ConnectionQualityMessage: StreamPayload {
    public var targetBitrate: UInt32?
    public var upstreamBitrate: UInt32?
    public var upstreamLoss: Float?
    public var disableUpstreamAudio: Bool?
    public var rtt: Double?
    public var loss: UInt64?

    public init(
        targetBitrate: UInt32? = nil, upstreamBitrate: UInt32? = nil, upstreamLoss: Float? = nil,
        disableUpstreamAudio: Bool? = nil, rtt: Double? = nil, loss: UInt64? = nil
    ) {
        self.targetBitrate = targetBitrate
        self.upstreamBitrate = upstreamBitrate
        self.upstreamLoss = upstreamLoss
        self.disableUpstreamAudio = disableUpstreamAudio
        self.rtt = rtt
        self.loss = loss
    }

    public init(fields f: [ProtobufField]) throws {
        targetBitrate = f.optionalUInt32(1)
        upstreamBitrate = f.optionalUInt32(2)
        if case .fixed32(let bits)? = f.last(3)?.value { upstreamLoss = Float(bitPattern: bits) }
        disableUpstreamAudio = f.optionalBool(4)
        if case .fixed64(let bits)? = f.last(5)?.value { rtt = Double(bitPattern: bits) }
        loss = f.optionalVarint(6)
    }

    public func write(to w: inout ProtobufWriter) {
        if let targetBitrate { w.varint(1, UInt64(targetBitrate)) }
        if let upstreamBitrate { w.varint(2, UInt64(upstreamBitrate)) }
        if let upstreamLoss { w.float(3, upstreamLoss) }
        if let disableUpstreamAudio { w.bool(4, disableUpstreamAudio) }
        if let rtt { w.double(5, rtt) }
        if let loss { w.varint(6, loss) }
    }
}

/// The controller kinds ControllerConnection names (section 4.1).
public enum StreamControllerType: UInt64, Sendable, Equatable {
    case notSet = 0, dualShock3, dualShock4, vita, xinput, mobile, dualSense, vr2Sense
}

/// ControllerConnection (wrapper payload field 22), client to console.
public struct ControllerConnectionMessage: StreamPayload {
    public var controllerId: Int32?
    public var connected: Bool?
    public var controllerType: StreamControllerType?

    public init(controllerId: Int32? = nil, connected: Bool? = nil, controllerType: StreamControllerType? = nil) {
        self.controllerId = controllerId
        self.connected = connected
        self.controllerType = controllerType
    }

    /// What the client sends after the StreamInfoAck (section 6.7): connected, a DualSense when DualSense
    /// features are on, else a DualShock 4.
    public static func connected(dualSense: Bool) -> ControllerConnectionMessage {
        ControllerConnectionMessage(connected: true, controllerType: dualSense ? .dualSense : .dualShock4)
    }

    public init(fields f: [ProtobufField]) throws {
        controllerId = f.optionalVarint(1).map { Int32(truncatingIfNeeded: $0) }
        connected = f.optionalBool(2)
        if let raw = f.optionalVarint(3) {
            guard let type = StreamControllerType(rawValue: raw) else { throw ProtobufError.badValue("controllerType") }
            controllerType = type
        }
    }

    public func write(to w: inout ProtobufWriter) {
        if let controllerId { w.int32(1, controllerId) }
        if let connected { w.bool(2, connected) }
        if let controllerType { w.varint(3, controllerType.rawValue) }
    }
}

// MARK: Probe (section 4.1, 5)

/// ProbeEcho.
public struct ProbeEcho: StreamPayload {
    public var enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
    public init(fields f: [ProtobufField]) throws { enabled = try f.requiredBool(1, "enabled") }
    public func write(to w: inout ProtobufWriter) { w.bool(1, enabled) }
}

/// ProbeMtu: clients send only `id` and `requestedMtu`.
public struct ProbeMtu: StreamPayload {
    public var id: UInt32
    public var requestedMtu: UInt32
    public var sentMtu: UInt32?
    public var count: UInt32?
    public var sendDelay: UInt32?
    public var delta: UInt32?

    public init(
        id: UInt32, requestedMtu: UInt32, sentMtu: UInt32? = nil, count: UInt32? = nil, sendDelay: UInt32? = nil,
        delta: UInt32? = nil
    ) {
        self.id = id
        self.requestedMtu = requestedMtu
        self.sentMtu = sentMtu
        self.count = count
        self.sendDelay = sendDelay
        self.delta = delta
    }

    public init(fields f: [ProtobufField]) throws {
        id = try f.requiredUInt32(1, "id")
        requestedMtu = try f.requiredUInt32(2, "requestedMtu")
        sentMtu = f.optionalUInt32(3)
        count = f.optionalUInt32(4)
        sendDelay = f.optionalUInt32(5)
        delta = f.optionalUInt32(6)
    }

    public func write(to w: inout ProtobufWriter) {
        w.varint(1, UInt64(id))
        w.varint(2, UInt64(requestedMtu))
        if let sentMtu { w.varint(3, UInt64(sentMtu)) }
        if let count { w.varint(4, UInt64(count)) }
        if let sendDelay { w.varint(5, UInt64(sendDelay)) }
        if let delta { w.varint(6, UInt64(delta)) }
    }
}

/// ProbeClientMtu.
public struct ProbeClientMtu: StreamPayload {
    public var id: UInt32
    public var requestedMtu: UInt32
    public var active: Bool
    public var downstreamMtu: UInt32?

    public init(id: UInt32, requestedMtu: UInt32, active: Bool, downstreamMtu: UInt32? = nil) {
        self.id = id
        self.requestedMtu = requestedMtu
        self.active = active
        self.downstreamMtu = downstreamMtu
    }

    public init(fields f: [ProtobufField]) throws {
        id = try f.requiredUInt32(1, "id")
        requestedMtu = try f.requiredUInt32(2, "requestedMtu")
        active = try f.requiredBool(3, "active")
        downstreamMtu = f.optionalUInt32(4)
    }

    public func write(to w: inout ProtobufWriter) {
        w.varint(1, UInt64(id))
        w.varint(2, UInt64(requestedMtu))
        w.bool(3, active)
        if let downstreamMtu { w.varint(4, UInt64(downstreamMtu)) }
    }
}

/// ProbeBandwidth (not used by clients).
public struct ProbeBandwidth: StreamPayload {
    public var id: UInt32
    public var time: UInt32
    public var bandwidth: UInt32?
    public var fps: UInt32?
    public var mtu: UInt32?
    public var naluCount: UInt32?
    public var totalSent: UInt32?
    public var upstream: Bool?
    public var loss: Double?

    public init(
        id: UInt32, time: UInt32, bandwidth: UInt32? = nil, fps: UInt32? = nil, mtu: UInt32? = nil,
        naluCount: UInt32? = nil, totalSent: UInt32? = nil, upstream: Bool? = nil, loss: Double? = nil
    ) {
        self.id = id
        self.time = time
        self.bandwidth = bandwidth
        self.fps = fps
        self.mtu = mtu
        self.naluCount = naluCount
        self.totalSent = totalSent
        self.upstream = upstream
        self.loss = loss
    }

    public init(fields f: [ProtobufField]) throws {
        id = try f.requiredUInt32(1, "id")
        time = try f.requiredUInt32(2, "time")
        bandwidth = f.optionalUInt32(3)
        fps = f.optionalUInt32(4)
        mtu = f.optionalUInt32(5)
        naluCount = f.optionalUInt32(6)
        totalSent = f.optionalUInt32(7)
        upstream = f.optionalBool(8)
        if case .fixed64(let bits)? = f.last(9)?.value { loss = Double(bitPattern: bits) }
    }

    public func write(to w: inout ProtobufWriter) {
        w.varint(1, UInt64(id))
        w.varint(2, UInt64(time))
        if let bandwidth { w.varint(3, UInt64(bandwidth)) }
        if let fps { w.varint(4, UInt64(fps)) }
        if let mtu { w.varint(5, UInt64(mtu)) }
        if let naluCount { w.varint(6, UInt64(naluCount)) }
        if let totalSent { w.varint(7, UInt64(totalSent)) }
        if let upstream { w.bool(8, upstream) }
        if let loss { w.double(9, loss) }
    }
}

/// Probe (wrapper payload field 14), network probe only.
public struct ProbeMessage: StreamPayload {
    /// Probe command values: 0 echo, 1 MTU, 3 bandwidth, 4 client MTU.
    public struct Command: RawRepresentable, Sendable, Equatable {
        public var rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let echo = Command(rawValue: 0)
        public static let mtu = Command(rawValue: 1)
        public static let bandwidth = Command(rawValue: 3)
        public static let clientMtu = Command(rawValue: 4)
    }

    public var command: Command
    public var echo: ProbeEcho?
    public var mtu: ProbeMtu?
    public var bandwidth: ProbeBandwidth?
    public var clientMtu: ProbeClientMtu?

    public init(
        command: Command, echo: ProbeEcho? = nil, mtu: ProbeMtu? = nil, bandwidth: ProbeBandwidth? = nil,
        clientMtu: ProbeClientMtu? = nil
    ) {
        self.command = command
        self.echo = echo
        self.mtu = mtu
        self.bandwidth = bandwidth
        self.clientMtu = clientMtu
    }

    /// Echo on or off (section 5.4 steps 1 and 4).
    public static func echo(enabled: Bool) -> ProbeMessage {
        ProbeMessage(command: .echo, echo: ProbeEcho(enabled: enabled))
    }

    /// Inbound MTU request (section 5.5).
    public static func mtu(id: UInt32, requestedMtu: UInt32) -> ProbeMessage {
        ProbeMessage(command: .mtu, mtu: ProbeMtu(id: id, requestedMtu: requestedMtu))
    }

    /// Client-MTU announcement (section 5.5, outbound steps 1 and 4).
    public static func clientMtu(id: UInt32, requestedMtu: UInt32, active: Bool, downstreamMtu: UInt32) -> ProbeMessage {
        ProbeMessage(
            command: .clientMtu,
            clientMtu: ProbeClientMtu(
                id: id, requestedMtu: requestedMtu, active: active, downstreamMtu: downstreamMtu))
    }

    public init(fields f: [ProtobufField]) throws {
        command = Command(rawValue: try f.requiredUInt32(1, "command"))
        echo = try f.optionalBytes(2).map { try ProbeEcho(decoding: $0) }
        mtu = try f.optionalBytes(3).map { try ProbeMtu(decoding: $0) }
        bandwidth = try f.optionalBytes(4).map { try ProbeBandwidth(decoding: $0) }
        clientMtu = try f.optionalBytes(5).map { try ProbeClientMtu(decoding: $0) }
    }

    public func write(to w: inout ProtobufWriter) {
        w.varint(1, UInt64(command.rawValue))
        if let echo { w.payload(2, echo) }
        if let mtu { w.payload(3, mtu) }
        if let bandwidth { w.payload(4, bandwidth) }
        if let clientMtu { w.payload(5, clientMtu) }
    }
}

/// TransportVersionRequest (wrapper payload field 31).
public struct TransportVersionRequest: StreamPayload {
    /// The probe sends one entry, 9 (section 5.2).
    public static let probe = TransportVersionRequest(supportedVersions: [9])

    public var supportedVersions: [UInt32]

    public init(supportedVersions: [UInt32]) { self.supportedVersions = supportedVersions }

    public init(fields f: [ProtobufField]) throws {
        supportedVersions = f.allVarints(1).map { UInt32(truncatingIfNeeded: $0) }
    }

    public func write(to w: inout ProtobufWriter) {
        for version in supportedVersions { w.varint(1, UInt64(version)) }
    }
}

/// TransportVersionAck (wrapper payload field 32).
public struct TransportVersionAck: StreamPayload {
    public var version: UInt32?
    public init(version: UInt32?) { self.version = version }
    public init(fields f: [ProtobufField]) throws { version = f.optionalUInt32(1) }
    public func write(to w: inout ProtobufWriter) { if let version { w.varint(1, UInt64(version)) } }
}
