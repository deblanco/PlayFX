import Foundation
import os

/// Something a session plays on a pad that can be told to stop: its rumble, its DualSense haptics output.
protocol PadOutput: AnyObject {
    /// Stops for good, from any thread; returns once the pad has been told.
    func quiet()
}

/// Leaves every pad quiet when PlayFX or psrp ends, however it ends. A game's rumble, a trigger effect and the
/// DualSense haptics stay on the pad after the process that started them is gone, until another program resets
/// them. A session ending already stops its own (MacOSBridge's `endSession`); this is for the process ending:
/// the app quitting (`sc_quiet_pads`), psrp's /quit, and SIGTERM, SIGINT and SIGHUP (`installSignalHandlers`).
/// SIGKILL can't be caught, nor can a crash be relied on to run anything: a pad then keeps what it was playing.
public enum PadQuiet {
    private struct Weak: @unchecked Sendable { weak var output: (any PadOutput)? }
    private static let outputs = OSAllocatedUnfairLock(initialState: [Weak]())

    /// Set once the process is ending: from then on nothing drives a pad again (a late rumble or trigger effect
    /// from a session still winding down would undo the quiet). Reset by tests.
    static let ending = OSAllocatedUnfairLock(initialState: false)
    static var isEnding: Bool { ending.withLock { $0 } }

    /// Turns the adaptive triggers off on every DualSense; on the main queue (replaced in tests).
    nonisolated(unsafe) static var releaseTriggers: () -> Void = { AdaptiveTriggers.applyNow(left: .off, right: .off) }

    /// Keeps `output` (weakly) to be stopped when the process ends.
    static func register(_ output: any PadOutput) {
        outputs.withLock { list in
            list.removeAll { $0.output == nil }
            list.append(Weak(output: output))
        }
    }

    /// Leaves every pad quiet now, from any thread: the outputs stopped (each on its own queue), then the triggers
    /// released on the main queue, where GameController is driven. Returns once that's done, or false after
    /// `timeout` if the main queue doesn't get to it (stuck). Safe to call again.
    @discardableResult
    public static func now(timeout: TimeInterval = 1) -> Bool {
        ending.withLock { $0 = true }
        for output in outputs.withLock({ $0.compactMap(\.output) }) { output.quiet() }
        if Thread.isMainThread {
            releaseTriggers()
            return true
        }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            releaseTriggers()
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success
    }

    // MARK: Signals

    /// SIGTERM (pkill, logging out), SIGINT (Ctrl-C), SIGHUP (the terminal closed). Not SIGKILL: it can't be caught.
    static let signals = [SIGTERM, SIGINT, SIGHUP]
    private static let signalQueue = DispatchQueue(label: "streamcore.signals")
    /// The installed signal sources, kept alive; empty until `installSignalHandlers`.
    private static let sources = OSAllocatedUnfairLock(initialState: [DispatchSourceSignal]())
    static var installedSignals: Int { sources.withLock { $0.count } }
    /// Ends the process after a signal was handled (replaced in tests).
    nonisolated(unsafe) static var end: (Int32) -> Void = { number in
        // As the signal would have without a handler, so the parent sees which one ended the process.
        signal(number, SIG_DFL)
        raise(number)
    }

    /// On SIGTERM, SIGINT or SIGHUP: runs `cleanUp`, quiets the pads, then ends the process as that signal does.
    /// The handlers run on a queue of their own, so a busy main thread can't keep the process from ending (the
    /// triggers then wait at most a second for it). Installs once; later calls change nothing and return false.
    @discardableResult
    public static func installSignalHandlers(cleanUp: @escaping @Sendable () -> Void = {}) -> Bool {
        sources.withLock { sources in
            guard sources.isEmpty else { return false }
            sources = signals.map { number in
                signal(number, SIG_IGN) // else the default action ends the process before the source sees it
                let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
                source.setEventHandler { handle(number, cleanUp: cleanUp) }
                source.resume()
                return source
            }
            return true
        }
    }

    static func handle(_ number: Int32, cleanUp: () -> Void) {
        Log.info(.input, "Signal \(number): leaving the pads quiet before ending")
        cleanUp()
        now()
        end(number)
    }
}
