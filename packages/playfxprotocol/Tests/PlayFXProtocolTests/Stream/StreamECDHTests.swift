import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

@Suite struct StreamECDHTests {
    @Test func publicKeysAndSignaturesMatchV_ST1() throws {
        let a = try StreamKeyPair(privateKey: StreamInputs.privateA)
        #expect(a.publicKey == StreamInputs.publicA)
        #expect(
            StreamSignature.sign(publicKey: a.publicKey, handshakeKey: StreamInputs.handshakeKey)
                == StreamInputs.signatureA)
        let b = try StreamKeyPair(privateKey: StreamInputs.privateB)
        #expect(b.publicKey == StreamInputs.publicB)
        #expect(
            StreamSignature.sign(publicKey: b.publicKey, handshakeKey: StreamInputs.handshakeKey)
                == StreamInputs.signatureB)
    }

    @Test func bothSidesDeriveTheSameRawXCoordinate() throws {
        let a = try StreamKeyPair(privateKey: StreamInputs.privateA)
        let b = try StreamKeyPair(privateKey: StreamInputs.privateB)
        #expect(try a.sharedSecret(consolePublicKey: StreamInputs.publicB) == StreamInputs.secret)
        #expect(try b.sharedSecret(consolePublicKey: StreamInputs.publicA) == StreamInputs.secret)
    }

    @Test func aCompressedConsoleKeyWorksToo() throws {
        let a = try StreamKeyPair(privateKey: StreamInputs.privateA)
        var compressed = [UInt8(StreamInputs.publicB[64] & 1 == 0 ? 2 : 3)]
        compressed += StreamInputs.publicB[1...32]
        #expect(try a.sharedSecret(consolePublicKey: compressed) == StreamInputs.secret)
    }

    @Test func badPublicKeysAreRefused() throws {
        let a = try StreamKeyPair(privateKey: StreamInputs.privateA)
        var offCurve = StreamInputs.publicB
        offCurve[64] ^= 1
        let bad: [[UInt8]] = [
            [], [4], offCurve, Array(StreamInputs.publicB.dropLast()), [UInt8](repeating: 0, count: 65),
            [6] + StreamInputs.publicB[1...], [5] + [UInt8](repeating: 2, count: 32),
        ]
        for key in bad {
            #expect(throws: StreamECDHError.invalidPublicKey) { try a.sharedSecret(consolePublicKey: key) }
        }
    }

    @Test func invalidPrivateKeysAreRefused() {
        for key in [
            [UInt8](repeating: 0, count: 32), [UInt8](repeating: 0xff, count: 32), [UInt8](repeating: 1, count: 31),
            [],
        ] {
            #expect(throws: StreamECDHError.invalidPrivateKey) { try StreamKeyPair(privateKey: key) }
        }
    }

    @Test func generationRetriesUntilTheScalarIsValid() throws {
        let draws = Locked(0)
        let pair = try StreamKeyPair(randomSource: { count in
            let n = draws.with { d -> Int in
                d += 1
                return d
            }
            switch n {
            case 1: return [UInt8](repeating: 0, count: count)  // zero
            case 2: return [UInt8](repeating: 0xff, count: count)  // above the curve order
            case 3: return [UInt8](repeating: 7, count: 5)  // wrong size
            default: return StreamInputs.privateA
            }
        })
        #expect(draws.with { $0 } == 4)
        #expect(pair.publicKey == StreamInputs.publicA)
    }

    @Test func aBrokenRandomSourceEndsInAnError() {
        #expect(throws: StreamECDHError.invalidPrivateKey) {
            try StreamKeyPair(randomSource: { [UInt8](repeating: 0, count: $0) })
        }
    }

    @Test func freshKeysDifferAndHaveTheRightShape() throws {
        let one = try StreamKeyPair()
        let two = try StreamKeyPair()
        #expect(one.publicKey.count == 65 && one.publicKey[0] == 4)
        #expect(one.publicKey != two.publicKey)
        #expect(try one.sharedSecret(consolePublicKey: two.publicKey) == (try two.sharedSecret(consolePublicKey: one.publicKey)))
    }

    @Test func wipingStopsFurtherUse() throws {
        let a = try StreamKeyPair(privateKey: StreamInputs.privateA)
        #expect(!a.isWiped)
        #expect(a.withSecretBytes { Array($0) } == StreamInputs.privateA)
        a.wipe()
        #expect(a.isWiped)
        #expect(a.withSecretBytes { $0.allSatisfy { $0 == 0 } })
        #expect(throws: StreamECDHError.invalidPrivateKey) { try a.sharedSecret(consolePublicKey: StreamInputs.publicB) }
    }

    @Test func nothingSecretShowsInDescriptionsOrDumps() throws {
        let pair = try StreamKeyPair(privateKey: StreamInputs.privateA)
        let handshake = try StreamHandshake(
            target: .ps5v1, sessionID: StreamInputs.sessionID, launchSpec: "LAUNCHSPEC",
            handshakeKey: StreamInputs.handshakeKey, keyPair: pair)
        let hello = HelloMessage(
            clientVersion: 12, sessionKey: StreamInputs.sessionID, launchSpec: "LAUNCHSPEC", encryptedKey: [0, 0, 0, 0])
        let objects: [Any] = [
            pair, handshake, hello, StreamMessage.hello(hello),
            ClientInfoMessage(sessionKey: StreamInputs.sessionID), StreamMessage.clientInfo(ClientInfoMessage(sessionKey: StreamInputs.sessionID)),
        ]
        let secrets = [
            StreamInputs.sessionID, "LAUNCHSPEC", encodeHex(StreamInputs.privateA),
            encodeHex(StreamInputs.handshakeKey), String(describing: StreamInputs.privateA),
            String(describing: StreamInputs.handshakeKey),
        ]
        for object in objects {
            var dumped = ""
            dump(object, to: &dumped)
            for text in [dumped, String(reflecting: object), String(describing: object)] {
                for secret in secrets { #expect(!text.contains(secret), "\(secret) leaked in \(text)") }
            }
        }
        #expect(String(describing: handshake) == "StreamHandshake(keys hidden)")
        #expect(String(reflecting: pair) == "StreamKeyPair(keys hidden)")
    }

    @Test func signatureVerification() {
        let key = StreamInputs.handshakeKey
        #expect(StreamSignature.verify(signature: StreamInputs.signatureA, publicKey: StreamInputs.publicA, handshakeKey: key))
        #expect(!StreamSignature.verify(signature: StreamInputs.signatureB, publicKey: StreamInputs.publicA, handshakeKey: key))
        #expect(!StreamSignature.verify(signature: [1, 2], publicKey: StreamInputs.publicA, handshakeKey: key))
    }
}
