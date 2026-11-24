import Foundation
import os
import Testing
@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport
@testable import StreamCore

/// Pairing through PSN with a stand-in for the library's registration, and once against PlayFXProtocol's fake PSN and
/// console on loopback: nothing here reaches PSN, a router or a console.
@Suite struct PSNPairingTests {
    private let account = "AQEBAQEBAQE="
    private static let result = PairingResult(
        registKey: hex("30313233616263640000000000000000"), rpKey: hex("a0a1a2a3a4a5a6a7a8a9aaabacadaeaf"),
        nickname: "PS5-454", mac: hex("001a2bc3d4ff"), target: .ps5v1, keyType: 2, apSSID: nil, apBSSID: nil,
        apKey: nil, apName: nil)

    /// A registration that reports `stages` from its own task and then returns `outcome`, recording what it was started with.
    private final class FakeRegistration: @unchecked Sendable {
        let stages: [InternetStage]
        let outcome: @Sendable () async throws -> PairingResult
        let started = OSAllocatedUnfairLock<(remote: PSNRemote, internet: InternetOptions)?>(initialState: nil)
        /// The registration saw its task cancelled.
        let cancelled: OSAllocatedUnfairLock<Bool>
        init(stages: [InternetStage] = [], cancelled: OSAllocatedUnfairLock<Bool> = OSAllocatedUnfairLock(initialState: false),
             outcome: @escaping @Sendable () async throws -> PairingResult) {
            self.stages = stages
            self.cancelled = cancelled
            self.outcome = outcome
        }

        var register: PSNPairing.Register {
            { remote, internet in
                self.started.withLock { $0 = (remote, internet) }
                self.stages.forEach(internet.progress)
                return try await self.outcome()
            }
        }

        /// Runs until cancelled, then fails as the library does.
        static func waitingToBeCancelled(stages: [InternetStage] = [.linkingPSN]) -> FakeRegistration {
            let cancelled = OSAllocatedUnfairLock(initialState: false)
            return FakeRegistration(stages: stages, cancelled: cancelled) {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { cancelled.withLock { $0 = true } }
                throw InternetStartError.cancelled
            }
        }
    }

    private func pairing(_ fake: FakeRegistration, accountId: String? = nil, duid: String = PSNVector.duid,
                         timeout: TimeInterval = 60, cleanupWait: TimeInterval = 60) -> PSNPairing {
        PSNPairing(token: { "tok" }, duid: duid, accountId: accountId ?? account, timeout: timeout,
                   cleanupWait: cleanupWait, register: fake.register)
    }

    private final class Stages: @unchecked Sendable {
        let seen = OSAllocatedUnfairLock<[PSNPairing.Stage]>(initialState: [])
        func add(_ stage: PSNPairing.Stage) { seen.withLock { $0.append(stage) } }
    }

    // MARK: Success

    @Test func returnsTheSameCredentialsAPINPairingGives() throws {
        let fake = FakeRegistration(stages: [.linkingPSN, .wakingConsole, .ctrlHole, .registering]) { Self.result }
        let stages = Stages()
        let paired = try pairing(fake).run { stages.add($0) }
        #expect(stages.seen.withLock { $0 } == [.linking, .registering])
        // The credentials a PIN pairing of the same result makes, but for the console's address (not learned over PSN).
        let viaPIN = Console.credentials(from: Self.result, address: "192.168.0.40", ps5: true, accountId: account)
        #expect(paired.address.isEmpty && paired.ps5 && paired.nickname == "PS5-454" && paired.accountId == account)
        #expect(paired.mac == "00:1a:2b:c3:d4:ff" && paired.mac == viaPIN.mac)
        #expect(paired.registKey == viaPIN.registKey && paired.rpKey == viaPIN.rpKey)
        #expect(Data(base64Encoded: paired.registKey) == Data("0123abcd".utf8) + Data(repeating: 0, count: 8))
        let started = try #require(fake.started.withLock { $0 })
        #expect(started.remote.accessToken == "tok" && started.remote.consoleDUID == PSNVector.duid)
        #expect(started.remote.platform == .ps5)
        // The JSON shape the desktop app stores and sends back.
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(paired)) as? [String: Any]
        #expect(Set(json.map { Array($0.keys) } ?? []) == ["address", "ps5", "nickname", "mac", "registKey", "rpKey", "accountId"])
    }

    @Test func mapsTheLibrarysStepsToTheTwoStages() {
        let mapped = InternetStage.allCases.map { PSNPairing.stage(for: $0)?.rawValue ?? "-" }
        #expect(mapped == ["linking", "-", "-", "registering", "-", "-", "-", "-", "-", "-"])
    }

    @Test func progressAfterTheEndIsDropped() throws {
        let fake = FakeRegistration(stages: []) { Self.result }
        let p = pairing(fake)
        let stages = Stages()
        _ = try p.run { stages.add($0) }
        let internet = try #require(fake.started.withLock { $0?.internet })
        internet.progress(.registering)
        #expect(stages.seen.withLock { $0 }.isEmpty)
    }

    // MARK: Failure

    @Test func eachWayItEndsWithoutTheKeysSaysWhatToDo() {
        func failure(_ error: InternetStartError) -> String? {
            do {
                _ = try pairing(FakeRegistration(stages: [.linkingPSN, .registering]) { throw error }).run { _ in }
                return nil
            } catch { return error.localizedDescription }
        }
        let refused = failure(.registration(RegistrationError(
            kind: .httpNotOK(status: 403), reasonCode: RPReason.invalidPSNID, consoleAnswered: true)))
        #expect(refused?.hasPrefix("The PS5 refused the pairing step") == true && refused?.contains("0x80108b02") == true)
        #expect(failure(.registration(RegistrationError(kind: .timeout, consoleAnswered: false)))
            == InternetStartError.registration(RegistrationError(kind: .timeout, consoleAnswered: false)).userMessage(console: .ps5))
        #expect(failure(.psn(.consoleUnreachable))?.contains("Remote Play is turned on") == true)
        #expect(failure(.psn(.unauthorized(step: .createSession, status: 401)))?.contains("Sign in to PlayFX") == true)
        #expect(failure(.holePunch(hole: .ctrl, .hostUnreachable))?.contains("direct connection") == true)
        #expect(failure(.noPublicAddress)?.contains("address on the internet") == true)
    }

    @Test func anErrorTheLibraryDoesNotType() {
        let error = PSNPairing.failure(for: URLError(.cancelled)) as? ConsoleError
        guard case .message(let text)? = error else { Issue.record("expected a message"); return }
        #expect(text.hasPrefix("Couldn't pair through PSN: "))
        #expect(PSNPairing.failure(for: InternetStartError.cancelled) as? PSNPairingError == .cancelled)
    }

    @Test func givesUpWhenNothingComesAndEndsTheRegistration() async {
        let fake = FakeRegistration.waitingToBeCancelled()
        do {
            _ = try pairing(fake, timeout: 0.05).run { _ in }
            Issue.record("expected a timeout")
        } catch {
            #expect(error.localizedDescription == "PSN didn't finish pairing in time. Check that the PS5 is on, and try again.")
        }
        // The registration was started and cancelled, and `run` waited for it (the library leaves PSN before it returns).
        // On a loaded machine the task may only get going after `run` gave up.
        #expect(await waitUntil { fake.started.withLock { $0 } != nil && fake.cancelled.withLock { $0 } })
    }

    @Test func doesNotWaitForeverForTheLibraryToLeavePSN() {
        // A registration that ignores its cancel for a while: `run` returns at its bound with the outcome it had.
        let fake = FakeRegistration {
            await withCheckedContinuation { done in DispatchQueue.global().asyncAfter(deadline: .now() + 2) { done.resume() } }
            throw InternetStartError.cancelled
        }
        let p = pairing(fake, timeout: 0.05, cleanupWait: 0.05)
        let began = Date()
        #expect(throws: ConsoleError.self) { try p.run { _ in } }
        #expect(Date().timeIntervalSince(began) < 1.5)
    }

    // MARK: Cancelling

    @Test func cancelStopsItAndTheRegistrationEnds() async throws {
        let fake = FakeRegistration.waitingToBeCancelled()
        let p = pairing(fake)
        Thread { // not on GCD's pool: `run` blocks a thread for its whole length
            Thread.sleep(forTimeInterval: 0.1)
            p.cancel()
        }.start()
        let began = Date()
        #expect(throws: PSNPairingError.cancelled) { try p.run { _ in } }
        #expect(Date().timeIntervalSince(began) < 30)
        #expect(await waitUntil { fake.cancelled.withLock { $0 } })
        #expect(PSNPairingError.cancelled.localizedDescription == "Pairing cancelled.")
    }

    @Test func cancelledBeforeItStartsNeverStartsTheRegistration() {
        let fake = FakeRegistration { Self.result }
        let p = pairing(fake)
        p.cancel()
        #expect(throws: PSNPairingError.cancelled) { try p.run { _ in } }
        #expect(fake.started.withLock { $0 } == nil)
    }

    /// The pairing, for a token fetch that cancels it.
    private final class Ref: @unchecked Sendable { var pairing: PSNPairing? }

    @Test func aCancelWhileTheTokenIsFetchedIsKept() {
        let fake = FakeRegistration { Self.result }
        let ref = Ref()
        ref.pairing = PSNPairing(token: { ref.pairing?.cancel(); return "tok" }, duid: PSNVector.duid, accountId: account,
                                 register: fake.register)
        #expect(throws: PSNPairingError.cancelled) { try ref.pairing?.run { _ in } }
        #expect(fake.started.withLock { $0 } == nil)
    }

    @Test func aCancelRightAfterTheRegistrationStartedStillEndsIt() {
        let fake = FakeRegistration.waitingToBeCancelled()
        let ref = Ref()
        // Cancels from inside the library's first progress report: before `run` has stored anything but the start.
        let cancelling = FakeRegistration(stages: [.linkingPSN]) {
            ref.pairing?.cancel()
            return try await fake.outcome()
        }
        ref.pairing = pairing(cancelling)
        #expect(throws: PSNPairingError.cancelled) { try ref.pairing?.run { _ in } }
    }

    @Test func aFailedTokenFetchIsTheFailure() {
        let fake = FakeRegistration { Self.result }
        let p = PSNPairing(token: { throw ConsoleError.message("PSN didn't answer") }, duid: PSNVector.duid,
                           accountId: account, register: fake.register)
        #expect(throws: ConsoleError.message("PSN didn't answer")) { try p.run { _ in } }
        #expect(fake.started.withLock { $0 } == nil)
    }

    // MARK: What it won't start without

    @Test func needsTheAccountIDAndAPS5DeviceID() {
        let fake = FakeRegistration { Self.result }
        #expect(throws: ConsoleError.message("Sign in to PlayStation first")) { try pairing(fake, accountId: "AQID").run { _ in } }
        for duid in ["", "not hex", String(repeating: "z", count: 64), "aa"] {
            #expect(throws: ConsoleError.message("Pairing through PSN needs a PS5 and its PSN device ID")) {
                try pairing(fake, duid: duid).run { _ in }
            }
        }
        #expect(fake.started.withLock { $0 } == nil)
    }

    @Test func thePublicInitialiserRefusesWithoutAnAccountIDBeforeAnyNetwork() {
        // Refused before any network: no account ID.
        let p = PSNPairing(token: { "tok" }, duid: PSNVector.duid, accountId: "")
        #expect(throws: ConsoleError.message("Sign in to PlayStation first")) { try p.run { _ in } }
    }

    // MARK: Through PlayFXProtocol, on loopback

    @Test func theRealRegistrationPairsWithTheFakeConsoleOverLoopback() throws {
        let rig = try InternetRig()
        defer { rig.stop() }
        let register: PSNPairing.Register = { remote, internet in
            var merged = rig.options
            merged.progress = internet.progress
            return try await Registration.registerThroughPSN(remote: remote, internet: merged, environment: rig.environment)
        }
        let stages = Stages()
        let p = PSNPairing(token: { PSNVector.token }, duid: PSNVector.duid, accountId: account, register: register)
        let paired = try p.run { stages.add($0) }
        #expect(stages.seen.withLock { $0 } == [.linking, .registering])
        #expect(paired.nickname == "PS5-TEST" && paired.address.isEmpty && paired.ps5)
        #expect(paired.mac == "0a:1b:2c:3d:4e:5f" && paired.accountId == account)
        #expect(Data(base64Encoded: paired.registKey) == Data(SessionVector.registKey))
        #expect(Data(base64Encoded: paired.rpKey) == Data(SessionVector.rpKey))
        // It left PSN and removed its mappings before `run` returned, and stayed on loopback.
        #expect(rig.leftPSN && Set(rig.mapper.removedPorts) == Set(rig.mapper.mapped.with { $0 }))
        #expect(rig.psn.hosts.isSubset(of: ["web.np.playstation.com", "mobile-pushcl.np.communication.playstation.net"]))
        #expect(rig.psn.unexpected.withLock { $0 }.isEmpty && LoopbackViolations.recorded.with { $0 }.isEmpty)
    }

    @Test func aConsoleThatRefusesIsReportedAndPSNIsLeft() throws {
        let rig = try InternetRig()
        defer { rig.stop() }
        rig.console.rudp.registrationReply = .refuse(reason: "80108b02")
        let register: PSNPairing.Register = { remote, internet in
            var merged = rig.options
            merged.progress = internet.progress
            return try await Registration.registerThroughPSN(remote: remote, internet: merged, environment: rig.environment)
        }
        let p = PSNPairing(token: { PSNVector.token }, duid: PSNVector.duid, accountId: account, register: register)
        do {
            _ = try p.run { _ in }
            Issue.record("expected a refusal")
        } catch {
            #expect(error.localizedDescription.hasPrefix("The PS5 refused the pairing step"))
        }
        #expect(rig.leftPSN && Set(rig.mapper.removedPorts) == Set(rig.mapper.mapped.with { $0 }))
    }
}
