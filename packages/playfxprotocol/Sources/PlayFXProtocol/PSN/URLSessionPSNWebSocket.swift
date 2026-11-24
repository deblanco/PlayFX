import Foundation
import os

/// `PSNWebSocket` over `URLSessionWebSocketTask`. The system answers the server's pings itself (with the same
/// payload), so `receive` never returns `.ping` and `sendPong` has nothing to do.
public final class URLSessionPSNWebSocket: NSObject, PSNWebSocket, URLSessionWebSocketDelegate, @unchecked Sendable {
    private struct State {
        var task: URLSessionWebSocketTask?
        var session: URLSession?
        var opening: CheckedContinuation<Void, Error>?
        var openResult: Result<Void, Error>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public override init() { super.init() }

    public func open(url: URL, headers: [String: String]) async throws {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        // URLSession replaces a User-Agent given on the request with its own; the session's default headers win.
        let configuration = URLSessionConfiguration.ephemeral
        if let agent = headers["User-Agent"] { configuration.httpAdditionalHeaders = ["User-Agent": agent] }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        state.withLock {
            $0.session = session
            $0.task = task
            $0.openResult = nil
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let early = state.withLock { state -> Result<Void, Error>? in
                    if let result = state.openResult { return result }
                    state.opening = continuation
                    return nil
                }
                if let early { continuation.resume(with: early) } else { task.resume() }
            }
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    public func receive() async throws -> PSNWebSocketFrame {
        guard let task = state.withLock({ $0.task }) else { throw URLError(.notConnectedToInternet) }
        switch try await task.receive() {
        case .string(let text): return .text(text)
        case .data(let data): return .binary(data)
        @unknown default: return .binary(Data())
        }
    }

    public func ping() async throws {
        guard let task = state.withLock({ $0.task }) else { throw URLError(.notConnectedToInternet) }
        let pending = PendingPing()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pending.install(continuation)
                task.sendPing { error in pending.complete(error.map { .failure($0) } ?? .success(())) }
            }
        } onCancel: {
            // A half-dead connection never calls the pong handler; cancelling must still end the wait.
            pending.complete(.failure(CancellationError()))
        }
    }

    public func sendPong(_ payload: Data) async throws {}

    public func close() async {
        let (task, session) = state.withLock { ($0.task, $0.session) }
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    // MARK: Delegate

    private func finishOpening(_ result: Result<Void, Error>) {
        let waiting = state.withLock { state -> CheckedContinuation<Void, Error>? in
            guard state.openResult == nil else { return nil }
            state.openResult = result
            defer { state.opening = nil }
            return state.opening
        }
        waiting?.resume(with: result)
    }

    public func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?
    ) {
        finishOpening(.success(()))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finishOpening(.failure(error ?? URLError(.networkConnectionLost)))
    }
}

/// A ping's continuation, resumed exactly once by whichever comes first: the pong, an error or a cancellation.
private final class PendingPing: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, Error>?
        var result: Result<Void, Error>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        let early = state.withLock { state -> Result<Void, Error>? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early) }
    }

    func complete(_ result: Result<Void, Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(with: result)
    }
}
