import Foundation

// Takion packet encodings and decodings (takion.md §2–§5, §7–§9). Builders return plain arrays (the send path
// may allocate); parsers read raw buffers, never trap on short or hostile input and return nil instead.

enum TakionPacketType: UInt8, Sendable {
    case control = 0
    case feedbackHistory = 1
    case video = 2
    case audio = 3
    case congestion = 5
    case feedbackState = 6
}

enum TakionChunkType: UInt8, Sendable {
    case data = 0x00
    case initiate = 0x01
    case initAck = 0x02
    case dataAck = 0x03
    case cookie = 0x0a
    case cookieAck = 0x0b
}

/// Constants of the transport (takion.md §4, §5).
enum TakionConstants {
    static let advertisedWindow: UInt32 = 0x0001_9000
    static let controlHeaderSize = 17
    static let dataAckSize = 29
    static let congestionSize = 15
    static let receiveWindow = 16
    static let maxDatagram = 2048
}

/// Fields of the 17-byte control header (§3.1).
struct TakionControlHeader: Sendable, Equatable {
    var tag: UInt32
    var gmac: UInt32
    var keyPosLow: UInt32
    var chunkType: UInt8
    var flags: UInt8
    var chunkLength: Int

    /// Nil unless the datagram is at least 17 bytes, a control packet, and `length − 13 = chunk length`.
    @_optimize(speed) static func parse(_ d: UnsafeRawBufferPointer) -> TakionControlHeader? {
        guard d.count >= TakionConstants.controlHeaderSize, d[0] & 0x0f == 0 else { return nil }
        let chunkLength = Int(d.be16(15))
        guard d.count - 13 == chunkLength else { return nil }
        return TakionControlHeader(tag: d.be32(1), gmac: d.be32(5), keyPosLow: d.be32(9), chunkType: d[13],
                                   flags: d[14], chunkLength: chunkLength)
    }
}

/// The console's INIT_ACK (§4.2) with the checks the client makes.
struct TakionInitAck: Sendable, Equatable {
    var consoleTag: UInt32
    var advertisedWindow: UInt32
    var outboundStreams: Int
    var inboundStreams: Int
    var initialTSN: UInt32
    var cookie: [UInt8]

    @_optimize(speed) static func parse(_ d: UnsafeRawBufferPointer, clientTag: UInt32) -> TakionInitAck? {
        guard d.count >= 65, let h = TakionControlHeader.parse(d), h.tag == clientTag,
              h.chunkType == TakionChunkType.initAck.rawValue, h.flags == 0 else { return nil }
        let consoleTag = d.be32(17)
        let out = Int(d.be16(25))
        let inbound = Int(d.be16(27))
        guard consoleTag != 0, out >= 1, out <= 100, inbound >= 100 else { return nil }
        return TakionInitAck(consoleTag: consoleTag, advertisedWindow: d.be32(21), outboundStreams: out,
                             inboundStreams: inbound, initialTSN: d.be32(29), cookie: Array(d[33..<65]))
    }
}

/// A DATA chunk as received (§5.1); `messageOffset` is where the message bytes start in the datagram.
struct TakionDataChunk: Sendable, Equatable {
    var tsn: UInt32
    var channel: UInt16
    var flags: UInt8
    /// The data-type byte at payload offset 8 (valid for a first fragment; a continuation has none).
    var dataType: UInt8

    static let firstMessageOffset = 26
    static let continuationOffset = 25

    /// Nil when the datagram is not a well formed DATA chunk with at least 9 payload bytes.
    @_optimize(speed) static func parse(_ d: UnsafeRawBufferPointer) -> TakionDataChunk? {
        guard let h = TakionControlHeader.parse(d), h.chunkType == TakionChunkType.data.rawValue,
              d.count >= firstMessageOffset else { return nil }
        return TakionDataChunk(tsn: d.be32(17), channel: d.be16(21), flags: h.flags, dataType: d[25])
    }
}

/// A DATA_ACK (§5.5).
struct TakionDataAck: Sendable, Equatable {
    var cumulativeTSN: UInt32
    var advertisedWindow: UInt32
    var gapBlocks: Int
    var duplicates: Int

    /// Nil unless the chunk length is exactly 12 + 4·g payload bytes.
    @_optimize(speed) static func parse(_ d: UnsafeRawBufferPointer) -> TakionDataAck? {
        guard let h = TakionControlHeader.parse(d), h.chunkType == TakionChunkType.dataAck.rawValue,
              d.count >= 29 else { return nil }
        let g = Int(d.be16(25))
        guard d.count - 17 == 12 + 4 * g else { return nil }
        return TakionDataAck(cumulativeTSN: d.be32(17), advertisedWindow: d.be32(21), gapBlocks: g,
                             duplicates: Int(d.be16(27)))
    }
}

/// Encoders for the control packets, GMAC and `keyPos` left zero (the connection seals them).
enum TakionWire {
    private static func control(tag: UInt32, chunk: TakionChunkType, flags: UInt8, payload: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 17 + payload.count)
        out.withUnsafeMutableBytes {
            $0.putBE32(tag, at: 1)
            $0[13] = chunk.rawValue
            $0[14] = flags
            $0.putBE16(UInt16(payload.count + 4), at: 15)
        }
        out.replaceSubrange(17..., with: payload)
        return out
    }

    private static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    private static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }

    /// INIT (§4.1): 33 bytes.
    static func initiate(clientTag: UInt32) -> [UInt8] {
        control(tag: 0, chunk: .initiate, flags: 0,
                payload: be32(clientTag) + be32(TakionConstants.advertisedWindow) + be16(100) + be16(100) + be32(clientTag))
    }

    /// INIT_ACK (§4.2), as a console would send it: 65 bytes.
    static func initAck(clientTag: UInt32, consoleTag: UInt32, initialTSN: UInt32, cookie: [UInt8]) -> [UInt8] {
        control(tag: clientTag, chunk: .initAck, flags: 0,
                payload: be32(consoleTag) + be32(TakionConstants.advertisedWindow) + be16(100) + be16(100)
                    + be32(initialTSN) + cookie)
    }

    /// COOKIE (§4.3): 49 bytes.
    static func cookie(consoleTag: UInt32, cookie: [UInt8]) -> [UInt8] {
        control(tag: consoleTag, chunk: .cookie, flags: 0, payload: cookie)
    }

    /// COOKIE_ACK (§4.4): 17 bytes.
    static func cookieAck(clientTag: UInt32) -> [UInt8] {
        control(tag: clientTag, chunk: .cookieAck, flags: 0, payload: [])
    }

    /// A DATA chunk (§5.1). `dataType` is nil for a continuation fragment.
    static func data(tag: UInt32, tsn: UInt32, channel: UInt16, dataType: UInt8?, flags: UInt8,
                     message: ArraySlice<UInt8>) -> [UInt8] {
        let prefix = be32(tsn) + be16(channel) + [0, 0] + (dataType.map { [$0] } ?? [])
        return control(tag: tag, chunk: .data, flags: flags, payload: prefix + message)
    }

    /// A DATA_ACK without gap blocks (§5.5): 29 bytes.
    static func dataAck(tag: UInt32, cumulativeTSN: UInt32) -> [UInt8] {
        control(tag: tag, chunk: .dataAck, flags: 0,
                payload: be32(cumulativeTSN) + be32(TakionConstants.advertisedWindow) + be16(0) + be16(0))
    }

    /// A congestion report (§8.1): 15 bytes.
    static func congestion(received: UInt16, lost: UInt16) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: TakionConstants.congestionSize)
        out[0] = TakionPacketType.congestion.rawValue
        out[3] = UInt8(received >> 8)
        out[4] = UInt8(received & 0xff)
        out[5] = UInt8(lost >> 8)
        out[6] = UInt8(lost & 0xff)
        return out
    }

    /// The 12-byte header of a feedback packet followed by the (still plain) body (§9.1).
    static func feedback(type: TakionPacketType, sequence: UInt16, byte3: UInt8, body: [UInt8]) -> [UInt8] {
        [type.rawValue, UInt8(sequence >> 8), UInt8(sequence & 0xff), byte3, 0, 0, 0, 0, 0, 0, 0, 0] + body
    }

    /// A client microphone packet (§7.5), body still plain: `payload` is the 120 bytes to encrypt.
    static func microphone(packetIndex: UInt16, version: Int, payload: [UInt8]) -> [UInt8] {
        let frame = packetIndex &+ 1
        var out: [UInt8] = [0x03, UInt8(packetIndex >> 8), UInt8(packetIndex & 0xff), UInt8(frame >> 8), UInt8(frame & 0xff),
                            0x00, 0x02, 0x28, 0x21, 0x05, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        if version >= 12 { out.append(0) }
        return out + payload
    }
}

/// What the layer above gets for each AV packet (§7.3): the parsed header fields; `av.md` takes it from here.
struct TakionAVHeader: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case video, audio, haptics }
    var kind: Kind
    var packetIndex: UInt16
    var frameIndex: UInt16
    var unitIndex: Int
    /// Total units of the frame, FEC units included.
    var totalUnits: Int
    var fecUnits: Int
    /// Audio only: the source units and the unit size of the unit word's low half.
    var sourceUnits: Int
    var unitSize: Int
    var codec: UInt8
    /// Video only: the 16-bit field at offset 18 and the adaptive stream index (`byte 20 >> 5`).
    var field18: UInt16
    var adaptiveStreamIndex: UInt8
    var extensionFlag: Bool
    /// The low 32 bits of `keyPos` as carried.
    var keyPosLow: UInt32

    var isVideo: Bool { kind == .video }
}

enum TakionAV {
    static let gmacOffset = 10
    static let keyPosOffset = 14

    /// Parses the header of `d` for a Takion version (7, 9 or 12). Returns the header and the offset where the
    /// payload starts, or nil when `d` is too short or not an AV packet. Does not look at the GMAC.
    @_optimize(speed) static func parse(_ d: UnsafeRawBufferPointer, version: Int) -> (header: TakionAVHeader, payloadOffset: Int)? {
        guard d.count >= 18 else { return nil }
        let type = d[0] & 0x0f
        guard type == TakionPacketType.video.rawValue || type == TakionPacketType.audio.rawValue else { return nil }
        let video = type == TakionPacketType.video.rawValue
        let ext = d[0] & 0x10 != 0
        let word = d.be32(5)
        var header = TakionAVHeader(kind: video ? .video : .audio, packetIndex: d.be16(1), frameIndex: d.be16(3),
                                    unitIndex: 0, totalUnits: 0, fecUnits: 0, sourceUnits: 0, unitSize: 0,
                                    codec: d[9], field18: 0, adaptiveStreamIndex: 0, extensionFlag: ext,
                                    keyPosLow: d.be32(14))
        let extra = ext ? 3 : 0
        let payloadOffset: Int
        let audioLayout = !video && version != 7
        if audioLayout {
            header.unitIndex = Int(word >> 24)
            header.totalUnits = Int((word >> 16) & 0xff) + 1
            header.unitSize = Int((word >> 8) & 0xff)
            header.fecUnits = Int((word >> 4) & 0xf)
            header.sourceUnits = Int(word & 0xf)
        } else {
            header.unitIndex = Int(word >> 21)
            header.totalUnits = Int((word >> 10) & 0x7ff) + 1
            header.fecUnits = Int(word & 0x3ff)
        }
        if video {
            guard d.count >= 21, version == 7 || d.count >= 25 else { return nil }
            header.field18 = d.be16(18)
            header.adaptiveStreamIndex = d[20] >> 5
            payloadOffset = 21 + extra
        } else if version == 7 {
            payloadOffset = 18 + extra
        } else if version == 12 {
            let streamAt = 19 + extra
            guard d.count >= 21, d.count > streamAt else { return nil }
            if d[streamAt] == 0x02 { header.kind = .haptics }
            payloadOffset = streamAt + 1
        } else {
            guard d.count >= 20 else { return nil }
            payloadOffset = 19 + extra
        }
        guard payloadOffset <= d.count else { return nil }
        return (header, payloadOffset)
    }
}

/// The probe's raw ping and pong datagrams (stream.md §5.4, takion.md §7.4).
enum TakionProbe {
    static let pingSize = 548

    /// A ping for unit `unit` with a 32-bit `tag`, `size` bytes long (548 for the RTT test; any size ≥ 26 for
    /// the outbound MTU test).
    static func ping(unit: Int, tag: UInt32, size: Int = pingSize) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: max(size, 26))
        let word = UInt32(0x7ff << 10) | (UInt32(unit & 0x7ff) << 21)
        out[0] = 0x03
        out[1] = 0
        out.withUnsafeMutableBytes {
            $0.putBE32(word, at: 5)
            $0[9] = 0xff
            $0.putBE32(tag, at: 22)
        }
        return out
    }

    /// True when `datagram` is the pong for ping `unit`/`tag`: an audio-type packet in the version-7 layout whose
    /// frame index is 0 and unit index is `unit`, with at least 8 data bytes whose bytes 4..7 equal `tag`.
    static func isPong(_ d: UnsafeRawBufferPointer, unit: Int, tag: UInt32) -> Bool {
        guard d.count >= 18, d[0] & 0x0f == TakionPacketType.audio.rawValue, d.be16(3) == 0,
              Int(d.be32(5) >> 21) == unit else { return false }
        let data = d[0] & 0x10 != 0 ? 21 : 18
        guard d.count >= data + 8 else { return false }
        return d.be32(data + 4) == tag
    }
}
