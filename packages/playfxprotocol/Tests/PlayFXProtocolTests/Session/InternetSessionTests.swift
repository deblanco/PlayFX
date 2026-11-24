import CryptoKit
import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

/// Internet play end to end on loopback: a fake PSN, a fake console that answers the hole-punch probes and speaks RUDP
/// and Takion, and the real session code on top (holepunch.md section 8).
extension StreamSessionSuites {
    @Suite struct InternetSessionTests {
        static let stageOrder: [InternetStage] = [
            .linkingPSN, .wakingConsole, .ctrlHole, .registering, .sessionInit, .ctrl, .dataHole, .probing,
            .streamConnecting, .connected,
        ]

        @Test func theRecordedStreamComesThroughAnInternetSession() async throws {
            let rig = try InternetRig()
            defer { rig.stop() }
            // One heartbeat request, after the session ID: the unrequested replies start once it has arrived.
            rig.console.rudp.ctrlScript = { peer in
                peer.sendHead()
                peer.send(0x33, sessionIDPlain)
                peer.send(0xfe)
                peer.pump(limit: 30)
            }
            let recorder = EventRecorder()
            let session = try await rig.start(recorder: recorder)

            // The stages, in order, each once.
            #expect(rig.stages.with { $0 } == Self.stageOrder)

            // The recorded video comes out intact, like the LAN test's (av.md V-AV7).
            #expect(await recorder.wait { _ in recorder.videoFrames.count >= 2 })
            for (index, frame) in [UInt16(1), 2].enumerated() {
                let want = try #require(captureExpected[frame])
                let got = recorder.videoFrames[index]
                #expect(got.info.frameIndex == frame && got.bytes.count == want.length)
                #expect(sha256Hex(got.bytes) == want.sha)
            }
            let info = try #require(session.connectedInfo)
            #expect(info.probeSucceeded && info.takionVersion == 12 && info.target == .ps5v1 && info.transport == "bsd")
            #expect(info.probe.mtuIn == 1400 && info.probe.mtuOut == 1300)

            // The registration came first, in the PSN form: HOST is the LOCAL candidate's address, and the console
            // read the account ID out of the inner text with the keys made from data1, data2 and customData1.
            let registration = try #require(rig.console.rudp.registrations.with { $0.first })
            #expect(registration.header.hasPrefix("POST /sie/ps5/rp/sess/rgst HTTP/1.1\r\n HTTP/1.1\r\nHOST: 127.0.0.1\r\n"))
            #expect(registration.inner == "Client-Type: \(RegistrationRequest.clientType)\r\nNp-AccountId: "
                + "\(Data(rig.console.rudp.secrets.accountID).base64EncodedString())\r\n")

            // Session init used the keys the registration returned, with the ctrl hole's selection as Host.
            let ctrlPort = rig.console.ctrlEndpoint.port
            let initRequest = try #require(rig.console.rudp.initRequests.with { $0.first })
            #expect(initRequest.contains("Host: 127.0.0.1:\(ctrlPort)\r\n"))
            #expect(initRequest.contains("RP-Registkey: 3031323361626364\r\n"))
            let ctrl = try #require(rig.console.rudp.ctrlRequests.with { $0.first })
            #expect(ctrl.contains("Host: 127.0.0.1:\(ctrlPort)\r\n") && ctrl.contains("Connection: keep-alive\r\n"))
            let peer = try #require(rig.console.rudp.peers.with { $0.first })
            #expect(peer.decryptedHeader("RP-Auth", counter: 0) == SessionVector.registKey)

            // Ctrl over RUDP: the start-up messages after the session ID decrypt at the counters of ctrl.md section 10
            // (the PS5 skipped one after the request), and the unrequested heartbeat replies come every interval.
            #expect(await waitUntil { peer.received.with { $0.filter { $0.type == 0x36 }.count } >= 2 })
            #expect(peer.received.with { $0.filter { $0.type == 0x36 }.allSatisfy { $0.plain == [0, 1, 1, 0x59] } })
            #expect(await waitUntil { peer.received.with { $0.filter { $0.type == 0x1fe }.count } >= 4 })  // the answer, then 3 more

            // The probe ran on the data hole's socket before the switch message, and the stream on the same one.
            #expect(!rig.console.stream.probeMessages.with { $0.isEmpty })
            #expect(rig.console.rudp.switchMessages.with { $0.count } == 1)
            #expect(rig.console.rudp.switchMessages.with { $0[0].count } == 8 + 16)
            #expect(rig.console.stream.hello != nil)
            #expect(rig.console.dataEndpoint.port != ctrlPort)

            // The two holes' sockets: nothing else was used, and nothing left the loopback.
            let sockets = rig.holeSockets.with { $0 }
            #expect(sockets.count == 2)
            for socket in sockets { #expect(socket.destinations.with { Set($0) }.isSubset(of: ["127.0.0.1", ""])) }

            // Ending the stream gives everything back.
            session.stop()
            #expect(await recorder.waitForEnd()?.code == .stoppedByClient)
            await rig.expectGivenBack()
            #expect(rig.mapper.mapped.with { $0.count } == 2)
            #expect(rig.psn.requests.last { $0.method == "DELETE" }?.url.path.hasSuffix("/members/me") == true)
        }

        /// `stopAndWait` returns only when the PSN session is left and the mappings are gone (an app quitting needs that).
        @Test func stopAndWaitGivesEverythingBackBeforeItReturns() async throws {
            let rig = try InternetRig()
            defer { rig.stop() }
            let recorder = EventRecorder()
            let session = try await rig.start(recorder: recorder)
            await session.stopAndWait()
            #expect(rig.leftPSN)
            #expect(Set(rig.mapper.removedPorts) == Set(rig.mapper.mapped.with { $0 }) && !rig.mapper.removedPorts.isEmpty)
            #expect(recorder.ended.first?.code == .stoppedByClient)
            #expect(rig.psn.socket.closeCount >= 1)
        }

        @Test func stunStandsInWhenTheRouterMapsNothing() async throws {
            let rig = try InternetRig()
            defer { rig.stop() }
            rig.mapper.failsMapping = true
            let recorder = EventRecorder()
            let session = try await rig.start(recorder: recorder)
            #expect(rig.stun.requests.with { $0 } == 5)  // four for the ctrl hole, one for the data hole
            #expect(await recorder.wait { _ in recorder.videoFrames.count >= 2 })
            session.stop()
            _ = await recorder.waitForEnd()
            await rig.expectGivenBack()
        }

        @Test func pinlessPairingGivesTheSamePairingRecord() async throws {
            let rig = try InternetRig()
            defer { rig.stop() }
            let pairing = try await Registration.registerThroughPSN(
                remote: rig.remote, internet: rig.options, environment: rig.environment)
            #expect(pairing.registKey == SessionVector.registKey && pairing.rpKey == SessionVector.rpKey)
            #expect(pairing.target == .ps5v1 && pairing.nickname == "PS5-TEST" && pairing.mac == hex("0a1b2c3d4e5f"))
            #expect(pairing.keyType == 2)
            // It stopped after the registration: no session init, no data hole.
            #expect(rig.console.rudp.initRequests.with { $0.isEmpty } && rig.console.rudp.registrations.with { $0.count } == 1)
            #expect(rig.stages.with { $0 } == [.linkingPSN, .wakingConsole, .ctrlHole, .registering])
            #expect(rig.leftPSN)
            #expect(rig.mapper.removedPorts == rig.mapper.mapped.with { $0 })
        }

        // MARK: Failures: each ends with the PSN session left and the mappings removed

        @Test func aPSNFailureEndsTheStart() async throws {
            let rig = try InternetRig { $0.createStatus = 500 }
            defer { rig.stop() }
            let error = await rig.startFailure()
            #expect(error == .psn(.httpStatus(step: .createSession, status: 500)))
            #expect(error?.userMessage(console: .ps5).contains("PlayStation Network") == true)
            #expect(rig.stages.with { $0 } == [.linkingPSN])
            // No session was made, so none is left, and no port had been mapped, so none is removed.
            #expect(rig.mapper.mapped.with { $0.isEmpty })
            await rig.expectGivenBack(leftSession: false)
            #expect(rig.mapper.removed.with { $0.isEmpty })
            #expect(!rig.leftPSN)
        }

        /// A failure after the ctrl hole's port was mapped removes that mapping (and leaves the session).
        @Test func aRefusedStartCommandRemovesTheMappingAndLeavesPSN() async throws {
            let rig = try InternetRig { $0.startStatus = 500 }
            defer { rig.stop() }
            let error = await rig.startFailure()
            #expect(error == .psn(.httpStatus(step: .startCommand, status: 500)))
            #expect(rig.mapper.mapped.with { $0.count } == 1)
            await rig.expectGivenBack()
            #expect(!rig.mapper.removedPorts.isEmpty)
        }

        @Test func noCandidatesEndsTheStartAndLeavesPSN() async throws {
            let rig = try InternetRig()
            defer { rig.stop() }
            rig.mapper.failsMapping = true
            rig.environment.stunServers = { [] }
            let error = await rig.startFailure()
            #expect(error == .noPublicAddress)
            #expect(error?.endReason?.code == .streamFailed)
            await rig.expectGivenBack()
        }

        @Test func anUnreachableConsoleEndsTheCtrlHole() async throws {
            let rig = try InternetRig()
            defer { rig.stop() }
            rig.console.ctrlEndpoint.answers = false
            rig.console.ctrlEndpoint.probes = false
            rig.environment.punch.resends = 3
            let error = await rig.startFailure()
            #expect(error == .holePunch(hole: .ctrl, .hostUnreachable))
            #expect(error?.retryClass == .dropped)
            #expect(error?.userMessage(console: .ps5).contains("direct connection") == true)
            await rig.expectGivenBack()
        }

        @Test func aConsoleThatNeverAnswersRUDPIsUnanswered() async throws {
            let rig = try InternetRig()
            defer { rig.stop() }
            rig.console.rudp.answersHandshake = false
            rig.environment.rudp.stepWait = 0.1
            let error = await rig.startFailure()
            #expect(error == .registration(RegistrationError(kind: .timeout, consoleAnswered: false)))
            #expect(error?.endReason?.code == .psnRegistrationUnanswered)
            await rig.expectGivenBack()
        }

        @Test func aRefusedRegistrationEndsTheStart() async throws {
            let rig = try InternetRig()
            defer { rig.stop() }
            rig.console.rudp.registrationReply = .refuse(reason: "80108b02")
            let error = await rig.startFailure()
            #expect(error == .registration(RegistrationError(
                kind: .httpNotOK(status: 403), reasonCode: RPReason.invalidPSNID, consoleAnswered: true)))
            #expect(error?.endReason?.code == .psnRegistrationFailed)
            #expect(error?.userMessage(console: .ps5).contains("0x80108b02") == true)
            await rig.expectGivenBack()
            #expect(rig.stages.with { $0 }.last == .registering)
        }

        @Test func aConsoleBusyWithAnotherSessionIsReportedAsBusy() async throws {
            let rig = try InternetRig()
            defer { rig.stop() }
            rig.console.rudp.initReplies = { _ in .refuse(status: "403 Forbidden", reason: "80108b10") }
            let error = await rig.startFailure()
            #expect(error == .session(.consoleBusy, stage: .sessionInit))
            #expect(error?.retryClass == .busy)
            #expect(error?.userMessage(console: .ps5).contains("already streaming") == true)
            await rig.expectGivenBack()
        }

        @Test func anUnreachableDataHoleEndsTheStartAfterCtrlIsUp() async throws {
            let rig = try InternetRig()
            defer { rig.stop() }
            rig.console.dataEndpoint.answers = false
            rig.console.dataEndpoint.probes = false
            rig.environment.punch.resends = 3
            let error = await rig.startFailure()
            #expect(error == .holePunch(hole: .data, .hostUnreachable))
            #expect(rig.stages.with { $0 }.last == .dataHole)
            await rig.expectGivenBack()
            #expect(rig.mapper.mapped.with { $0.count } == 2)
        }

        /// A connect that fails on the data hole is a socket error, like the ctrl hole's, not a vague stream failure.
        @Test func aSocketThatCannotConnectIsASocketErrorOnTheDataHole() async throws {
            let rig = try InternetRig()
            defer { rig.stop() }
            let makeSocket = rig.environment.makeSocket
            let calls = Locked(0)
            rig.environment.makeSocket = {
                let socket = try makeSocket()
                return calls.with { $0 += 1; return $0 } == 2 ? ConnectFailingSocket(socket) : socket
            }
            let error = await rig.startFailure()
            #expect(error == .socket(.networkUnreachable))
            await rig.expectGivenBack()
        }

        @Test func aSwitchThatIsNeverAcknowledgedEndsTheStart() async throws {
            let rig = try InternetRig()
            defer { rig.stop() }
            rig.console.rudp.acknowledgesSwitch = false
            rig.environment.rudp.switchWait = 0.3
            let error = await rig.startFailure()
            #expect(error == .switchNotAcknowledged)
            #expect(rig.stages.with { $0 }.last == .streamConnecting)
            await rig.expectGivenBack()
        }

        @Test func theConsoleEndingCtrlEndsTheRunningStream() async throws {
            let rig = try InternetRig()
            defer { rig.stop() }
            let recorder = EventRecorder()
            _ = try await rig.start(recorder: recorder)
            rig.console.rudp.finishCtrl()
            let ended = await recorder.waitForEnd()
            #expect(ended?.code == .ctrlFailed)
            await rig.expectGivenBack()
        }

        @Test func aLoginPINReplyUsesTheCounterBeforeTheNextOne() async throws {
            let rig = try InternetRig()
            defer { rig.stop() }
            let reply = Locked<(type: UInt16, plain: [UInt8], wire: [UInt8])?>(nil)
            rig.console.rudp.ctrlScript = { peer in
                peer.sendHead()
                peer.send(0x04)
                guard let received = peer.receive(timeout: 5) else { return }
                reply.with { $0 = received }
                peer.send(0x05, [0])
                peer.send(0x33, sessionIDPlain)
                peer.pump(limit: 30)
            }
            let recorder = EventRecorder()
            recorder.onEvent = { event, session in
                if case .loginPINRequested = event { try? session.sendLoginPIN("1234") }
            }
            let session = try await rig.start(recorder: recorder)
            defer { session.stop() }
            // ctrl.md section 10: the PS5 skipped counter 5 after the request, and the PIN reply, the first encrypted
            // message, takes that skipped value; the messages after it continue at 7.
            let received = try #require(reply.with { $0 })
            let peer = try #require(rig.console.rudp.peers.with { $0.first })
            #expect(received.type == 0x8004)
            #expect(peer.cipher.apply(received.wire, counter: 5, encrypt: false) == Array("1234".utf8))
            #expect(await waitUntil { peer.received.with { $0.filter { $0.type == 0x36 }.count } >= 2 })
            #expect(peer.received.with { $0.filter { $0.type == 0x36 }.allSatisfy { $0.plain == [0, 1, 1, 0x59] } })
        }

        @Test func aCtrlRequestNobodyAnswersEndsAsNoAnswer() async throws {
            let rig = try InternetRig()
            defer { rig.stop() }
            rig.console.rudp.ctrlScript = { _ in }
            rig.environment.rudp.stepWait = 0.1
            let error = await rig.startFailure()
            #expect(error == .session(.noAnswer(.timeout), stage: .ctrl))
            await rig.expectGivenBack()
        }

        @Test func aCtrlHeaderThatComesTooLateIsNotRetriedOverRUDP() async throws {
            let rig = try InternetRig()
            defer { rig.stop() }
            rig.console.rudp.ctrlScript = { peer in
                sleepSeconds(0.6)
                peer.sendHead()
            }
            rig.environment.ctrlHeaderTimeout = 0.2
            let error = await rig.startFailure()
            #expect(error == .session(.noAnswer(.timeout), stage: .ctrl))
            #expect(rig.console.rudp.ctrlRequests.with { $0.count } == 1)
            await rig.expectGivenBack()
        }

        // MARK: Cancellation

        @Test(arguments: [InternetStage.ctrlHole, .registering, .sessionInit, .ctrl, .dataHole, .probing, .streamConnecting])
        func cancellingMidwayGivesEverythingBack(stage: InternetStage) async throws {
            let rig = try InternetRig()
            defer { rig.stop() }
            // Stall the stage that is cancelled in: no probes, no answers, no reply, no session ID, no acknowledgement.
            switch stage {
            case .ctrlHole:
                rig.console.ctrlEndpoint.answers = false
                rig.console.ctrlEndpoint.probes = false
            case .registering:
                rig.console.rudp.registrationReply = .silent
            case .sessionInit:
                rig.console.rudp.initReplies = { _ in .hang }
            case .ctrl:
                rig.console.rudp.ctrlScript = { peer in
                    peer.sendHead()
                    peer.pump(limit: 30)
                }
            case .dataHole:
                rig.console.dataEndpoint.answers = false
                rig.console.dataEndpoint.probes = false
            case .probing:
                rig.console.stream.probeScript = .silent
                rig.streamEnvironment.probe.connectTimeout = 30
                rig.streamEnvironment.probe.stepTimeout = 30
            default:
                rig.console.rudp.acknowledgesSwitch = false
                rig.environment.rudp.switchWait = 30
            }
            rig.environment.registrationTimeout = 30
            rig.environment.rudp.stepWait = 2
            let reached = Locked(false)
            let progress = rig.options.progress
            rig.options.progress = { reported in
                progress(reported)
                if reported == stage { reached.with { $0 = true } }
            }
            let task = Task { await rig.startFailure() }
            #expect(await waitUntil { reached.with { $0 } })
            try await Task.sleep(nanoseconds: 200_000_000)
            let began = monotonicSeconds()
            task.cancel()
            let error = await task.value
            #expect(error == .cancelled, "\(String(describing: error))")
            #expect(monotonicSeconds() - began < 3, "cancelling is noticed at once, not at a timeout")
            #expect(error?.userMessage(console: .ps5) == "")
            await rig.expectGivenBack()
        }

        @Test func aCtrlEndDuringTheSwitchWaitIsACtrlFailureNotAMissingAcknowledgement() async throws {
            let rig = try InternetRig()
            defer { rig.stop() }
            rig.console.rudp.acknowledgesSwitch = false
            rig.environment.rudp.switchWait = 30
            let task = Task { await rig.startFailure() }
            #expect(await waitUntil { rig.stages.with { $0.last == .streamConnecting } })
            try await Task.sleep(nanoseconds: 200_000_000)
            let began = monotonicSeconds()
            rig.console.rudp.finishCtrl()
            let error = await task.value
            #expect(monotonicSeconds() - began < 3)
            guard case .stream(let reason, _)? = error else {
                Issue.record("expected a ctrl failure, got \(String(describing: error))")
                return
            }
            #expect(reason.code == .ctrlFailed)
            await rig.expectGivenBack()
        }

        /// Cancelling returns at once; the leaving (here a DELETE that hangs for 3 s) goes on in the background.
        @Test func cancellingDoesNotWaitForThePSNLeave() async throws {
            let rig = try InternetRig()
            defer { rig.stop() }
            rig.console.ctrlEndpoint.answers = false
            rig.console.ctrlEndpoint.probes = false
            rig.options.psnTimeouts.request = 3
            var script = rig.psn.script
            script.hang = ["/members/me"]
            rig.psn.script = script
            let task = Task { await rig.startFailure() }
            #expect(await waitUntil { rig.stages.with { $0.last == .ctrlHole } })
            try await Task.sleep(nanoseconds: 200_000_000)
            let began = monotonicSeconds()
            task.cancel()
            #expect(await task.value == .cancelled)
            #expect(monotonicSeconds() - began < 1.5)
            // The DELETE was started and still gets its turn (and the mapping goes after it).
            #expect(await waitUntil { rig.leftPSN })
            #expect(await waitUntil(timeout: 10) { !rig.mapper.removed.with { $0.isEmpty } })
        }

        /// `stop()` from the event handler while the start is still running (the console asks for a login PIN and
        /// nobody answers): the start ends with `.cancelled`, nothing is left behind.
        @Test func stopBeforeTheStreamIsUpCancelsTheStart() async throws {
            let rig = try InternetRig()
            defer { rig.stop() }
            rig.console.rudp.ctrlScript = { peer in
                peer.sendHead()
                peer.send(0x04)
                peer.pump(limit: 30)
            }
            let recorder = EventRecorder()
            recorder.onEvent = { event, session in
                if case .loginPINRequested = event { session.stop() }
            }
            let began = monotonicSeconds()
            #expect(await rig.startFailure(recorder: recorder) == .cancelled)
            #expect(monotonicSeconds() - began < 5)
            #expect(rig.stages.with { $0.last } == .ctrl)
            await rig.expectGivenBack()
        }
    }
}

/// Forwards everything but `connect`, which fails: the system refusing a route.
final class ConnectFailingSocket: UDPPunchSocket, @unchecked Sendable {
    let inner: any UDPPunchSocket
    init(_ inner: any UDPPunchSocket) { self.inner = inner }
    var localPort: UInt16 { inner.localPort }
    func send(_ bytes: [UInt8], to host: String, port: UInt16) throws { try inner.send(bytes, to: host, port: port) }
    func receive(timeout: Double) throws -> UDPPacket? { try inner.receive(timeout: timeout) }
    func connect(host: String, port: UInt16) throws { throw FailureKind.networkUnreachable }
    func setTimeToLive(_ ttl: Int) throws { try inner.setTimeToLive(ttl) }
    func close() { inner.close() }
}
