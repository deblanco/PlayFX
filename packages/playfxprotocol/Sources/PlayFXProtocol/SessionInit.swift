import Foundation
import Security

/// `count` bytes from the system's secure generator.
func secureRandomBytes(_ count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
    return bytes
}

/// What the session-init exchange yields: the negotiated version and the session cipher (session.md 5, 6.1).
struct SessionInitResult: Sendable {
    var target: RPTarget
    /// How many requests it took (1 unless the version was negotiated).
    var attempts: Int
    var context: RPCryptContext
}

/// The pure parts of session init: request bytes and the reading of the answer.
enum SessionInit {
    /// Lower-case hex of `registKey` up to, not including, its first zero byte (session.md section 4).
    static func registKeyHex(_ registKey: [UInt8]) -> String {
        encodeHex(Array(registKey.prefix { $0 != 0 }))
    }

    /// The request, byte for byte as session.md section 4 has it: note `Rp-Version` and the header order.
    static func request(host: String, port: UInt16, target: RPTarget, registKey: [UInt8]) -> [UInt8] {
        var text = "GET \(target.sessionInitPath) HTTP/1.1\r\n"
        text += "Host: \(host):\(port)\r\n"
        text += "User-Agent: remoteplay Windows\r\n"
        text += "Connection: close\r\n"
        text += "Content-Length: 0\r\n"
        text += "RP-Registkey: \(registKeyHex(registKey))\r\n"
        text += "Rp-Version: \(target.protocolVersion)\r\n"
        text += "\r\n"
        return Array(text.utf8)
    }

    enum Outcome: Equatable {
        case success(nonce: [UInt8])
        /// Repeat the whole init on a new connection with this target (session.md section 5.3).
        case retry(RPTarget)
        case failure(SessionError)
    }

    /// Reads a response header (session.md sections 5.2 to 5.4); `sent` is the target the request used.
    static func interpret(_ head: MiniHTTP.ResponseHead, sent: RPTarget) -> Outcome {
        if head.status == 200 {
            guard let text = head.headers["rp-nonce"], let nonce = Data(base64Encoded: text), nonce.count == 16
            else { return .failure(.invalidResponse) }
            return .success(nonce: Array(nonce))
        }
        guard let reason = head.applicationReason else { return .failure(.refused(reason: nil)) }
        guard reason == RPReason.versionMismatch || reason == RPReason.unknown else {
            return .failure(.from(reason: reason))
        }
        // A mismatch the console explains with a different version of the same family: try that one.
        if let reported = head.headers["rp-version"], reported != sent.protocolVersion {
            // Never the version that was just refused (a PS4 answering 5.0 to a 9.0 request).
            if let next = sent.target(forReportedVersion: reported), next != sent { return .retry(next) }
            return .failure(.versionMismatch)
        }
        return .failure(reason == RPReason.unknown ? .refused(reason: reason) : .versionMismatch)
    }
}

/// Runs session init over an injectable blocking connection (session.md sections 4, 5).
struct SessionInitClient: Sendable {
    var port: UInt16 = 9295
    var connectTimeout = 5.0
    var sendTimeout = 5.0
    var headerTimeout = 5.0
    /// Requests in total, the first plus retries (session.md section 5.3).
    var maximumAttempts = 3
    var maximumHeader = 16 * 1024
    var token = CancelToken()
    var makeConnection: @Sendable (_ host: String, _ port: UInt16) throws -> BlockingTCPConnection = { host, port in
        try NWBlockingTCPConnection(host: host, port: port)
    }

    func run(address: String, target: RPTarget, registKey: [UInt8], rpKey: [UInt8]) throws -> SessionInitResult {
        guard registKey.count == 16, rpKey.count == 16 else { throw SessionError.invalidInput }
        var current = target
        do {
            for attempt in 1...maximumAttempts {
                if token.isCancelled { throw FailureKind.cancelled }
                let head = try exchange(address: address, target: current, registKey: registKey)
                switch SessionInit.interpret(head, sent: current) {
                case .success(let nonce):
                    let context = try RPCryptContext.session(target: current, nonce: nonce, rpKey: rpKey)
                    return SessionInitResult(target: current, attempts: attempt, context: context)
                case .retry(let next):
                    current = next
                case .failure(let error):
                    throw error
                }
            }
            throw SessionError.versionMismatch
        } catch let error as SessionError {
            throw token.isCancelled ? SessionError.cancelled : error
        } catch let kind as FailureKind {
            throw token.isCancelled ? SessionError.cancelled : SessionError.from(kind)
        } catch RPCryptError.badLength {
            throw SessionError.invalidInput
        } catch {
            throw SessionError.cryptoFailure
        }
    }

    /// One connection: send the request, read the response header, close.
    private func exchange(address: String, target: RPTarget, registKey: [UInt8]) throws -> MiniHTTP.ResponseHead {
        let connection = try makeConnection(address, port)
        token.onCancel { connection.close() }
        defer { connection.close() }
        try connection.connect(timeout: connectTimeout)
        try connection.send(
            SessionInit.request(host: address, port: port, target: target, registKey: registKey), timeout: sendTimeout)
        let deadline = monotonicSeconds() + headerTimeout
        var received: [UInt8] = []
        while true {
            switch MiniHTTP.parseHead(received) {
            case .invalid:
                throw FailureKind.invalidResponse
            case .head(let head):
                return head
            case .needMore:
                guard received.count < maximumHeader else { throw FailureKind.invalidResponse }
                let chunk = try connection.receive(maximum: 4096, timeout: max(0.001, deadline - monotonicSeconds()))
                guard !chunk.isEmpty else { throw FailureKind.disconnected }
                received += chunk
            }
        }
    }
}
