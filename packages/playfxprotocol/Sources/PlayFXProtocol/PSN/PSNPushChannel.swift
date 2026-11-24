import Foundation
import os

/// A frame of the push WebSocket.
public enum PSNWebSocketFrame: Sendable, Equatable {
    case text(String)
    case binary(Data)
    /// A ping from the server; `PSNPushChannel` answers with `sendPong` carrying the same payload. A
    /// URLSession-based socket never yields it (the system answers pings itself).
    case ping(Data)
}

/// The WebSocket under the push channel (psn.md section 5.2). `URLSessionPSNWebSocket` is the real one;
/// tests inject a fake.
public protocol PSNWebSocket: Sendable {
    /// Performs the upgrade and returns once the socket is open; throws if it can't be opened.
    func open(url: URL, headers: [String: String]) async throws
    /// The next frame; throws when the socket closes or fails.
    func receive() async throws -> PSNWebSocketFrame
    /// Sends a ping with an empty payload and returns when its pong arrives.
    func ping() async throws
    func sendPong(_ payload: Data) async throws
    func close() async
}

/// Notifications in arrival order, with waiters (psn.md section 5.4): every notification is kept until a step
/// takes the first one it waits for. A `remotePlaySession:deleted` for this session (or without an ID) ends
/// the inbox; one for another session is ignored.
actor PSNInbox {
    private struct Waiter {
        let id: Int
        let deliver: (PSNNotification) -> Bool
        let fail: (Error) -> Void
        let timer: Task<Void, Never>?
    }

    private var buffer: [PSNNotification] = []
    private var waiters: [Waiter] = []
    private var ended: PSNError?
    private var boundSession: String?
    private var nextID = 0
    private let capacity: Int

    /// - Parameter capacity: how many unclaimed notifications are kept; the oldest go first.
    init(capacity: Int = 256) { self.capacity = capacity }

    /// Names the session whose deletion ends the inbox. A deletion that arrived before this call (the session
    /// ID is known only once the create call answers) is not lost: it ends the inbox now.
    func bind(sessionID: String) {
        boundSession = sessionID
        buffer.removeAll {
            if case .sessionDeleted(let id?) = $0 { return id != sessionID }
            return false
        }
        if buffer.contains(.sessionDeleted(sessionID: sessionID)) { close(.sessionEnded) }
    }

    func push(_ notification: PSNNotification) {
        var endsSession = false
        if case .sessionDeleted(let id) = notification {
            if let bound = boundSession {
                guard id == nil || id == bound else { return }
                endsSession = true
            } else if id == nil {
                endsSession = true
            }
            // Unbound and named: kept until `bind` says whether it is ours.
        }
        if let index = waiters.firstIndex(where: { $0.deliver(notification) }) {
            waiters.remove(at: index).timer?.cancel()
        } else {
            buffer.append(notification)
            if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        }
        if endsSession { close(.sessionEnded) }
    }

    /// Fails every waiter with `reason` (the first reason sticks); buffered notifications can still be taken.
    func close(_ reason: PSNError) {
        if ended == nil { ended = reason }
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.timer?.cancel()
            waiter.fail(reason)
        }
    }

    var isClosed: Bool { ended != nil }

    /// The first buffered or future notification `matches` accepts, or `PSNError.timedOut(step)` after `timeout`
    /// (nil waits for good).
    func take(step: PSNStep, timeout: TimeInterval?, matching matches: @escaping @Sendable (PSNNotification) -> Bool)
        async throws -> PSNNotification
    {
        if let index = buffer.firstIndex(where: matches) { return buffer.remove(at: index) }
        if let ended { throw ended }
        let id = nextID
        nextID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PSNNotification, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timer = timeout.map { limit in
                    Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(limit)) } catch { return }
                        await self?.expire(id, step: step)
                    }
                }
                waiters.append(
                    Waiter(
                        id: id,
                        deliver: { notification in
                            guard matches(notification) else { return false }
                            continuation.resume(returning: notification)
                            return true
                        },
                        fail: { continuation.resume(throwing: $0) }, timer: timer))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func remove(_ id: Int) -> Waiter? {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
        let waiter = waiters.remove(at: index)
        waiter.timer?.cancel()
        return waiter
    }

    private func expire(_ id: Int, step: PSNStep) {
        remove(id)?.fail(PSNError.timedOut(step: step))
    }

    private func cancel(_ id: Int) {
        remove(id)?.fail(CancellationError())
    }
}

/// The open push WebSocket of a session (psn.md section 5): receives frames, decodes them to
/// `PSNNotification`s and keeps them for the session's waits, pings every 5 s and treats a missing pong as a
/// dead channel. Open it before creating the session; close it after leaving.
public final class PSNPushChannel: Sendable {
    let inbox = PSNInbox()
    private let socket: any PSNWebSocket
    private let timeouts: PSNTimeouts
    private let lifecycle = Lifecycle()

    /// The reader and pinger tasks, and whether the socket was already closed. The tasks hold this, not the
    /// channel, so a channel that is let go can still be cleaned up by its `deinit`.
    private final class Lifecycle: Sendable {
        private struct State {
            var tasks: [Task<Void, Never>] = []
            var closed = false
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        func adopt(_ tasks: [Task<Void, Never>]) { state.withLock { $0.tasks = tasks } }

        /// Cancels the tasks and returns true the first time only (the caller then closes the socket).
        func stop() -> Bool {
            let (tasks, first) = state.withLock { state -> ([Task<Void, Never>], Bool) in
                defer { state.tasks = [] }
                let first = !state.closed
                state.closed = true
                return (state.tasks, first)
            }
            for task in tasks { task.cancel() }
            return first
        }
    }

    /// Ends everything once: waits fail with `reason`, the tasks stop and the socket closes.
    private static func shutdown(
        _ reason: PSNError, lifecycle: Lifecycle, inbox: PSNInbox, socket: any PSNWebSocket
    ) async {
        await inbox.close(reason)
        if lifecycle.stop() { await socket.close() }
    }

    deinit {
        let socket = self.socket
        if lifecycle.stop() { Task { await socket.close() } }
    }

    init(socket: any PSNWebSocket, timeouts: PSNTimeouts) {
        self.socket = socket
        self.timeouts = timeouts
    }

    /// Opens `wss://<host>/np/pushNotification` with the headers of psn.md section 5.2 on `socket`, waiting up to
    /// `timeouts.webSocketConnect`, and starts reading and pinging.
    public static func open(host: String, accessToken: String, socket: any PSNWebSocket, timeouts: PSNTimeouts = .init())
        async throws -> PSNPushChannel
    {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.path = "/np/pushNotification"
        let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        guard !host.isEmpty, host.unicodeScalars.allSatisfy(hostCharacters.contains), let url = components.url else {
            throw PSNError.invalidResponse(step: .pushServerAddress, reason: "bad host")
        }
        return try await open(url: url, accessToken: accessToken, socket: socket, timeouts: timeouts)
    }

    /// `open(host:...)` for an explicit URL (tests point it at a loopback server).
    static func open(url: URL, accessToken: String, socket: any PSNWebSocket, timeouts: PSNTimeouts)
        async throws -> PSNPushChannel
    {
        let headers = [
            "Authorization": "Bearer \(accessToken)",
            "Sec-WebSocket-Protocol": "np-pushpacket",
            "User-Agent": "WebSocket++/0.8.2",
            "X-PSN-APP-TYPE": "REMOTE_PLAY",
            "X-PSN-APP-VER": "RemotePlay/1.0",
            "X-PSN-KEEP-ALIVE-STATUS-TYPE": "3",
            "X-PSN-OS-VER": "Windows/10.0",
            "X-PSN-PROTOCOL-VERSION": "2.1",
            "X-PSN-RECONNECTION": "false",
        ]
        do {
            try await psnWithDeadline(timeouts.webSocketConnect, error: .timedOut(step: .webSocketConnect)) {
                try await socket.open(url: url, headers: headers)
            }
        } catch let error as PSNError {
            await socket.close()
            throw error
        } catch {
            await socket.close()
            if error is CancellationError { throw error }
            throw PSNError.webSocketFailed(description: error.localizedDescription)
        }
        let channel = PSNPushChannel(socket: socket, timeouts: timeouts)
        channel.startLoops()
        return channel
    }

    /// False once the socket closed, failed, missed a pong, or `close()` ran.
    public var isOpen: Bool {
        get async { await !inbox.isClosed }
    }

    /// Stops reading and pinging and closes the socket; waits still pending fail with `pushChannelClosed`.
    public func close() async {
        await Self.shutdown(.pushChannelClosed, lifecycle: lifecycle, inbox: inbox, socket: socket)
    }

    private func startLoops() {
        let lifecycle = self.lifecycle
        let reader = Task { [inbox, socket] in
            do {
                while true {
                    switch try await socket.receive() {
                    case .text(let text): await inbox.deliver(frame: Data(text.utf8))
                    case .binary(let data): await inbox.deliver(frame: data)
                    case .ping(let payload): try await socket.sendPong(payload)
                    }
                }
            } catch {
                await Self.shutdown(.pushChannelClosed, lifecycle: lifecycle, inbox: inbox, socket: socket)
            }
        }
        let pinger = Task { [inbox, socket, timeouts] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(timeouts.pingInterval)) } catch { return }
                do {
                    try await psnWithDeadline(timeouts.pongDeadline, error: .pushChannelNotResponding) {
                        try await socket.ping()
                    }
                } catch {
                    if Task.isCancelled { return }
                    let reason = (error as? PSNError) ?? .pushChannelClosed
                    await Self.shutdown(reason, lifecycle: lifecycle, inbox: inbox, socket: socket)
                    return
                }
            }
        }
        lifecycle.adopt([reader, pinger])
    }
}

extension PSNInbox {
    /// Decodes a frame and keeps it; frames that aren't a used notification are ignored (psn.md section 5.4).
    func deliver(frame: Data) {
        if let notification = PSNNotification.decode(frame: frame) { push(notification) }
    }
}
