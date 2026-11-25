import Foundation
import os

// The PSN side of a hole punch (psn.md section 7, holepunch.md sections 4.5 and 6): `PunchSignaling` over a
// `PSNRemotePlaySession`. The hole punch is blocking code on a thread of its own; PSN's calls are async, so each
// call here waits for its async twin. Never call it from the Swift concurrency pool.

extension PunchCandidate {
    /// From PSN's candidate. An unknown type from the console was already read as `STATIC` by the decoder.
    init(_ candidate: PSNCandidate) {
        self.init(
            type: PunchCandidateType(rawValue: candidate.type.rawValue) ?? .staticAddress, address: candidate.address,
            port: candidate.port, mappedAddress: candidate.mappedAddress, mappedPort: candidate.mappedPort)
    }

    /// As PSN's candidate.
    var psn: PSNCandidate {
        PSNCandidate(
            type: PSNCandidateType(rawValue: type.rawValue) ?? .staticAddress, address: address,
            mappedAddress: mappedAddress, port: port, mappedPort: mappedPort)
    }
}

/// `PunchSignaling` over PSN's session messages.
///
/// What the adapter fixes, per holepunch.md section 4.5: the OFFER's `skey`, `natType` 2, empty
/// `defaultRouteMacAddr`, `localPeerAddr` with platform `REMOTE_PLAY` and the base64 `localHashedId` (all written by
/// `PSNRemotePlaySession`, which also owns the `reqId`s and the RESULTs); the ACCEPT's `natType` 0 and empty
/// `localHashedId`. The console's `sid` keeps its low 16 bits. Each wait is PSN's own 30 s (`PSNTimeouts.notification`):
/// the `timeout` arguments of `PunchSignaling` are not used.
final class PSNPunchSignaling: PunchSignaling, @unchecked Sendable {
    private let session: PSNRemotePlaySession
    private let lock = NSLock()
    private var running: Task<Void, Never>?
    private var cancelled = false
    private var firstFailure: PSNError?

    init(session: PSNRemotePlaySession) { self.session = session }

    /// The PSN error that ended the last call, if one did (the hole punch only sees `signalingFailed`).
    var failure: PSNError? { lock.withLock { firstFailure } }

    /// Ends the call in progress and fails every later one: the setup was cancelled.
    func cancel() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            cancelled = true
            return running
        }
        task?.cancel()
    }

    private func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let outcome = OSAllocatedUnfairLock<Result<T, any Error>?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        let task = Task {
            let result: Result<T, any Error>
            do { result = .success(try await body()) } catch { result = .failure(error) }
            outcome.withLock { $0 = result }
            done.signal()
        }
        let alreadyCancelled = lock.withLock { () -> Bool in
            running = task
            return cancelled
        }
        if alreadyCancelled { task.cancel() }
        done.wait()
        lock.withLock { running = nil }
        do {
            return try outcome.withLock { $0 }!.get()
        } catch let error as PSNError {
            lock.withLock { if firstFailure == nil { firstFailure = error } }
            throw PunchError.signalingFailed("\(error)")
        } catch {
            throw PunchError.cancelled
        }
    }

    func receiveConsoleOffer(timeout: Double) throws -> PunchOffer {
        let message = try blocking { [session] in try await session.receiveOffer() }
        let request = message.request
        return PunchOffer(
            sid: UInt16(truncatingIfNeeded: request.sid), peerSid: UInt16(truncatingIfNeeded: request.peerSid),
            hashedID: request.localHashedID, candidates: request.candidates.map(PunchCandidate.init))
    }

    func sendOffer(_ offer: PunchOffer, timeout: Double) throws {
        let candidates = offer.candidates.map(\.psn)
        try blocking { [session] in try await session.sendOffer(candidates: candidates) }
    }

    func sendAccept(_ accept: PunchAccept) throws {
        let selected = accept.candidate.psn
        try blocking { [session] in try await session.sendAccept(selected: selected) }
    }

    func receiveConsoleAccept(timeout: Double) throws -> PunchAccept {
        let message = try blocking { [session] in try await session.receiveAccept() }
        let request = message.request
        // The hole punch doesn't read the console's ACCEPT (holepunch.md section 5.5); a missing candidate is no failure.
        let candidate = request.candidates.first.map(PunchCandidate.init)
            ?? PunchCandidate(type: .staticAddress, address: "", port: 0)
        return PunchAccept(
            sid: UInt16(truncatingIfNeeded: request.sid), peerSid: UInt16(truncatingIfNeeded: request.peerSid),
            candidate: candidate)
    }
}
