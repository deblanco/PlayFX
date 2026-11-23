/// One AV packet as the audio/video layer sees it: the header fields of takion.md section 7.2 that av.md
/// uses, and the decrypted payload. The transport fills it in on its receive thread.
///
/// `payload` points into the transport's buffer and is only valid for the call it is passed to; the layer
/// copies what it keeps.
public struct AVUnit {
    public enum Kind: UInt8, Sendable {
        case video = 2
        case audio = 3
    }

    public var kind: Kind
    /// Per-stream packet counter (not used by the assembly).
    public var packetIndex: UInt16
    /// Video: the frame this unit belongs to. Audio: the frame index of the packet's first source unit.
    public var frameIndex: UInt16
    /// The raw 32-bit unit word. Read it with `video` or `audio`.
    public var unitWord: UInt32
    public var codec: UInt8
    /// Bit 4 of byte 0 of the packet. The 3 extension bytes are already skipped by the transport.
    public var extensionFlag: Bool
    /// Video only: the stream-info resolution (profile) this frame uses.
    public var adaptiveStreamIndex: UInt8
    /// PS5 (takionVersion 12) audio packets: the stream byte, `0x02` = haptics. Nil on PS4 audio.
    public var streamByte: UInt8?
    /// Video only: the 16-bit field at offset 18 (meaning unknown, ignored).
    public var offset18: UInt16
    public var payload: UnsafeRawBufferPointer

    public init(
        kind: Kind, packetIndex: UInt16 = 0, frameIndex: UInt16, unitWord: UInt32, codec: UInt8,
        extensionFlag: Bool = false, adaptiveStreamIndex: UInt8 = 0, streamByte: UInt8? = nil,
        offset18: UInt16 = 0, payload: UnsafeRawBufferPointer
    ) {
        self.kind = kind
        self.packetIndex = packetIndex
        self.frameIndex = frameIndex
        self.unitWord = unitWord
        self.codec = codec
        self.extensionFlag = extensionFlag
        self.adaptiveStreamIndex = adaptiveStreamIndex
        self.streamByte = streamByte
        self.offset18 = offset18
        self.payload = payload
    }

    /// The unit word of a video packet (av.md section 1).
    public struct VideoWord: Equatable, Sendable {
        public var unitIndex: Int
        /// `unitsTotal`: source plus parity units.
        public var unitsTotal: Int
        public var fecUnits: Int

        public init(_ word: UInt32) {
            unitIndex = Int(word >> 21)
            unitsTotal = Int((word >> 10) & 0x7ff) + 1
            fecUnits = Int(word & 0x3ff)
        }
    }

    /// The unit word of an audio packet (av.md section 1).
    public struct AudioWord: Equatable, Sendable {
        public var unitIndex: Int
        public var unitsTotal: Int
        public var unitSize: Int
        public var redundantUnits: Int
        public var sourceUnits: Int

        public init(_ word: UInt32) {
            unitIndex = Int(word >> 24)
            unitsTotal = Int((word >> 16) & 0xff) + 1
            unitSize = Int((word >> 8) & 0xff)
            redundantUnits = Int((word >> 4) & 0xf)
            sourceUnits = Int(word & 0xf)
        }
    }

    public var video: VideoWord { VideoWord(unitWord) }
    public var audio: AudioWord { AudioWord(unitWord) }

    /// `streamByte` of a PS5 haptics packet.
    public static let hapticsStreamByte: UInt8 = 0x02
    /// `codec` of every audio packet (Opus).
    public static let opusCodec: UInt8 = 5
}

/// 16-bit serial-number arithmetic (RFC 1982, av.md section 4.1).
enum Serial16 {
    /// `a` is newer than `b`.
    @inline(__always)
    static func isNewer(_ a: UInt16, than b: UInt16) -> Bool {
        let d = a &- b
        return d != 0 && d < 0x8000
    }

    /// `a` is older than `b`.
    @inline(__always)
    static func isOlder(_ a: UInt16, than b: UInt16) -> Bool {
        let d = a &- b
        return d > 0x8000
    }
}
