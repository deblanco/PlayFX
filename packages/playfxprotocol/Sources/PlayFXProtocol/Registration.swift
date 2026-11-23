import Foundation
import Security

/// Who the user is to the console (registration.md section 1).
public enum RegistrationIdentity: Sendable, Equatable {
    /// The 8-byte little-endian PSN account ID. Works for every target.
    case accountID([UInt8])
    /// The PSN online ID (sign-in name); only PS4-8 and PS4-9 accept it.
    case onlineID(String)
}

/// The pairing record the console returns (registration.md section 5). These are secrets: store them in the
/// Keychain and never log them.
public struct PairingResult: Sendable, Equatable {
    /// The 16-byte registration key field: the decoded `RegistKey` text (normally 8 ASCII hex characters),
    /// then zero bytes.
    public var registKey: [UInt8]
    /// The 16-byte `RP-Key`.
    public var rpKey: [UInt8]
    /// The console's name; empty if it sent none.
    public var nickname: String
    /// The console's 6-byte MAC address.
    public var mac: [UInt8]
    /// The target the registration used.
    public var target: RPTarget
    /// `RP-KeyType`, stored only.
    public var keyType: UInt32?
    /// `AP-Ssid`, `AP-Bssid`, `AP-Key`, `AP-Name`: stored only.
    public var apSSID: String?
    public var apBSSID: String?
    public var apKey: String?
    public var apName: String?
}

/// The request bytes of a registration and the context that decrypts the answer.
struct RegistrationRequest {
    var header: [UInt8]
    var body: [UInt8]
    var context: RPCryptContext

    static let fillerLength = 0x1e0
    static let clientType = "dabfa2ec873de5839bee8d3f4c0239c4282c07c25c6077a2931afcf0adc0d34f"

    /// Builds the LAN registration request (registration.md section 3, rpcrypt.md section 6).
    static func build(
        target: RPTarget, identity: RegistrationIdentity, pin: UInt32, seed: [UInt8], filler: UInt8 = 0x41
    ) throws -> RegistrationRequest {
        let inner: String
        switch identity {
        case .accountID(let id):
            guard id.count == 8 else { throw FailureKind.invalidInput }
            let encoded = Data(id).base64EncodedString()
            inner = target.isLegacy
                ? "Client-Type: Windows\r\nNp-AccountId: \(encoded)\r\n"
                : "Client-Type: \(clientType)\r\nNp-AccountId: \(encoded)\r\n"
        case .onlineID(let name):
            guard target.isLegacy, !name.isEmpty,
                  !name.utf8.contains(where: { $0 == 0x0d || $0 == 0x0a || $0 == 0 }) else {
                throw FailureKind.invalidInput
            }
            inner = "Client-Type: Windows\r\nNp-Online-Id: \(name)\r\n"
        }
        guard seed.count == 16 else { throw FailureKind.invalidInput }

        var body = [UInt8](repeating: filler, count: fillerLength)
        let crypt = try RPCryptContext.registration(
            target: target, pin: pin, seed: seed,
            keyColumn: Int(body[0x18d] & 0x1f), maskColumn: Int(body[0] >> 3))
        let m = crypt.maskedSeed
        if target.isLegacy {
            body.replaceSubrange(0x11c..<0x12c, with: m)
        } else {
            body.replaceSubrange(0x0c7..<0x0cf, with: m[8..<16])
            body.replaceSubrange(0x191..<0x199, with: m[0..<8])
        }
        var innerBytes = Array(inner.utf8)
        try crypt.context.encrypt(&innerBytes, counter: 0)
        body += innerBytes

        let path = target.isLegacy ? "/sce/rp/regist" : target.isPS5 ? "/sie/ps5/rp/sess/rgst" : "/sie/ps4/rp/sess/rgst"
        let version: String? = switch target {
        case .ps4v8: nil
        case .ps4v9: "9.0"
        case .ps4v10: "10.0"
        case .ps5v1: "1.0"
        }
        return RegistrationRequest(
            header: MiniHTTP.registrationHeader(path: path, contentLength: body.count, rpVersion: version),
            body: body, context: crypt.context)
    }

    /// Decrypts and reads a 200 response body (registration.md section 4.2).
    func parsePairing(_ encryptedBody: [UInt8], target: RPTarget) throws -> PairingResult {
        var plain = encryptedBody
        try context.decrypt(&plain, counter: 0)
        let fields = MiniHTTP.parseFields(plain)
        let prefix = target.isPS5 ? "PS5" : "PS4"
        guard let keyText = fields["\(prefix)-RegistKey"], var registKey = decodeHex(keyText.utf8),
              !registKey.isEmpty, registKey.count <= 16,
              let rpText = fields["RP-Key"], let rpKey = decodeHex(rpText.utf8), rpKey.count == 16,
              let macText = fields["\(prefix)-Mac"], let mac = decodeHex(macText.utf8), mac.count == 6
        else { throw FailureKind.invalidData }
        registKey += [UInt8](repeating: 0, count: 16 - registKey.count)
        return PairingResult(
            registKey: registKey, rpKey: rpKey, nickname: fields["\(prefix)-Nickname"] ?? "", mac: mac,
            target: target, keyType: fields["RP-KeyType"].flatMap { UInt32($0) },
            apSSID: fields["AP-Ssid"], apBSSID: fields["AP-Bssid"], apKey: fields["AP-Key"],
            apName: fields["AP-Name"])
    }
}

/// Runs a registration; every dependency that touches the outside world is injectable for tests.
struct RegistrationClient {
    var searchPort: UInt16 = 9295
    var requestPort: UInt16 = 9295
    var searchTimeout = 3.0
    var pauseAfterSearch = 0.1
    var connectTimeout = 3.0
    var sendTimeout = 3.0
    var headerTimeout = 3.0
    var bodyTimeout = 3.0
    /// Largest response header or body accepted.
    var maximumResponse = 64 * 1024
    /// Fires when the calling task is cancelled.
    var token = CancelToken()
    var makeSocket: @Sendable (_ host: String, _ port: UInt16) throws -> DatagramSocket = { host, port in
        try POSIXDatagramSocket(ipv6: SocketAddress.isIPv6(host), peer: (host, port))
    }
    var makeConnection: @Sendable (_ host: String, _ port: UInt16) throws -> BlockingTCPConnection = { host, port in
        try NWBlockingTCPConnection(host: host, port: port)
    }
    var randomBytes: @Sendable (_ count: Int) -> [UInt8] = { count in
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes
    }
    var pause: @Sendable (Double) -> Void = sleepSeconds

    func register(
        address: String, target: RPTarget, identity: RegistrationIdentity, pin: UInt32
    ) throws -> PairingResult {
        var answered = false
        do {
            let request = try RegistrationRequest.build(
                target: target, identity: identity, pin: pin, seed: randomBytes(16))
            let consoleAddress = try search(address: address, ps5: target.isPS5)
            answered = true
            pause(pauseAfterSearch)
            if token.isCancelled { throw FailureKind.cancelled }
            let connection = try makeConnection(consoleAddress, requestPort)
            token.onCancel { connection.close() }
            defer { connection.close() }
            try connection.connect(timeout: connectTimeout)
            try connection.send(request.header + request.body, timeout: sendTimeout)
            let body = try readResponse(connection)
            return try request.parsePairing(body, target: target)
        } catch let error as RegistrationError {
            throw token.isCancelled ? RegistrationError(kind: .cancelled, consoleAnswered: answered) : error
        } catch let kind as FailureKind {
            throw RegistrationError(kind: token.isCancelled ? .cancelled : kind, consoleAnswered: answered)
        } catch {
            // Only RPCryptError is left: the cipher could not run.
            throw RegistrationError(kind: .other(errno: 0), consoleAnswered: answered)
        }
    }

    /// UDP search (registration.md section 2); returns the address the answer came from.
    private func search(address: String, ps5: Bool) throws -> String {
        let socket = try makeSocket(address, searchPort)
        try socket.send(Array((ps5 ? "SRC3" : "SRC2").utf8) + [0], to: address, port: searchPort)
        let expected = Array((ps5 ? "RES3" : "RES2").utf8)
        let deadline = monotonicSeconds() + searchTimeout
        while true {
            if token.isCancelled { throw FailureKind.cancelled }
            let remaining = deadline - monotonicSeconds()
            guard remaining > 0 else { throw FailureKind.timeout }
            // Short waits, so a cancelled task stops within a slice.
            if let datagram = try socket.receive(timeout: min(remaining, 0.05)), datagram.bytes.starts(with: expected) {
                return datagram.source
            }
        }
    }

    /// Reads the response header and, for status 200, the body (registration.md section 4.1).
    private func readResponse(_ connection: BlockingTCPConnection) throws -> [UInt8] {
        var received: [UInt8] = []
        var deadline = monotonicSeconds() + headerTimeout
        func more() throws {
            let chunk = try connection.receive(
                maximum: 4096, timeout: max(0.001, deadline - monotonicSeconds()))
            guard !chunk.isEmpty else { throw FailureKind.disconnected }
            received += chunk
        }
        var head: MiniHTTP.ResponseHead
        while true {
            switch MiniHTTP.parseHead(received) {
            case .invalid:
                throw FailureKind.invalidResponse
            case .head(let parsed):
                head = parsed
            case .needMore:
                guard received.count < maximumResponse else { throw FailureKind.invalidResponse }
                try more()
                continue
            }
            break
        }
        guard head.status == 200 else {
            throw RegistrationError(
                kind: .httpNotOK(status: head.status), reasonCode: head.applicationReason, consoleAnswered: true)
        }
        guard let length = head.contentLength, length > 0, length <= maximumResponse else {
            throw FailureKind.invalidResponse
        }
        deadline = monotonicSeconds() + bodyTimeout
        while received.count - head.length < length { try more() }
        return Array(received[head.length..<head.length + length])
    }
}

/// Pairing with a console that shows its PIN (registration.md).
public enum Registration {
    /// Pairs using PlayFX's default target (PS5-1 for a PS5, PS4-10 for a PS4). Blocks for up to about 20
    /// seconds. `accountId` is the 8-byte little-endian PSN account ID. Throws `RegistrationError`.
    public static func register(address: String, ps5: Bool, accountId: [UInt8], pin: UInt32) throws -> PairingResult {
        try register(address: address, target: ps5 ? .ps5v1 : .ps4v10, identity: .accountID(accountId), pin: pin)
    }

    /// Pairs for an explicit target and identity. Throws `RegistrationError`.
    public static func register(
        address: String, target: RPTarget, identity: RegistrationIdentity, pin: UInt32
    ) throws -> PairingResult {
        try RegistrationClient().register(address: address, target: target, identity: identity, pin: pin)
    }

    /// Async `register`: the blocking work runs off the caller's thread, and cancelling the task stops it
    /// within about 50 ms, throwing a `RegistrationError` of kind `.cancelled` (its `userMessage` is empty:
    /// do not show it).
    public static func registerAsync(
        address: String, ps5: Bool, accountId: [UInt8], pin: UInt32
    ) async throws -> PairingResult {
        try await registerAsync(
            address: address, target: ps5 ? .ps5v1 : .ps4v10, identity: .accountID(accountId), pin: pin)
    }

    /// Async `register` for an explicit target and identity.
    public static func registerAsync(
        address: String, target: RPTarget, identity: RegistrationIdentity, pin: UInt32
    ) async throws -> PairingResult {
        try await registerAsync(
            client: RegistrationClient(), address: address, target: target, identity: identity, pin: pin)
    }

    static func registerAsync(
        client: RegistrationClient, address: String, target: RPTarget, identity: RegistrationIdentity,
        pin: UInt32
    ) async throws -> PairingResult {
        let token = CancelToken()
        var client = client
        client.token = token
        let ready = client
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try ready.register(address: address, target: target, identity: identity, pin: pin)
                    })
                }
            }
        } onCancel: {
            token.cancel()
        }
    }
}
