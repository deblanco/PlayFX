import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

@Suite struct StreamHandshakeTests {
    func ps5Handshake() throws -> StreamHandshake {
        try StreamHandshake(
            target: .ps5v1, sessionID: StreamInputs.sessionID,
            launchSpec: StreamLaunchSpec.encode(
                request: StreamInputs.ps5Launch(), target: .ps5v1, probe: StreamInputs.probe,
                handshakeKey: StreamInputs.handshakeKey, crypt: StreamInputs.ps5Crypt()),
            handshakeKey: StreamInputs.handshakeKey, keyPair: vectorKeyPair())
    }

    // MARK: V-ST4

    @Test func ps5HelloMatchesTheVector() throws {
        let hello = try ps5Handshake().helloBytes
        #expect(hello.count == 1409)
        #expect(hello == hex(StreamVectors.ps5HelloHex))
        #expect(sha256Hex(hello) == "01a67a5af27f022fa63a6e91cc0c96202ec509e4cff85c9d029820e1c2ad308c")
        #expect(Array(hello.prefix(5)) == hex("080012fc0a"))
    }

    @Test func ps5HelloSplitsIn1378And31() throws {
        let handshake = try ps5Handshake()
        let pieces = handshake.helloPieces()
        #expect(pieces.map(\.bytes.count) == [1378, 31])
        #expect(pieces.map(\.chunkFlags) == [0, 1])
        #expect(pieces.map(\.isContinuation) == [false, true])
        #expect(pieces.flatMap(\.bytes) == handshake.helloBytes)
    }

    @Test func splitWithSmallerMTUs() throws {
        let pieces = try ps5Handshake().helloPieces(mtuIn: 1200, mtuOut: 1300)
        #expect(pieces.map(\.bytes.count) == [1124, 285])
        #expect(pieces.map(\.chunkFlags) == [0, 1])
    }

    @Test func ps4HelloIsOneMessage() throws {
        let handshake = try StreamHandshake(
            target: .ps4v10, sessionID: StreamInputs.sessionID,
            launchSpec: StreamLaunchSpec.encode(
                request: StreamInputs.ps4Launch(), target: .ps4v10, probe: StreamInputs.probe,
                handshakeKey: StreamInputs.handshakeKey, crypt: StreamInputs.ps4Crypt()),
            handshakeKey: StreamInputs.handshakeKey, keyPair: vectorKeyPair())
        #expect(handshake.helloBytes.count == 1313)
        let pieces = handshake.helloPieces()
        #expect(pieces.count == 1 && pieces[0].chunkFlags == 1 && !pieces[0].isContinuation)
        guard case .hello(let hello) = try StreamMessage.decode(handshake.helloBytes) else {
            Issue.record("not a Hello")
            return
        }
        #expect(hello.clientVersion == 9)
        #expect(hello.encryptedKey == [0, 0, 0, 0])
        #expect(hello.sessionKey == StreamInputs.sessionID)
        #expect(hello.ecdhPublicKey == StreamInputs.publicA && hello.ecdhSignature == StreamInputs.signatureA)
        #expect(StreamHandshake.takionVersion(for: .ps4v9) == 9 && StreamHandshake.takionVersion(for: .ps5v1) == 12)
    }

    // MARK: Splitting rules

    @Test func splitBoundaries() {
        // M = 1404: a message of 1378 fits; 1379 doesn't.
        func pieces(_ n: Int) -> [StreamMessagePiece] {
            StreamMessageSplit.split([UInt8](repeating: 7, count: n), mtuIn: 1454, mtuOut: 1454)
        }
        #expect(pieces(1378).count == 1)
        #expect(pieces(1379).map(\.bytes.count) == [1378, 1])
        // First piece 1378, then pieces of M - 25 = 1379; a remainder of exactly 1379 is the final piece.
        #expect(pieces(1378 + 1379).map(\.chunkFlags) == [0, 1])
        #expect(pieces(1378 + 1379).map(\.bytes.count) == [1378, 1379])
        #expect(pieces(1378 + 1380).map(\.bytes.count) == [1378, 1379, 1])
        #expect(pieces(1378 + 1380).map(\.chunkFlags) == [0, 0, 1])
        #expect(pieces(0).count == 1)
        #expect(StreamMessageSplit.budget(mtuIn: 1300, mtuOut: 1454) == 1250)
    }

    @Test func splitPiecesAlwaysAddUp() {
        for mtu in [0, 27, 60, 576, 1000, 1454] {
            for length in [0, 1, 25, 26, 27, 100, 1409, 5000] {
                let bytes = (0..<length).map { UInt8(truncatingIfNeeded: $0) }
                let pieces = StreamMessageSplit.split(bytes, mtuIn: mtu, mtuOut: mtu)
                #expect(pieces.flatMap(\.bytes) == bytes)
                #expect(pieces.last?.chunkFlags == 1)
                #expect(pieces.dropLast().allSatisfy { $0.chunkFlags == 0 })
                #expect(pieces.first?.isContinuation == false)
                #expect(pieces.dropFirst().allSatisfy { $0.isContinuation })
            }
        }
    }

    // MARK: HelloReply handling

    func reply(_ edit: (inout HelloReplyMessage) -> Void = { _ in }) -> [UInt8] {
        var r = StreamMessageTests.helloReply
        edit(&r)
        return StreamMessage.helloReply(r).encoded
    }

    func completed(_ event: StreamHandshakeEvent) -> StreamHandshakeResult? {
        if case .completed(let result) = event { result } else { nil }
    }

    @Test func goodReplyYieldsTheSecret() throws {
        let event = try ps5Handshake().receive(hex(StreamMessageTests.helloReplyHex))
        let result = try #require(completed(event))
        #expect(result.ecdhSecret == StreamInputs.secret)
        #expect(result.consoleSignatureMatches)
        #expect(result.reply.serverVersion == 12)
        #expect(!"\(result)".contains("secret =") && Mirror(reflecting: result).children.isEmpty)
    }

    @Test func anEarlyStreamInfoIsKeptAndTheReplyStillWorks() throws {
        let handshake = try ps5Handshake()
        let early = try #require(try StreamMessage.decode(hex(StreamMessageTests.streamInfoHex)).streamInfo)
        #expect(try handshake.receive(hex(StreamMessageTests.streamInfoHex)) == .earlyStreamInfo(early))
        #expect(handshake.earlyStreamInfo == early)
        // A second StreamInfo is ignored; the first stays.
        #expect(try handshake.receive(StreamMessage.streamInfo(.microphone).encoded) == .ignored)
        #expect(handshake.earlyStreamInfo == early)
        let result = try #require(completed(try handshake.receive(reply())))
        #expect(result.ecdhSecret == StreamInputs.secret)
        #expect(handshake.earlyStreamInfo == early)
    }

    @Test func unrelatedMessagesAreIgnoredAndTheKeySurvives() throws {
        let pair = try vectorKeyPair()
        let handshake = try StreamHandshake(
            target: .ps5v1, sessionID: "id", launchSpec: "ls", handshakeKey: StreamInputs.handshakeKey, keyPair: pair)
        let noise: [[UInt8]] = [
            StreamMessage.heartbeat.encoded, StreamMessage.streamInfoAck.encoded,
            StreamMessage.connectionQuality(ConnectionQualityMessage(targetBitrate: 1)).encoded,
            StreamMessage.unknown(type: 77).encoded, [0x08], [0xff, 0xff], [],
            [0x08, 0x06, 0x42, 0x02, 0x08, 0x01],  // a malformed Cursor
        ]
        for bytes in noise { #expect(try handshake.receive(bytes) == .ignored) }
        #expect(!pair.isWiped)
        #expect(completed(try handshake.receive(reply())) != nil)
        #expect(pair.isWiped)
        #expect(pair.withSecretBytes { $0.allSatisfy { $0 == 0 } })
    }

    @Test func aDisconnectBeforeTheReplyEndsAndWipes() throws {
        let pair = try vectorKeyPair()
        let handshake = try StreamHandshake(
            target: .ps5v1, sessionID: "id", launchSpec: "ls", handshakeKey: StreamInputs.handshakeKey, keyPair: pair)
        let bye = StreamMessage.disconnect(DisconnectMessage(reason: "Server shutting down")).encoded
        #expect(try handshake.receive(bye) == .remoteDisconnect(reason: "Server shutting down"))
        #expect(pair.isWiped)
        #expect(throws: StreamHandshakeError.finished) { try handshake.receive(reply()) }
        let again = try ps5Handshake()
        #expect(try again.receive([0x08, 0x08, 0x52, 0x00]) == .remoteDisconnect(reason: nil))
    }

    @Test func abortWipes() throws {
        let pair = try vectorKeyPair()
        let handshake = try StreamHandshake(
            target: .ps5v1, sessionID: "id", launchSpec: "ls", handshakeKey: StreamInputs.handshakeKey, keyPair: pair)
        handshake.abort()
        #expect(pair.isWiped)
        #expect(throws: StreamHandshakeError.finished) { try handshake.receive(reply()) }
    }

    @Test func aBadReplyIsTerminalToo() throws {
        let pair = try vectorKeyPair()
        let handshake = try StreamHandshake(
            target: .ps5v1, sessionID: "id", launchSpec: "ls", handshakeKey: StreamInputs.handshakeKey, keyPair: pair)
        #expect(throws: StreamHandshakeError.versionRejected) {
            try handshake.receive(reply { $0.versionAccepted = false })
        }
        #expect(pair.isWiped)
    }

    @Test func aWrongSignatureIsIgnoredByDefaultAndRejectedWhenEnforced() throws {
        let wrong = reply { $0.ecdhSignature = [UInt8](repeating: 1, count: 32) }
        let lenient = try #require(completed(try ps5Handshake().receive(wrong)))
        #expect(!lenient.consoleSignatureMatches)
        #expect(lenient.ecdhSecret == StreamInputs.secret)
        #expect(throws: StreamHandshakeError.consoleSignatureMismatch) {
            try ps5Handshake().receive(wrong, signaturePolicy: .enforce)
        }
        let strict = try #require(completed(try ps5Handshake().receive(reply(), signaturePolicy: .enforce)))
        #expect(strict.consoleSignatureMatches)
    }

    @Test func aReplyWithoutTheUnusedFieldsIsAccepted() throws {
        let bytes = reply {
            $0.serverVersion = nil
            $0.token = nil
            $0.sessionKey = nil
        }
        #expect(completed(try ps5Handshake().receive(bytes)) != nil)
    }

    @Test func everyRefusalOfSection6_3() throws {
        func fails(_ bytes: [UInt8], _ error: StreamHandshakeError) throws {
            #expect(throws: error) { try ps5Handshake().receive(bytes) }
        }
        try fails(reply { $0.versionAccepted = false }, .versionRejected)
        try fails(reply { $0.keyAccepted = false }, .keyRejected)
        try fails(reply { $0.ecdhPublicKey = nil }, .missingPublicKey)
        try fails(reply { $0.ecdhPublicKey = [] }, .missingPublicKey)
        try fails(reply { $0.ecdhPublicKey = [UInt8](repeating: 4, count: 129) }, .publicKeyTooLong)
        try fails(reply { $0.ecdhSignature = nil }, .missingSignature)
        try fails(reply { $0.ecdhSignature = [] }, .missingSignature)
        try fails(reply { $0.ecdhSignature = [UInt8](repeating: 4, count: 33) }, .signatureTooLong)
        try fails(reply { $0.ecdhPublicKey = [UInt8](repeating: 4, count: 65) }, .invalidPublicKey)
        try fails([0x08, 0x01], .malformed(.missingField("payload 3")))
        try fails([0x08, 0x01, 0x1a, 0x05, 0x08], .malformed(.lengthPastEnd))
    }

    @Test func theHandshakeKeyMustBe16Bytes() {
        for count in [0, 15, 17, 32] {
            #expect(throws: StreamHandshakeError.badHandshakeKey) {
                try StreamHandshake(
                    target: .ps5v1, sessionID: "id", launchSpec: "ls",
                    handshakeKey: [UInt8](repeating: 1, count: count))
            }
        }
    }

    @Test func piecesCarryChannelAndDataType() throws {
        for piece in try ps5Handshake().helloPieces() { #expect(piece.channel == 1 && piece.dataType == 0) }
    }

    // MARK: From a StreamHandoff

    @Test func buildsTheHelloFromAHandoff() throws {
        let handoff = StreamHandoff(
            consoleAddress: "192.0.2.10", negotiatedVersion: .ps5v1, crypt: try StreamInputs.ps5Crypt(),
            sessionID: SessionID(value: StreamInputs.sessionID), streamHandshakeKey: StreamInputs.handshakeKey,
            consoleModel: .ps5, streamingType: .h265, dualSenseEnabled: true)
        let handshake = try StreamHandshake(
            handoff: handoff, settings: StreamInputs.ps5Settings, probe: StreamInputs.probe, keyPair: vectorKeyPair())
        #expect(handshake.helloBytes == hex(StreamVectors.ps5HelloHex))
        // A fresh key pair when none is given.
        let fresh = try StreamHandshake(handoff: handoff, settings: StreamInputs.ps5Settings)
        #expect(fresh.helloBytes.count == 1409 && fresh.helloBytes != handshake.helloBytes)
    }
}
