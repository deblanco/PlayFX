import Testing

@testable import PlayFXProtocol

@Suite struct ProtobufTests {
    @Test func varintEncodingAndRoundTrip() throws {
        var w = ProtobufWriter()
        for v: UInt64 in [0, 1, 127, 128, 300, 16384, UInt64(UInt32.max), UInt64.max] { w.varint(1, v) }
        let fields = try ProtobufReader.fields(of: w.encoded)
        #expect(fields.compactMap(\.varint) == [0, 1, 127, 128, 300, 16384, UInt64(UInt32.max), UInt64.max])
        var one = ProtobufWriter()
        one.appendVarint(300)
        #expect(one.encoded == [0xac, 0x02])
    }

    @Test func allWireTypes() throws {
        var w = ProtobufWriter()
        w.varint(1, 7)
        w.bytes(2, [1, 2, 3])
        w.string(3, "hi")
        w.fixed32(4, 0x0102_0304)
        w.fixed64(5, 0x0102_0304_0506_0708)
        w.float(6, 1.5)
        w.double(7, -2.25)
        w.bool(8, true)
        w.int32(9, -1)
        w.varint(22, 1)  // a two-byte tag
        let f = try ProtobufReader.fields(of: w.encoded)
        #expect(f.count == 10)
        #expect(f[0].value == .varint(7))
        #expect(f[1].bytes == [1, 2, 3])
        #expect(f[2].bytes == Array("hi".utf8))
        #expect(f[3].value == .fixed32(0x0102_0304))
        #expect(f[4].value == .fixed64(0x0102_0304_0506_0708))
        #expect(f[5].value == .fixed32(Float(1.5).bitPattern))
        #expect(f[6].value == .fixed64(Double(-2.25).bitPattern))
        #expect(f[7].varint == 1)
        #expect(f[8].varint == UInt64.max)  // int32 -1 is sign-extended to ten bytes
        #expect(f[9].number == 22)
        #expect(Array(w.encoded.suffix(3)) == [0xb0, 0x01, 0x01])
        #expect(f[0].bytes == nil && f[1].varint == nil)
    }

    @Test func nestedMessage() throws {
        var inner = ProtobufWriter()
        inner.varint(1, 5)
        var outer = ProtobufWriter()
        outer.message(2, inner)
        #expect(outer.encoded == [0x12, 0x02, 0x08, 0x05])
    }

    @Test func lastValueWinsAndUnknownFieldsAreSkipped() throws {
        var w = ProtobufWriter()
        w.varint(1, 1)
        w.varint(99, 5)
        w.bytes(98, [9, 9])
        w.varint(1, 2)
        let f = try ProtobufReader.fields(of: w.encoded)
        #expect(try f.requiredVarint(1, "x") == 2)
        #expect(f.optionalVarint(50) == nil)
        #expect(throws: ProtobufError.missingField("y")) { try f.requiredVarint(7, "y") }
        #expect(throws: ProtobufError.missingField("z")) { try f.requiredBytes(1, "z") }
    }

    @Test func groupsAreSkipped() throws {
        // field 5 group { field 1 varint 1; field 2 len 1 'x'; field 3 fixed32; field 4 fixed64; nested group }, then field 1.
        let bytes: [UInt8] = [
            0x2b, 0x08, 0x01, 0x12, 0x01, 0x78, 0x1d, 1, 2, 3, 4, 0x21, 1, 2, 3, 4, 5, 6, 7, 8,
            0x33, 0x34, 0x2c, 0x08, 0x09,
        ]
        let f = try ProtobufReader.fields(of: bytes)
        #expect(f.count == 1)
        #expect(f[0].varint == 9)
    }

    @Test func hostileInputNeverTraps() throws {
        let cases: [([UInt8], ProtobufError)] = [
            ([0x08], .truncated),  // tag without value
            ([0x80], .truncated),  // varint cut off
            ([0x08, 0x80, 0x80], .truncated),
            ([0x08] + [UInt8](repeating: 0xff, count: 11), .malformedVarint),
            ([0x12, 0x05, 1, 2], .lengthPastEnd),
            ([0x12, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f], .lengthPastEnd),
            ([0x12], .truncated),
            ([0x0d, 1, 2], .truncated),  // fixed32 short
            ([0x09, 1, 2, 3], .truncated),  // fixed64 short
            ([0x0e, 0], .badWireType),  // wire type 6
            ([0x0f, 0], .badWireType),  // wire type 7
            ([0x0c], .badWireType),  // end group without start
            ([0x00, 0x01], .badFieldNumber),  // field 0
            ([0x2b], .truncated),  // group never ends
            ([0x2b, 0x00], .badFieldNumber),  // field 0 inside a group
            ([0x2b, 0x0e], .badWireType),
            ([0x2b, 0x12, 0x05], .lengthPastEnd),
            ([0x2b, 0x0d, 1], .truncated),
        ]
        for (bytes, expected) in cases {
            #expect(throws: expected, "\(bytes)") { try ProtobufReader.fields(of: bytes) }
        }
    }

    @Test func deepGroupNestingIsRejected() {
        let deep = [UInt8](repeating: 0x2b, count: 40) + [UInt8](repeating: 0x2c, count: 40)
        #expect(throws: ProtobufError.tooDeep) { try ProtobufReader.fields(of: deep) }
        let fine = [UInt8](repeating: 0x2b, count: 10) + [UInt8](repeating: 0x2c, count: 10)
        #expect((try? ProtobufReader.fields(of: fine))?.isEmpty == true)
    }

    @Test func everyPrefixOfAMessageDecodesOrThrows() throws {
        let message = StreamMessage.streamInfo(
            StreamInfoMessage(
                videoProfiles: [VideoProfile(width: 1920, height: 1080, header: [1, 2, 3])],
                audioHeader: MicrophoneSettings.announcedHeader.bytes, audioChannels: [StreamAudioChannel(channelType: 1, audioHeader: [1])]))
        let bytes = message.encoded
        #expect(try StreamMessage.decode(bytes) == message)
        var failures = 0
        for n in 0..<bytes.count {
            if (try? StreamMessage.decode(Array(bytes.prefix(n)))) == nil { failures += 1 }
        }
        // Most cut-offs land inside a field or before the required ones; none may trap.
        #expect(failures > bytes.count / 2)
        #expect(throws: ProtobufError.self) { try StreamMessage.decode([]) }
        // Flipping any byte either fails or decodes to something else; it never traps.
        var changed = 0
        for i in bytes.indices {
            var copy = bytes
            copy[i] ^= 0xff
            if (try? StreamMessage.decode(copy)) != message { changed += 1 }
        }
        #expect(changed == bytes.count)
    }

    @Test func helpersCoerceTypes() throws {
        var w = ProtobufWriter()
        w.varint(1, 0x1_0000_0005)  // wider than uint32: truncated like protobuf does
        w.bool(2, true)
        w.string(3, "text")
        w.varint(4, 1)
        let f = try ProtobufReader.fields(of: w.encoded)
        #expect(try f.requiredUInt32(1, "a") == 5)
        #expect(f.optionalUInt32(1) == 5)
        #expect(try f.requiredBool(2, "b"))
        #expect(f.optionalBool(2) == true)
        #expect(try f.requiredString(3, "c") == "text")
        #expect(f.optionalString(3) == "text")
        #expect(f.allVarints(4) == [1])
        #expect(f.allBytes(3) == [Array("text".utf8)])
    }
}
