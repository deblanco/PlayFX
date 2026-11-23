/// The wrapper every protobuf message travels in (stream.md section 3.2), as a typed value.

/// Wrapper `type` values.
public enum StreamMessageType: UInt64, Sendable, Equatable, CaseIterable {
    case hello = 0, helloReply, info, heartbeat, packetLoss, corruptFrame, cursor, timer, disconnect, log
    case headerRequest, debug, probe, streamInfo, streamInfoAck, homeMenuCommand, connectionQuality
    case clientMetric, playTimeLeft, serverMessage, fpsChange, controllerConnection, clientInfo
    case videoCapture, audioCapture, idrRequest, cryptoTrace, periodicTimestamp, serverSettings
    case directMessage, micConnection, transportVersionRequest, transportVersionAck

    /// Types a client acts on when the console sends them. A malformed body of any other type is kept as raw
    /// bytes instead of being an error (`StreamInbound.parse`).
    public var isActedOn: Bool {
        switch self {
        case .helloReply, .disconnect, .streamInfo, .probe, .connectionQuality, .transportVersionAck,
            .corruptFrame, .hello, .heartbeat, .streamInfoAck, .idrRequest, .controllerConnection,
            .transportVersionRequest:
            true
        default: false
        }
    }

    /// The wrapper field that carries this type's payload; nil for the three types without one.
    /// There is no payload field 7.
    public var payloadField: Int? {
        switch self {
        case .heartbeat, .streamInfoAck, .idrRequest: nil
        case .hello: 2
        case .helloReply: 3
        case .info: 4
        case .packetLoss: 5
        case .corruptFrame: 6
        case .cursor: 8
        case .timer: 9
        case .disconnect: 10
        case .log: 11
        case .headerRequest: 12
        case .debug: 13
        case .probe: 14
        case .streamInfo: 15
        case .homeMenuCommand: 16
        case .connectionQuality: 17
        case .clientMetric: 18
        case .playTimeLeft: 19
        case .serverMessage: 20
        case .fpsChange: 21
        case .controllerConnection: 22
        case .clientInfo: 23
        case .videoCapture: 24
        case .audioCapture: 25
        case .cryptoTrace: 26
        case .periodicTimestamp: 27
        case .serverSettings: 28
        case .directMessage: 29
        case .micConnection: 30
        case .transportVersionRequest: 31
        case .transportVersionAck: 32
        }
    }
}

/// A decoded wrapper.
public enum StreamMessage: Sendable, Equatable {
    case hello(HelloMessage)
    case helloReply(HelloReplyMessage)
    case info(InfoMessage)
    case heartbeat
    case packetLoss(PacketLossMessage)
    case corruptFrame(CorruptFrameMessage)
    case cursor(CursorMessage)
    case timer(TimerMessage)
    case disconnect(DisconnectMessage)
    case headerRequest(HeaderRequestMessage)
    case probe(ProbeMessage)
    case streamInfo(StreamInfoMessage)
    case streamInfoAck
    case homeMenuCommand(HomeMenuCommandMessage)
    case connectionQuality(ConnectionQualityMessage)
    case playTimeLeft(PlayTimeLeftMessage)
    case serverMessage(ServerTextMessage)
    case fpsChange(FpsChangeMessage)
    case controllerConnection(ControllerConnectionMessage)
    case clientInfo(ClientInfoMessage)
    case videoCapture(VideoCaptureMessage)
    case audioCapture(AudioCaptureMessage)
    case idrRequest
    case cryptoTrace(CryptoTraceMessage)
    case periodicTimestamp(PeriodicTimestampMessage)
    case serverSettings(ServerSettingsMessage)
    case directMessage(DirectMessagePayload)
    case micConnection(MicConnectionMessage)
    case transportVersionRequest(TransportVersionRequest)
    case transportVersionAck(TransportVersionAck)
    /// Log, Debug and ClientMetric: the payload bytes, not interpreted.
    case unparsed(type: StreamMessageType, payload: [UInt8])
    /// A `type` this spec doesn't list.
    case unknown(type: UInt64)

    public var type: StreamMessageType? {
        switch self {
        case .hello: .hello
        case .helloReply: .helloReply
        case .info: .info
        case .heartbeat: .heartbeat
        case .packetLoss: .packetLoss
        case .corruptFrame: .corruptFrame
        case .cursor: .cursor
        case .timer: .timer
        case .disconnect: .disconnect
        case .headerRequest: .headerRequest
        case .probe: .probe
        case .streamInfo: .streamInfo
        case .streamInfoAck: .streamInfoAck
        case .homeMenuCommand: .homeMenuCommand
        case .connectionQuality: .connectionQuality
        case .playTimeLeft: .playTimeLeft
        case .serverMessage: .serverMessage
        case .fpsChange: .fpsChange
        case .controllerConnection: .controllerConnection
        case .clientInfo: .clientInfo
        case .videoCapture: .videoCapture
        case .audioCapture: .audioCapture
        case .idrRequest: .idrRequest
        case .cryptoTrace: .cryptoTrace
        case .periodicTimestamp: .periodicTimestamp
        case .serverSettings: .serverSettings
        case .directMessage: .directMessage
        case .micConnection: .micConnection
        case .transportVersionRequest: .transportVersionRequest
        case .transportVersionAck: .transportVersionAck
        case .unparsed(let type, _): type
        case .unknown: nil
        }
    }

    private var payloadBytes: [UInt8]? {
        switch self {
        case .hello(let p): p.encoded
        case .helloReply(let p): p.encoded
        case .info(let p): p.encoded
        case .packetLoss(let p): p.encoded
        case .corruptFrame(let p): p.encoded
        case .cursor(let p): p.encoded
        case .timer(let p): p.encoded
        case .disconnect(let p): p.encoded
        case .headerRequest(let p): p.encoded
        case .probe(let p): p.encoded
        case .streamInfo(let p): p.encoded
        case .homeMenuCommand(let p): p.encoded
        case .connectionQuality(let p): p.encoded
        case .playTimeLeft(let p): p.encoded
        case .serverMessage(let p): p.encoded
        case .fpsChange(let p): p.encoded
        case .controllerConnection(let p): p.encoded
        case .clientInfo(let p): p.encoded
        case .videoCapture(let p): p.encoded
        case .audioCapture(let p): p.encoded
        case .cryptoTrace(let p): p.encoded
        case .periodicTimestamp(let p): p.encoded
        case .serverSettings(let p): p.encoded
        case .directMessage(let p): p.encoded
        case .micConnection(let p): p.encoded
        case .transportVersionRequest(let p): p.encoded
        case .transportVersionAck(let p): p.encoded
        case .unparsed(_, let payload): payload
        case .heartbeat, .streamInfoAck, .idrRequest, .unknown: nil
        }
    }

    /// The wrapper bytes: the message body of a Takion data message (data type 0).
    public var encoded: [UInt8] {
        var w = ProtobufWriter()
        switch self {
        case .unknown(let raw): w.varint(1, raw)
        default:
            // `type` is non-nil for every case but `.unknown`.
            let kind = self.type!
            w.varint(1, kind.rawValue)
            if let field = kind.payloadField, let body = payloadBytes { w.bytes(field, body) }
        }
        return w.encoded
    }

    /// Decodes a wrapper. A known type whose payload field is missing, or a payload that doesn't decode,
    /// throws; an unlisted type becomes `.unknown`.
    public static func decode(_ bytes: [UInt8]) throws -> StreamMessage {
        let fields = try ProtobufReader.fields(of: bytes)
        let raw = try fields.requiredVarint(1, "type")
        guard let type = StreamMessageType(rawValue: raw) else { return .unknown(type: raw) }
        guard let field = type.payloadField else {
            switch type {
            case .heartbeat: return .heartbeat
            case .streamInfoAck: return .streamInfoAck
            default: return .idrRequest
            }
        }
        let body = try fields.requiredBytes(field, "payload \(field)")
        switch type {
        case .hello: return .hello(try HelloMessage(decoding: body))
        case .helloReply: return .helloReply(try HelloReplyMessage(decoding: body))
        case .info: return .info(try InfoMessage(decoding: body))
        case .packetLoss: return .packetLoss(try PacketLossMessage(decoding: body))
        case .corruptFrame: return .corruptFrame(try CorruptFrameMessage(decoding: body))
        case .cursor: return .cursor(try CursorMessage(decoding: body))
        case .timer: return .timer(try TimerMessage(decoding: body))
        case .disconnect: return .disconnect(try DisconnectMessage(decoding: body))
        case .headerRequest: return .headerRequest(try HeaderRequestMessage(decoding: body))
        case .probe: return .probe(try ProbeMessage(decoding: body))
        case .streamInfo: return .streamInfo(try StreamInfoMessage(decoding: body))
        case .homeMenuCommand: return .homeMenuCommand(try HomeMenuCommandMessage(decoding: body))
        case .connectionQuality: return .connectionQuality(try ConnectionQualityMessage(decoding: body))
        case .playTimeLeft: return .playTimeLeft(try PlayTimeLeftMessage(decoding: body))
        case .serverMessage: return .serverMessage(try ServerTextMessage(decoding: body))
        case .fpsChange: return .fpsChange(try FpsChangeMessage(decoding: body))
        case .controllerConnection: return .controllerConnection(try ControllerConnectionMessage(decoding: body))
        case .clientInfo: return .clientInfo(try ClientInfoMessage(decoding: body))
        case .videoCapture: return .videoCapture(try VideoCaptureMessage(decoding: body))
        case .audioCapture: return .audioCapture(try AudioCaptureMessage(decoding: body))
        case .cryptoTrace: return .cryptoTrace(try CryptoTraceMessage(decoding: body))
        case .periodicTimestamp: return .periodicTimestamp(try PeriodicTimestampMessage(decoding: body))
        case .serverSettings: return .serverSettings(try ServerSettingsMessage(decoding: body))
        case .directMessage: return .directMessage(try DirectMessagePayload(decoding: body))
        case .micConnection: return .micConnection(try MicConnectionMessage(decoding: body))
        case .transportVersionRequest:
            return .transportVersionRequest(try TransportVersionRequest(decoding: body))
        case .transportVersionAck: return .transportVersionAck(try TransportVersionAck(decoding: body))
        case .log, .debug, .clientMetric: return .unparsed(type: type, payload: body)
        case .heartbeat, .streamInfoAck, .idrRequest: return .unknown(type: raw)  // unreachable: no payload field
        }
    }
}

// MARK: Outgoing messages, with the channel each goes out on (section 2.1)

/// A message the client sends: its wrapper bytes and the Takion channel. All go out as data type 0 with
/// chunk flags 1 (the Hello may be split, see `StreamMessageSplit`).
public struct OutgoingStreamMessage: Sendable, Equatable {
    public var channel: UInt16
    public var bytes: [UInt8]
    /// Takion data type: 0 for everything the client sends.
    public var dataType: UInt8 { 0 }

    public init(channel: UInt16, message: StreamMessage) {
        self.channel = channel
        bytes = message.encoded
    }

    /// Heartbeat, every second from the end of the handshake (channel 1).
    public static let heartbeat = OutgoingStreamMessage(channel: 1, message: .heartbeat)
    /// StreamInfoAck (channel 9).
    public static let streamInfoAck = OutgoingStreamMessage(channel: 9, message: .streamInfoAck)
    /// IdrRequest (channel 2).
    public static let idrRequest = OutgoingStreamMessage(channel: 2, message: .idrRequest)
    /// Disconnect "Client Disconnecting" (channel 1); also ends the probe.
    public static let disconnect = OutgoingStreamMessage(channel: 1, message: .disconnect(.client))
    /// The microphone StreamInfo (channel 1).
    public static let microphoneStreamInfo = OutgoingStreamMessage(channel: 1, message: .streamInfo(.microphone))
    /// The probe's version request (channel 1).
    public static let probeVersionRequest = OutgoingStreamMessage(
        channel: 1, message: .transportVersionRequest(.probe))
    /// The probe's Hello (channel 1).
    public static let probeHello = OutgoingStreamMessage(channel: 1, message: .hello(.probe))

    /// CorruptFrame {first, last} (channel 2); frame indices are the 16-bit frame counter.
    public static func corruptFrame(first: UInt16, last: UInt16) -> OutgoingStreamMessage {
        OutgoingStreamMessage(
            channel: 2, message: .corruptFrame(CorruptFrameMessage(firstFrame: first, lastFrame: last)))
    }

    /// ControllerConnection (channel 1).
    public static func controllerConnection(dualSense: Bool) -> OutgoingStreamMessage {
        OutgoingStreamMessage(channel: 1, message: .controllerConnection(.connected(dualSense: dualSense)))
    }

    /// A probe command (channel 8).
    public static func probe(_ message: ProbeMessage) -> OutgoingStreamMessage {
        OutgoingStreamMessage(channel: 8, message: .probe(message))
    }
}
