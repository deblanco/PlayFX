import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

@Suite struct SessionInitVectorTests {
    @Test func requestBytesPS5() {
        let text = "GET /sie/ps5/rp/sess/init HTTP/1.1\r\nHost: 192.0.2.10:9295\r\nUser-Agent: remoteplay Windows\r\n"
            + "Connection: close\r\nContent-Length: 0\r\nRP-Registkey: 3031323361626364\r\nRp-Version: 1.0\r\n\r\n"
        let bytes = SessionInit.request(host: SessionVector.host, port: 9295, target: .ps5v1, registKey: SessionVector.registKey)
        #expect(String(decoding: bytes, as: UTF8.self) == text)
    }

    @Test(arguments: [
        (RPTarget.ps4v10, "/sie/ps4/rp/sess/init", "10.0"), (.ps4v9, "/sce/rp/session", "9.0"),
        (.ps4v8, "/sce/rp/session", "8.0"),
    ]) func requestBytesPS4(_ row: (RPTarget, String, String)) {
        let bytes = SessionInit.request(host: SessionVector.host, port: 9295, target: row.0, registKey: SessionVector.registKey)
        #expect(String(decoding: bytes, as: UTF8.self) == "GET \(row.1) HTTP/1.1\r\nHost: 192.0.2.10:9295\r\n"
            + "User-Agent: remoteplay Windows\r\nConnection: close\r\nContent-Length: 0\r\n"
            + "RP-Registkey: 3031323361626364\r\nRp-Version: \(row.2)\r\n\r\n")
    }

    @Test func registKeyHexStopsAtFirstZero() {
        #expect(SessionInit.registKeyHex(SessionVector.registKey) == "3031323361626364")
        #expect(SessionInit.registKeyHex([0xab, 0, 0xcd]) == "ab")
        #expect(SessionInit.registKeyHex([UInt8](repeating: 0x7f, count: 16)) == String(repeating: "7f", count: 16))
    }

    @Test func sessionKeysAndIVs() throws {
        for (target, key, seed) in SessionVector.keys {
            let context = try SessionVector.context(target)
            #expect(context.key == hex(key) && context.seed == hex(seed))
        }
        let ivs: [(RPTarget, String, String, String)] = [
            (.ps5v1, "0a894340fc4845e95ddd09d81177fef6", "aa43c204afffe7e708129e8d075c6e0f", "b60c50d0d3ac6404c947e8aa110c8351"),
            (.ps4v10, "c8b0c57d4b68ff953209efa913889d06", "5183f0941626679ea4f3d6dcd6ac234b", "3d33cfde9275e774b027268650a7fad3"),
            (.ps4v9, "d799a38dc0086f841bc81345eb18f7be", "53bf311e0cc6ac60c0b052e31b6d2d28", "ee51faf35fbc957a20d2901f67eb5a31"),
        ]
        for (target, iv0, iv5, ivBig) in ivs {
            let context = try SessionVector.context(target)
            #expect(context.iv(counter: 0) == hex(iv0))
            #expect(context.iv(counter: 5) == hex(iv5))
            #expect(context.iv(counter: 0x0102030405060708) == hex(ivBig))
        }
    }

    // MARK: Reading the answer

    static func head(_ status: Int, _ fields: [String: String]) -> MiniHTTP.ResponseHead {
        MiniHTTP.ResponseHead(status: status, headers: fields, length: 0)
    }

    @Test func nonceSuccess() {
        let outcome = SessionInit.interpret(Self.head(200, ["rp-nonce": "AAECAwQFBgcICQoLDA0ODw=="]), sent: .ps5v1)
        #expect(outcome == .success(nonce: SessionVector.nonce))
    }

    @Test func badNonceIsInvalid() {
        for fields in [[:], ["rp-nonce": "AAEC"], ["rp-nonce": "!!!"]] {
            #expect(SessionInit.interpret(Self.head(200, fields), sent: .ps5v1) == .failure(.invalidResponse))
        }
    }

    @Test func refusalReasons() {
        func reason(_ text: String?) -> SessionInit.Outcome {
            SessionInit.interpret(Self.head(403, text.map { ["rp-application-reason": $0] } ?? [:]), sent: .ps5v1)
        }
        #expect(reason("80108b10") == .failure(.consoleBusy))
        #expect(reason("80108b15") == .failure(.remotePlayCrashed))
        #expect(reason("80108b11") == .failure(.versionMismatch))
        #expect(reason("80108bff") == .failure(.refused(reason: 0x80108bff)))
        #expect(reason("80108b09") == .failure(.refused(reason: 0x80108b09)))
        #expect(reason("12345678") == .failure(.refused(reason: 0x12345678)))
        #expect(reason(nil) == .failure(.refused(reason: nil)))
        #expect(reason("zz") == .failure(.refused(reason: nil)))
    }

    @Test func versionNegotiation() {
        func answer(_ reason: String, _ version: String?, sent: RPTarget) -> SessionInit.Outcome {
            var fields = ["rp-application-reason": reason]
            fields["rp-version"] = version
            return SessionInit.interpret(Self.head(403, fields), sent: sent)
        }
        #expect(answer("80108b11", "9.0", sent: .ps4v10) == .retry(.ps4v9))
        #expect(answer("80108bff", "8.0", sent: .ps4v10) == .retry(.ps4v8))
        #expect(answer("80108b11", "10.0", sent: .ps4v9) == .retry(.ps4v10))
        // A PS4 that says 5.0 is retried as 9.0.
        #expect(answer("80108b11", "5.0", sent: .ps4v10) == .retry(.ps4v9))
        // Unknown version, another family, or the same version: no retry.
        #expect(answer("80108b11", "7.0", sent: .ps4v10) == .failure(.versionMismatch))
        #expect(answer("80108b11", "1.0", sent: .ps4v10) == .failure(.versionMismatch))
        #expect(answer("80108b11", "9.0", sent: .ps5v1) == .failure(.versionMismatch))
        #expect(answer("80108b11", "1.0", sent: .ps5v1) == .failure(.versionMismatch))
        #expect(answer("80108bff", "10.0", sent: .ps4v10) == .failure(.refused(reason: 0x80108bff)))
        #expect(answer("80108bff", nil, sent: .ps4v10) == .failure(.refused(reason: 0x80108bff)))
        // Other reasons ignore the version.
        #expect(answer("80108b10", "9.0", sent: .ps4v10) == .failure(.consoleBusy))
    }

    @Test func protocolVersionsAndPaths() {
        #expect(RPTarget.allCases.map(\.protocolVersion) == ["8.0", "9.0", "10.0", "1.0"])
        #expect(RPTarget.allCases.map(\.sessionInitPath)
            == ["/sce/rp/session", "/sce/rp/session", "/sie/ps4/rp/sess/init", "/sie/ps5/rp/sess/init"])
        #expect(RPTarget.allCases.map(\.ctrlPath)
            == ["/sce/rp/session/ctrl", "/sce/rp/session/ctrl", "/sie/ps4/rp/sess/ctrl", "/sie/ps5/rp/sess/ctrl"])
    }
}

@Suite struct CtrlVectorTests {
    static func request(_ target: RPTarget, _ type: StreamingType = .h265) throws -> CtrlRequest {
        try CtrlRequest.build(
            host: SessionVector.host, port: 9295, target: target, context: SessionVector.context(target),
            registKey: SessionVector.registKey, deviceID: SessionVector.deviceID, streamingType: type)
    }

    static func lines(_ request: CtrlRequest) -> [String] {
        String(decoding: request.bytes, as: UTF8.self).components(separatedBy: "\r\n")
    }

    @Test func requestPS5() throws {
        let request = try Self.request(.ps5v1)
        let expected = "GET /sie/ps5/rp/sess/ctrl HTTP/1.1\r\nHost: 192.0.2.10:9295\r\nUser-Agent: remoteplay Windows\r\n"
            + "Connection: keep-alive\r\nContent-Length: 0\r\nRP-Auth: At1kpVXuVkWfSAj4uw5Z6g==\r\nRP-Version: 1.0\r\n"
            + "RP-Did: AgLF531dlzOoNd5VV3A/ARdz1zNGsz/s2NZS1Lud53k=\r\nRP-ControllerType: 3\r\nRP-ClientType: 11\r\n"
            + "RP-OSType: WppWi0vRPn6MYw==\r\nRP-ConPath: 1\r\nRP-PadProcNo: 3\r\nRP-StartBitrate: hBNd0Q==\r\n"
            + "RP-StreamingType: bHrR3w==\r\n\r\n"
        #expect(String(decoding: request.bytes, as: UTF8.self) == expected)
        #expect(request.nextLocalCounter == 5)
    }

    @Test func requestPS4v10() throws {
        let request = try Self.request(.ps4v10)
        let expected = "GET /sie/ps4/rp/sess/ctrl HTTP/1.1\r\nHost: 192.0.2.10:9295\r\nUser-Agent: remoteplay Windows\r\n"
            + "Connection: keep-alive\r\nContent-Length: 0\r\nRP-Auth: N7LirEio935gaE5np3Tq2Q==\r\nRP-Version: 10.0\r\n"
            + "RP-Did: irESUyEEXgGaFjmEo2BQEesbMio8H0FFgsoQh/JZYGg=\r\nRP-ControllerType: 3\r\nRP-ClientType: 11\r\n"
            + "RP-OSType: dgDI1RykIcw6WQ==\r\nRP-ConPath: 1\r\nRP-StartBitrate: bpEReQ==\r\n\r\n"
        #expect(String(decoding: request.bytes, as: UTF8.self) == expected)
        #expect(request.nextLocalCounter == 4)
    }

    @Test func requestPS4v9() throws {
        let request = try Self.request(.ps4v9)
        let expected = "GET /sce/rp/session/ctrl HTTP/1.1\r\nHost: 192.0.2.10:9295\r\nUser-Agent: remoteplay Windows\r\n"
            + "Connection: keep-alive\r\nContent-Length: 0\r\nRP-Auth: 8Hp9RDVRqLd+/QLGUHvR9w==\r\nRP-Version: 9.0\r\n"
            + "RP-Did: Uix96LtYLK+7STqi8rX0gnevJZ7eDhvd3a4tdIGtB6w=\r\nRP-ControllerType: 3\r\nRP-ClientType: 11\r\n"
            + "RP-OSType: hW3WhjU/euJqhw==\r\nRP-ConPath: 1\r\n\r\n"
        #expect(String(decoding: request.bytes, as: UTF8.self) == expected)
        #expect(request.nextLocalCounter == 3)
    }

    @Test func streamingTypeIsLittleEndianAndPS4v8HasNoOptionalHeaders() throws {
        // H.264 = 1 little-endian: plaintext 01 00 00 00 at counter 4.
        let context = try SessionVector.context(.ps5v1)
        let expected = try context.encrypted([1, 0, 0, 0], counter: 4)
        let text = Self.lines(try Self.request(.ps5v1, .h264)).first { $0.hasPrefix("RP-StreamingType") }
        #expect(text == "RP-StreamingType: \(Data(expected).base64EncodedString())")
        let v8 = try Self.request(.ps4v8)
        #expect(v8.nextLocalCounter == 3 && !Self.lines(v8).contains { $0.hasPrefix("RP-StartBitrate") })
    }

    @Test func deviceIDLayout() {
        let id = CtrlRequest.deviceID(random: hex("202122232425262728292a2b2c2d2e2f"))
        #expect(id == SessionVector.deviceID && id.count == 32)
    }

    @Test func serverTypeDecryption() throws {
        let context = try SessionVector.context(.ps5v1)
        let plain = try context.decrypted(Array(Data(base64Encoded: "MOxWljSMNSGfSAj4uw5Z6g==")!), counter: 0)
        #expect(plain == hex("02000000000000000000000000000000"))
    }

    // MARK: Frames

    @Test func plainFrames() {
        #expect(CtrlWire.frame(type: CtrlType.heartbeatReply, payload: []) == hex("00000000 01fe 0000"))
        #expect(CtrlWire.frame(type: CtrlType.goToBed, payload: []) == hex("00000000 0050 0000"))
        #expect(CtrlOutgoing.heartbeatReply.payload.isEmpty && CtrlOutgoing.goToBed.type == 0x0050)
        #expect(CtrlWire.frame(type: CtrlType.heartbeatRequest, payload: []) == hex("00000000 00fe 0000"))
    }

    func wire(_ message: CtrlOutgoing, _ target: RPTarget, counter: UInt64) throws -> [UInt8] {
        CtrlWire.frame(type: message.type, payload: try SessionVector.context(target).encrypted(message.payload, counter: counter))
    }

    @Test func loginPINReply() throws {
        let pin = try #require(CtrlOutgoing.loginPIN("1234"))
        #expect(pin.payload == hex("31323334"))
        #expect(try wire(pin, .ps5v1, counter: 5) == hex("00000004 8004 0000 9bf82809"))
        #expect(try wire(pin, .ps4v10, counter: 5) == hex("00000004 8004 0000 6084531f"))
        #expect(try wire(pin, .ps4v9, counter: 5) == hex("00000004 8004 0000 340694f0"))
    }

    @Test func loginPINValidation() {
        #expect(CtrlOutgoing.loginPIN("") == nil)
        #expect(CtrlOutgoing.loginPIN("12a4") == nil)
        #expect(CtrlOutgoing.loginPIN(String(repeating: "1", count: 33)) == nil)
        #expect(CtrlOutgoing.loginPIN("0000") != nil)
    }

    @Test func sessionIDFrame() throws {
        let wire = hex("""
            0000004b 0033 0000 485b87a4391fd134e0fcb43f391e556b8e8601bd95d432c262d42b6e8a7562d1
            4952f1cbf256c87ae11147f7f4fd52fcc4d6140595a3caaaf2e98c4f60031cf3 e12ea890026b4bf19e21f4
            """)
        var splitter = CtrlStreamSplitter()
        _ = splitter.feed(Array("HTTP/1.1 200 OK\r\n\r\n".utf8))
        guard case .frame(let type, let payload)? = splitter.feed(wire).first else {
            Issue.record("no frame")
            return
        }
        #expect(type == 0x33 && payload.count == 0x4b)
        let plain = try SessionVector.context(.ps5v1).decrypted(payload, counter: 1)
        #expect(plain == [0x4a] + Array(SessionVector.sessionIDText.utf8))
        let parsed = try #require(CtrlInbound.parseSessionID(plain))
        #expect(parsed.id == SessionVector.sessionIDText && parsed.id.count == 74 && parsed.lengthByteExpected)
    }

    @Test func microphoneStateFrame() throws {
        #expect(try wire(.microphoneState(1), .ps5v1, counter: 6) == hex("00000004 0036 0000 837aca85"))
        #expect(CtrlOutgoing.microphoneState(0).payload == hex("00010059"))
    }

    @Test func keyboardSetTextFrame() throws {
        let message = CtrlOutgoing.keyboardSetText(sequence: 1, text: "hi")
        #expect(message.payload == hex("00000001 00000002 0000000000000000 00000000000000000000000000000000 00000002 6869"))
        #expect(try wire(message, .ps5v1, counter: 7) == hex("""
            00000026 0023 0000 b2231dce4fa03fbd6fe77254bfb595bdbd84e8114941afbb3c97365e3b48850bee6deecfb8bf
            """))
    }

    @Test func otherClientPayloads() {
        #expect(CtrlOutgoing.keyboardEnable.payload == hex("00000001000005ae 0000000000000000"))
        #expect(CtrlOutgoing.keyboardToggle.payload == [1])
        #expect(CtrlOutgoing.keyboardClose(accept: true).payload == hex("00000000"))
        #expect(CtrlOutgoing.keyboardClose(accept: false).payload == hex("00000001"))
        #expect(CtrlOutgoing.goHome.payload == hex("00ff") + [UInt8](repeating: 0, count: 14))
        #expect(CtrlOutgoing.goHome.payload.count == 16 && CtrlOutgoing.goHome.type == 0x14)
        #expect(CtrlOutgoing.microphoneConnect.payload == [0, 0] && CtrlOutgoing.microphoneConnect.type == 0x30)
        #expect(CtrlOutgoing.displayDevices.payload == [0, 0, 0, 0] && CtrlOutgoing.displayDevices.type == 0x910)
        #expect(CtrlOutgoing.dualSenseEnable.payload == hex("004000") && CtrlOutgoing.dualSenseEnable.type == 0x13)
        #expect(CtrlOutgoing.controllerFeaturesConnect.payload == hex("a0ab51bdd17e0000ffffffffff000000"))
        #expect(CtrlOutgoing.controllerFeaturesConnect.type == 0x11)
    }

    @Test func startupOrder() {
        func types(_ list: [CtrlOutgoing]) -> [UInt16] { list.map(\.type) }
        #expect(types(CtrlOutgoing.startup(dualSense: true, keyboard: false)) == [0x13, 0x11, 0x36, 0x36, 0x910])
        #expect(types(CtrlOutgoing.startup(dualSense: false, keyboard: false)) == [0x36, 0x36, 0x910])
        #expect(types(CtrlOutgoing.startup(dualSense: true, keyboard: true)) == [0x13, 0x11, 0x0d, 0x20, 0x36, 0x36, 0x910])
        #expect(CtrlOutgoing.startup(dualSense: false, keyboard: false)[0].payload == hex("00010159"))
    }
}
