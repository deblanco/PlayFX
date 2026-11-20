import CChiaki
import Foundation
import os
import Testing
@testable import StreamCore

/// Pairing through PSN with a stand-in for the session: nothing here reaches PSN or a console.
@Suite struct PSNPairingTests {
    private let account = "AQEBAQEBAQE="
    private let paired = ConsoleCredentials(address: "", ps5: true, nickname: "PS5-454", mac: "00:1a:2b:c3:d4:ff",
                                            registKey: "AAAAAAAAAAAAAAAAAAAAAA==", rpKey: "AAAAAAAAAAAAAAAAAAAAAA==",
                                            accountId: "AQEBAQEBAQE=")

    /// A session that reports `reports` from another thread, as libchiaki does, and records its stop.
    private final class FakeSession: @unchecked Sendable {
        let reports: [PSNPairing.Report]
        let started = OSAllocatedUnfairLock<PSNPairing.Request?>(initialState: nil)
        let stops = OSAllocatedUnfairLock(initialState: 0)
        init(_ reports: [PSNPairing.Report]) { self.reports = reports }

        func start(_ request: PSNPairing.Request, _ report: @escaping @Sendable (PSNPairing.Report) -> Void) -> () -> Void {
            started.withLock { $0 = request }
            let reports = reports
            DispatchQueue.global().async { reports.forEach(report) }
            return { self.stops.withLock { $0 += 1 } }
        }
    }

    private func pairing(_ session: FakeSession, accountId: String? = nil, timeout: TimeInterval = 5) -> PSNPairing {
        PSNPairing(token: { "tok" }, duid: "aa", accountId: accountId ?? account, timeout: timeout, start: session.start)
    }

    private final class Stages: @unchecked Sendable {
        let seen = OSAllocatedUnfairLock<[PSNPairing.Stage]>(initialState: [])
        func add(_ stage: PSNPairing.Stage) { seen.withLock { $0.append(stage) } }
    }

    @Test func returnsTheKeysTheConsoleGaveAndStopsTheSession() throws {
        let session = FakeSession([.progress(.linking), .progress(.registering), .registered(paired),
                                   .quit(reason: "Stopped", error: false)])
        let stages = Stages()
        let result = try pairing(session).run { stages.add($0) }
        #expect(result.nickname == "PS5-454" && result.address.isEmpty && result.ps5)
        #expect(stages.seen.withLock { $0 } == [.linking, .registering])
        #expect(session.started.withLock { $0?.duid } == "aa")
        #expect(session.started.withLock { $0?.token } == "tok")
        #expect(session.stops.withLock { $0 } == 1)
    }

    @Test func aQuitWithoutTheKeysIsAFailureSayingWhy() {
        let session = FakeSession([.progress(.linking), .quit(reason: PSNPairing.psnRegistFailed, error: true)])
        #expect(throws: ConsoleError.self) { try pairing(session).run { _ in } }
        do {
            _ = try pairing(FakeSession([.quit(reason: PSNPairing.psnRegistFailed, error: true)])).run { _ in }
        } catch {
            #expect(error.localizedDescription.hasPrefix("The PS5 didn't accept pairing through PSN."))
        }
        #expect(session.stops.withLock { $0 } == 1)
    }

    /// libchiaki (fork: "Session: keep a failed PSN registration's quit reason") ends a refused registration
    /// with its reason, an unanswered one as a plain stop: the user is told which.
    @Test func aRefusalIsToldApartFromNoAnswer() {
        func failure(_ quit: PSNPairing.Report) -> String {
            do {
                _ = try pairing(FakeSession([.progress(.linking), .progress(.registering), quit])).run { _ in }
                return "paired"
            } catch { return error.localizedDescription }
        }
        #expect(failure(.quit(reason: PSNPairing.psnRegistFailed, error: true))
            .hasPrefix("The PS5 didn't accept pairing through PSN."))
        #expect(failure(.quit(reason: "Stopped", error: false)).hasPrefix("The PS5 didn't answer through PSN."))
    }

    @Test func explainsEachWayItCanEnd() {
        #expect(PSNPairing.failureMessage(reason: "Stopped", error: false).hasPrefix("The PS5 didn't answer through PSN."))
        #expect(PSNPairing.failureMessage(reason: PSNPairing.psnRegistFailed + ": details", error: true)
            .contains("signed in with the PS5 user's account"))
        let shim = "PSN couldn't reach your PS5. Check that it's on. (Host is down)"
        #expect(PSNPairing.failureMessage(reason: shim, error: true) == shim) // already says what to do
    }

    @Test func cancelStopsIt() throws {
        let session = FakeSession([.progress(.linking)]) // never finishes on its own
        let p = pairing(session)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { p.cancel() }
        #expect(throws: PSNPairingError.cancelled) { try p.run { _ in } }
        #expect(session.stops.withLock { $0 } == 1)
        #expect(PSNPairingError.cancelled.localizedDescription == "Pairing cancelled.")
    }

    @Test func cancelledBeforeItStartsNeverStartsTheSession() {
        let session = FakeSession([.registered(paired)])
        let p = pairing(session)
        p.cancel()
        #expect(throws: PSNPairingError.cancelled) { try p.run { _ in } }
        #expect(session.started.withLock { $0 } == nil)
    }

    /// The pairing, for a token fetch that cancels it.
    private final class Ref: @unchecked Sendable { var pairing: PSNPairing? }

    @Test func aCancelWhileTheTokenIsFetchedIsKept() {
        let session = FakeSession([.registered(paired)])
        let ref = Ref()
        ref.pairing = PSNPairing(token: { ref.pairing?.cancel(); return "tok" }, duid: "aa", accountId: account,
                                 start: session.start)
        #expect(throws: PSNPairingError.cancelled) { try ref.pairing?.run { _ in } }
        #expect(session.started.withLock { $0 } == nil)
    }

    @Test func aFailedTokenFetchIsTheFailure() {
        let session = FakeSession([.registered(paired)])
        let p = PSNPairing(token: { throw ConsoleError.message("PSN didn't answer") }, duid: "aa", accountId: account,
                           start: session.start)
        #expect(throws: ConsoleError.message("PSN didn't answer")) { try p.run { _ in } }
        #expect(session.started.withLock { $0 } == nil)
    }

    @Test func givesUpWhenNothingComes() {
        let session = FakeSession([])
        do {
            _ = try pairing(session, timeout: 0.05).run { _ in }
            Issue.record("expected a timeout")
        } catch {
            #expect(error.localizedDescription.hasPrefix("PSN didn't finish pairing in time."))
        }
        #expect(session.stops.withLock { $0 } == 1)
    }

    @Test func needsTheAccountID() {
        let session = FakeSession([.registered(paired)])
        #expect(throws: ConsoleError.self) { try pairing(session, accountId: "AQID").run { _ in } }
        #expect(session.started.withLock { $0 } == nil)
    }

    @Test func progressAfterTheEndIsDropped() throws {
        let session = FakeSession([.registered(paired), .progress(.registering)])
        let stages = Stages()
        _ = try pairing(session).run { stages.add($0) }
        Thread.sleep(forTimeInterval: 0.05)
        #expect(stages.seen.withLock { $0 }.isEmpty)
    }

    @Test func mapsTheShimsEvents() {
        let progress = Int32(PSRP_EVENT_REMOTE_PROGRESS.rawValue), quit = Int32(PSRP_EVENT_QUIT.rawValue)
        guard case .progress(.linking) = PSNPairing.report(type: progress, a: Int32(PSRP_REMOTE_LINKING.rawValue), message: "")
        else { Issue.record("linking"); return }
        guard case .progress(.registering) = PSNPairing.report(type: progress, a: Int32(PSRP_REMOTE_REGISTERING.rawValue), message: "")
        else { Issue.record("registering"); return }
        #expect(PSNPairing.report(type: progress, a: Int32(PSRP_REMOTE_DATA.rawValue), message: "") == nil)
        guard case .quit(let reason, let error) = PSNPairing.report(type: quit, a: 1, message: "Bye") else {
            Issue.record("quit"); return
        }
        #expect(reason == "Bye" && error)
        #expect(PSNPairing.report(type: Int32(PSRP_EVENT_CONNECTED.rawValue), a: 0, message: "") == nil)
    }

    /// The real session refuses at once, before any network, without a PS5 device ID or a PSN token.
    @Test func theShimRefusesWithoutADeviceID() throws {
        let request = PSNPairing.Request(token: "tok", duid: "not hex", accountId: account)
        #expect(throws: ConsoleError.self) { _ = try PSNPairing.startSession(request) { _ in } }
        do { _ = try PSNPairing.startSession(request) { _ in } } catch {
            #expect(error.localizedDescription == "Pairing through PSN needs a PS5 and its PSN device ID")
        }
        var config = PsrpSessionConfig()
        config.register_only = true
        var callbacks = PsrpCallbacks()
        var message = [CChar](repeating: 0, count: 128)
        #expect(psrp_session_start(&config, &callbacks, &message, message.count) == nil)
        #expect(String(cString: message) == "Pairing through PSN needs a PSN sign-in")
    }
}
