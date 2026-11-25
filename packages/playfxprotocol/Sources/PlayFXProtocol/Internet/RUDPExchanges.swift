import Foundation

// The HTTP-style exchanges over the ctrl hole's RUDP channel: registration through PSN (registration.md section 8)
// and session init (session.md section 11).

/// Registration through PSN, over RUDP.
enum PSNRegistration {
    /// Runs the PIN-less registration (registration.md section 8.4): one RUDP exchange with the request (header and
    /// body together) and the whole response in one message. Blocks the calling thread for up to the RUDP steps'
    /// tries (3 s per step by default).
    ///
    /// - Parameters:
    ///   - host: the `HOST` header value: the `LOCAL` candidate's address of the ctrl-hole OFFER (empty when none).
    /// - Throws: `RegistrationError`. `consoleAnswered` tells whether the console's INIT_ACK came (stream.md section
    ///   11.2 reasons 13 and 14: refused, or never answered).
    static func run(
        over rudp: RUDPConnection, target: RPTarget, accountID: [UInt8], data1: [UInt8], data2: [UInt8],
        customData1: [UInt8], host: String, seed: [UInt8] = secureRandomBytes(16)
    ) throws -> PairingResult {
        let request: RegistrationRequest
        do {
            request = try RegistrationRequest.buildPSN(
                target: target, accountID: accountID, seed: seed, data1: data1, data2: data2,
                customData1: customData1, host: host)
        } catch let kind as FailureKind {
            throw RegistrationError(kind: kind, consoleAnswered: false)
        } catch {
            throw RegistrationError(kind: .other(errno: 0), consoleAnswered: false)
        }
        let response: [UInt8]
        do {
            response = try rudp.exchange(request: request.header + request.body, expectFinish: true)
        } catch let error as RUDPError {
            switch error {
            case .timeout(.initAck): throw RegistrationError(kind: .timeout, consoleAnswered: false)
            case .timeout: throw RegistrationError(kind: .timeout, consoleAnswered: true)
            case .closed: throw RegistrationError(kind: .cancelled, consoleAnswered: false)
            default: throw RegistrationError(kind: .invalidInput, consoleAnswered: false)
            }
        }
        guard case .head(let head) = MiniHTTP.parseHead(response) else {
            throw RegistrationError(kind: .invalidResponse, consoleAnswered: true)
        }
        guard head.status == 200 else {
            throw RegistrationError(
                kind: .httpNotOK(status: head.status), reasonCode: head.applicationReason, consoleAnswered: true)
        }
        // The whole body must be in the same message (registration.md section 8.4 step 3).
        guard let length = head.contentLength, length > 0, response.count - head.length >= length else {
            throw RegistrationError(kind: .invalidResponse, consoleAnswered: true)
        }
        do {
            return try request.parsePairing(Array(response[head.length..<head.length + length]), target: target)
        } catch {
            throw RegistrationError(kind: .invalidData, consoleAnswered: true)
        }
    }
}

/// Session init's `BlockingTCPConnection` over RUDP: `send` runs the whole exchange (handshake, request, response,
/// ACK, FINISH; rudp.md sections 5 and 6) and `receive` returns the response, so `SessionInitClient` and its
/// version negotiation run unchanged, each retry a new handshake on the same socket. Closing it leaves the RUDP
/// connection open: ctrl and the switch message follow on it.
final class RUDPHTTPConnection: BlockingTCPConnection, @unchecked Sendable {
    private let rudp: RUDPConnection
    private let lock = NSLock()
    private var response: [UInt8]?

    init(_ rudp: RUDPConnection) { self.rudp = rudp }

    func connect(timeout: Double) throws {}

    func send(_ bytes: [UInt8], timeout: Double) throws {
        do {
            let answer = try rudp.exchange(request: bytes, expectFinish: true)
            lock.withLock { response = answer }
        } catch let error as RUDPError {
            switch error {
            case .timeout: throw FailureKind.timeout
            case .closed: throw FailureKind.cancelled
            default: throw FailureKind.invalidInput
            }
        }
    }

    func receive(maximum: Int, timeout: Double) throws -> [UInt8] {
        // One message holds the whole header (session.md section 11); afterwards the "stream" is closed.
        lock.withLock { () -> [UInt8] in
            defer { response = nil }
            return response ?? []
        }
    }

    func close() {}
}
