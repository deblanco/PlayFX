import Foundation
import os
import PlayFXProtocol

/// Pairs this Mac with a PS5 through PSN, with no code from the console: PlayFXProtocol registers it over PSN, as it
/// does at the start of every internet session, then leaves PSN (`Registration.registerThroughPSN`). Takes 20 to 30
/// seconds, like connecting over the internet. The keys are the ones a PIN pairing gives; the console's address is
/// not learned over PSN ("" until the console is found on the home network).
public final class PSNPairing: @unchecked Sendable {
    public enum Stage: String, Sendable {
        /// PSN session and reaching the console (each step can take up to ~30 s).
        case linking
        /// Reached; registering this Mac with it.
        case registering
    }

    /// The stage the library's start step stands for (nil for the steps in between, which stay in the one before).
    static func stage(for step: InternetStage) -> Stage? {
        switch step {
        case .linkingPSN: .linking
        case .registering: .registering
        default: nil
        }
    }

    struct Request: Sendable {
        let token: String
        let duid: String
        let accountId: String
    }

    /// Runs the registration through PSN with the options (progress, log); returns when it has left PSN (tests: a stand-in).
    typealias Register = @Sendable (_ remote: PSNRemote, _ internet: InternetOptions) async throws -> PairingResult

    static let liveRegister: Register = { remote, internet in
        try await Registration.registerThroughPSN(remote: remote, internet: internet)
    }

    private struct State {
        var outcome: Result<ConsoleCredentials, Error>?
        var task: Task<Void, Never>?
    }

    private let token: @Sendable () throws -> String
    private let duid: String
    private let accountId: String
    private let register: Register
    private let timeout: TimeInterval
    private let cleanupWait: TimeInterval
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let finished = DispatchSemaphore(value: 0)
    private let taskDone = DispatchSemaphore(value: 0)

    /// `token`: fetches the PSN token (blocking, up to ~30 s), once `run` starts, so a cancel meanwhile counts.
    /// `timeout`: the setup steps can each take up to ~30 s. `cleanupWait`: how long to wait, after the outcome,
    /// for the library to leave PSN and remove its router mappings.
    init(token: @escaping @Sendable () throws -> String, duid: String, accountId: String, timeout: TimeInterval = 120,
         cleanupWait: TimeInterval = 10, register: @escaping Register = PSNPairing.liveRegister) {
        self.token = token
        self.duid = duid
        self.accountId = accountId
        self.register = register
        self.timeout = timeout
        self.cleanupWait = cleanupWait
    }

    public convenience init(token: @escaping @Sendable () throws -> String, duid: String, accountId: String) {
        self.init(token: token, duid: duid, accountId: accountId, timeout: 120)
    }

    private var outcome: Result<ConsoleCredentials, Error>? { state.withLock { $0.outcome } }

    /// Blocking (not on the main thread): pairs, reporting each stage to `progress` as it starts (from the library's
    /// threads). Throws the reason, with what to do next, when it fails or is cancelled.
    public func run(progress: @escaping @Sendable (Stage) -> Void) throws -> ConsoleCredentials {
        guard let account = Data(base64Encoded: accountId), account.count == StreamEngineConfig.accountIDSize else {
            throw ConsoleError.message("Sign in to PlayStation first")
        }
        if let done = outcome { return try done.get() } // cancelled before it started
        let token = Result { try self.token() }
        if let done = outcome { return try done.get() } // cancelled while fetching the token
        let accessToken = try token.get()
        guard PlayFXEngine.isDeviceID(duid) else {
            throw ConsoleError.message("Pairing through PSN needs a PS5 and its PSN device ID")
        }
        let remote = PSNRemote(accessToken: accessToken, consoleDUID: duid, platform: .ps5)
        Log.info(.console, "Pairing through PSN")
        var internet = PlayFXEngine.internetOptions(environment: ProcessInfo.processInfo.environment) { [self] step in
            if let stage = Self.stage(for: step), outcome == nil { progress(stage) }
        }
        internet.log = { Log.debug(.console, "Pairing through PSN: \($0)") }
        start(remote, internet)
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            finish(.failure(ConsoleError.message("PSN didn't finish pairing in time. Check that the PS5 is on, and try again.")))
        }
        // Registered or not, it ends here: the library leaves PSN and removes its mappings before it returns.
        state.withLock { $0.task }?.cancel()
        if taskDone.wait(timeout: .now() + cleanupWait) == .timedOut {
            Log.warning(.console, "Pairing through PSN: the PSN session wasn't left within \(cleanupWait) s; it ends in the background")
        }
        let result = outcome ?? .failure(PSNPairingError.cancelled)
        switch result {
        case .success(let paired): Log.info(.console, "Paired with \(paired.nickname) through PSN")
        case .failure(let error): Log.warning(.console, "Pairing through PSN failed: \(error.localizedDescription)")
        }
        return try result.get()
    }

    /// Stops a pairing under way (any thread); `run` then throws `PSNPairingError.cancelled`.
    public func cancel() {
        finish(.failure(PSNPairingError.cancelled))
        state.withLock { $0.task }?.cancel()
    }

    private func start(_ remote: PSNRemote, _ internet: InternetOptions) {
        let accountId = accountId
        let register = register
        // The user is waiting on it: not left behind CPU-bound work on the default pool.
        let task = Task(priority: .userInitiated) { [self] in
            do {
                let result = try await register(remote, internet)
                finish(.success(Console.credentials(from: result, address: "", ps5: true, accountId: accountId)))
            } catch {
                finish(.failure(Self.failure(for: error)))
            }
            taskDone.signal()
        }
        let cancelled = state.withLock { s -> Bool in
            s.task = task
            return s.outcome != nil
        }
        if cancelled { task.cancel() }
    }

    /// Keeps the first outcome and wakes `run`.
    private func finish(_ result: Result<ConsoleCredentials, Error>) {
        let first = state.withLock { s -> Bool in
            guard s.outcome == nil else { return false }
            s.outcome = result
            return true
        }
        if first { finished.signal() }
    }

    /// What to tell the user when it ended without the keys.
    static func failure(for error: Error) -> Error {
        guard let failure = error as? InternetStartError else {
            return ConsoleError.message("Couldn't pair through PSN: \(error.localizedDescription)")
        }
        if case .cancelled = failure { return PSNPairingError.cancelled }
        return ConsoleError.message(failure.userMessage(console: .ps5))
    }
}

public enum PSNPairingError: Error, LocalizedError {
    case cancelled
    public var errorDescription: String? { "Pairing cancelled." }
}
