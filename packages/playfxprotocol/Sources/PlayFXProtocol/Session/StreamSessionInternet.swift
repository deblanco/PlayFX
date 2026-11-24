import Foundation

// Internet play behind the two public entry points (`StreamSession.start(remote:...)`, in StreamSession.swift, and
// `Registration.registerThroughPSN`, in Registration.swift): what they run with an environment, so tests can inject theirs.

extension StreamSession {
    static func start(
        remote: PSNRemote, settings: StreamSettings, options: StreamSessionOptions, internet: InternetOptions,
        internetEnvironment: InternetEnvironment, streamEnvironment: StreamEnvironment,
        events: @escaping @Sendable (StreamEvent, StreamSession) -> Void
    ) async throws -> StreamSession {
        let (link, pairing) = try await InternetConnector.prepare(
            remote: remote, options: internet, environment: internetEnvironment)
        var environment = streamEnvironment
        environment.control = link.controlEnvironment(base: streamEnvironment.control)
        do {
            let session = try await start(
                environment: environment, address: link.consoleAddress, target: pairing.target,
                registKey: pairing.registKey, rpKey: pairing.rpKey, settings: settings, transport: .bsd,
                options: options, internet: link, events: events)
            link.report(.connected)
            return session
        } catch {
            let failure = Self.internetError(error, link: link)
            if failure == .cancelled { link.shutdown() } else { await link.shutdownAndWait() }
            throw failure
        }
    }

    /// What a failed internet `start` throws: the typed failure the link recorded, else the start error mapped.
    private static func internetError(_ error: any Error, link: InternetLink) -> InternetStartError {
        // A cancel (the task, or `stop()`) wins over anything recorded on the way out.
        if case .cancelled? = error as? StreamStartError { return .cancelled }
        if let recorded = link.failure, recorded != .cancelled { return recorded }
        switch error as? StreamStartError {
        case .session(let error, let stage)?: return .session(error, stage: stage)
        case .stream(let reason, let detail)?: return .stream(reason, detail: detail)
        default: return .cancelled
        }
    }
}

extension Registration {
    static func registerThroughPSN(
        remote: PSNRemote, internet: InternetOptions, environment: InternetEnvironment
    ) async throws -> PairingResult {
        let (link, pairing) = try await InternetConnector.prepare(remote: remote, options: internet, environment: environment)
        await link.shutdownAndWait()
        return pairing
    }
}
