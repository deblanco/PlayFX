import Foundation
import os

/// One HTTPS request to a PSN host. Printing or dumping it hides the `Authorization` value.
public struct PSNHTTPRequest: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    /// The step's limit in seconds (psn.md section 10); `PSNClient` enforces it around the transport call.
    public var timeout: TimeInterval

    public init(method: String, url: URL, headers: [String: String], body: Data? = nil, timeout: TimeInterval) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    private var redactedHeaders: [String: String] {
        var shown = headers
        for name in headers.keys where name.lowercased() == "authorization" { shown[name] = "<redacted>" }
        return shown
    }

    public var description: String {
        "\(method) \(url.absoluteString) headers=\(redactedHeaders.sorted { $0.key < $1.key }) body=\(body?.count ?? 0) bytes"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "method": method, "url": url, "headers": redactedHeaders, "bodyBytes": body?.count ?? 0,
                "timeout": timeout,
            ], displayStyle: .struct)
    }
}

/// The status and body of an answer.
public struct PSNHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
    }
}

/// Sends PSN's HTTP requests. `URLSessionPSNTransport` is the real one; tests inject a fake, so nothing in the
/// package's tests touches the network.
public protocol PSNTransport: Sendable {
    func send(_ request: PSNHTTPRequest) async throws -> PSNHTTPResponse
}

/// `PSNTransport` over a `URLSession` (HTTPS with normal certificate checks). The default session is ephemeral:
/// no cookies, credentials or disk cache, and every request reloads.
public struct URLSessionPSNTransport: PSNTransport {
    private let session: URLSession

    /// - Parameter session: defaults to `makeSession()`; tests pass one with a stubbed `URLProtocol`.
    public init(session: URLSession? = nil) { self.session = session ?? Self.makeSession() }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    public func send(_ request: PSNHTTPRequest) async throws -> PSNHTTPResponse {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return PSNHTTPResponse(status: http.statusCode, body: data)
    }
}

/// One finish for a race between a body and its deadline; whoever gets there first wins, the rest is cancelled.
private final class DeadlineRace<Value: Sendable>: @unchecked Sendable {
    private struct State {
        var finished = false
        var result: Result<Value, any Error>?
        var continuation: CheckedContinuation<Value, any Error>?
        var tasks: [Task<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        let early = state.withLock { state -> Result<Value, any Error>? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early) }
    }

    func track(_ tasks: [Task<Void, Never>]) {
        let finished = state.withLock { state -> Bool in
            if !state.finished { state.tasks = tasks }
            return state.finished
        }
        if finished { for task in tasks { task.cancel() } }
    }

    func finish(_ result: Result<Value, any Error>) {
        let (continuation, tasks) = state.withLock { state -> (CheckedContinuation<Value, any Error>?, [Task<Void, Never>]) in
            guard !state.finished else { return (nil, []) }
            state.finished = true
            state.result = result
            defer { state.continuation = nil; state.tasks = [] }
            return (state.continuation, state.tasks)
        }
        for task in tasks { task.cancel() }
        continuation?.resume(with: result)
    }
}

/// Runs `body`, throwing `error` if it hasn't finished after `seconds`. The caller doesn't wait for a `body` that
/// ignores cancellation: it is cancelled and left to finish on its own. Cancelling the caller throws
/// `CancellationError` at once.
func psnWithDeadline<Value: Sendable>(
    _ seconds: TimeInterval, error: PSNError, _ body: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let race = DeadlineRace<Value>()
    let expiry = error
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
            race.install(continuation)
            let work = Task {
                do { race.finish(.success(try await body())) } catch { race.finish(.failure(error)) }
            }
            let timer = Task {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                race.finish(.failure(expiry))
            }
            race.track([work, timer])
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}
