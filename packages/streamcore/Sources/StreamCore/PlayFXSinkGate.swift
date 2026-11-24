import Foundation
import os

/// Keeps `PlayFXEngine`'s calls into the sink inside the contract: none starts once the engine is stopping, `.quit`
/// is the last of them (and goes out once), and `stop()` can wait for the ones in flight.
///
/// Every sink call is bracketed by `enter` / `leave`. A thread inside a call keeps a depth count in thread-local
/// storage, one key per gate (so a thread inside another engine's call isn't taken for being inside this one's), which
/// lets a `stop()` that the app's own event handler makes (from inside `deliver`) wait for the other threads' calls
/// without waiting for itself, and lets that `stop()` leave the `.quit` pending until its own call has returned.
final class PlayFXSinkGate: @unchecked Sendable {
    private struct State {
        var inFlight = 0
        var closed = false
        var quitClaimed = false
        /// A `.quit` a nested `stop()` claimed, to be delivered once its thread is out of its sink calls. It counts as
        /// in flight until then.
        var quitPending = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let depthKey: pthread_key_t

    init() {
        var key = pthread_key_t()
        pthread_key_create(&key, nil)
        depthKey = key
    }

    deinit { pthread_key_delete(depthKey) }

    /// How many of this thread's frames are inside a call of this gate.
    private var depth: Int {
        get { Int(bitPattern: pthread_getspecific(depthKey)) }
        set { pthread_setspecific(depthKey, UnsafeRawPointer(bitPattern: newValue)) }
    }

    /// Whether the calling thread is inside a call of this gate (a `stop()` from here can't wait for the engine's threads).
    var isInsideCall: Bool { depth > 0 }

    /// Starts a sink call; false when the gate is closed or `.quit` was claimed (make no call then).
    func enter() -> Bool {
        let ok = state.withLock { s -> Bool in
            guard !s.closed, !s.quitClaimed else { return false }
            s.inFlight += 1
            return true
        }
        if ok { depth += 1 }
        return ok
    }

    func leave() {
        depth -= 1
        state.withLock { $0.inFlight -= 1 }
    }

    /// Starts the call that delivers `.quit`: false when the engine is stopping or a `.quit` was already claimed.
    /// From here no other call starts.
    func enterForQuit() -> Bool {
        let ok = state.withLock { s -> Bool in
            guard !s.closed, !s.quitClaimed else { return false }
            s.quitClaimed = true
            s.inFlight += 1
            return true
        }
        if ok { depth += 1 }
        return ok
    }

    /// Makes every later `enter` fail.
    func close() { state.withLock { $0.closed = true } }

    /// Claims the right to deliver `.quit` when nobody has yet (used by `stop()`, after `close`).
    func claimQuit() -> Bool {
        state.withLock { s -> Bool in
            guard !s.quitClaimed else { return false }
            s.quitClaimed = true
            return true
        }
    }

    /// Like `claimQuit`, for a `stop()` called from inside a sink call: the quit is held, counted as in flight, for
    /// `takePendingQuit` to hand out when the thread has left its calls.
    func claimQuitLater() -> Bool {
        state.withLock { s -> Bool in
            guard !s.quitClaimed else { return false }
            s.quitClaimed = true
            s.quitPending = true
            s.inFlight += 1
            return true
        }
    }

    /// True once, for a quit `claimQuitLater` held, when this thread is out of its sink calls. The caller delivers it
    /// and then calls `quitDelivered`.
    func takePendingQuit() -> Bool {
        guard depth == 0 else { return false }
        return state.withLock { s -> Bool in
            guard s.quitPending else { return false }
            s.quitPending = false
            return true
        }
    }

    /// The pending quit was delivered.
    func quitDelivered() { state.withLock { $0.inFlight -= 1 } }

    /// Waits for the sink calls other threads have in flight (this thread's own, if it's inside one, can't finish),
    /// up to `timeout` seconds. False when that ran out.
    @discardableResult
    func waitForOtherCalls(timeout: Double = 5) -> Bool {
        let own = depth
        let deadline = Date(timeIntervalSinceNow: timeout)
        while state.withLock({ $0.inFlight }) > own {
            if Date() >= deadline { return false }
            usleep(200)
        }
        return true
    }
}
