import CSecp256k1
import CryptoKit
import Darwin
import Foundation

/// Why an ECDH step failed.
public enum StreamECDHError: Error, Sendable, Equatable {
    /// The key is not 33 bytes (02/03) or 65 bytes (04) that decode to a point on secp256k1.
    case invalidPublicKey
    /// The private key is zero or not below the curve order, or the library refused the exchange.
    case invalidPrivateKey
    /// The library could not create its context.
    case contextFailure
}

/// The process-wide libsecp256k1 context: created once and randomized (blinding) before it is shared. It is
/// only passed to functions that take it `const`, which the library documents as thread-safe.
private final class Secp256k1Context: @unchecked Sendable {
    static let shared = Secp256k1Context()

    /// Nil only if the library failed to allocate.
    let pointer: OpaquePointer?

    private init() {
        var context = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_NONE))
        if let raw = context {
            var seed = secureRandomBytes(32)
            let randomized = secp256k1_context_randomize(raw, seed)
            seed.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
            if randomized != 1 {
                secp256k1_context_destroy(raw)
                context = nil
            }
        }
        pointer = context
    }
}

/// Overwrites memory in a way the optimiser may not remove.
private func secureWipe(_ pointer: UnsafeMutableRawPointer, count: Int) {
    _ = memset_s(pointer, count, 0, count)
}

/// A secp256k1 key pair for the stream handshake (stream.md section 6.4). The private scalar lives in memory
/// this class owns and is wiped by `wipe()` and on deinit. Keep one per session and drop it once the shared
/// secret is derived.
public final class StreamKeyPair: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public var description: String { "StreamKeyPair(keys hidden)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    private let secret: UnsafeMutableRawPointer
    private var wiped = false
    private let lock = NSLock()

    /// The 65-byte uncompressed public key `04 || X || Y`.
    public let publicKey: [UInt8]

    /// Makes a fresh key pair from secure random bytes, drawing again while the scalar is not in `[1, n-1]`.
    public convenience init() throws {
        try self.init(randomSource: secureRandomBytes)
    }

    /// As `init()`, with the random source injected (tests feed invalid scalars first).
    convenience init(randomSource: (Int) -> [UInt8]) throws {
        guard let context = Secp256k1Context.shared.pointer else { throw StreamECDHError.contextFailure }
        // The chance of one invalid draw is about 2^-128; the bound only keeps a broken source from looping.
        for _ in 0..<64 {
            var candidate = randomSource(32)
            defer { candidate.withUnsafeMutableBytes { secureWipe($0.baseAddress!, count: $0.count) } }
            if candidate.count == 32, secp256k1_ec_seckey_verify(context, candidate) == 1 {
                try self.init(validated: candidate, context: context)
                return
            }
        }
        throw StreamECDHError.invalidPrivateKey
    }

    /// A key pair from a known 32-byte private scalar (test vectors). The caller's array is not wiped.
    convenience init(privateKey: [UInt8]) throws {
        guard let context = Secp256k1Context.shared.pointer else { throw StreamECDHError.contextFailure }
        guard privateKey.count == 32, secp256k1_ec_seckey_verify(context, privateKey) == 1 else {
            throw StreamECDHError.invalidPrivateKey
        }
        try self.init(validated: privateKey, context: context)
    }

    private init(validated privateKey: [UInt8], context: OpaquePointer) throws {
        var pubkey = secp256k1_pubkey()
        guard secp256k1_ec_pubkey_create(context, &pubkey, privateKey) == 1 else {
            throw StreamECDHError.invalidPrivateKey
        }
        var out = [UInt8](repeating: 0, count: 65)
        var length = 65
        _ = secp256k1_ec_pubkey_serialize(context, &out, &length, &pubkey, UInt32(SECP256K1_EC_UNCOMPRESSED))
        publicKey = out
        secret = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 1)
        privateKey.withUnsafeBytes { secret.copyMemory(from: $0.baseAddress!, byteCount: 32) }
    }

    deinit {
        secureWipe(secret, count: 32)
        secret.deallocate()
    }

    /// True once `wipe()` has run.
    public var isWiped: Bool { lock.withLock { wiped } }

    /// The stored scalar's bytes, for tests that check the wipe really zeroed them.
    func withSecretBytes<R>(_ body: (UnsafeRawBufferPointer) -> R) -> R {
        lock.withLock { body(UnsafeRawBufferPointer(start: secret, count: 32)) }
    }

    /// Overwrites the private scalar. `sharedSecret` then fails.
    public func wipe() {
        lock.withLock {
            secureWipe(secret, count: 32)
            wiped = true
        }
    }

    /// `ecdhSecret`: the 32-byte big-endian X coordinate of `private x consolePublic`, not hashed. Accepts a
    /// 65-byte uncompressed or a 33-byte compressed key.
    public func sharedSecret(consolePublicKey: [UInt8]) throws -> [UInt8] {
        guard let context = Secp256k1Context.shared.pointer else { throw StreamECDHError.contextFailure }
        let validShape =
            (consolePublicKey.count == 65 && consolePublicKey[0] == 0x04)
            || (consolePublicKey.count == 33 && (consolePublicKey[0] == 0x02 || consolePublicKey[0] == 0x03))
        var pubkey = secp256k1_pubkey()
        guard validShape,
            secp256k1_ec_pubkey_parse(context, &pubkey, consolePublicKey, consolePublicKey.count) == 1
        else { throw StreamECDHError.invalidPublicKey }
        return try lock.withLock {
            guard !wiped else { throw StreamECDHError.invalidPrivateKey }
            var output = [UInt8](repeating: 0, count: 32)
            let status = secp256k1_ecdh(
                context, &output, &pubkey, secret.assumingMemoryBound(to: UInt8.self),
                { out, x32, _, _ in
                    // The raw X coordinate, as the spec requires: no hashing.
                    out!.update(from: x32!, count: 32)
                    return 1
                }, nil)
            guard status == 1 else { throw StreamECDHError.invalidPrivateKey }
            return output
        }
    }
}

/// HMAC-SHA256 signatures over public keys (section 6.4).
public enum StreamSignature {
    /// `HMAC-SHA256(key = streamHandshakeKey, message = publicKey)`.
    public static func sign(publicKey: [UInt8], handshakeKey: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: publicKey, using: SymmetricKey(data: handshakeKey)))
    }

    /// Constant-time check of a signature made the same way.
    public static func verify(signature: [UInt8], publicKey: [UInt8], handshakeKey: [UInt8]) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            signature, authenticating: publicKey, using: SymmetricKey(data: handshakeKey))
    }
}
