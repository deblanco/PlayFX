import Foundation
import os
import Testing
@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport
@testable import StreamCore

/// Internet play on the PlayFX engine, on loopback only: PlayFXProtocol's fake PSN, router, STUN server and console
/// (`InternetRig`) stand in for everything outside the machine, so nothing here reaches PSN, Sony, a router or a console.

/// The engine under test with its sink, over an `InternetRig`.
final class InternetHarness: @unchecked Sendable {
    let rig: InternetRig
    let sink = RecordingSink()
    let engine: PlayFXEngine
    /// What the engine asked the library to start with.
    let started = OSAllocatedUnfairLock<(remote: PSNRemote, internet: InternetOptions)?>(initialState: nil)

    static func config(ps5: Bool = true, duid: String = PSNVector.duid) -> StreamEngineConfig {
        var config = PlayFXHarness.config(ps5: ps5)
        config.host = ""
        config.remote = CoreSession.Remote(token: PSNVector.token, duid: duid)
        return config
    }

    /// `starter` replaces the library's start (for tests of the engine's own handling).
    init(rig: InternetRig, config: StreamEngineConfig = InternetHarness.config(),
         environment: [String: String] = [:], starter: PlayFXEngine.RemoteStarter? = nil) throws {
        self.rig = rig
        let started = started
        let real: PlayFXEngine.RemoteStarter = { remote, settings, options, internet, events in
            started.withLock { $0 = (remote, internet) }
            // The rig's limits and fakes, with what the engine chose for progress, log and probe identity.
            var merged = rig.options
            let rigProgress = merged.progress
            let progress = internet.progress
            merged.progress = { rigProgress($0); progress($0) }
            merged.log = internet.log
            merged.probeIdentity = internet.probeIdentity
            return try await PlayFXLibrarySession.start(
                remote: remote, settings: settings, options: options, internet: merged,
                internetEnvironment: rig.environment, streamEnvironment: rig.streamEnvironment, events: events)
        }
        let remoteStarter = starter ?? real
        // A local-network start must never happen in these tests.
        let noLocal: PlayFXEngine.Starter = { _, _, _, _, _, _, _ in
            Issue.record("the local start was used for an internet session")
            throw CancellationError()
        }
        engine = try PlayFXEngine(config: config, sink: sink, start: noLocal, startRemote: remoteStarter, environment: environment)
    }

    /// Off: the engine is released without `stop()` (its `deinit` ends the library's session).
    var stopsOnRelease = true

    deinit {
        if stopsOnRelease { engine.stop() }
        rig.stop()
    }

    func connect() async -> Bool {
        await waitUntil { sink.labels.contains("connected") }
    }

    var quits: [String] { sink.quits }
}

/// The fakes saw only what a console, PSN and a router would, all of it on loopback.
func expectNoRealNetwork(_ rig: InternetRig, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(rig.psn.hosts.isSubset(of: ["web.np.playstation.com", "mobile-pushcl.np.communication.playstation.net"]),
            "PSN calls went to the fake transport only", sourceLocation: sourceLocation)
    #expect(rig.psn.unexpected.withLock { $0 }.isEmpty, sourceLocation: sourceLocation)
    #expect(LoopbackViolations.recorded.with { $0 }.isEmpty, "nothing left loopback", sourceLocation: sourceLocation)
}

/// What every ending leaves behind once PSN was reached: the session left, the push channel closed, every mapped port removed.
func expectGivenBack(_ rig: InternetRig, leftSession: Bool = true, wait: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) async {
    let mapped = Set(rig.mapper.mapped.with { $0 })
    let ready = { (!leftSession || rig.leftPSN) && Set(rig.mapper.removedPorts) == mapped && (!leftSession || rig.psn.socket.closeCount >= 1) }
    if wait { _ = await waitUntil(timeout: 10) { ready() } }
    #expect(!leftSession || rig.leftPSN, "the PSN session is left", sourceLocation: sourceLocation)
    #expect(Set(rig.mapper.removedPorts) == mapped, "every mapping is removed", sourceLocation: sourceLocation)
    #expect(!leftSession || rig.psn.socket.closeCount >= 1, "the push channel is closed", sourceLocation: sourceLocation)
}

extension Serial {
    @Suite struct PlayFXEngineInternetTests {
        // MARK: A whole session

        @Test func anInternetStartReachesTheStreamAndStopLeavesPSN() async throws {
            let h = try InternetHarness(rig: try InternetRig())
            #expect(await h.connect())
            // The contract's order: the three steps, then the stream's own `connected`.
            #expect(Array(h.sink.labels.prefix(4)) == ["progress linking", "progress data", "progress connected", "connected"])
            let seen = try #require(h.started.withLock { $0 })
            #expect(seen.remote.accessToken == PSNVector.token && seen.remote.consoleDUID == PSNVector.duid)
            #expect(seen.remote.platform == .ps5 && seen.internet.probeIdentity == .strict)
            #expect(await waitUntil { h.sink.units.count >= 2 })
            #expect(h.sink.units.first.map { !$0.bytes.isEmpty } == true)
            // It stayed on loopback: the PSN calls carried the token to the fake transport only.
            #expect(h.rig.psn.requests.allSatisfy { $0.headers["Authorization"] == "Bearer \(PSNVector.token)" })
            #expect(!h.rig.mapper.mapped.with { $0.isEmpty })
            expectNoRealNetwork(h.rig)

            let began = monotonicSeconds()
            h.engine.stop()
            // `stop()` returned: the quit is out, and PSN is left and the mappings are gone, with no waiting.
            #expect(h.quits == ["quit stopped false Stopped"] && h.sink.labels.last == h.quits.last)
            await expectGivenBack(h.rig)
            #expect(monotonicSeconds() - began < PlayFXEngine.internetStopTimeout)
            #expect(h.sink.state.withLock { $0.callsAfterQuit == 0 && $0.mainThreadCalls == 0 && $0.overlaps == 0 })
            h.engine.stop()
            #expect(h.quits.count == 1)
        }

        @Test func commandsReachTheInternetSession() async throws {
            let h = try InternetHarness(rig: try InternetRig())
            #expect(await h.connect())
            h.engine.setLoginPin("1234") // nobody asked for it: it must neither crash nor hang
            h.engine.requestKeyFrame()
            h.engine.setController(CoreController())
            h.engine.setMicrophone(true)
            #expect(await waitUntil { h.sink.units.count >= 2 })
            h.engine.stop()
            expectNoRealNetwork(h.rig)
        }

        // MARK: Progress

        @Test func eachStepGoesOutOnceAndInOrder() async throws {
            let stages: [InternetStage] = [
                .linkingPSN, .wakingConsole, .ctrlHole, .registering, .linkingPSN, .sessionInit, .ctrl, .dataHole, .dataHole,
                .probing, .streamConnecting, .connected, .linkingPSN, .dataHole,
            ]
            let h = try InternetHarness(rig: try InternetRig(), starter: { _, _, _, internet, _ in
                stages.forEach(internet.progress)
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { throw InternetStartError.cancelled }
                throw InternetStartError.cancelled
            })
            #expect(await waitUntil { h.sink.labels.count >= 3 })
            try await Task.sleep(nanoseconds: 100_000_000)
            // The library's own `.connected` stage isn't one of the three: the stream's `connected` event comes after it.
            #expect(h.sink.labels == ["progress linking", "progress data", "progress connected"])
            h.engine.stop()
            #expect(h.quits == ["quit stopped false Stopped"])
        }

        @Test func theLibrarysStagesMapToTheContractsThree() {
            let mapped = InternetStage.allCases.map { PlayFXEngine.remoteStage(for: $0)?.rawValue ?? "-" }
            #expect(mapped == ["linking", "-", "-", "-", "-", "-", "data", "connected", "-", "-"])
        }

        // MARK: Failures

        /// Starts an internet session that fails at the step `rig` is set up to fail at, and waits for its quit.
        private func failure(_ rig: InternetRig) async throws -> InternetHarness {
            let h = try InternetHarness(rig: rig)
            #expect(await waitUntil { !h.quits.isEmpty })
            #expect(!h.sink.labels.contains("connected"))
            return h
        }

        @Test func aRefusedSignInIsFinal() async throws {
            let h = try await failure(try InternetRig { $0.createStatus = 401 })
            let message = InternetStartError.psn(.unauthorized(step: .createSession, status: 401)).userMessage(console: .ps5)
            #expect(h.sink.labels == ["progress linking", "quit final true \(message)"])
            #expect(message.contains("Sign in to PlayFX"))
            await expectGivenBack(h.rig, leftSession: false)
            #expect(!h.rig.leftPSN)
            expectNoRealNetwork(h.rig)
        }

        @Test func aBusyConsoleIsBusy() async throws {
            let rig = try InternetRig()
            rig.console.rudp.initReplies = { _ in .refuse(status: "403 Forbidden", reason: "80108b10") }
            let h = try await failure(rig)
            let message = InternetStartError.session(.consoleBusy, stage: .sessionInit).userMessage(console: .ps5)
            #expect(h.quits == ["quit busy true \(message)"])
            #expect(h.sink.labels.first == "progress linking" && !h.sink.labels.contains("progress data"))
            await expectGivenBack(h.rig, wait: true)
            expectNoRealNetwork(h.rig)
        }

        @Test func aHoleThatCannotBePunchedIsFinalNotDropped() async throws {
            let rig = try InternetRig()
            rig.console.ctrlEndpoint.answers = false
            rig.console.ctrlEndpoint.probes = false
            rig.environment.punch.resends = 3
            let h = try await failure(rig)
            // The library calls it `.dropped` (a later try can help); the app must not reconnect a stream that never was.
            #expect(InternetStartError.holePunch(hole: .ctrl, .hostUnreachable).retryClass == .dropped)
            #expect(h.quits.count == 1 && h.quits[0].hasPrefix("quit final true PlayFX couldn't open a direct connection"))
            await expectGivenBack(h.rig, wait: true)
        }

        @Test func aRefusedPairingStepIsFinalAndSaysWhy() async throws {
            let rig = try InternetRig()
            rig.console.rudp.registrationReply = .refuse(reason: "80108b02")
            let h = try await failure(rig)
            #expect(h.quits.count == 1 && h.quits[0].hasPrefix("quit final true The PS5 refused the pairing step"))
            #expect(h.quits[0].contains("0x80108b02"))
            await expectGivenBack(h.rig, wait: true)
        }

        @Test func noPublicAddressIsFinal() async throws {
            let rig = try InternetRig()
            rig.mapper.failsMapping = true
            rig.environment.stunServers = { [] }
            let h = try await failure(rig)
            #expect(h.quits == ["quit final true \(InternetStartError.noPublicAddress.userMessage(console: .ps5))"])
            await expectGivenBack(h.rig, wait: true)
        }

        @Test func aDataHoleThatCannotBePunchedAfterCtrlIsUpKeepsTheStepsItReached() async throws {
            let rig = try InternetRig()
            rig.console.dataEndpoint.answers = false
            rig.console.dataEndpoint.probes = false
            rig.environment.punch.resends = 3
            let h = try await failure(rig)
            #expect(h.sink.labels.prefix(2) == ["progress linking", "progress data"] && !h.sink.labels.contains("progress connected"))
            #expect(h.quits.count == 1 && h.quits[0].hasPrefix("quit final true "))
            await expectGivenBack(h.rig, wait: true)
        }

        @Test func startFailuresMapToQuitKinds() {
            func quit(_ error: Error) -> PlayFXEngine.Quit { PlayFXEngine.quit(forStartFailure: error, console: .ps5) }
            #expect(quit(InternetStartError.cancelled) == PlayFXEngine.Quit(reason: "Stopped", error: false, kind: .stopped))
            #expect(quit(InternetStartError.session(.consoleBusy, stage: .sessionInit)).kind == .busy)
            #expect(quit(InternetStartError.switchNotAcknowledged).kind == .final)
            #expect(quit(InternetStartError.holePunch(hole: .data, .consoleDidNotProbe)).kind == .final)
            let stream = quit(InternetStartError.stream(StreamEndReason(code: .streamFailed), detail: "no probe"))
            #expect(stream.kind == .final && stream.error && !stream.reason.isEmpty)
            #expect(quit(InternetStartError.psn(.timedOut(step: .startCommand))).error)
            #expect(quit(CancellationError()).kind == .final)
        }

        // MARK: Stopping

        @Test func stoppingDuringTheStartCancelsItAndGivesEverythingBack() async throws {
            let rig = try InternetRig()
            rig.console.ctrlEndpoint.answers = false
            rig.console.ctrlEndpoint.probes = false
            let h = try InternetHarness(rig: rig)
            #expect(await waitUntil { rig.stages.with { $0.last == .ctrlHole } })
            let began = monotonicSeconds()
            h.engine.stop()
            #expect(monotonicSeconds() - began < 5)
            #expect(h.quits == ["quit stopped false Stopped"] && h.sink.labels.last == h.quits.last)
            // Cancelling doesn't wait for the library's leaving; it goes on in the background.
            await expectGivenBack(rig, wait: true)
            #expect(h.sink.state.withLock { $0.callsAfterQuit } == 0)
            expectNoRealNetwork(rig)
        }

        @Test func stopWaitsForPSNAtMostItsBound() async throws {
            let rig = try InternetRig()
            rig.options.psnTimeouts.request = 3
            var script = rig.psn.script
            script.hang = ["/members/me"] // the leave never answers
            rig.psn.script = script
            let h = try InternetHarness(rig: rig)
            h.engine.internetLeaveWait = 0.3
            #expect(await h.connect())
            let began = monotonicSeconds()
            h.engine.stop()
            #expect(monotonicSeconds() - began < 2.5, "stop() gave up waiting for PSN at its bound")
            #expect(h.quits == ["quit stopped false Stopped"])
            // The leave goes on in the background and finishes: the DELETE was sent and the mappings go after it.
            await expectGivenBack(rig, wait: true)
        }

        @Test func stoppingFromInsideTheEventHandlerDoesNotWaitForItself() async throws {
            let rig = try InternetRig()
            let h = try InternetHarness(rig: rig)
            let stopped = OSAllocatedUnfairLock(initialState: false)
            h.sink.onEvent = { [unowned h] event in
                if case .connected = event, !stopped.withLock({ let was = $0; $0 = true; return was }) { h.engine.stop() }
            }
            #expect(await waitUntil { h.quits.count == 1 })
            #expect(h.quits == ["quit stopped false Stopped"] && h.sink.labels.last == h.quits.last)
            await expectGivenBack(rig, wait: true)
        }

        @Test func anEngineReleasedWithoutStopEndsTheLibrarysSession() async throws {
            let rig = try InternetRig()
            var h: InternetHarness? = try InternetHarness(rig: rig)
            #expect(await h?.connect() == true)
            h?.stopsOnRelease = false
            // The contract has the sink outlive the engine's last call; in the app `StreamSession.deinit` stops it.
            let sink = h?.sink
            h = nil
            // `deinit` stops the library's session; the leaving then goes on in the background.
            await expectGivenBack(rig, wait: true)
            withExtendedLifetime(sink) {}
        }

        // MARK: Setting it up

        @Test func internetPlayNeedsAPS5AndItsDeviceID() throws {
            let message = ConsoleError.message("Internet play needs a PS5 and its PSN device ID")
            let rig = try InternetRig()
            defer { rig.stop() }
            #expect(throws: message) { _ = try InternetHarness(rig: rig, config: InternetHarness.config(ps5: false)) }
            for duid in ["", "ab", String(repeating: "g", count: 64), String(repeating: "ab", count: 33), PSNVector.duid + "0"] {
                #expect(throws: message) { _ = try InternetHarness(rig: rig, config: InternetHarness.config(duid: duid)) }
            }
            #expect(PlayFXEngine.isDeviceID(PSNVector.duid) && PlayFXEngine.isDeviceID(PSNVector.duid.uppercased()))
            #expect(!PlayFXEngine.isDeviceID(String(repeating: "é", count: 32)))
        }

        @Test func thePublicInitialiserRefusesInternetPlayOnAPS4() {
            var options = CoreSession.Options()
            options.audio = false
            var credentials = fakeCredentials()
            credentials.ps5 = false
            #expect(throws: ConsoleError.message("Internet play needs a PS5 and its PSN device ID")) {
                _ = try CoreSession(credentials: credentials, options: options,
                                remote: CoreSession.Remote(token: "t", duid: PSNVector.duid))
            }
        }

        @Test func theProbeIdentityCheckIsStrictUnlessDevelopmentAsksOtherwise() {
            #expect(PlayFXEngine.internetOptions(environment: [:]) { _ in }.probeIdentity == .strict)
            #expect(PlayFXEngine.internetOptions(environment: ["PLAYFX_PROBE_IDENTITY": "strict"]) { _ in }.probeIdentity == .strict)
            let relaxed = PlayFXEngine.internetOptions(environment: ["PLAYFX_PROBE_IDENTITY": "logOnly"]) { _ in }
            #expect(relaxed.probeIdentity == .logOnly)
            relaxed.log("a line the app logs") // goes to StreamCore's log, not the system's default
        }

        @Test func theEngineChoosesLogOnlyFromTheEnvironment() async throws {
            let h = try InternetHarness(rig: try InternetRig(), environment: ["PLAYFX_PROBE_IDENTITY": "logOnly"])
            #expect(await h.connect())
            #expect(h.started.withLock { $0?.internet.probeIdentity } == .logOnly)
            h.engine.stop()
        }
    }
}
