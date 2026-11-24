import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

@Suite struct PSNCodecTests {
    // MARK: JSON helpers

    @Test func quoteEscapes() {
        #expect(PSNJSON.quote("a\"b\\c/d") == #""a\"b\\c/d""#)
        #expect(PSNJSON.quote("\n\r\t\u{08}\u{0C}") == #""\n\r\t\b\f""#)
        #expect(PSNJSON.quote("\u{01}\u{1F}") == #""\u0001\u001f""#)
        #expect(PSNJSON.quote("é") == "\"é\"")
    }

    @Test func numbers() {
        let object = PSNJSON.object(Data(#"{"a":5,"b":true,"c":1.5,"d":"12","e":18446744073709551615,"f":"x"}"#.utf8))
        #expect(PSNJSON.int(object?["a"]) == 5)
        #expect(PSNJSON.int(object?["b"]) == nil)
        #expect(PSNJSON.int(object?["c"]) == nil)
        #expect(PSNJSON.int(object?["d"]) == nil)
        #expect(PSNJSON.int(nil) == nil)
        #expect(PSNJSON.uint64(object?["d"]) == 12)
        #expect(PSNJSON.uint64(object?["a"]) == 5)
        #expect(PSNJSON.uint64(object?["e"]) == UInt64.max)
        #expect(PSNJSON.uint64(object?["b"]) == nil)
        #expect(PSNJSON.uint64(object?["f"]) == nil)
        #expect(PSNJSON.object(Data("[1]".utf8)) == nil)
    }

    // MARK: Notifications (psn.md section 5.4)

    @Test func decodesAllSixNotificationTypes() {
        func decode(_ text: String) -> PSNNotification? { PSNNotification.decode(frame: Data(text.utf8)) }
        #expect(decode(PSNVector.createdFrame) == .sessionCreated(onlineID: "playfx-tester"))
        #expect(decode(PSNVector.memberFrame()) == .memberJoined(deviceUniqueID: PSNVector.duid))
        #expect(decode(PSNVector.customDataFrame()) == .customDataUpdated(customData1: PSNVector.customData1Text))
        #expect(decode(PSNVector.memberDeletedFrame) == .memberLeft)
        #expect(decode(PSNVector.sessionDeletedFrame()) == .sessionDeleted(sessionID: PSNVector.sessionID))
        let message = decode(PSNVector.messageFrame(PSNVector.consoleOfferText()))
        guard case .sessionMessage(let payload?) = message else {
            Issue.record("not a session message: \(String(describing: message))")
            return
        }
        #expect(payload.hasPrefix("ver=1.0, type=text, body={\"action\":\"OFFER\""))
    }

    @Test func missingFieldsAreNil() {
        func decode(_ text: String) -> PSNNotification? { PSNNotification.decode(frame: Data(text.utf8)) }
        let prefix = "psn:sessionManager:sys:"
        #expect(decode(#"{"dataType":"\#(prefix)remotePlaySession:created"}"#) == .sessionCreated(onlineID: nil))
        #expect(decode(#"{"dataType":"\#(prefix)rps:members:created","body":{"data":{"members":[]}}}"#) == .memberJoined(deviceUniqueID: nil))
        #expect(decode(#"{"dataType":"\#(prefix)rps:customData1:updated"}"#) == .customDataUpdated(customData1: nil))
        #expect(decode(#"{"dataType":"\#(prefix)rps:sessionMessage:created"}"#) == .sessionMessage(payload: nil))
        #expect(decode(PSNVector.sessionDeletedFrame(nil)) == .sessionDeleted(sessionID: nil))
    }

    @Test func ignoresOtherFramesAndBinaryWorks() {
        #expect(PSNNotification.decode(frame: Data("not json".utf8)) == nil)
        #expect(PSNNotification.decode(frame: Data(#"{"dataType":"psn:other"}"#.utf8)) == nil)
        #expect(PSNNotification.decode(frame: Data(#"{"noType":1}"#.utf8)) == nil)
        #expect(PSNNotification.decode(frame: Data(#"{"dataType":5}"#.utf8)) == nil)
        #expect(PSNNotification.decode(frame: Data()) == nil)
        #expect(PSNNotification.decode(frame: Data(PSNVector.memberDeletedFrame.utf8)) == .memberLeft)
    }

    // MARK: customData1 (section 6.5, vector P3)

    @Test func customDataVectorP3() throws {
        #expect(try PSNCustomData.decode(PSNVector.customData1Text) == PSNVector.customData1)
        #expect(encodeHex(try PSNCustomData.decode(PSNVector.customData1Text)) == "303132333435363738393a3b3c3d3e3f")
    }

    @Test func customDataExtraBytesAndFailures() throws {
        func doubleBase64(_ bytes: [UInt8]) -> String {
            Data(Data(bytes).base64EncodedString().utf8).base64EncodedString()
        }
        let seventeen = PSNVector.customData1 + [0xff]
        #expect(try PSNCustomData.decode(doubleBase64(seventeen)) == PSNVector.customData1)
        #expect(try PSNCustomData.decode(doubleBase64(PSNVector.customData1 + [1, 2, 3, 4])) == PSNVector.customData1)
        let tooLong = doubleBase64(PSNVector.customData1 + [1, 2, 3, 4, 5])
        let tooShort = doubleBase64(Array(PSNVector.customData1.prefix(15)))
        for bad in ["", "!!!!", tooLong, tooShort, Data("%%%%".utf8).base64EncodedString()] {
            #expect(throws: PSNError.invalidCustomData) { try PSNCustomData.decode(bad) }
        }
    }

    // MARK: Messages: building (vectors P5, P6, P7)

    static let candidates = [
        PSNCandidate(type: .stun, address: "203.0.113.5", port: 40006),
        PSNCandidate(type: .staticAddress, address: "203.0.113.5", port: 50123),
        PSNCandidate(type: .local, address: "192.168.1.20", port: 50123),
    ]

    static func peer() -> PSNPeerAddress {
        PSNPeerAddress(accountID: String(PSNVector.accountID), platform: "REMOTE_PLAY")
    }

    @Test func resultAndOfferPayloads() {
        let result = PSNMessage(action: .result, reqID: 1, connRequest: nil)
        #expect(result.payload() == #"ver=1.0, type=text, body={"action":"RESULT","reqId":1,"error":0,"connRequest":{}}"#)
        let offer = PSNMessage(
            action: .offer, reqID: 2,
            connRequest: PSNConnRequest(
                sid: 4660, peerSid: 0, natType: 2, candidates: Self.candidates, localPeerAddress: Self.peer(),
                localHashedID: PSNVector.localHashedID))
        #expect(
            offer.json()
                == #"{"action":"OFFER","reqId":2,"error":0,"connRequest":{"sid":4660,"peerSid":0,"skey":"AAAAAAAAAAAAAAAAAAAAAA==","natType":2,"candidate":[{"type":"STUN","addr":"203.0.113.5","mappedAddr":"0.0.0.0","port":40006,"mappedPort":0},{"type":"STATIC","addr":"203.0.113.5","mappedAddr":"0.0.0.0","port":50123,"mappedPort":0},{"type":"LOCAL","addr":"192.168.1.20","mappedAddr":"0.0.0.0","port":50123,"mappedPort":0}],"defaultRouteMacAddr":"","localPeerAddr":{"accountId":"1234567890123456789","platform":"REMOTE_PLAY"},"localHashedId":"AAECAwQFBgcICQoLDA0ODxAREhM="}}"#
        )
    }

    @Test func missingPeerAddressWritesEmptyObject() {
        let request = PSNConnRequest(sid: 1, peerSid: 2, natType: 0, candidates: [], localPeerAddress: nil, localHashedID: [])
        #expect(request.json().contains(#""candidate":[],"defaultRouteMacAddr":"","localPeerAddr":{},"localHashedId":"""#))
    }

    // MARK: Messages: receiving (P4)

    static func p4Payload() -> String { "ver=1.0, type=text, body=" + PSNVector.consoleOfferText() }

    @Test func decodesConsoleOfferWithBrokenJSON() throws {
        let message = try PSNMessage.decode(payload: Self.p4Payload())
        #expect(message.action == .offer)
        #expect(message.reqID == 1)
        #expect(message.error == 0)
        let request = try #require(message.connRequest)
        #expect(request.sid == 43981)
        #expect(request.peerSid == 0)
        #expect(request.natType == 2)
        #expect(request.skey == [UInt8](repeating: 0, count: 16))
        #expect(request.defaultRouteMACAddress == "0a:1b:2c:3d:4e:5f")
        #expect(request.localHashedID == (0xa0...0xb3).map { UInt8($0) })
        #expect(request.localPeerAddress == nil)
        #expect(
            request.candidates == [
                PSNCandidate(type: .staticAddress, address: "198.51.100.7", port: 50123),
                PSNCandidate(type: .local, address: "192.168.0.30", port: 9303),
            ])
    }

    @Test func repairsLocalPeerAddr() {
        let repair = PSNMessage.repairLocalPeerAddr
        #expect(repair(#"{"localPeerAddr":,"x":1}"#) == #"{"localPeerAddr":{},"x":1}"#)
        #expect(repair(#"{"localPeerAddr": ,"x":1}"#) == #"{"localPeerAddr":{} ,"x":1}"#)
        #expect(repair(#"{"localPeerAddr":}"#) == #"{"localPeerAddr":{}}"#)
        #expect(repair(#"{"localPeerAddr":{"a":1},"x":1}"#) == #"{"localPeerAddr":{"a":1},"x":1}"#)
        #expect(repair(#"{"localPeerAddr":null}"#) == #"{"localPeerAddr":null}"#)
        #expect(repair(#"[{"localPeerAddr":,},{"localPeerAddr":,}]"#) == #"[{"localPeerAddr":{},},{"localPeerAddr":{},}]"#)
        #expect(repair("no key") == "no key")
    }

    @Test func decodesValidPeerAddress() throws {
        let text = PSNVector.consoleOfferText().replacingOccurrences(
            of: #""localPeerAddr":,"#, with: #""localPeerAddr":{"accountId":"42","platform":"PROSPERO"},"#)
        let message = try PSNMessage.decode(payload: "ver=1.0, type=text, body=" + text)
        #expect(message.connRequest?.localPeerAddress == PSNPeerAddress(accountID: "42", platform: "PROSPERO"))
    }

    @Test func decodesResultAndTerminate() throws {
        let result = try PSNMessage.decode(payload: "ver=1.0, type=text, body=" + PSNVector.consoleResultText(reqID: 9))
        #expect(result == PSNMessage(action: .result, reqID: 9, connRequest: nil))
        let terminate = try PSNMessage.decode(
            payload: #"ver=1.0, type=text, body={"action":"TERMINATE","reqId":3,"error":7,"connRequest":{"junk":1}}"#)
        #expect(terminate == PSNMessage(action: .terminate, reqID: 3, error: 7, connRequest: nil))
    }

    @Test func roundTripsOurOwnMessages() throws {
        let offer = PSNMessage(
            action: .accept, reqID: 3,
            connRequest: PSNConnRequest(
                sid: 4660, peerSid: 43981, natType: 0,
                candidates: [PSNCandidate(type: .staticAddress, address: "198.51.100.7", mappedAddress: "203.0.113.5", port: 50123, mappedPort: 40006)],
                localPeerAddress: Self.peer(), localHashedID: []))
        #expect(try PSNMessage.decode(payload: offer.payload()) == offer)
    }

    @Test func rejectsInvalidMessages() {
        func reject(_ payload: String, _ fragment: String, line: UInt = #line) {
            do {
                _ = try PSNMessage.decode(payload: payload)
                Issue.record("accepted \(payload)")
            } catch let PSNError.invalidMessage(reason) {
                #expect(fragment.isEmpty || reason.contains(fragment), "\(reason) vs \(fragment)")
            } catch {
                Issue.record("wrong error \(error)")
            }
        }
        func body(_ text: String) -> String { "ver=1.0, type=text, body=" + text }
        reject("no marker", "body=")
        reject(body("nope"), "not JSON")
        reject(body(#"{"reqId":1,"error":0,"connRequest":{}}"#), "action")
        reject(body(#"{"action":"HELLO","reqId":1,"error":0,"connRequest":{}}"#), "unknown action")
        reject(body(#"{"action":"RESULT","error":0,"connRequest":{}}"#), "reqId")
        reject(body(#"{"action":"RESULT","reqId":1,"connRequest":{}}"#), "error")
        reject(body(#"{"action":"RESULT","reqId":1,"error":0}"#), "connRequest")
        reject(body(#"{"action":"RESULT","reqId":1,"error":0,"connRequest":[]}"#), "connRequest")
        // Each required connRequest key, removed or mistyped, and each candidate key.
        let offer = PSNVector.consoleOfferText()
        for (key, wrong) in [
            (#""sid":43981"#, #""sid":"x""#), (#""peerSid":0"#, #""peerSid":"x""#),
            (#""skey":"AAAAAAAAAAAAAAAAAAAAAA==""#, #""skey":5"#), (#""natType":2"#, #""natType":"x""#),
            (#""candidate":"#, #""candidates":"#), (#""defaultRouteMacAddr":"0a:1b:2c:3d:4e:5f""#, #""defaultRouteMacAddr":1"#),
            (#""localHashedId":"oKGio6SlpqeoqaqrrK2ur7CxsrM=""#, #""localHashedId":"%%%""#),
            (#""type":"STATIC""#, #""type":1"#), (#""addr":"198.51.100.7""#, #""addr":1"#),
            (#""mappedAddr":"0.0.0.0","port":50123"#, #""mappedAddr":1,"port":50123"#),
            (#""port":50123"#, #""port":70000"#), (#""mappedPort":0},{"type":"LOCAL""#, #""mappedPort":-1},{"type":"LOCAL""#),
            (#"{"type":"STATIC","addr":"198.51.100.7","mappedAddr":"0.0.0.0","port":50123,"mappedPort":0}"#, "5"),
        ] {
            reject(body(offer.replacingOccurrences(of: key, with: wrong)), "")
        }
    }

    @Test func unknownCandidateTypeReadsAsStatic() throws {
        let text = PSNVector.consoleOfferText().replacingOccurrences(of: #""type":"STATIC""#, with: #""type":"WEIRD""#)
        let message = try PSNMessage.decode(payload: "body=" + text)
        #expect(message.connRequest?.candidates.first?.type == .staticAddress)
    }

    // MARK: The selected pair (holepunch.md section 6, vector P7)

    @Test func acceptingCandidateMapping() {
        let local = PSNCandidate(type: .local, address: "192.168.1.20", port: 50123)
        let first = PSNCandidate(type: .stun, address: "203.0.113.5", port: 40006)
        func accept(_ type: PSNCandidateType, _ address: String) -> PSNCandidate {
            PSNCandidate.accepting(
                selected: PSNCandidate(type: type, address: address, port: 9303), clientLocal: local,
                clientFirstOffer: first)
        }
        let viaFirst = accept(.staticAddress, "198.51.100.7")
        #expect(viaFirst.mappedAddress == "203.0.113.5" && viaFirst.mappedPort == 40006)
        #expect(viaFirst.address == "198.51.100.7" && viaFirst.port == 9303 && viaFirst.type == .staticAddress)
        for (type, address) in [
            (PSNCandidateType.local, "198.51.100.9"), (.derived, "10.1.2.3"), (.derived, "192.168.5.5"),
            (.derived, "172.16.0.1"), (.derived, "172.31.255.1"), (.derived, "fd00::1"), (.derived, "FC00::1"),
        ] {
            let mapped = accept(type, address)
            #expect(mapped.mappedAddress == "192.168.1.20" && mapped.mappedPort == 50123, "\(type) \(address)")
        }
        for address in ["172.15.0.1", "172.32.0.1", "172.x", "172", "8.8.8.8", "fe80::1"] {
            #expect(accept(.derived, address).mappedAddress == "203.0.113.5", "\(address)")
        }
    }

    @Test func parametersValidateSizes() throws {
        let good = try PSNVector.parameters()
        func make(context: String = PSNVector.pushContextID, d1: Int = 16, d2: Int = 16, hashed: Int = 20) throws {
            _ = try PSNSessionParameters(
                pushContextID: context, data1: [UInt8](repeating: 1, count: d1), data2: [UInt8](repeating: 2, count: d2),
                localSid: 1, localHashedID: [UInt8](repeating: 3, count: hashed))
        }
        #expect(good.localSid == 4660)
        for (name, build) in [
            ("pushContextID", { try make(context: "short") }), ("data1", { try make(d1: 15) }),
            ("data2", { try make(d2: 17) }), ("localHashedID", { try make(hashed: 19) }),
        ] as [(String, () throws -> Void)] {
            #expect(throws: PSNError.invalidParameter(reason: name)) { try build() }
        }
        let random = PSNSessionParameters.random()
        #expect(random.pushContextID.count == 36 && random.pushContextID == random.pushContextID.lowercased())
        #expect(random.data1 != random.data2 && random.data1 != PSNSessionParameters.random().data1)
        #expect(UUID(uuidString: random.pushContextID) != nil)
    }
}
