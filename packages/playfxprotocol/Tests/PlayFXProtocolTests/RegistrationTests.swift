import Testing

@testable import PlayFXProtocol

@Suite struct RegistrationTests {
    static func build(
        _ target: RPTarget, _ identity: RegistrationIdentity? = nil
    ) throws -> RegistrationRequest {
        try RegistrationRequest.build(
            target: target, identity: identity ?? .accountID(Vector.accountID), pin: Vector.pin, seed: Vector.seed)
    }

    // test-vectors.md section 4.1.
    @Test func headers() throws {
        let tail = "HTTP/1.1\r\nHOST: 10.0.2.15\r\nUser-Agent: remoteplay Windows\r\nConnection: close\r\n"
        let expected: [(RPTarget, String)] = [
            (.ps5v1, "POST /sie/ps5/rp/sess/rgst HTTP/1.1\r\n \(tail)Content-Length: 587\r\nRP-Version: 1.0\r\n\r\n"),
            (.ps4v10, "POST /sie/ps4/rp/sess/rgst HTTP/1.1\r\n \(tail)Content-Length: 587\r\nRP-Version: 10.0\r\n\r\n"),
            (.ps4v9, "POST /sce/rp/regist HTTP/1.1\r\n \(tail)Content-Length: 530\r\nRP-Version: 9.0\r\n\r\n"),
            (.ps4v8, "POST /sce/rp/regist HTTP/1.1\r\n \(tail)Content-Length: 530\r\n\r\n"),
        ]
        for (target, header) in expected {
            #expect(String(decoding: try Self.build(target).header, as: UTF8.self) == header, "\(target)")
        }
    }

    // test-vectors.md section 4.2.
    @Test func bodies() throws {
        let cases: [(RPTarget, RegistrationIdentity?, String, Int, String)] = [
            (.ps5v1, nil, "regist-body-ps5-1", 587, "b81c94e6e6e91cc61c544a004ac8e1108ce0d7ee4358e4afe06e5bd5379f210b"),
            (.ps4v10, nil, "regist-body-ps4-10", 587, "c38d217d245d52fe0b14f7eb89ed5198e0e84535514c19311dc4ea3e8c80f72b"),
            (.ps4v9, nil, "regist-body-ps4-9-account", 530, "12f7e5cd77a296db5a772c91d6543e9efdc03f6cc68ab8da5a8b4c8f554ee4af"),
            (.ps4v8, nil, "regist-body-ps4-9-account", 530, "12f7e5cd77a296db5a772c91d6543e9efdc03f6cc68ab8da5a8b4c8f554ee4af"),
            (.ps4v9, .onlineID("playfx-tester"), "regist-body-ps4-9-online", 531, "05e3787b844c8a0720ebcda3ac225b3c5adf342f7d1f7926a074ece4fa06bc83"),
        ]
        for (target, identity, name, size, digest) in cases {
            let recorded = try fixture(name)
            #expect(recorded.count == size)
            #expect(sha256Hex(recorded) == digest, "\(name) fixture")
            #expect(try Self.build(target, identity).body == recorded, "\(name) \(target)")
        }
    }

    @Test func bodyLayout() throws {
        let ps5 = try Self.build(.ps5v1).body
        #expect(ps5[0x0c7...0x0ce] == hex("c0b17cf1a1274c57")[...])
        #expect(ps5[0x191...0x198] == hex("7afd215f437e47f0")[...])
        #expect(ps5[..<0x1e0].enumerated().allSatisfy { (0x0c7...0x0ce).contains($0.offset) || (0x191...0x198).contains($0.offset) || $0.element == 0x41 })
        #expect(ps5[0x1e0...] == hex("""
            9cd0fe2bcf0b07264ea347cb15f94026bff41f76bb17a0f8c9e4ff4e02a8ecb1538a9486b91772304f3c3cfa3d525eacd7766b3723ce
            6c87795735bbe4f13663ac5b1ba51626ccb1c840d3e5f182da10f1e256e21cec7d3dc05cdfa850046ba559cd6fa630f70d7580a863
            """)[...])
        let ps4 = try Self.build(.ps4v9).body
        #expect(ps4[0x11c...0x12b] == hex("07189e2ac39132cdaa6a6ff81eae6abc")[...])
        #expect(ps4[0x1e0...] == hex("""
            56652bbc50e4ed0867f9eae5f4805d60aba972509faae5ce52647a1b7f13c93b694c89184ea231def6de117730dcd67b7cef
            """)[...])
    }

    /// PSN-mode bodies are the same layout with the PSN derivation (registration.md section 3.2 note).
    @Test func psnBodies() throws {
        for (target, name, digest) in [
            (RPTarget.ps5v1, "regist-body-psn-ps5-1", "f33ff313d91c4875af9647b17ef27953c604e3dc1130b4aacab7494c57b6dde3"),
            (.ps4v10, "regist-body-psn-ps4-10", "bf33add66e5796144618dca23a29dfc7c94b8fe59f2521ba7f29a74bfec77744"),
        ] {
            let crypt = try RPCryptContext.psnRegistration(
                target: target, seed: Vector.seed, d1: Vector.d1, d2: Vector.d2, cd: Vector.cd,
                keyColumn: 1, maskColumn: 8)
            var body = [UInt8](repeating: 0x41, count: 0x1e0)
            body.replaceSubrange(0x0c7..<0x0cf, with: crypt.maskedSeed[8..<16])
            body.replaceSubrange(0x191..<0x199, with: crypt.maskedSeed[0..<8])
            let inner = "Client-Type: \(RegistrationRequest.clientType)\r\nNp-AccountId: FYHpffQQIhE=\r\n"
            body += try crypt.context.encrypted(Array(inner.utf8), counter: 0)
            #expect(body == (try fixture(name)))
            #expect(sha256Hex(body) == digest)
        }
    }

    @Test func buildRejectsBadInput() {
        #expect(throws: FailureKind.invalidInput) { try Self.build(.ps5v1, .accountID([1, 2, 3])) }
        #expect(throws: FailureKind.invalidInput) { try Self.build(.ps5v1, .onlineID("name")) }
        #expect(throws: FailureKind.invalidInput) { try Self.build(.ps4v9, .onlineID("")) }
        #expect(throws: FailureKind.invalidInput) {
            try RegistrationRequest.build(target: .ps5v1, identity: .accountID(Vector.accountID), pin: 1, seed: [1])
        }
    }

    // test-vectors.md section 5.
    @Test func responseDecryptionAndPairingRecord() throws {
        for (target, name) in [(RPTarget.ps5v1, "response-ps5-1"), (.ps4v10, "response-ps4-10"), (.ps4v9, "response-ps4-9"), (.ps4v8, "response-ps4-9")] {
            let request = try Self.build(target)
            let recorded = try fixture(name)
            #expect(recorded.count == 137)
            // The plaintext encrypts to the recorded bytes, and the recorded bytes parse to the record.
            #expect(try request.context.encrypted(Array(FakeConsole.pairingPlaintext(ps5: target.isPS5).utf8), counter: 0) == recorded)
            let result = try request.parsePairing(recorded, target: target)
            #expect(result == PairingResult(
                registKey: Vector.registKey, rpKey: hex("00112233445566778899aabbccddeeff"), nickname: "\(target.isPS5 ? "PS5" : "PS4")-TEST",
                mac: hex("0a1b2c3d4e5f"), target: target, keyType: 2, apSSID: nil, apBSSID: nil, apKey: nil, apName: nil))
            #expect(Discovery.wakeCredential(registKey: result.registKey) == "2712847316")
        }
    }

    private func parse(_ text: String, ps5: Bool = true) throws -> PairingResult {
        let request = try Self.build(ps5 ? .ps5v1 : .ps4v10)
        return try request.parsePairing(try request.context.encrypted(Array(text.utf8), counter: 0), target: ps5 ? .ps5v1 : .ps4v10)
    }

    @Test func pairingRecordVariants() throws {
        // Upper-case hex, an unterminated last line, LF-only endings, optional fields and unknown names.
        let text = "PS5-RegistKey:6131623263336434\nRP-Key: 00112233445566778899AABBCCDDEEFF\nPS5-Mac: 0A1B2C3D4E5F\n"
            + "AP-Ssid: net\nAP-Bssid: aa\nAP-Key: k\nAP-Name: n\nRP-SupportCmd: 1\nbogus line\nRP-KeyType: 7"
        let result = try parse(text)
        #expect(result.rpKey == hex("00112233445566778899aabbccddeeff"))
        #expect(result.nickname == "" && result.keyType == 7)
        #expect([result.apSSID, result.apBSSID, result.apKey, result.apName] == ["net", "aa", "k", "n"])
        // Without the optional nickname/keytype the record still parses; PS4 uses PS4- names.
        let ps4 = try parse("PS4-RegistKey: 6131\r\nRP-Key: 00112233445566778899aabbccddeeff\r\nPS4-Mac: 0a1b2c3d4e5f\r\n", ps5: false)
        #expect(ps4.registKey == [0x61, 0x31] + [UInt8](repeating: 0, count: 14) && ps4.keyType == nil)
    }

    @Test(arguments: [
        "RP-Key: 00112233445566778899aabbccddeeff\r\nPS5-Mac: 0a1b2c3d4e5f\r\n",
        "PS5-RegistKey: 61316232\r\nPS5-Mac: 0a1b2c3d4e5f\r\n",
        "PS5-RegistKey: 61316232\r\nRP-Key: 00112233445566778899aabbccddeeff\r\n",
        "PS5-RegistKey: 6131623\r\nRP-Key: 00112233445566778899aabbccddeeff\r\nPS5-Mac: 0a1b2c3d4e5f\r\n",
        "PS5-RegistKey: zz\r\nRP-Key: 00112233445566778899aabbccddeeff\r\nPS5-Mac: 0a1b2c3d4e5f\r\n",
        "PS5-RegistKey: 61316232633364346131623263336434aa\r\nRP-Key: 00112233445566778899aabbccddeeff\r\nPS5-Mac: 0a1b2c3d4e5f\r\n",
        "PS5-RegistKey: 61\r\nRP-Key: 0011\r\nPS5-Mac: 0a1b2c3d4e5f\r\n",
        "PS5-RegistKey: 61\r\nRP-Key: 00112233445566778899aabbccddeeff\r\nPS5-Mac: 0a1b2c3d4e\r\n",
        "PS4-RegistKey: 61\r\nRP-Key: 00112233445566778899aabbccddeeff\r\nPS4-Mac: 0a1b2c3d4e5f\r\n",
    ])
    func unusableRecords(_ text: String) {
        #expect(throws: FailureKind.invalidData) { try parse(text) }
    }

    @Test func httpHead() throws {
        let head = "HTTP/1.1 403 Forbidden\r\nRP-Application-Reason: 80108b09\r\nContent-Length:0\r\nOdd line\r\n\r\nBODY"
        guard case .head(let parsed) = MiniHTTP.parseHead(Array(head.utf8)) else {
            Issue.record("expected a head")
            return
        }
        #expect(parsed.status == 403 && parsed.applicationReason == 0x80108b09 && parsed.contentLength == 0)
        #expect(parsed.length == head.utf8.count - 4)

        func reason(_ value: String) -> UInt32? {
            guard case .head(let h) = MiniHTTP.parseHead(Array("HTTP/1.1 400 X\r\nRP-Application-Reason:\(value)\r\n\r\n".utf8)) else { return nil }
            return h.applicationReason
        }
        #expect(reason("0x80108b02") == 0x80108b02 && reason("0X80108B11") == 0x80108b11 && reason("nothex") == nil)

        #expect(MiniHTTP.parseHead(Array("HTTP/1.1 200 OK\r\nContent-".utf8)) == .needMore)
        #expect(MiniHTTP.parseHead(Array("HTTP/1.".utf8)) == .needMore)
        #expect(MiniHTTP.parseHead(Array("HTTP/1.0 200 OK\r\n\r\n".utf8)) == .invalid)
        #expect(MiniHTTP.parseHead(Array("HTTP/1.1 x\r\n\r\n".utf8)) == .invalid)
        #expect(MiniHTTP.parseHead(Array("HTTP/1.1 200\r\n\r\n".utf8)) != .invalid)
        #expect(MiniHTTP.parseHead([]) == .needMore)
    }
}
