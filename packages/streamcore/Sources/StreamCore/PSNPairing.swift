import CChiaki
import Foundation
import os

/// Pairs this Mac with a PS5 through PSN, with no code from the console: libchiaki registers it over PSN, as
/// it does at the start of every internet session, then stops (`register_only`). Takes 20 to 30 seconds, like
/// connecting over the internet. The keys are the ones a PIN pairing gives; the console's address is only
/// known once it's found on the home network ("" until then).
public final class PSNPairing: @unchecked Sendable {
    public enum Stage: String, Sendable {
        /// PSN session and reaching the console (each step can take up to ~30 s).
        case linking
        /// Reached; registering this Mac with it.
        case registering
    }

    /// What the session reports while pairing, from libchiaki's threads.
    enum Report: Sendable {
        case progress(Stage)
        case registered(ConsoleCredentials)
        case quit(reason: String, error: Bool)
    }

    struct Request: Sendable {
        let token: String
        let duid: String
        let accountId: String
    }

    /// Starts the session (returning at once, reports arriving later); its result stops and frees it.
    typealias Start = (Request, @escaping @Sendable (Report) -> Void) throws -> () -> Void

    private let token: @Sendable () throws -> String
    private let duid: String
    private let accountId: String
    private let start: Start
    private let timeout: TimeInterval
    private let outcome = OSAllocatedUnfairLock<Result<ConsoleCredentials, Error>?>(initialState: nil)
    private let finished = DispatchSemaphore(value: 0)

    /// `token`: fetches the PSN token (blocking, up to ~30 s), once `run` starts, so a cancel meanwhile counts.
    /// `timeout`: the setup steps can each take up to ~30 s.
    init(token: @escaping @Sendable () throws -> String, duid: String, accountId: String, timeout: TimeInterval = 120,
         start: @escaping Start = PSNPairing.startSession) {
        self.token = token
        self.duid = duid
        self.accountId = accountId
        self.start = start
        self.timeout = timeout
    }

    public convenience init(token: @escaping @Sendable () throws -> String, duid: String, accountId: String) {
        self.init(token: token, duid: duid, accountId: accountId, timeout: 120)
    }

    /// Blocking (not on the main thread): pairs, reporting each stage to `progress` as it starts (from
    /// libchiaki's threads). Throws the reason, with what to do next, when it fails or is cancelled.
    public func run(progress: @escaping @Sendable (Stage) -> Void) throws -> ConsoleCredentials {
        guard let account = Data(base64Encoded: accountId), account.count == Int(PSRP_ACCOUNT_ID_SIZE) else {
            throw ConsoleError.message("Sign in to PlayStation first")
        }
        if let done = outcome.withLock({ $0 }) { return try done.get() } // cancelled before it started
        let token = Result { try self.token() }
        if let done = outcome.withLock({ $0 }) { return try done.get() } // cancelled while fetching the token
        let request = Request(token: try token.get(), duid: duid, accountId: accountId)
        Log.info(.console, "Pairing through PSN")
        let stop = try start(request) { [self] report in handle(report, progress) }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            finish(.failure(ConsoleError.message(
                "PSN didn't finish pairing in time. Check that the PS5 is on, and try again.")))
        }
        stop() // registered or not, the session ends here
        let result = outcome.withLock { $0 } ?? .failure(PSNPairingError.cancelled)
        switch result {
        case .success(let paired): Log.info(.console, "Paired with \(paired.nickname) through PSN")
        case .failure(let error): Log.warning(.console, "Pairing through PSN failed: \(error.localizedDescription)")
        }
        return try result.get()
    }

    /// Stops a pairing under way (any thread); `run` then throws `PSNPairingError.cancelled`.
    public func cancel() { finish(.failure(PSNPairingError.cancelled)) }

    private func handle(_ report: Report, _ progress: (Stage) -> Void) {
        switch report {
        case .progress(let stage):
            if outcome.withLock({ $0 == nil }) { progress(stage) }
        case .registered(let credentials):
            finish(.success(credentials))
        case .quit(let reason, let error):
            // After the keys arrived, the session's own stop is the expected end: the first outcome stands.
            finish(.failure(ConsoleError.message(Self.failureMessage(reason: reason, error: error))))
        }
    }

    /// Keeps the first outcome and wakes `run`.
    private func finish(_ result: Result<ConsoleCredentials, Error>) {
        let first = outcome.withLock { current -> Bool in
            guard current == nil else { return false }
            current = result
            return true
        }
        if first { finished.signal() }
    }

    /// libchiaki's quit reason (Session.c's quit reason strings) when it ended without the keys.
    static let psnRegistFailed = "The Console Registration using PSN has failed"

    /// What to tell the user when the session ended without registering.
    static func failureMessage(reason: String, error: Bool) -> String {
        if !error {
            // A clean stop with neither the keys nor a failed registration: rare, as libchiaki waits for it to end.
            return "The PS5 didn't answer through PSN. Check that it's on, or in rest mode with \"Stay connected "
                + "to the internet\" on, and try again."
        }
        if reason.hasPrefix(psnRegistFailed) {
            return "The PS5 didn't accept pairing through PSN. Check that Remote Play is on and that you signed in "
                + "with the PS5 user's account."
        }
        return reason // the shim's own messages say what to do (psrp_remote_error_message)
    }

    /// A PsrpEventType callback as a report (nil for events pairing doesn't use).
    static func report(type: Int32, a: Int32, message: String) -> Report? {
        switch UInt32(type) {
        case PSRP_EVENT_REMOTE_PROGRESS.rawValue:
            switch UInt32(a) {
            case PSRP_REMOTE_LINKING.rawValue: return .progress(.linking)
            case PSRP_REMOTE_REGISTERING.rawValue: return .progress(.registering)
            default: return nil
            }
        case PSRP_EVENT_QUIT.rawValue: return .quit(reason: message, error: a != 0)
        default: return nil
        }
    }

    /// What the C callbacks need: where reports go, and the account the keys belong to.
    private final class Context: @unchecked Sendable {
        let report: @Sendable (Report) -> Void
        let accountId: String
        init(report: @escaping @Sendable (Report) -> Void, accountId: String) {
            self.report = report
            self.accountId = accountId
        }
    }

    /// The real session: psrp_session_start in `register_only` mode.
    static func startSession(_ request: Request, _ report: @escaping @Sendable (Report) -> Void) throws -> () -> Void {
        let account = Data(base64Encoded: request.accountId) ?? Data()
        let context = Unmanaged.passRetained(Context(report: report, accountId: request.accountId))
        var config = PsrpSessionConfig()
        config.ps5 = true
        config.register_only = true
        _ = withUnsafeMutableBytes(of: &config.account_id) { account.prefix(Int(PSRP_ACCOUNT_ID_SIZE)).copyBytes(to: $0) }
        var callbacks = PsrpCallbacks()
        callbacks.user = context.toOpaque()
        callbacks.event = { user, type, a, _, message in
            let c = Unmanaged<Context>.fromOpaque(user!).takeUnretainedValue()
            if let r = PSNPairing.report(type: type, a: a, message: message.map { String(cString: $0) } ?? "") { c.report(r) }
        }
        callbacks.registered = { user, registration in
            let c = Unmanaged<Context>.fromOpaque(user!).takeUnretainedValue()
            guard let registration else { return }
            c.report(.registered(Console.credentials(from: registration.pointee, address: "", ps5: true,
                                                     accountId: c.accountId)))
        }
        var error = [CChar](repeating: 0, count: 512)
        let handle = request.token.withCString { token in
            request.duid.withCString { duid in
                config.psn_token = token
                config.psn_duid = duid
                return psrp_session_start(&config, &callbacks, &error, error.count)
            }
        }
        guard let handle else {
            context.release()
            throw ConsoleError.message(String(cString: error))
        }
        return {
            psrp_session_stop(handle) // joins libchiaki's threads: no callback after this
            context.release()
        }
    }
}

public enum PSNPairingError: Error, LocalizedError {
    case cancelled
    public var errorDescription: String? { "Pairing cancelled." }
}
