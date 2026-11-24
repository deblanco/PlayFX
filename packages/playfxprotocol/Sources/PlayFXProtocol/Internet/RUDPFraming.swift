// RUDP framing (rudp.md sections 1 to 5, 8): the 8-byte message header, chained messages, and builders for every
// message the client sends.

/// One RUDP message: a type and its data (the header's length and constant are implied).
public struct RUDPMessage: Sendable, Equatable {
    /// `type`, BE16 (rudp.md section 2).
    public var type: UInt16
    /// The message's data bytes.
    public var data: [UInt8]

    public init(type: UInt16, data: [UInt8]) {
        self.type = type
        self.data = data
    }

    /// The type's first byte, which the receiver dispatches on.
    public var flags: UInt8 { UInt8(type >> 8) }

    /// Data bytes 0-1 as BE16, when there are at least two.
    public var peerSeq: UInt16? { data.count >= 2 ? UInt16(data[0]) << 8 | UInt16(data[1]) : nil }
}

/// The known `type` values (rudp.md section 2).
public enum RUDPType {
    public static let initiate: UInt16 = 0x8030
    public static let initiateAck: UInt16 = 0xD000
    public static let cookie: UInt16 = 0x9030
    public static let cookieAck: UInt16 = 0xA030
    public static let request: UInt16 = 0x2030
    public static let data: UInt16 = 0x0230
    public static let ack: UInt16 = 0x2430
    public static let finish: UInt16 = 0xC000
}

/// Encoding and decoding of RUDP datagrams.
public enum RUDPFraming {
    /// `24 4f 24 4f` in every message.
    public static let constant: [UInt8] = [0x24, 0x4f, 0x24, 0x4f]
    /// A message is at most 4095 bytes with its header (12-bit length).
    public static let maxMessageLength = 4095
    /// The longest data of one message.
    public static let maxDataLength = maxMessageLength - 8
    /// INIT and COOKIE data after `seq`: `0b 01 01 00 01 00`.
    static let handshakeConstant: [UInt8] = [0x0b, 0x01, 0x01, 0x00, 0x01, 0x00]
    /// The two bytes closing INIT and COOKIE: `05 82`.
    static let handshakeTrailer: [UInt8] = [0x05, 0x82]
    /// The trailing bytes of the client's ACK: `00 92`.
    static let ackTrailer: [UInt8] = [0x00, 0x92]
    /// Bytes 2-9 of the switch message: a ctrl header with payload length 16 and type `0x000D`.
    static let switchHeader: [UInt8] = [0x00, 0x00, 0x00, 0x10, 0x00, 0x0d, 0x00, 0x00]

    static func be16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xff)] }

    /// One message with the client's `lenField` (high nibble `0xC`). `data` must fit (`maxDataLength`).
    public static func encode(type: UInt16, data: [UInt8]) -> [UInt8] {
        precondition(data.count <= maxDataLength, "RUDP message too long")
        return be16(0xC000 | UInt16(8 + data.count)) + constant + be16(type) + data
    }

    /// INIT (rudp.md section 5.1).
    public static func initMessage(seq: UInt16, tag: UInt32) -> [UInt8] {
        encode(type: RUDPType.initiate, data: handshakeBody(seq: seq, tag: tag))
    }

    /// The longest cookie a COOKIE message can carry (4087 data bytes less the 14 of INIT's layout).
    public static let maxCookieLength = maxDataLength - 14

    /// COOKIE (rudp.md section 5.3): INIT's layout followed by the cookie. Nil when the cookie is too long.
    public static func cookieMessage(seq: UInt16, tag: UInt32, cookie: [UInt8]) -> [UInt8]? {
        guard cookie.count <= maxCookieLength else { return nil }
        return encode(type: RUDPType.cookie, data: handshakeBody(seq: seq, tag: tag) + cookie)
    }

    private static func handshakeBody(seq: UInt16, tag: UInt32) -> [UInt8] {
        be16(seq) + handshakeConstant + [UInt8(tag >> 24), UInt8((tag >> 16) & 0xff), UInt8((tag >> 8) & 0xff),
                                         UInt8(tag & 0xff)] + handshakeTrailer
    }

    /// The REQUEST wrapper followed in the same datagram by the DATA message carrying `request` under the same `seq`
    /// (rudp.md section 6.1).
    public static func requestDatagram(seq: UInt16, ack: UInt16, request: [UInt8]) -> [UInt8] {
        encode(type: RUDPType.request, data: be16(seq) + be16(ack)) + dataMessage(seq: seq, payload: request)
    }

    /// DATA: `seq` then the payload (an HTTP text or one ctrl frame).
    public static func dataMessage(seq: UInt16, payload: [UInt8]) -> [UInt8] {
        encode(type: RUDPType.data, data: be16(seq) + payload)
    }

    /// ACK: `seq`, `ack`, then `00 92` (rudp.md section 4.3).
    public static func ackMessage(seq: UInt16, ack: UInt16) -> [UInt8] {
        encode(type: RUDPType.ack, data: be16(seq) + be16(ack) + ackTrailer)
    }

    /// The switch-to-stream DATA message (rudp.md section 8): `seq`, the ctrl-shaped header, 16 random bytes. Nil unless
    /// `random` is exactly 16 bytes.
    public static func switchMessage(seq: UInt16, random: [UInt8]) -> [UInt8]? {
        guard random.count == 16 else { return nil }
        return dataMessage(seq: seq, payload: switchHeader + random)
    }

    /// Splits a datagram into its messages (rudp.md section 1.1). Fewer than 8 bytes give none (the spec drops
    /// anything up to 8, but a FINISH may be empty, section 2, and then it is a bare header). A length longer than
    /// what remains takes what remains; a length of 8 or less is a message without data; 8 or more bytes after a
    /// message start the next one. A header without the `24 4f 24 4f` constant ends the parse (it is not RUDP: a late
    /// hole-punch probe, for example).
    public static func parse(_ datagram: [UInt8]) -> [RUDPMessage] {
        guard datagram.count >= 8 else { return [] }
        var messages: [RUDPMessage] = []
        var offset = 0
        while datagram.count - offset >= 8 {
            guard Array(datagram[(offset + 2)..<(offset + 6)]) == constant else { break }
            let length = Int(datagram[offset] & 0x0f) << 8 | Int(datagram[offset + 1])
            let type = UInt16(datagram[offset + 6]) << 8 | UInt16(datagram[offset + 7])
            let start = offset + 8
            let take = min(max(0, length - 8), datagram.count - start)
            messages.append(RUDPMessage(type: type, data: Array(datagram[start..<(start + take)])))
            offset = start + take
        }
        return messages
    }
}
