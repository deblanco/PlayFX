import Dispatch
import Foundation
import Network

/// A blocking TCP connection, small enough for tests to replace with a fake that injects failures.
protocol BlockingTCPConnection: AnyObject {
    /// Connects, or throws `FailureKind` (timeout, refused, unreachable, ...).
    func connect(timeout: Double) throws
    func send(_ bytes: [UInt8], timeout: Double) throws
    /// Up to `maximum` bytes (at least one); an empty array means the peer closed the stream.
    func receive(maximum: Int, timeout: Double) throws -> [UInt8]
    func close()
}

/// The result of one asynchronous Network.framework call, waited on by the calling thread.
private final class Pending<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<T, FailureKind>?

    /// Records the first outcome; later ones are ignored.
    func complete(_ outcome: Result<T, FailureKind>) {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil else { return }
        result = outcome
        semaphore.signal()
    }

    func wait(timeout: Double) -> Result<T, FailureKind> {
        if semaphore.wait(timeout: .now() + max(0, timeout)) == .timedOut { return .failure(.timeout) }
        lock.lock()
        defer { lock.unlock() }
        return result ?? .failure(.disconnected)
    }
}

/// `BlockingTCPConnection` over `NWConnection` (TCP).
final class NWBlockingTCPConnection: BlockingTCPConnection, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "PlayFXProtocol.tcp")

    init(host: String, port: UInt16) throws {
        guard let port = NWEndpoint.Port(rawValue: port), !host.isEmpty else { throw FailureKind.badAddress }
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
    }

    deinit { connection.cancel() }

    static func failure(_ error: NWError) -> FailureKind {
        switch error {
        case .posix(let code): FailureKind(errno: code.rawValue)
        case .dns: .badAddress
        default: .other(errno: 0)
        }
    }

    /// What a connection state means for a pending connect; nil while it is still going. `.waiting` carries
    /// the reason the connection cannot proceed (refused, no route), so it ends the attempt.
    static func connectOutcome(for state: NWConnection.State) -> Result<Void, FailureKind>? {
        switch state {
        case .ready: .success(())
        case .failed(let error), .waiting(let error): .failure(failure(error))
        case .cancelled: .failure(.disconnected)
        default: nil
        }
    }

    func connect(timeout: Double) throws {
        let pending = Pending<Void>()
        connection.stateUpdateHandler = { state in
            if let outcome = Self.connectOutcome(for: state) { pending.complete(outcome) }
        }
        connection.start(queue: queue)
        try finish(pending.wait(timeout: timeout))
    }

    func send(_ bytes: [UInt8], timeout: Double) throws {
        let pending = Pending<Void>()
        connection.send(content: Data(bytes), completion: .contentProcessed { error in
            pending.complete(error.map { .failure(Self.failure($0)) } ?? .success(()))
        })
        try finish(pending.wait(timeout: timeout))
    }

    func receive(maximum: Int, timeout: Double) throws -> [UInt8] {
        let pending = Pending<[UInt8]>()
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, _, error in
            if let error {
                pending.complete(.failure(Self.failure(error)))
            } else {
                pending.complete(.success(data.map { Array($0) } ?? []))
            }
        }
        return try finish(pending.wait(timeout: timeout))
    }

    func close() { connection.cancel() }

    /// Unwraps a result; a timeout also tears the connection down so late callbacks do nothing.
    private func finish<T>(_ result: Result<T, FailureKind>) throws -> T {
        do {
            return try result.get()
        } catch {
            connection.cancel()
            throw error
        }
    }
}
