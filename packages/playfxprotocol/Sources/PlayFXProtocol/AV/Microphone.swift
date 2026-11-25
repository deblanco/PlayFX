/// The microphone upstream (av.md section 8), as pure functions of the encoded frames. The caller runs the
/// Opus encoder with `MicrophoneSettings` and the transport encrypts and frames what `MicrophonePacketizer`
/// returns (takion.md section 7.5).
public enum MicrophoneSettings {
    public static let sampleRate = 48000
    /// The encoder is stereo although the announced header says 1 channel (open question 4).
    public static let channels = 2
    /// Samples per channel per frame (10 ms).
    public static let frameSamples = 480
    /// Interleaved s16 values per frame.
    public static var pcmValuesPerFrame: Int { frameSamples * channels }
    public static let bitrate = 32000
    public static let variableBitrate = false
    /// libopus: `OPUS_APPLICATION_RESTRICTED_LOWDELAY` (CELT only), signal type music, phase inversion off.
    public static let application = "restricted-lowdelay"
    public static let signalMusic = true
    public static let phaseInversionDisabled = true
    /// Every packet is this long; other sizes are not sent.
    public static let packetSize = 40
    /// The unit word: unit index 0, 3 units in total, unit size 40, 2 redundant, 1 source.
    public static let unitWord: UInt32 = 0x0002_2821
    public static let codec: UInt8 = 5
    /// The audio header announced in the client's StreamInfo, `01 10 0000bb80 000001e0 00000001`.
    public static let announcedHeader = AudioHeader(
        channels: 1, bitsPerSample: 16, sampleRate: 48000, frameSize: 480, unknown: 1)
    /// The stream byte of PS5 packets.
    public static let streamByte: UInt8 = 0x00
}

/// One microphone AV packet before encryption: the header fields and the 120-byte payload.
public struct MicrophonePacket: Sendable, Equatable {
    public var packetIndex: UInt16
    public var frameIndex: UInt16
    public var unitWord: UInt32
    public var codec: UInt8
    /// New frame (40) || frame two back (40) || frame one back (40).
    public var payload: [UInt8]
}

/// Builds the packets: a 16-bit counter `c` from 0, `frameIndex = c + 1`, and the two previous frames repeated
/// (the first frame stands in for frames that don't exist yet).
public struct MicrophonePacketizer: Sendable {
    private var counter: UInt16 = 0
    private var first: [UInt8]?
    private var oneBack: [UInt8] = []
    private var twoBack: [UInt8] = []

    public init() {}

    /// The packet for the next 10 ms frame, or nil (and no state change) when the encoded frame isn't 40 bytes.
    public mutating func packet(opusFrame: [UInt8]) -> MicrophonePacket? {
        guard opusFrame.count == MicrophoneSettings.packetSize else { return nil }
        if first == nil {
            first = opusFrame
            oneBack = opusFrame
            twoBack = opusFrame
        }
        let packet = MicrophonePacket(
            packetIndex: counter, frameIndex: counter &+ 1, unitWord: MicrophoneSettings.unitWord,
            codec: MicrophoneSettings.codec, payload: opusFrame + twoBack + oneBack)
        twoBack = oneBack
        oneBack = opusFrame
        counter &+= 1
        return packet
    }
}
