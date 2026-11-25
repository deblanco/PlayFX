import CommonCrypto
import Foundation

/// A console family plus Remote Play protocol version (rpcrypt.md section 1).
public enum RPTarget: Sendable, Equatable, CaseIterable {
    case ps4v8, ps4v9, ps4v10, ps5v1

    /// PS4-8 and PS4-9 use the legacy ("P9") derivations; PS4-10 and PS5-1 use the table ones.
    var isLegacy: Bool { self == .ps4v8 || self == .ps4v9 }
    /// True for a PS5 target.
    public var isPS5: Bool { self == .ps5v1 }
}

/// Why a context could not be built.
public enum RPCryptError: Error, Sendable, Equatable {
    /// An input had the wrong length (all keys, seeds and nonces are 16 bytes).
    case badLength
    /// PSN-mode registration exists only for PS4-10 and PS5-1.
    case unsupportedTarget
    /// CommonCrypto refused to create or run the cipher (not expected with valid keys).
    case cipherFailure
}

/// One AES-128 ECB encryptor, created once per context, that the CFB loop drives block by block (CFB uses the
/// AES encrypt direction for both encryption and decryption).
final class AESBlockEngine: @unchecked Sendable {
    private let lock = NSLock()
    private let cryptor: CCCryptorRef

    init(key: [UInt8]) throws {
        var ref: CCCryptorRef?
        let status = key.withUnsafeBytes {
            CCCryptorCreateWithMode(
                CCOperation(kCCEncrypt), CCMode(kCCModeECB), CCAlgorithm(kCCAlgorithmAES),
                CCPadding(ccNoPadding), nil, $0.baseAddress, 16, nil, 0, 0, 0, &ref)
        }
        guard status == kCCSuccess, let ref else { throw RPCryptError.cipherFailure }
        cryptor = ref
    }

    deinit { CCCryptorRelease(cryptor) }

    /// AES-128-CFB128 over `buffer` in place from `iv` (16 bytes), no heap allocation.
    func cfb(iv: UnsafeRawBufferPointer, buffer: UnsafeMutableRawBufferPointer, encrypt: Bool) throws {
        try withUnsafeTemporaryAllocation(byteCount: 32, alignment: 1) { scratch in
            let feedback = UnsafeMutableRawBufferPointer(rebasing: scratch[0..<16])
            let stream = UnsafeMutableRawBufferPointer(rebasing: scratch[16..<32])
            feedback.copyMemory(from: iv)
            lock.lock()
            defer { lock.unlock() }
            var offset = 0
            while offset < buffer.count {
                var moved = 0
                guard CCCryptorUpdate(cryptor, feedback.baseAddress, 16, stream.baseAddress, 16, &moved)
                        == kCCSuccess, moved == 16 else { throw RPCryptError.cipherFailure }
                let n = min(16, buffer.count - offset)
                if !encrypt && n == 16 {
                    feedback.copyMemory(from: UnsafeRawBufferPointer(rebasing: buffer[offset..<offset + 16]))
                }
                for i in 0..<n { buffer[offset + i] ^= stream[i] }
                if encrypt && n == 16 {
                    feedback.copyMemory(from: UnsafeRawBufferPointer(rebasing: buffer[offset..<offset + 16]))
                }
                offset += n
            }
        }
    }
}

/// A registration context plus the masked seed to put in the request body (rpcrypt.md sections 6 and 7).
public struct RPRegistrationCrypt: Sendable, Equatable {
    public let context: RPCryptContext
    /// The 16-byte masked seed `M`.
    public let maskedSeed: [UInt8]
}

/// The RP-crypt cipher context: AES key `K`, IV seed `S` and HMAC key `H` (rpcrypt.md). Each operation is
/// independent: it derives `IV(c)` from the counter and runs AES-128-CFB from a fresh state.
public struct RPCryptContext: Sendable, Equatable {
    public let key: [UInt8]
    public let seed: [UInt8]
    public let hmacKey: [UInt8]
    private let engine: AESBlockEngine

    /// Builds a context from its three 16-byte values.
    public init(key: [UInt8], seed: [UInt8], hmacKey: [UInt8]) throws {
        guard key.count == 16, seed.count == 16, hmacKey.count == 16 else { throw RPCryptError.badLength }
        self.key = key
        self.seed = seed
        self.hmacKey = hmacKey
        engine = try AESBlockEngine(key: key)
    }

    private init(unchecked key: [UInt8], _ seed: [UInt8], _ hmacKey: [UInt8]) throws {
        self.key = key
        self.seed = seed
        self.hmacKey = hmacKey
        engine = try AESBlockEngine(key: key)
    }

    public static func == (a: RPCryptContext, b: RPCryptContext) -> Bool {
        a.key == b.key && a.seed == b.seed && a.hmacKey == b.hmacKey
    }

    /// `H` for a target (section 2.4).
    static func hmacKey(for target: RPTarget) -> [UInt8] {
        switch target {
        case .ps4v8, .ps4v9: RPTables.ivHmacKeyP9
        case .ps4v10: RPTables.ivHmacKeyPs4
        case .ps5v1: RPTables.ivHmacKeyPs5
        }
    }

    // MARK: Derivations

    /// Session mode (section 5): `nonce` is the console's 16-byte `RP-Nonce`, `rpKey` the 16-byte `RP-Key`.
    public static func session(target: RPTarget, nonce n: [UInt8], rpKey r: [UInt8]) throws -> RPCryptContext {
        guard n.count == 16, r.count == 16 else { throw RPCryptError.badLength }
        var s = [UInt8](repeating: 0, count: 16)
        var k = [UInt8](repeating: 0, count: 16)
        switch target {
        case .ps4v8, .ps4v9:
            let p9n = RPTables.p9NonceMask, p9m = RPTables.p9Mask
            for i in 0..<16 {
                let b = UInt8(truncatingIfNeeded: i)
                s[i] = (n[i] &- b &- 0x27) ^ p9n[i]
                k[i] = (r[i] &- b &+ 0x34) ^ p9m[i] ^ n[i]
            }
        case .ps4v10:
            let a = Int(n[0] >> 3) * 0x70, b = Int(n[7] >> 3) * 0x70
            let seeds = RPTables.sessionSeedPs4, keys = RPTables.sessionKeyPs4
            for i in 0..<16 {
                let x = UInt8(truncatingIfNeeded: i)
                s[i] = (n[i] &+ 0x36 &+ x) ^ seeds[a + i]
                k[i] = ((keys[b + i] ^ r[i]) &+ 0x21 &+ x) ^ n[i]
            }
        case .ps5v1:
            let a = Int(n[0] >> 3) * 0x70, b = Int(n[7] >> 3) * 0x70
            let seeds = RPTables.sessionSeedPs5, keys = RPTables.sessionKeyPs5
            for i in 0..<16 {
                let x = UInt8(truncatingIfNeeded: i)
                s[i] = (n[i] &- 0x2d &- x) ^ seeds[a + i]
                k[i] = (r[i] &+ 0x18 &+ x) ^ n[i] ^ keys[b + i]
            }
        }
        return try RPCryptContext(unchecked: k, s, hmacKey(for: target))
    }

    /// LAN registration (section 6). `seed` is the client's random 16-byte `S`; `keyColumn` and `maskColumn`
    /// (0..31) are `filler[0x18d] & 0x1f` and `filler[0] >> 3`, and are ignored for PS4-8/PS4-9.
    public static func registration(
        target: RPTarget, pin: UInt32, seed s: [UInt8], keyColumn: Int, maskColumn: Int
    ) throws -> RPRegistrationCrypt {
        guard s.count == 16 else { throw RPCryptError.badLength }
        let pinBytes = [UInt8(truncatingIfNeeded: pin >> 24), UInt8(truncatingIfNeeded: pin >> 16),
                        UInt8(truncatingIfNeeded: pin >> 8), UInt8(truncatingIfNeeded: pin)]
        var k = [UInt8](repeating: 0, count: 16)
        var m = [UInt8](repeating: 0, count: 16)
        if target.isLegacy {
            k = RPTables.p9RegistKey
            for j in 0..<4 { k[j] ^= pinBytes[j] }
            let p9m = RPTables.p9Mask
            for i in 0..<16 { m[i] = (s[i] &- UInt8(truncatingIfNeeded: i) &- 0x29) ^ p9m[i] }
        } else {
            let (keyTable, maskTable, add) = registrationTables(target)
            let kc = keyColumn & 0x1f, mc = maskColumn & 0x1f
            for i in 0..<16 {
                k[i] = keyTable[i * 0x20 + kc]
                m[i] = (s[i] ^ maskTable[i * 0x20 + mc]) &+ add &+ UInt8(truncatingIfNeeded: i)
            }
            for j in 0..<4 { k[12 + j] ^= pinBytes[j] }
        }
        return try RPRegistrationCrypt(
            context: RPCryptContext(unchecked: k, s, hmacKey(for: target)), maskedSeed: m)
    }

    /// PSN (internet) registration (section 7), PS4-10 and PS5-1 only. `d1`, `d2` and `cd` are the 16-byte
    /// values of the PSN session setup.
    public static func psnRegistration(
        target: RPTarget, seed s: [UInt8], d1: [UInt8], d2: [UInt8], cd: [UInt8],
        keyColumn: Int, maskColumn: Int
    ) throws -> RPRegistrationCrypt {
        guard !target.isLegacy else { throw RPCryptError.unsupportedTarget }
        guard s.count == 16 else { throw RPCryptError.badLength }
        let helper = try RPCryptContext(key: d1, seed: d2, hmacKey: hmacKey(for: target))
        guard cd.count == 16 else { throw RPCryptError.badLength }
        let e = try helper.encrypted(cd, counter: 0)
        let (keyTable, maskTable, _) = registrationTables(target)
        let add: UInt8 = target == .ps5v1 ? 0x2b : 0xd7
        let kc = keyColumn & 0x1f, mc = maskColumn & 0x1f
        var k = [UInt8](repeating: 0, count: 16)
        var m = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            k[i] = keyTable[i * 0x20 + kc] ^ e[i]
            m[i] = (s[i] &- UInt8(truncatingIfNeeded: i) &+ add) ^ maskTable[i * 0x20 + mc]
        }
        return try RPRegistrationCrypt(
            context: RPCryptContext(unchecked: k, s, hmacKey(for: target)), maskedSeed: m)
    }

    /// Key table, mask table and the byte `m` of section 6.1 for a table target.
    private static func registrationTables(_ target: RPTarget) -> ([UInt8], [UInt8], UInt8) {
        target == .ps5v1
            ? (RPTables.registKeyPs5, RPTables.registMaskPs5, 0xd3)
            : (RPTables.registKeyPs4, RPTables.registMaskPs4, 0x29)
    }

    // MARK: Cipher

    /// `IV(c)`: the first 16 bytes of HMAC-SHA256(key `H`, `S || BE64(c)`) (section 2.1).
    public func iv(counter: UInt64) -> [UInt8] {
        withIV(counter: counter) { Array($0) }
    }

    /// Derives `IV(c)` into a stack buffer without heap allocation, and hands it to `body`.
    private func withIV<R>(
        counter: UInt64, _ body: (UnsafeRawBufferPointer) throws -> R
    ) rethrows -> R {
        try withUnsafeTemporaryAllocation(byteCount: 56, alignment: 1) { scratch in
            let mac = UnsafeMutableRawBufferPointer(rebasing: scratch[0..<32])
            let msg = UnsafeMutableRawBufferPointer(rebasing: scratch[32..<56])
            seed.withUnsafeBytes { msg.copyMemory(from: $0) }
            for j in 0..<8 {
                msg[16 + j] = UInt8(truncatingIfNeeded: counter >> UInt64(56 - 8 * j))
            }
            hmacKey.withUnsafeBytes { keyBytes in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), keyBytes.baseAddress, 16,
                       msg.baseAddress, 24, mac.baseAddress)
            }
            return try body(UnsafeRawBufferPointer(rebasing: mac[0..<16]))
        }
    }

    /// AES-128-CFB128 over `buffer` in place, with `IV(counter)`; `encrypt` picks the direction. Throws
    /// `RPCryptError.cipherFailure` if CommonCrypto fails (not expected with a valid context).
    public func apply(counter: UInt64, to buffer: UnsafeMutableRawBufferPointer, encrypt: Bool) throws {
        guard !buffer.isEmpty else { return }
        try withIV(counter: counter) { iv in
            try engine.cfb(iv: iv, buffer: buffer, encrypt: encrypt)
        }
    }

    /// Encrypts `bytes` in place at `counter`.
    public func encrypt(_ bytes: inout [UInt8], counter: UInt64) throws {
        try bytes.withUnsafeMutableBytes { try apply(counter: counter, to: $0, encrypt: true) }
    }

    /// Decrypts `bytes` in place at `counter`.
    public func decrypt(_ bytes: inout [UInt8], counter: UInt64) throws {
        try bytes.withUnsafeMutableBytes { try apply(counter: counter, to: $0, encrypt: false) }
    }

    /// Returns the encryption of `bytes` at `counter` (one copy; use `encrypt(_:counter:)` to avoid it).
    public func encrypted(_ bytes: [UInt8], counter: UInt64) throws -> [UInt8] {
        var copy = bytes
        try encrypt(&copy, counter: counter)
        return copy
    }

    /// Returns the decryption of `bytes` at `counter` (one copy; use `decrypt(_:counter:)` to avoid it).
    public func decrypted(_ bytes: [UInt8], counter: UInt64) throws -> [UInt8] {
        var copy = bytes
        try decrypt(&copy, counter: counter)
        return copy
    }

    /// Keystream-only form (section 2.3): `bytes XOR Encrypt(c = 0, zeros)`, in place.
    public func xorKeystream(_ bytes: inout [UInt8]) throws {
        var stream = [UInt8](repeating: 0, count: bytes.count)
        try encrypt(&stream, counter: 0)
        for i in bytes.indices { bytes[i] ^= stream[i] }
    }
}

/// Keys never show up in logs, `print` or `dump`.
extension RPCryptContext: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "RPCryptContext(keys hidden)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
