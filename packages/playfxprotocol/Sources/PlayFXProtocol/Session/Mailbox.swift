import Foundation

/// A small blocking queue between the Takion receive thread (which posts) and the thread that drives a start-up
/// step (which waits). Used by the network probe and by the stream handshake, both control-plane code.
final class Mailbox<Event>: @unchecked Sendable {
    private let condition = NSCondition()
    private var items: [Event] = []
    private let capacity: Int

    init(capacity: Int = 512) { self.capacity = capacity }

    func post(_ event: Event) {
        condition.lock()
        items.append(event)
        if items.count > capacity { items.removeFirst(items.count - capacity) }
        condition.broadcast()
        condition.unlock()
    }

    /// Waits up to `timeout` seconds for an event `match` accepts. Events that arrive before it and don't match
    /// are discarded. Returns nil on timeout, or as soon as `abort()` says so (it is polled every 10 ms and
    /// must not touch this mailbox).
    func take<T>(timeout: Double, abort: () -> Bool = { false }, _ match: (Event) -> T?) -> T? {
        let deadline = monotonicSeconds() + timeout
        condition.lock()
        defer { condition.unlock() }
        while true {
            while !items.isEmpty {
                if let found = match(items.removeFirst()) { return found }
            }
            if abort() { return nil }
            let remaining = deadline - monotonicSeconds()
            if remaining <= 0 { return nil }
            condition.wait(until: Date(timeIntervalSinceNow: min(remaining, 0.01)))
        }
    }
}

/// Lets the receive thread call the app's handler without ever calling it after `close()` returned.
///
/// `enter` hands out the handler (nil once closed) and counts the call as in flight; `leave` ends it. `close`
/// makes every later `enter` return nil, hands the handler back and waits for the calls already in flight. It must
/// not be called from inside a handler call (the session closes the gate from its control queue, never from
/// the callbacks).
///
/// The lock is taken with explicit `lock()` and `unlock()`, not through a generic `withLock` closure: returning a
/// function value out of a generic closure makes Swift allocate a reabstraction thunk on every call, and `enter`
/// runs once per video, audio and haptics event.
final class EventGate: @unchecked Sendable {
    typealias Handler = @Sendable (StreamEvent, StreamSession) -> Void

    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private var handler: Handler?
    private var inFlight = 0

    init(handler: @escaping Handler) {
        lock.initialize(to: os_unfair_lock())
        self.handler = handler
    }

    deinit { lock.deallocate() }

    @inline(__always) func enter() -> Handler? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard let handler else { return nil }
        inFlight += 1
        return handler
    }

    @inline(__always) func leave() {
        os_unfair_lock_lock(lock)
        inFlight -= 1
        os_unfair_lock_unlock(lock)
    }

    private var calls: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return inFlight
    }

    /// Closes the gate and returns the handler, for the one `ended` event the session delivers itself.
    @discardableResult
    func close() -> Handler? {
        os_unfair_lock_lock(lock)
        let last = handler
        handler = nil
        os_unfair_lock_unlock(lock)
        while calls > 0 { usleep(200) }
        return last
    }
}
