/// The raw-byte bodies the console sends with data types other than 0 (stream.md sections 2.1, 9.6 to 9.9),
/// and one entry point that turns any received data message into a typed value.

/// Rumble levels (data type 7).
public struct RumbleLevels: Sendable, Equatable {
    public var unknown: UInt8
    /// Heavy, low-frequency motor, 0...255.
    public var left: UInt8
    /// Light, high-frequency motor, 0...255.
    public var right: UInt8

    /// Nil for a body shorter than 3 bytes (ignored).
    public init?(body: [UInt8]) {
        guard body.count >= 3 else { return nil }
        unknown = body[0]
        left = body[1]
        right = body[2]
    }
}

/// Adaptive-trigger effects (data type 11, PS5): a mode and 10 parameter bytes per trigger, in the
/// DualSense controller's own trigger format.
public struct TriggerEffects: Sendable, Equatable {
    public var unknown: UInt8
    public var leftMode: UInt8
    public var rightMode: UInt8
    /// Bytes 3 and 4, unknown.
    public var unknownPair: [UInt8]
    public var leftParameters: [UInt8]
    public var rightParameters: [UInt8]

    /// Nil for a body shorter than 25 bytes (ignored).
    public init?(body: [UInt8]) {
        guard body.count >= 25 else { return nil }
        unknown = body[0]
        leftMode = body[1]
        rightMode = body[2]
        unknownPair = Array(body[3..<5])
        leftParameters = Array(body[5..<15])
        rightParameters = Array(body[15..<25])
    }
}

/// The DualSense vibration or trigger strength setting reported in pad info.
public enum DualSenseIntensity: UInt8, Sendable, Equatable {
    case off = 0, strong, medium, weak
}

/// Pad info (data type 9): player index, light-bar colour, motion reset and the DualSense intensities.
public struct PadInfo: Sendable, Equatable {
    /// 0 = player 1.
    public var playerIndex: UInt8
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    /// Non-zero in the body: take the controller's current orientation as the new origin.
    public var motionReset: Bool
    public var hapticsIntensityRaw: UInt8
    public var triggerIntensityRaw: UInt8
    /// Only in the 25-byte form: the sequence number of the feedback packet this answers (assumed).
    public var sequence: UInt16?
    /// Only in the 25-byte form: a time stamp (assumed seconds since the stream began).
    public var timestamp: UInt32?

    /// `nil` unless the value is one of the four known strengths.
    public var hapticsIntensity: DualSenseIntensity? { DualSenseIntensity(rawValue: hapticsIntensityRaw) }
    public var triggerIntensity: DualSenseIntensity? { DualSenseIntensity(rawValue: triggerIntensityRaw) }

    /// Nil unless the body is 17 or 25 bytes (other sizes are ignored).
    public init?(body b: [UInt8]) {
        switch b.count {
        case 25:
            sequence = UInt16(b[0]) << 8 | UInt16(b[1])
            timestamp = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
            (playerIndex, red, green, blue, motionReset) = (b[8], b[9], b[10], b[11], b[12] != 0)
            (hapticsIntensityRaw, triggerIntensityRaw) = (b[20], b[21])
        case 17:
            (playerIndex, red, green, blue, motionReset) = (b[0], b[1], b[2], b[3], b[4] != 0)
            (hapticsIntensityRaw, triggerIntensityRaw) = (b[12], b[13])
        default:
            return nil
        }
    }
}

/// The haptics stream's PCM format (section 9.9): played by the DualSense's two voice-coil actuators.
public enum StreamHapticsFormat {
    public static let sampleRate = 3000
    public static let channels = 2
    /// Signed 16-bit, interleaved, little-endian (assumed from working playback).
    public static let bytesPerSample = 2
}

/// A received Takion data message, typed.
public enum StreamInbound: Sendable, Equatable {
    case message(StreamMessage)
    case rumble(RumbleLevels)
    case triggerEffects(TriggerEffects)
    case padInfo(PadInfo)
    /// An unknown data type, or a body of a size the spec says to ignore.
    case ignored

    /// Takion data types (section 2.1).
    public enum DataType {
        public static let protobuf: UInt8 = 0
        public static let rumble: UInt8 = 7
        public static let padInfo: UInt8 = 9
        public static let triggerEffects: UInt8 = 11
    }

    /// Parses the body of a reliable data message. Throws only for a data-type-0 body that isn't a valid
    /// wrapper, or whose message type the client acts on doesn't decode (a malformed body of any other type
    /// becomes `.message(.unparsed)`); everything else that doesn't fit becomes `.ignored`.
    public static func parse(dataType: UInt8, body: [UInt8]) throws -> StreamInbound {
        switch dataType {
        case DataType.protobuf:
            do { return .message(try StreamMessage.decode(body)) } catch let error as ProtobufError {
                // A body that doesn't decode is an error only for types the client acts on.
                let fields = try ProtobufReader.fields(of: body)
                if let raw = fields.optionalVarint(1), let type = StreamMessageType(rawValue: raw), !type.isActedOn,
                    let field = type.payloadField, let payload = fields.optionalBytes(field)
                {
                    return .message(.unparsed(type: type, payload: payload))
                }
                throw error
            }
        case DataType.rumble: return RumbleLevels(body: body).map { .rumble($0) } ?? .ignored
        case DataType.triggerEffects: return TriggerEffects(body: body).map { .triggerEffects($0) } ?? .ignored
        case DataType.padInfo: return PadInfo(body: body).map { .padInfo($0) } ?? .ignored
        default: return .ignored
        }
    }
}
