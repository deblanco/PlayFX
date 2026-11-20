import CObjCCatch
import Foundation
import os
import VideoToolbox

/// The calls the app makes on one of VideoToolbox's frame processors (macOS 26+): `VTProcessor` in the app,
/// stand-ins in tests, so the defence around them (`GuardedProcessor`, `VideoProcessorHealth`) is tested where
/// VideoToolbox can't run (CI's virtual machines).
protocol VideoProcessing: AnyObject {
    /// Starts the session for a `VTFrameProcessorConfiguration`; throws when it can't run it.
    func startSession(configuration: AnyObject) throws
    /// Runs one call's `VTFrameProcessorParameters`, returning once the outputs are written; throws on failure.
    func process(parameters: AnyObject) throws
    func endSession()
}

enum VideoProcessorError: Error {
    /// A configuration or parameters object that isn't VideoToolbox's.
    case wrongType
    /// The processor said no without saying why.
    case failed
}

/// VideoToolbox's frame processor. Frames go through its synchronous call (`playfx_vt_process`), on the caller's
/// queue: the Metal command-buffer call (`process(with:parameters:)`) makes a Metal shared event per call and
/// never frees it, until the system has none left and the call raises an exception (a 10–40 minute session).
@available(macOS 26.0, iOS 26.0, *)
final class VTProcessor: VideoProcessing {
    private let processor = VTFrameProcessor()

    func startSession(configuration: AnyObject) throws {
        guard let configuration = configuration as? any VTFrameProcessorConfiguration else { throw VideoProcessorError.wrongType }
        try processor.startSession(configuration: configuration)
    }

    func process(parameters: AnyObject) throws {
        guard let parameters = parameters as? any VTFrameProcessorParameters else { throw VideoProcessorError.wrongType }
        var error: NSError?
        guard playfx_vt_process(processor, parameters, &error) else { throw error ?? VideoProcessorError.failed }
    }

    func endSession() { processor.endSession() }
}

/// VideoToolbox's processor where there is one (macOS 26+).
func makeVTProcessor() -> VideoProcessing? {
    if #available(macOS 26.0, iOS 26.0, *) { return VTProcessor() }
    return nil
}

/// What a call into a processor did.
enum ProcessorOutcome: Equatable {
    case done
    /// It returned an error: nothing was made, and the processor can still be ended normally.
    case failed(String)
    /// It raised an Objective-C exception, possibly holding its own lock for good: nothing may be called on it again.
    case threw(String)
    /// Not called: the processor is poisoned or retired, or not in a state for the call.
    case notCalled

    /// Runs `body`, catching Swift errors and Objective-C exceptions alike.
    static func of(_ body: () throws -> Void) -> ProcessorOutcome {
        var failure: String?
        let exception = playfx_catch {
            do { try body() } catch { failure = "\(error)" }
        }
        if let exception { return .threw(exception) }
        return failure.map { .failed($0) } ?? .done
    }
}

/// One processor with the app's defence around every call into it. An Objective-C exception poisons it (VideoToolbox
/// raised one with its lock held, so the next call deadlocks or the process is killed): it's quarantined, never called
/// again, not even ended, and the owner starts a fresh one. An error from a processor that has worked (or whose
/// configuration has, `proven`) counts toward the feature's failure budget. Retiring it ends its session later, off
/// the caller's queue, once no call into it is running; the feature turning off retires it too. Thread-safe.
final class GuardedProcessor {
    /// What one `process` call came to.
    enum Processed: Equatable {
        case done
        /// An error from a processor that never made anything, at a configuration that never worked: it may not
        /// take this input (VideoToolbox's low-latency interpolation refuses 960×540, say). Not counted; the owner
        /// decides (`ProcessorSizes`).
        case refused
        /// An error after it had worked, or an exception: counted, and the owner starts a fresh processor.
        case failed
    }

    private struct State {
        var started = false
        var worked = false
        var poisoned = false
        var retired = false
        var inFlight = 0
    }

    private let processor: VideoProcessing
    private let health: VideoProcessorHealth
    private let state: OSAllocatedUnfairLock<State>

    /// `proven`: its configuration made something in this run already, so even its first error is a failure.
    init(_ processor: VideoProcessing, health: VideoProcessorHealth, proven: Bool = false) {
        self.processor = processor
        self.health = health
        state = OSAllocatedUnfairLock(initialState: State(worked: proven))
        health.register(self)
    }

    /// Never left running: dropped without `retire()` (its owner going away), it's retired here.
    deinit { retire() }

    var isPoisoned: Bool { state.withLock { $0.poisoned } }

    /// Starts its session: `.failed` when it can't run this configuration.
    func start(_ configuration: AnyObject) -> ProcessorOutcome {
        call(when: { !$0.started }, done: { $0.started = true }) { try processor.startSession(configuration: configuration) }
    }

    /// Runs one call; `.done` once its outputs are written.
    func process(_ parameters: AnyObject) -> Processed {
        let worked = state.withLock { $0.worked }
        switch call(when: \.started, done: { $0.worked = true }, { try processor.process(parameters: parameters) }) {
        case .done:
            return .done
        case .failed(let reason):
            guard worked else { return .refused }
            health.failed(reason)
            return .failed
        case .threw, .notCalled:
            return .failed // counted when it threw (see `call`)
        }
    }

    /// No more calls. A started session (or one still starting) is ended `health.grace` seconds later, once no call is
    /// running: VideoToolbox can still be finishing the last call on its own queue when the call returns. Nothing for
    /// a poisoned one. Any thread.
    func retire() {
        let end = state.withLock { s -> Bool in
            defer { s.retired = true }
            return (s.started || s.inFlight > 0) && !s.retired && !s.poisoned
        }
        guard end else { return }
        health.retire(processor) { [state] in
            state.withLock { $0.inFlight > 0 ? .wait : $0.poisoned || !$0.started ? .skip : .end }
        }
    }

    /// Runs `body` unless the processor is poisoned or retired, `allowed` says no, or the feature is off; `done`
    /// updates the state when it succeeds, under the same lock that ends the call (so a retirement sees it).
    private func call(when allowed: (State) -> Bool, done: (inout State) -> Void, _ body: () throws -> Void) -> ProcessorOutcome {
        let go = state.withLock { s -> Bool in
            // A processor made or called once the feature is off is never started: nothing would end it (see
            // `VideoProcessorHealth.failed`). One already running when it turns off is retired there.
            guard !s.poisoned, !s.retired, allowed(s), !health.isOff else { return false }
            s.inFlight += 1
            return true
        }
        guard go else { return .notCalled }
        let outcome = ProcessorOutcome.of(body)
        state.withLock { s in
            s.inFlight -= 1
            switch outcome {
            case .threw: s.poisoned = true
            case .done: done(&s)
            case .failed, .notCalled: break
            }
        }
        if case .threw(let reason) = outcome { health.quarantine(processor, reason: reason) }
        return outcome
    }
}

/// How one feature's video processors are doing over the whole run. Processors that raised an exception are kept
/// here for good (releasing one may call into it). Failures past a budget (3 in a minute, or 10 in all) turn the
/// feature off for the rest of the run instead of starting processor after processor: the picture goes on without
/// it, and the stats line says why. Turning off retires every processor still running (nobody calls their owners
/// again once it's off). Also ends retired processors' sessions. Thread-safe.
final class VideoProcessorHealth: @unchecked Sendable {
    static let interpolation = VideoProcessorHealth(feature: "Frame interpolation")
    static let upscaling = VideoProcessorHealth(feature: "ML upscaling")

    enum Retirement { case wait, end, skip }

    let feature: String
    /// Failures within `window` seconds that turn the feature off, and failures over the run that do.
    let budget: Int
    let window: Double
    let limit: Int
    /// Seconds a retired processor is left before its session is ended.
    let grace: Double

    private struct Live { weak var processor: GuardedProcessor? }

    private struct State {
        var recent: [Double] = []
        var failures = 0
        var off = false
        var quarantine: [AnyObject] = []
        /// Every guarded processor made for this feature and not yet gone, to retire when it turns off.
        var live: [Live] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let now: () -> Double
    private let queue = DispatchQueue(label: "streamcore.video-processor-retirement", qos: .utility)
    private let retiring = DispatchGroup()

    init(feature: String, budget: Int = 3, window: Double = 60, limit: Int = 10, grace: Double = 1,
         now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.feature = feature
        self.budget = budget
        self.window = window
        self.limit = limit
        self.grace = grace
        self.now = now
    }

    /// Whether the feature is off for the rest of the run.
    var isOff: Bool { state.withLock { $0.off } }
    var failures: Int { state.withLock { $0.failures } }
    var quarantined: Int { state.withLock { $0.quarantine.count } }

    /// A processor call failed (that frame or pair gets nothing).
    func failed(_ reason: String) {
        let t = now()
        let turnedOff = state.withLock { s -> Bool in
            s.failures += 1
            s.recent = s.recent.filter { t - $0 < window } + [t]
            guard !s.off, s.recent.count >= budget || s.failures >= limit else { return false }
            s.off = true
            return true
        }
        Log.warning(.renderer, "\(feature): the video processor failed (\(reason))")
        guard turnedOff else { return }
        Log.error(.renderer, "\(feature) is off until the app restarts: its video processor keeps failing")
        // Retired outside the lock: retiring one may release the last reference to it.
        let live = state.withLock { s in
            defer { s.live = [] }
            return s.live.compactMap(\.processor)
        }
        live.forEach { $0.retire() }
    }

    /// A guarded processor made for this feature (see `failed`).
    func register(_ processor: GuardedProcessor) {
        state.withLock { s in
            s.live.removeAll { $0.processor == nil }
            s.live.append(Live(processor: processor))
        }
    }

    /// A processor raised an exception: kept for good, never called again.
    func quarantine(_ processor: AnyObject, reason: String) {
        state.withLock { $0.quarantine.append(processor) }
        failed("exception: \(reason)")
    }

    /// Ends `processor`'s session `grace` seconds from now, on a queue of its own, once `check` says no call into it
    /// is running (`.wait` looks again a grace later; `.skip` never ends it).
    func retire(_ processor: VideoProcessing, check: @escaping () -> Retirement) {
        retiring.enter()
        schedule(processor, check)
    }

    private func schedule(_ processor: VideoProcessing, _ check: @escaping () -> Retirement) {
        queue.asyncAfter(deadline: .now() + grace) { [self] in
            switch check() {
            case .wait:
                schedule(processor, check)
                return
            case .end:
                if case .threw(let reason) = ProcessorOutcome.of({ processor.endSession() }) {
                    quarantine(processor, reason: reason)
                }
            case .skip:
                break
            }
            retiring.leave()
        }
    }

    /// Waits until every processor retired so far is ended (or skipped); false on timeout. For tests and tools.
    @discardableResult
    func waitForRetirements(timeout: Double) -> Bool { retiring.wait(timeout: .now() + timeout) == .success }
}

/// Which configurations (a frame size with its steps or scale factor) a feature's processors have made something at
/// in this run, and how many fresh processors in a row erred at once at one that never has. A fresh processor's
/// error is ambiguous: VideoToolbox refusing the size (interpolation at 960×540, every time) or a fault that passes
/// (a GPU reset on wake, for a call or two). At a configuration that worked before it's a fault: counted, and the
/// processor restarted (`GuardedProcessor`'s `proven`). At one that never has, it's a refusal once `tries` fresh
/// processors in a row have erred, so a fault on the very first call doesn't drop the size for the run.
struct ProcessorSizes {
    static let tries = 2
    private var worked: Set<String> = []
    private var errors: [String: Int] = [:]

    func hasWorked(_ key: String) -> Bool { worked.contains(key) }

    mutating func worked(_ key: String) {
        guard !worked.contains(key) else { return }
        worked.insert(key)
        errors[key] = nil
    }

    /// A fresh processor erred at once at `key`, which never worked: whether that makes the configuration refused.
    mutating func refuses(_ key: String) -> Bool {
        errors[key, default: 0] += 1
        return errors[key, default: 0] >= Self.tries
    }
}
