import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

/// rudp.md sections 1, 2, 5, 8 and the vectors R1 to R7 of section 12.
@Suite struct RUDPFramingTests {
    /// R3's request text (183 bytes).
    static let sessionInit = Array(("GET /sie/ps5/rp/sess/init HTTP/1.1\r\nHost: 198.51.100.7:50123\r\n"
        + "User-Agent: remoteplay Windows\r\nConnection: close\r\nContent-Length: 0\r\n"
        + "RP-Registkey: 3031323361626364\r\nRp-Version: 1.0\r\n\r\n").utf8)
    static let cookie = hex("c0c1c2c3c4c5c6c7c8c9cacbcccdcecf")

    @Test func r1Init() {
        #expect(RUDPFraming.initMessage(seq: 0x1234, tag: 0x89ab_cdef) == hex("c016 244f244f 8030 1234 0b0101000100 89abcdef 0582"))
        #expect(RUDPFraming.initMessage(seq: 0x1234, tag: 0x89ab_cdef).count == 22)
    }

    @Test func r2Cookie() {
        #expect(RUDPFraming.cookieMessage(seq: 0x1235, tag: 0x89ab_cdef, cookie: Self.cookie)
            == hex("c026 244f244f 9030 1235 0b0101000100 89abcdef 0582 c0c1c2c3c4c5c6c7c8c9cacbcccdcecf"))
        // An empty cookie is just INIT's layout with the COOKIE type.
        #expect(RUDPFraming.cookieMessage(seq: 1, tag: 2, cookie: []) == hex("c016 244f244f 9030 0001 0b0101000100 00000002 0582"))
        // Item 15: the longest cookie fits (4095 bytes with the header), one more is refused instead of trapping.
        #expect(RUDPFraming.cookieMessage(seq: 1, tag: 2, cookie: [UInt8](repeating: 1, count: RUDPFraming.maxCookieLength))?.count == 4095)
        #expect(RUDPFraming.cookieMessage(seq: 1, tag: 2, cookie: [UInt8](repeating: 1, count: RUDPFraming.maxCookieLength + 1)) == nil)
    }

    @Test func r3SessionInitRequest() {
        #expect(Self.sessionInit.count == 183)
        let datagram = RUDPFraming.requestDatagram(seq: 0x1236, ack: 0x5679, request: Self.sessionInit)
        #expect(datagram == hex("""
            c00c 244f244f 2030 1236 5679
            c0c1 244f244f 0230 1236 474554202f7369652f7073352f72702f736573732f696e697420485454502f312e310d0a
            486f73743a203139382e35312e3130302e373a35303132330d0a557365722d4167656e743a2072656d6f7465706c6179
            2057696e646f77730d0a436f6e6e656374696f6e3a20636c6f73650d0a436f6e74656e742d4c656e6774683a20300d0a
            52502d5265676973746b65793a20333033313332333336313632363336340d0a52702d56657273696f6e3a20312e300d
            0a0d0a
            """))
        #expect(datagram.count == 205)
    }

    @Test func r4Ack() {
        #expect(RUDPFraming.ackMessage(seq: 0x1237, ack: 0x567a) == hex("c00e 244f244f 2430 1237 567a 0092"))
    }

    @Test func r5HeartbeatReply() {
        #expect(RUDPFraming.dataMessage(seq: 0x1237, payload: hex("00000000 01fe 0000")) == hex("c012 244f244f 0230 1237 0000000001fe0000"))
    }

    @Test func r6Switch() {
        let random = hex("404142434445464748494a4b4c4d4e4f")
        #expect(RUDPFraming.switchMessage(seq: 0x1238, random: random)
            == hex("c022 244f244f 0230 1238 00000010000d0000 404142434445464748494a4b4c4d4e4f"))
        #expect(RUDPFraming.switchMessage(seq: 0x1238, random: random)?.count == 34)
        #expect(RUDPFraming.switchMessage(seq: 1, random: []) == nil && RUDPFraming.switchMessage(seq: 1, random: random + [0]) == nil)
    }

    @Test func r7TwoMessageDatagram() throws {
        let messages = RUDPFraming.parse(hex("c00e244f244f2430 567812390092 c012244f244f0230 56790000000000fe0000"))
        #expect(messages.count == 2)
        #expect(messages[0] == RUDPMessage(type: 0x2430, data: hex("5678 1239 0092")))
        #expect(messages[0].flags == 0x24 && messages[0].peerSeq == 0x5678)
        #expect(messages[1] == RUDPMessage(type: 0x0230, data: hex("5679 00000000 00fe 0000")))
        #expect(messages[1].flags == 0x02 && messages[1].peerSeq == 0x5679)
        #expect(try #require(messages[1].peerSeq) &+ 1 == 0x567a)
    }

    @Test func parseRules() {
        #expect(RUDPFraming.parse([]).isEmpty)
        // Fewer than 8 bytes: dropped. A bare header (an empty FINISH) is a message without data.
        #expect(RUDPFraming.parse(hex("c008 244f244f d0")).isEmpty)
        #expect(RUDPFraming.parse(hex("c008 244f244f c000")) == [RUDPMessage(type: 0xc000, data: [])])
        // A length longer than the datagram takes what remains.
        #expect(RUDPFraming.parse(hex("c0ff 244f244f 0230 aabb")) == [RUDPMessage(type: 0x0230, data: hex("aabb"))])
        // The high nibble is ignored; a length of 8 or less has no data, and a header-only message can follow.
        #expect(RUDPFraming.parse(hex("0007 244f244f c000 aa")) == [RUDPMessage(type: 0xc000, data: [])])
        #expect(RUDPFraming.parse(hex("0008 244f244f c000 c008 244f244f d000")).map(\.type) == [0xc000, 0xd000])
        // Not RUDP (a late probe): ends the parse, and a bad second header drops only the rest.
        #expect(RUDPFraming.parse([UInt8](repeating: 6, count: 88)).isEmpty)
        #expect(RUDPFraming.parse(hex("c00a 244f244f 0230 aabb c00a 11111111 0230 ccdd")) == [RUDPMessage(type: 0x0230, data: hex("aabb"))])
        // Fewer than 8 trailing bytes are ignored.
        #expect(RUDPFraming.parse(hex("c00a 244f244f 0230 aabb ffffff")).count == 1)
        // A message without two data bytes has no peerSeq.
        #expect(RUDPMessage(type: 0xc000, data: []).peerSeq == nil)
    }

    @Test func limits() {
        #expect(RUDPFraming.maxDataLength == 4087)
        let biggest = RUDPFraming.encode(type: RUDPType.data, data: [UInt8](repeating: 1, count: 4087))
        #expect(biggest[0] == 0xCF && biggest[1] == 0xFF)
        #expect(RUDPFraming.parse(biggest).first?.data.count == 4087)
    }
}
