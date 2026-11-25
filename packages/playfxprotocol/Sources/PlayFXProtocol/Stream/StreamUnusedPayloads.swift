/// The wrapper's payloads that existing clients neither send nor act on (stream.md section 4.2). They are
/// decoded, and can be encoded again, so an implementation can log them. Log, Debug and ClientMetric stay
/// raw bytes (see `StreamMessage.unparsed`).

/// Info (4): thirteen required uint32 fields, in field order.
public struct InfoMessage: StreamPayload {
    public var effectiveBandwidth, bitrate, minBitrate, targetBitrate, corruptFrameFrequency, mtu, fps: UInt32
    public var monitorInterval, externalOverhead, internalOverhead, timeoutInterval, minResumeQuality, minFps: UInt32

    public init(fields f: [ProtobufField]) throws {
        func u(_ n: Int, _ name: String) throws -> UInt32 { try f.requiredUInt32(n, name) }
        effectiveBandwidth = try u(1, "effectiveBandwidth")
        bitrate = try u(2, "bitrate")
        minBitrate = try u(3, "minBitrate")
        targetBitrate = try u(4, "targetBitrate")
        corruptFrameFrequency = try u(5, "corruptFrameFrequency")
        mtu = try u(6, "mtu")
        fps = try u(7, "fps")
        monitorInterval = try u(8, "monitorInterval")
        externalOverhead = try u(9, "externalOverhead")
        internalOverhead = try u(10, "internalOverhead")
        timeoutInterval = try u(11, "timeoutInterval")
        minResumeQuality = try u(12, "minResumeQuality")
        minFps = try u(13, "minFps")
    }

    public func write(to w: inout ProtobufWriter) {
        let values = [
            effectiveBandwidth, bitrate, minBitrate, targetBitrate, corruptFrameFrequency, mtu, fps,
            monitorInterval, externalOverhead, internalOverhead, timeoutInterval, minResumeQuality, minFps,
        ]
        for (index, value) in values.enumerated() { w.varint(index + 1, UInt64(value)) }
    }
}

/// PacketLoss (5).
public struct PacketLossMessage: StreamPayload {
    public var first, last, packetsReceived: UInt32
    public init(first: UInt32, last: UInt32, packetsReceived: UInt32) {
        self.first = first
        self.last = last
        self.packetsReceived = packetsReceived
    }
    public init(fields f: [ProtobufField]) throws {
        first = try f.requiredUInt32(1, "first")
        last = try f.requiredUInt32(2, "last")
        packetsReceived = try f.requiredUInt32(3, "packetsReceived")
    }
    public func write(to w: inout ProtobufWriter) {
        w.varint(1, UInt64(first))
        w.varint(2, UInt64(last))
        w.varint(3, UInt64(packetsReceived))
    }
}

/// Cursor (8).
public struct CursorMessage: StreamPayload {
    public var id, width, height, hotspotX, hotspotY: UInt32
    public var pixels: [UInt8]?
    public init(id: UInt32, width: UInt32, height: UInt32, hotspotX: UInt32, hotspotY: UInt32, pixels: [UInt8]? = nil) {
        self.id = id
        self.width = width
        self.height = height
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.pixels = pixels
    }
    public init(fields f: [ProtobufField]) throws {
        id = try f.requiredUInt32(1, "id")
        width = try f.requiredUInt32(2, "width")
        height = try f.requiredUInt32(3, "height")
        hotspotX = try f.requiredUInt32(4, "hotspotX")
        hotspotY = try f.requiredUInt32(5, "hotspotY")
        pixels = f.optionalBytes(6)
    }
    public func write(to w: inout ProtobufWriter) {
        w.varint(1, UInt64(id))
        w.varint(2, UInt64(width))
        w.varint(3, UInt64(height))
        w.varint(4, UInt64(hotspotX))
        w.varint(5, UInt64(hotspotY))
        if let pixels { w.bytes(6, pixels) }
    }
}

/// Timer (9).
public struct TimerMessage: StreamPayload {
    public var secondsLeft, totalSeconds: UInt32
    public init(secondsLeft: UInt32, totalSeconds: UInt32) {
        self.secondsLeft = secondsLeft
        self.totalSeconds = totalSeconds
    }
    public init(fields f: [ProtobufField]) throws {
        secondsLeft = try f.requiredUInt32(1, "secondsLeft")
        totalSeconds = try f.requiredUInt32(2, "totalSeconds")
    }
    public func write(to w: inout ProtobufWriter) {
        w.varint(1, UInt64(secondsLeft))
        w.varint(2, UInt64(totalSeconds))
    }
}

/// HeaderRequest (12): 0 audio, 1 video.
public struct HeaderRequestMessage: StreamPayload {
    public var kind: UInt32
    public init(kind: UInt32) { self.kind = kind }
    public init(fields f: [ProtobufField]) throws { kind = try f.requiredUInt32(1, "kind") }
    public func write(to w: inout ProtobufWriter) { w.varint(1, UInt64(kind)) }
}

/// HomeMenuCommand (16): 0 off, 1 on, 2 toggle.
public struct HomeMenuCommandMessage: StreamPayload {
    public var command: UInt32
    public var playerId: UInt32?
    public init(command: UInt32, playerId: UInt32? = nil) {
        self.command = command
        self.playerId = playerId
    }
    public init(fields f: [ProtobufField]) throws {
        command = try f.requiredUInt32(1, "command")
        playerId = f.optionalUInt32(2)
    }
    public func write(to w: inout ProtobufWriter) {
        w.varint(1, UInt64(command))
        if let playerId { w.varint(2, UInt64(playerId)) }
    }
}

/// PlayTimeLeft (19).
public struct PlayTimeLeftMessage: StreamPayload {
    public var timeLeft: UInt32?
    public var reason: String?
    public init(timeLeft: UInt32? = nil, reason: String? = nil) {
        self.timeLeft = timeLeft
        self.reason = reason
    }
    public init(fields f: [ProtobufField]) throws {
        timeLeft = f.optionalUInt32(1)
        reason = f.optionalString(2)
    }
    public func write(to w: inout ProtobufWriter) {
        if let timeLeft { w.varint(1, UInt64(timeLeft)) }
        if let reason { w.string(2, reason) }
    }
}

/// ServerMessage (20).
public struct ServerTextMessage: StreamPayload {
    public var text: String?
    public init(text: String?) { self.text = text }
    public init(fields f: [ProtobufField]) throws { text = f.optionalString(1) }
    public func write(to w: inout ProtobufWriter) { if let text { w.string(1, text) } }
}

/// FpsChange (21).
public struct FpsChangeMessage: StreamPayload {
    public var fps: UInt32
    public init(fps: UInt32) { self.fps = fps }
    public init(fields f: [ProtobufField]) throws { fps = try f.requiredUInt32(1, "fps") }
    public func write(to w: inout ProtobufWriter) { w.varint(1, UInt64(fps)) }
}

/// ClientInfo (23).
public struct ClientInfoMessage: StreamPayload, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "ClientInfoMessage(session key hidden)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
    public var sessionKey: String
    public var gcmTag: UInt32?
    public var keyPosition: UInt32?
    public init(sessionKey: String, gcmTag: UInt32? = nil, keyPosition: UInt32? = nil) {
        self.sessionKey = sessionKey
        self.gcmTag = gcmTag
        self.keyPosition = keyPosition
    }
    public init(fields f: [ProtobufField]) throws {
        sessionKey = try f.requiredString(1, "sessionKey")
        gcmTag = f.optionalUInt32(2)
        keyPosition = f.optionalUInt32(3)
    }
    public func write(to w: inout ProtobufWriter) {
        w.string(1, sessionKey)
        if let gcmTag { w.varint(2, UInt64(gcmTag)) }
        if let keyPosition { w.varint(3, UInt64(keyPosition)) }
    }
}

/// VideoCapture (24): `serverSide` defaults to false, `idrPeriod` to 0.
public struct VideoCaptureMessage: StreamPayload {
    public var serverSide: Bool
    public var idrPeriod: UInt32
    public init(serverSide: Bool = false, idrPeriod: UInt32 = 0) {
        self.serverSide = serverSide
        self.idrPeriod = idrPeriod
    }
    public init(fields f: [ProtobufField]) throws {
        serverSide = f.optionalBool(1) ?? false
        idrPeriod = f.optionalUInt32(2) ?? 0
    }
    public func write(to w: inout ProtobufWriter) {
        w.bool(1, serverSide)
        w.varint(2, UInt64(idrPeriod))
    }
}

/// AudioCapture (25).
public struct AudioCaptureMessage: StreamPayload {
    public var serverSide: Bool?
    public init(serverSide: Bool?) { self.serverSide = serverSide }
    public init(fields f: [ProtobufField]) throws { serverSide = f.optionalBool(1) }
    public func write(to w: inout ProtobufWriter) { if let serverSide { w.bool(1, serverSide) } }
}

/// CryptoTrace (26).
public struct CryptoTraceMessage: StreamPayload {
    public var sequence, gcmTag, keyPosition: UInt32
    public init(sequence: UInt32, gcmTag: UInt32, keyPosition: UInt32) {
        self.sequence = sequence
        self.gcmTag = gcmTag
        self.keyPosition = keyPosition
    }
    public init(fields f: [ProtobufField]) throws {
        sequence = try f.requiredUInt32(1, "sequence")
        gcmTag = try f.requiredUInt32(2, "gcmTag")
        keyPosition = try f.requiredUInt32(3, "keyPosition")
    }
    public func write(to w: inout ProtobufWriter) {
        w.varint(1, UInt64(sequence))
        w.varint(2, UInt64(gcmTag))
        w.varint(3, UInt64(keyPosition))
    }
}

/// PeriodicTimestamp (27).
public struct PeriodicTimestampMessage: StreamPayload {
    public var info: [UInt8]
    public var version: UInt32
    public init(info: [UInt8], version: UInt32) {
        self.info = info
        self.version = version
    }
    public init(fields f: [ProtobufField]) throws {
        info = try f.requiredBytes(1, "info")
        version = try f.requiredUInt32(2, "version")
    }
    public func write(to w: inout ProtobufWriter) {
        w.bytes(1, info)
        w.varint(2, UInt64(version))
    }
}

/// ServerSettings (28).
public struct ServerSettingsMessage: StreamPayload {
    public var idrPeriod: UInt32?
    public var sendPeriodicTimestamp: Bool?
    public init(idrPeriod: UInt32? = nil, sendPeriodicTimestamp: Bool? = nil) {
        self.idrPeriod = idrPeriod
        self.sendPeriodicTimestamp = sendPeriodicTimestamp
    }
    public init(fields f: [ProtobufField]) throws {
        idrPeriod = f.optionalUInt32(1)
        sendPeriodicTimestamp = f.optionalBool(2)
    }
    public func write(to w: inout ProtobufWriter) {
        if let idrPeriod { w.varint(1, UInt64(idrPeriod)) }
        if let sendPeriodicTimestamp { w.bool(2, sendPeriodicTimestamp) }
    }
}

/// DirectMessage (29): kind 0 deep link, 1 mic info; destination 1000 controller service, 1001 client.
public struct DirectMessagePayload: StreamPayload {
    public var kind: UInt32
    public var destination: UInt32
    public var data: [UInt8]?
    public init(kind: UInt32, destination: UInt32, data: [UInt8]? = nil) {
        self.kind = kind
        self.destination = destination
        self.data = data
    }
    public init(fields f: [ProtobufField]) throws {
        kind = try f.requiredUInt32(1, "kind")
        destination = try f.requiredUInt32(2, "destination")
        data = f.optionalBytes(3)
    }
    public func write(to w: inout ProtobufWriter) {
        w.varint(1, UInt64(kind))
        w.varint(2, UInt64(destination))
        if let data { w.bytes(3, data) }
    }
}

/// MicConnection (30).
public struct MicConnectionMessage: StreamPayload {
    public var controllerId: Int32
    public var connected: Bool
    public var result: Bool?
    public init(controllerId: Int32, connected: Bool, result: Bool? = nil) {
        self.controllerId = controllerId
        self.connected = connected
        self.result = result
    }
    public init(fields f: [ProtobufField]) throws {
        controllerId = Int32(truncatingIfNeeded: try f.requiredVarint(1, "controllerId"))
        connected = try f.requiredBool(2, "connected")
        result = f.optionalBool(3)
    }
    public func write(to w: inout ProtobufWriter) {
        w.int32(1, controllerId)
        w.bool(2, connected)
        if let result { w.bool(3, result) }
    }
}
