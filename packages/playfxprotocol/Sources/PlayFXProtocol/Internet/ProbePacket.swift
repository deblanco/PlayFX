/// The 88-byte connectivity-check packets of the hole punch (holepunch.md section 5.1).
public struct ProbePacket: Sendable, Equatable {
    /// The two kinds, by their first four bytes.
    public enum Kind: Sendable, Equatable {
        /// `06 00 00 00`.
        case request
        /// `07 00 00 00`.
        case response
    }

    /// Total length of every probe packet.
    public static let length = 88

    /// Request or response.
    public var kind: Kind
    /// The sender's hashed id (offset 0x04).
    public var senderHashedID: [UInt8]
    /// The receiver's hashed id (offset 0x24).
    public var receiverHashedID: [UInt8]
    /// The sender's `sid` (offset 0x44).
    public var senderSid: UInt16
    /// The receiver's `sid` (offset 0x46).
    public var receiverSid: UInt16
    /// The 5-byte request id (offset 0x4B), copied into the response.
    public var requestID: [UInt8]

    /// A request.
    public static func request(senderHashedID: [UInt8], receiverHashedID: [UInt8], senderSid: UInt16,
                               receiverSid: UInt16, requestID: [UInt8]) -> [UInt8] {
        build(kind: .request, senderHashedID, receiverHashedID, senderSid, receiverSid, requestID, masked: nil)
    }

    /// A response to a request that came from `source` (an IPv4 address and port). Offsets 0x50..0x55 tell the
    /// requester where its request came from, masked with the sids like STUN's XOR-MAPPED-ADDRESS. Nil if `source`
    /// isn't dotted IPv4 text.
    public static func response(senderHashedID: [UInt8], receiverHashedID: [UInt8], senderSid: UInt16,
                                receiverSid: UInt16, requestID: [UInt8], source: (address: String, port: UInt16))
        -> [UInt8]? {
        let parts = source.address.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { UInt8($0) }
        guard parts.count == 4, octets.count == 4 else { return nil }
        let first = (UInt16(octets[0]) << 8 | UInt16(octets[1])) ^ senderSid
        let second = (UInt16(octets[2]) << 8 | UInt16(octets[3])) ^ receiverSid
        let third = source.port ^ senderSid
        return build(kind: .response, senderHashedID, receiverHashedID, senderSid, receiverSid, requestID,
                     masked: (first, second, third))
    }

    private static func build(kind: Kind, _ sender: [UInt8], _ receiver: [UInt8], _ senderSid: UInt16,
                              _ receiverSid: UInt16, _ requestID: [UInt8],
                              masked: (UInt16, UInt16, UInt16)?) -> [UInt8] {
        precondition(sender.count == 20 && receiver.count == 20 && requestID.count == 5, "probe field sizes")
        var out = [UInt8](repeating: 0, count: length)
        out[0] = kind == .request ? 0x06 : 0x07
        out.replaceSubrange(0x04..<0x18, with: sender)
        out.replaceSubrange(0x24..<0x38, with: receiver)
        put16(&out, 0x44, senderSid)
        put16(&out, 0x46, receiverSid)
        out.replaceSubrange(0x4B..<0x50, with: requestID)
        if let masked {
            put16(&out, 0x50, masked.0)
            put16(&out, 0x52, masked.1)
            put16(&out, 0x54, masked.2)
        }
        return out
    }

    private static func put16(_ out: inout [UInt8], _ offset: Int, _ value: UInt16) {
        out[offset] = UInt8(value >> 8)
        out[offset + 1] = UInt8(value & 0xff)
    }

    /// Parses a datagram: exactly 88 bytes and type `06000000` or `07000000`; anything else is nil.
    public static func parse(_ bytes: [UInt8]) -> ProbePacket? {
        guard bytes.count == length, bytes[1] == 0, bytes[2] == 0, bytes[3] == 0,
              bytes[0] == 0x06 || bytes[0] == 0x07 else { return nil }
        return ProbePacket(
            kind: bytes[0] == 0x06 ? .request : .response,
            senderHashedID: Array(bytes[0x04..<0x18]), receiverHashedID: Array(bytes[0x24..<0x38]),
            senderSid: UInt16(bytes[0x44]) << 8 | UInt16(bytes[0x45]),
            receiverSid: UInt16(bytes[0x46]) << 8 | UInt16(bytes[0x47]), requestID: Array(bytes[0x4B..<0x50]))
    }
}
