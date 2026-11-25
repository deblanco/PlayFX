import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

/// holepunch.md section 11: the probe packets (vectors H1 and H2) and section 6 (H3).
@Suite struct PunchPacketTests {
    static let local = hex("000102030405060708090a0b0c0d0e0f10111213")
    static let console = hex("a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3")

    @Test func h1ClientRequest() {
        let packet = ProbePacket.request(senderHashedID: Self.local, receiverHashedID: Self.console, senderSid: 0x1234,
                                         receiverSid: 0xabcd, requestID: hex("5152535455"))
        #expect(packet == hex("""
            06000000 000102030405060708090a0b0c0d0e0f10111213 000000000000000000000000
            a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3 000000000000000000000000
            1234 abcd 000000 5152535455 0000000000000000
            """))
        #expect(packet.count == 88)
    }

    @Test func h2ClientResponse() throws {
        let packet = try #require(ProbePacket.response(
            senderHashedID: Self.local, receiverHashedID: Self.console, senderSid: 0x1234, receiverSid: 0xabcd,
            requestID: hex("7172737475"), source: ("198.51.100.7", 50123)))
        #expect(packet == hex("""
            07000000 000102030405060708090a0b0c0d0e0f10111213 000000000000000000000000
            a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3 000000000000000000000000
            1234 abcd 000000 7172737475 d407 cfca d1ff 0000
            """))
    }

    @Test func parseRoundTrip() throws {
        let request = ProbePacket.request(senderHashedID: Self.console, receiverHashedID: Self.local,
                                          senderSid: 0xabcd, receiverSid: 0x1234, requestID: hex("0102030405"))
        let parsed = try #require(ProbePacket.parse(request))
        #expect(parsed == ProbePacket(kind: .request, senderHashedID: Self.console, receiverHashedID: Self.local,
                                      senderSid: 0xabcd, receiverSid: 0x1234, requestID: hex("0102030405")))
        var response = request
        response[0] = 0x07
        #expect(ProbePacket.parse(response)?.kind == .response)
    }

    @Test func parseRejectsOtherDatagrams() {
        let good = ProbePacket.request(senderHashedID: Self.local, receiverHashedID: Self.console, senderSid: 1,
                                       receiverSid: 2, requestID: hex("0102030405"))
        #expect(ProbePacket.parse(Array(good.dropLast())) == nil)
        #expect(ProbePacket.parse(good + [0]) == nil)
        for (index, value) in [(0, UInt8(0x08)), (1, 1), (2, 1), (3, 1)] {
            var changed = good
            changed[index] = value
            #expect(ProbePacket.parse(changed) == nil)
        }
    }

    @Test func responseNeedsAnIPv4Source() {
        for bad in ["fe80::1", "1.2.3", "1.2.3.256", "a.b.c.d", ""] {
            #expect(ProbePacket.response(senderHashedID: Self.local, receiverHashedID: Self.console, senderSid: 1,
                                         receiverSid: 2, requestID: hex("0102030405"), source: (bad, 1)) == nil)
        }
    }

    /// H3: the ACCEPT's candidate.
    @Test func h3AcceptCandidate() {
        let client = ClientCandidates(candidates: [
            PunchCandidate(type: .stun, address: "203.0.113.5", port: 40006),
            PunchCandidate(type: .staticAddress, address: "203.0.113.5", port: 50123),
            PunchCandidate(type: .local, address: "192.168.1.20", port: 50123),
        ], randomAllocation: false)
        let selected = PunchCandidate(type: .staticAddress, address: "198.51.100.7", port: 50123)
        #expect(CandidateBuilder.acceptCandidate(selected: selected, client: client) == PunchCandidate(
            type: .staticAddress, address: "198.51.100.7", port: 50123, mappedAddress: "203.0.113.5", mappedPort: 40006))
        // LOCAL, and a DERIVED private address, map to the client's LOCAL candidate.
        let local = PunchCandidate(type: .local, address: "192.168.0.30", port: 9303)
        #expect(CandidateBuilder.acceptCandidate(selected: local, client: client).mappedAddress == "192.168.1.20")
        let derivedPrivate = PunchCandidate(type: .derived, address: "10.1.2.3", port: 9)
        #expect(CandidateBuilder.acceptCandidate(selected: derivedPrivate, client: client).mappedPort == 50123)
        let derivedPublic = PunchCandidate(type: .derived, address: "198.51.100.9", port: 9)
        #expect(CandidateBuilder.acceptCandidate(selected: derivedPublic, client: client).mappedPort == 40006)
        // No candidates at all: zeros rather than a crash.
        let empty = CandidateBuilder.acceptCandidate(selected: local, client: ClientCandidates(candidates: [], randomAllocation: false))
        #expect(empty.mappedAddress == "0.0.0.0" && empty.mappedPort == 0)
    }

    @Test func privateAddresses() {
        for text in ["10.0.0.1", "192.168.5.5", "172.16.0.1", "172.31.255.1", "fd00::1", "FC00::2"] {
            #expect(PunchCandidate(type: .local, address: text, port: 1).isPrivateAddress, "\(text)")
        }
        for text in ["172.15.0.1", "172.32.0.1", "198.51.100.7", "192.169.0.1", "8.8.8.8"] {
            #expect(!PunchCandidate(type: .local, address: text, port: 1).isPrivateAddress, "\(text)")
        }
    }

    @Test func identityRandom() {
        let a = PunchIdentity.random()
        let b = PunchIdentity.random()
        #expect(a.hashedID.count == 20 && a != b)
    }
}
