import Foundation

/// The stream Hello and HelloReply (stream.md section 6): build and split the Hello, check the reply, derive
/// `ecdhSecret`. Pure bytes and crypto; Takion does the framing and the sending.

/// One Takion data message of a split Hello (section 2.3).
public struct StreamMessagePiece: Sendable, Equatable {
    /// The bytes after the Takion data-message header.
    public var bytes: [UInt8]
    /// True for a continuation data message (the header without the data-type byte); false for the first.
    public var isContinuation: Bool
    /// Takion chunk flags: 1 when this is the whole message or its last piece, else 0.
    public var chunkFlags: UInt8
    /// The Takion channel (1 for the Hello).
    public var channel: UInt16 = 1
    /// The data-type byte of an ordinary (first) piece; a continuation has none. 0 is a protobuf message.
    public var dataType: UInt8 = 0
}

/// Splitting a long message (section 2.3).
public enum StreamMessageSplit {
    /// Datagram overhead of an ordinary data message and of a continuation (takion.md).
    static let ordinaryOverhead = 26
    static let continuationOverhead = 25

    /// `M = min(mtuIn, mtuOut) - 50`.
    public static func budget(mtuIn: Int, mtuOut: Int) -> Int { max(min(mtuIn, mtuOut), 0) - 50 }

    /// Cuts `bytes` into the pieces to send, in order, on channel 1 with data type 0 for the first piece.
    /// `mtuIn` and `mtuOut` come from the probe (1454 each if it failed). A budget too small to carry a byte
    /// per piece is raised to 27, the smallest that makes progress.
    public static func split(_ bytes: [UInt8], mtuIn: Int, mtuOut: Int) -> [StreamMessagePiece] {
        let m = max(budget(mtuIn: mtuIn, mtuOut: mtuOut), ordinaryOverhead + 1)
        if bytes.count + ordinaryOverhead <= m {
            return [StreamMessagePiece(bytes: bytes, isContinuation: false, chunkFlags: 1)]
        }
        let first = m - ordinaryOverhead
        var pieces = [StreamMessagePiece(bytes: Array(bytes[0..<first]), isContinuation: false, chunkFlags: 0)]
        let size = m - continuationOverhead
        var offset = first
        while bytes.count - offset > size {
            pieces.append(
                StreamMessagePiece(bytes: Array(bytes[offset..<offset + size]), isContinuation: true, chunkFlags: 0))
            offset += size
        }
        pieces.append(StreamMessagePiece(bytes: Array(bytes[offset...]), isContinuation: true, chunkFlags: 1))
        return pieces
    }
}

/// Why the handshake failed (section 6.3). Any of these ends the session as `streamFailed`; a console
/// Disconnect is reported as `StreamHandshakeEvent.remoteDisconnect` instead.
public enum StreamHandshakeError: Error, Sendable, Equatable {
    /// `handshakeKey` is not 16 bytes.
    case badHandshakeKey
    /// The HelloReply's wrapper or payload did not decode.
    case malformed(ProtobufError)
    /// The handshake already finished (a reply was examined or a Disconnect arrived).
    case finished
    case versionRejected
    case keyRejected
    case missingPublicKey
    /// The console's key is longer than the 128 bytes existing clients accept.
    case publicKeyTooLong
    case missingSignature
    /// The console's signature is longer than the 32 bytes existing clients accept.
    case signatureTooLong
    /// The key isn't a point on secp256k1.
    case invalidPublicKey
    /// ECDH itself failed (the key pair was already wiped, or the library refused).
    case ecdhFailed
    /// `ConsoleSignaturePolicy.enforce` was chosen and the signature isn't HMAC-SHA256(handshake key, key).
    case consoleSignatureMismatch
}

/// What one received message did to the handshake.
public enum StreamHandshakeEvent: Sendable, Equatable {
    /// Not for the handshake (section 6.2: anything else is ignored); the key pair is untouched.
    case ignored
    /// The first StreamInfo, which may arrive before the HelloReply. It is kept (`earlyStreamInfo`): apply it
    /// after `.completed`.
    case earlyStreamInfo(StreamInfoMessage)
    /// The console ended the session. Terminal: the key pair is wiped.
    case remoteDisconnect(reason: String?)
    /// The HelloReply was good. Terminal: the key pair is wiped.
    case completed(StreamHandshakeResult)
}

/// What to do with the console's HelloReply signature. Existing clients never check it, and whether it is
/// HMAC-SHA256(streamHandshakeKey, console key) is an open question (stream.md section 14, item 1).
public enum ConsoleSignaturePolicy: Sendable, Equatable {
    /// The observed behaviour: don't reject on the signature. The result still says whether it matched.
    case ignore
    /// Reject a signature that doesn't match.
    case enforce
}

/// What a good HelloReply yields.
public struct StreamHandshakeResult: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    /// The 32-byte shared secret (section 6.4): the input, with `streamHandshakeKey`, of the GKCrypt keys.
    public var ecdhSecret: [UInt8]
    public var reply: HelloReplyMessage
    /// Whether the console's signature equals HMAC-SHA256(streamHandshakeKey, console public key).
    public var consoleSignatureMatches: Bool

    public var description: String { "StreamHandshakeResult(secret hidden)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// One stream handshake: owns the session's key pair and handshake key. Feed it every message the console
/// sends on channel 1 until it reports a terminal event.
public final class StreamHandshake: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    /// The Takion version the client speaks on the stream: 12 for a PS5, 9 for a PS4.
    public static func takionVersion(for target: RPTarget) -> UInt32 { target.isPS5 ? 12 : 9 }

    public let target: RPTarget
    private let handshakeKey: [UInt8]
    private let keyPair: StreamKeyPair
    /// The Hello's wrapper bytes (section 6.2).
    public let helloBytes: [UInt8]

    private let lock = NSLock()
    private var kept: StreamInfoMessage?
    private var done = false

    public var description: String { "StreamHandshake(keys hidden)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    /// Builds the Hello from the ctrl hand-off: `sessionID` and `handshakeKey` go in as they are, the launch
    /// spec is made from `settings` and `probe` and encrypted with the session context.
    public convenience init(
        handoff: StreamHandoff, settings: StreamSettings, probe: StreamProbeResult = .fallback,
        keyPair: StreamKeyPair? = nil
    ) throws {
        let request = settings.launchRequest(target: handoff.negotiatedVersion, model: handoff.consoleModel)
        let launchSpec = try StreamLaunchSpec.encode(
            request: request, target: handoff.negotiatedVersion, probe: probe,
            handshakeKey: handoff.streamHandshakeKey, crypt: handoff.crypt)
        try self.init(
            target: handoff.negotiatedVersion, sessionID: handoff.sessionID.value, launchSpec: launchSpec,
            handshakeKey: handoff.streamHandshakeKey, keyPair: keyPair)
    }

    /// Lower level: the launch spec text is given. `keyPair` is made fresh unless a test supplies one. Throws
    /// `StreamHandshakeError.badHandshakeKey` unless `handshakeKey` is 16 bytes.
    public init(
        target: RPTarget, sessionID: String, launchSpec: String, handshakeKey: [UInt8], keyPair: StreamKeyPair? = nil
    ) throws {
        guard handshakeKey.count == 16 else { throw StreamHandshakeError.badHandshakeKey }
        self.target = target
        self.handshakeKey = handshakeKey
        let pair = try keyPair ?? StreamKeyPair()
        self.keyPair = pair
        helloBytes = StreamMessage.hello(
            HelloMessage(
                clientVersion: Self.takionVersion(for: target), sessionKey: sessionID, launchSpec: launchSpec,
                encryptedKey: [0, 0, 0, 0], ecdhPublicKey: pair.publicKey,
                ecdhSignature: StreamSignature.sign(publicKey: pair.publicKey, handshakeKey: handshakeKey))
        ).encoded
    }

    /// The Hello's Takion data messages for these probe MTUs (1454 each if the probe failed).
    public func helloPieces(mtuIn: Int = 1454, mtuOut: Int = 1454) -> [StreamMessagePiece] {
        StreamMessageSplit.split(helloBytes, mtuIn: mtuIn, mtuOut: mtuOut)
    }

    /// The first StreamInfo seen while waiting for the HelloReply, if any.
    public var earlyStreamInfo: StreamInfoMessage? { lock.withLock { kept } }

    /// Wipes the key pair without a reply (timeout, or the session ends first).
    public func abort() {
        lock.withLock { done = true }
        keyPair.wipe()
    }

    /// Handles one data-type-0 message from the console (wrapper bytes) while waiting for the HelloReply
    /// (section 6.2): a StreamInfo is kept (the first one only), a Disconnect ends the session, a HelloReply is
    /// checked (section 6.3) and yields `ecdhSecret`, anything else is ignored. The key pair is wiped only on
    /// the terminal outcomes (a HelloReply examined, good or bad, or a Disconnect).
    public func receive(
        _ bytes: [UInt8], signaturePolicy: ConsoleSignaturePolicy = .ignore
    ) throws -> StreamHandshakeEvent {
        if lock.withLock({ done }) { throw StreamHandshakeError.finished }
        let message: StreamMessage
        do { message = try StreamMessage.decode(bytes) } catch let error as ProtobufError {
            // Only a malformed HelloReply matters; any other undecodable message is ignored.
            guard Self.isHelloReply(bytes) else { return .ignored }
            finish()
            throw StreamHandshakeError.malformed(error)
        }
        switch message {
        case .streamInfo(let info):
            return lock.withLock {
                guard kept == nil else { return .ignored }
                kept = info
                return .earlyStreamInfo(info)
            }
        case .disconnect(let d):
            finish()
            return .remoteDisconnect(reason: d.reason)
        case .helloReply(let reply):
            defer { finish() }
            return .completed(try complete(reply, signaturePolicy: signaturePolicy))
        default:
            return .ignored
        }
    }

    private func finish() {
        lock.withLock { done = true }
        keyPair.wipe()
    }

    private static func isHelloReply(_ bytes: [UInt8]) -> Bool {
        // The type is the first field; read it even if what follows is cut off.
        var reader = ProtobufReader(bytes)
        while let field = try? reader.next() {
            if field.number == 1 { return field.varint == StreamMessageType.helloReply.rawValue }
        }
        return false
    }

    private func complete(_ reply: HelloReplyMessage, signaturePolicy: ConsoleSignaturePolicy) throws
        -> StreamHandshakeResult
    {
        guard reply.versionAccepted else { throw StreamHandshakeError.versionRejected }
        guard reply.keyAccepted else { throw StreamHandshakeError.keyRejected }
        guard let consoleKey = reply.ecdhPublicKey, !consoleKey.isEmpty else {
            throw StreamHandshakeError.missingPublicKey
        }
        guard consoleKey.count <= 128 else { throw StreamHandshakeError.publicKeyTooLong }
        guard let signature = reply.ecdhSignature, !signature.isEmpty else {
            throw StreamHandshakeError.missingSignature
        }
        guard signature.count <= 32 else { throw StreamHandshakeError.signatureTooLong }
        let secret: [UInt8]
        do { secret = try keyPair.sharedSecret(consolePublicKey: consoleKey) } catch StreamECDHError.invalidPublicKey {
            throw StreamHandshakeError.invalidPublicKey
        } catch {
            throw StreamHandshakeError.ecdhFailed
        }
        let matches = StreamSignature.verify(signature: signature, publicKey: consoleKey, handshakeKey: handshakeKey)
        if signaturePolicy == .enforce && !matches { throw StreamHandshakeError.consoleSignatureMismatch }
        return StreamHandshakeResult(ecdhSecret: secret, reply: reply, consoleSignatureMatches: matches)
    }
}
