import Foundation
import Testing
import os

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

// Regression tests for the review of the first PSN delivery (one per real bug).

/// Runs `body` and reports whether it finished within `seconds`; a hang fails the test instead of blocking it.
func finishes(within seconds: TimeInterval = 5, _ body: @escaping @Sendable () async -> Void) async -> Bool {
    let done = OSAllocatedUnfairLock(initialState: false)
    let task = Task {
        await body()
        done.withLock { $0 = true }
    }
    let finished = await eventually(seconds) { done.withLock { $0 } }
    task.cancel()
    return finished
}

@Suite struct PSNReviewTests {
    // MARK: 1. The pong deadline against a server that never answers pings (psn.md section 5.3)

    @Test func pongDeadlineFiresWithARealSocketThatNeverGetsAPong() async throws {
        let server = try LoopbackWebSocketServer(answerPings: false)
        let port = try await server.start()
        defer { server.stop() }
        let socket = URLSessionPSNWebSocket()
        try await socket.open(url: URL(string: "ws://127.0.0.1:\(port)/np/pushNotification")!, headers: [:])
        // URLSession only reads while a receive is pending, as the channel's reader always has.
        let reader = Task { while true { _ = try await socket.receive() } }
        defer { reader.cancel() }
        let outcome = OSAllocatedUnfairLock<PSNError?>(initialState: nil)
        let finished = await finishes {
            do {
                try await psnWithDeadline(0.3, error: .pushChannelNotResponding) { try await socket.ping() }
            } catch { outcome.withLock { $0 = error as? PSNError } }
        }
        #expect(finished, "the deadline never fired: ping() ignores cancellation")
        #expect(outcome.withLock { $0 } == .pushChannelNotResponding)
        await socket.close()
    }

    @Test func aCancelledPingThrows() async throws {
        let server = try LoopbackWebSocketServer(answerPings: false)
        let port = try await server.start()
        defer { server.stop() }
        let socket = URLSessionPSNWebSocket()
        try await socket.open(url: URL(string: "ws://127.0.0.1:\(port)/x")!, headers: [:])
        let reader = Task { while true { _ = try await socket.receive() } }
        defer { reader.cancel() }
        let ping = Task { try await socket.ping() }
        _ = await eventually { !server.seen.pings.isEmpty }
        ping.cancel()
        let finished = await finishes { _ = try? await ping.value }
        #expect(finished)
        await socket.close()
    }

    @Test func deadlineDoesNotWaitForABodyThatIgnoresCancellation() async {
        let finished = await finishes {
            do {
                try await psnWithDeadline(0.05, error: .timedOut(step: .consoleList)) {
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                }
                Issue.record("returned")
            } catch {
                #expect(error as? PSNError == .timedOut(step: .consoleList))
            }
        }
        #expect(finished)
    }

    // MARK: 2. Leaving from a cancelled task still sends the DELETE (psn.md section 8)

    @Test func leaveFromACancelledTaskStillDeletes() async throws {
        let (psn, session) = try await PSNSessionTests.started()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await session.leave()
        }
        let result = await task.value
        #expect(result == PSNLeaveResult(deleteSucceeded: true, deletionConfirmed: true))
        #expect(psn.requests(containing: "/members/me").count == 1)
        #expect(psn.socket.closeCount >= 1)
    }

    @Test func aCancelledCreateLeavesTheSessionItMade() async throws {
        let (psn, client, channel) = try await PSNSessionTests.setUp(
            { $0.afterCreate = [] }, timeouts: PSNVector.patientTimeouts())
        let create = Task { try await PSNRemotePlaySession.create(client: client, channel: channel, parameters: try PSNVector.parameters()) }
        _ = await eventually { !psn.requests(containing: "/remotePlaySessions").isEmpty }
        create.cancel()
        do {
            _ = try await create.value
            Issue.record("created")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await eventually { psn.requests(containing: "/members/me").count == 1 })
        #expect(await eventually { psn.socket.closeCount >= 1 })
    }

    // MARK: 3. Only a 64-character DUID counts as the console joining (section 6.3)

    @Test func malformedMemberNotificationsAreSkipped() async throws {
        let (_, session) = try await PSNSessionTests.started {
            $0.afterStart = [PSNVector.memberFrame("short"), PSNVector.memberFrame("zz" + String(repeating: "0", count: 62)),
                PSNVector.memberFrame(), PSNVector.customDataFrame()]
        }
        #expect(await session.console?.duid == PSNVector.duid)
        await session.leave()
    }

    // MARK: 4. Values from PSN's answers are checked before use

    @Test func ps4BaseURLMustBeHTTPS() async {
        for base in ["http://userprofile.example.test/up", "ftp://userprofile.example.test/up", "https:///nohost", "userprofile"] {
            let psn = FakePSN()
            psn.script.ps4BaseURL = base
            let client = PSNClient(accessToken: PSNVector.token, transport: psn, timeouts: PSNVector.patientTimeouts())
            await #expect(throws: PSNError.invalidResponse(step: .ps4Profile, reason: "url")) {
                try await client.wakePS4(onlineID: "x", sessionID: PSNVector.sessionID, data1: PSNVector.data1, data2: PSNVector.data2)
            }
            #expect(psn.requests(containing: "wakeUp").isEmpty, "\(base)")
        }
    }

    @Test func sessionIDMustBeAUUID() async {
        let psn = FakePSN()
        psn.script.createBody = #"{"remotePlaySessions":[{"sessionId":"zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz","members":[{"accountId":1}]}]}"#
        let client = PSNClient(accessToken: PSNVector.token, transport: psn, timeouts: PSNVector.patientTimeouts())
        #expect(psn.script.createBody.contains("sessionId"))
        await #expect(throws: PSNError.invalidResponse(step: .createSession, reason: "sessionId")) {
            _ = try await client.createSession(pushContextID: PSNVector.pushContextID)
        }
    }

    // MARK: 5. Retransmitted OFFERs are answered while nobody is waiting (section 7.6)

    static func established() async throws -> (FakePSN, PSNRemotePlaySession) {
        let (psn, session) = try await PSNSessionTests.started(PSNSessionTests.cooperativeConsole)
        psn.socket.emit(.text(PSNVector.messageFrame(PSNVector.consoleOfferText())))
        _ = try await session.exchangeOffers(candidates: PSNCodecTests.candidates)
        return (psn, session)
    }

    static func results(_ psn: FakePSN, reqID: Int) -> Int {
        PSNSessionTests.posted(psn).filter { $0.action == .result && $0.reqID == reqID }.count
    }

    @Test func offerRetransmittedDuringProbingGetsAResult() async throws {
        let (psn, session) = try await Self.established()
        #expect(Self.results(psn, reqID: 1) == 1)
        psn.socket.emit(.text(PSNVector.messageFrame(PSNVector.consoleOfferText())))
        #expect(await eventually { Self.results(psn, reqID: 1) == 2 })
        // The ACCEPT still works afterwards (the responder steps aside).
        _ = try await session.accept(selected: PSNCodecTests.candidates[1])
        await session.leave()
    }

    @Test func offersAfterTheDataHoleKeepGettingResultsForTheRestOfTheSession() async throws {
        let (psn, session) = try await Self.established()
        let candidate = PSNCandidate(type: .staticAddress, address: "198.51.100.7", port: 50123)
        _ = try await session.accept(selected: candidate)
        // Between the holes an OFFER is the data hole's first, not a retransmission: nobody answers it alone.
        psn.socket.emit(.text(PSNVector.messageFrame(PSNVector.consoleOfferText(reqID: 8, sid: 777))))
        _ = try await session.exchangeOffers(candidates: PSNCodecTests.candidates)
        #expect(Self.results(psn, reqID: 8) == 1)
        _ = try await session.accept(selected: candidate)
        psn.socket.emit(.text(PSNVector.messageFrame(PSNVector.consoleOfferText(reqID: 8, sid: 777))))
        #expect(await eventually { Self.results(psn, reqID: 8) == 2 })
        await session.leave()
    }

    @Test func theBackgroundResponderIsBoundedAndStopsOnLeave() async throws {
        let (psn, session) = try await Self.established()
        for _ in 0..<200 { psn.socket.emit(.text(PSNVector.messageFrame(PSNVector.consoleOfferText()))) }
        #expect(await eventually { Self.results(psn, reqID: 1) > 5 })
        await session.leave()
        let afterLeave = Self.results(psn, reqID: 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(Self.results(psn, reqID: 1) == afterLeave)
        #expect(afterLeave <= 1 + PSNRemotePlaySession.maxBackgroundResults)
    }

    // MARK: 6. A channel that ended, or was dropped, cleans up after itself

    @Test func aReceiveErrorStopsThePingerAndClosesTheSocket() async throws {
        let socket = FakeWebSocket()
        let channel = try await PSNPushChannelTests.open(socket)
        defer { withExtendedLifetime(channel) {} }
        #expect(await eventually { socket.pings >= 1 })
        socket.drop()
        #expect(await eventually { socket.closeCount >= 1 })
        try await Task.sleep(for: .milliseconds(100))
        let settled = socket.pings
        try await Task.sleep(for: .milliseconds(200))
        #expect(socket.pings == settled, "the pinger kept running")
    }

    @Test func aChannelDroppedWithoutCloseCleansUp() async throws {
        let socket = FakeWebSocket()
        func openAndForget() async throws {
            _ = try await PSNPushChannelTests.open(socket, timeouts: PSNPushChannelTests.quiet())
        }
        try await openAndForget()
        #expect(await eventually { socket.closeCount >= 1 })
    }

    @Test func aChannelOnARealSocketDiesWhenPongsStopAndLivesWhenTheyCome() async throws {
        var timeouts = PSNVector.fastTimeouts()
        timeouts.pongDeadline = 0.3
        let silent = try LoopbackWebSocketServer(answerPings: false)
        let silentPort = try await silent.start()
        defer { silent.stop() }
        let dead = try await PSNPushChannel.open(
            url: URL(string: "ws://127.0.0.1:\(silentPort)/np/pushNotification")!, accessToken: PSNVector.token,
            socket: URLSessionPSNWebSocket(), timeouts: timeouts)
        let outcome = OSAllocatedUnfairLock<PSNError?>(initialState: nil)
        let finished = await finishes(within: 10) {
            do { _ = try await dead.inbox.take(step: .waitOffer, timeout: nil) { _ in false } } catch {
                outcome.withLock { $0 = error as? PSNError }
            }
        }
        #expect(finished)
        #expect(outcome.withLock { $0 } == .pushChannelNotResponding)

        let lively = try LoopbackWebSocketServer()
        let livelyPort = try await lively.start()
        defer { lively.stop() }
        let alive = try await PSNPushChannel.open(
            url: URL(string: "ws://127.0.0.1:\(livelyPort)/np/pushNotification")!, accessToken: PSNVector.token,
            socket: URLSessionPSNWebSocket(), timeouts: timeouts)
        #expect(await eventually { lively.seen.pings.count >= 3 })
        #expect(await alive.isOpen)
        await alive.close()
        await dead.close()
    }

    // MARK: 7. The notification buffer is bounded

    @Test func theBufferDropsTheOldestNotifications() async throws {
        let inbox = PSNInbox(capacity: 3)
        for index in 0..<5 { await inbox.push(.customDataUpdated(customData1: "\(index)")) }
        var seen: [PSNNotification] = []
        for _ in 0..<3 { seen.append(try await inbox.take(step: .waitCustomData, timeout: 1) { _ in true }) }
        #expect(seen == (2..<5).map { .customDataUpdated(customData1: "\($0)") })
        await #expect(throws: PSNError.timedOut(step: .waitCustomData)) {
            _ = try await inbox.take(step: .waitCustomData, timeout: 0.05) { _ in true }
        }
    }

    // MARK: 8. Concurrent leave() calls share one result

    @Test func overlappingLeavesAwaitTheFirst() async throws {
        let (psn, session) = try await PSNSessionTests.started()
        async let first = session.leave()
        async let second = session.leave()
        let results = await [first, second]
        #expect(results == [PSNLeaveResult(deleteSucceeded: true, deletionConfirmed: true)] * 2)
        #expect(psn.requests(containing: "/members/me").count == 1)
    }

    // MARK: Suggestions

    @Test func theDeletionBeforeBindingIsNotLost() async {
        let inbox = PSNInbox()
        await inbox.push(.sessionDeleted(sessionID: PSNVector.sessionID))
        await inbox.push(.sessionDeleted(sessionID: "aaaaaaaa-1d3f-4e6a-9b7c-0d1e2f3a4b5c"))
        #expect(!(await inbox.isClosed))
        await inbox.bind(sessionID: PSNVector.sessionID)
        #expect(await inbox.isClosed)
        let deleted = try? await inbox.take(step: .waitDeletion, timeout: 1) { _ in true }
        #expect(deleted == .sessionDeleted(sessionID: PSNVector.sessionID))
        await #expect(throws: PSNError.sessionEnded) { _ = try await inbox.take(step: .waitDeletion, timeout: 1) { _ in true } }
    }

    @Test func terminateWithoutAConnRequestIsTerminated() async throws {
        let message = try PSNMessage.decode(payload: #"body={"action":"TERMINATE","reqId":4,"error":2}"#)
        #expect(message == PSNMessage(action: .terminate, reqID: 4, error: 2, connRequest: nil))
        let (psn, session) = try await PSNSessionTests.started()
        psn.socket.emit(.text(PSNVector.messageFrame(#"{"action":"TERMINATE","reqId":4,"error":2}"#)))
        await #expect(throws: PSNError.terminated) { _ = try await session.exchangeOffers(candidates: []) }
        await session.leave()
    }

    @Test func theTokenNeverShowsInPrintedOrDumpedValues() {
        let request = PSNHTTPRequest(
            method: "GET", url: URL(string: "https://web.np.playstation.com/x")!,
            headers: ["Authorization": "Bearer \(PSNVector.token)", "Accept-Language": "jp"], timeout: 1)
        let client = PSNClient(accessToken: PSNVector.token, transport: FakePSN())
        var dumped = ""
        for value in [request, client] as [Any] {
            dump(value, to: &dumped)
            dumped += "\(value) \(String(describing: value)) \(String(reflecting: value))"
        }
        #expect(!dumped.contains(PSNVector.token))
        #expect(dumped.contains("Accept-Language"))
        #expect(request.description.contains("GET https://web.np.playstation.com/x"))
        // The request itself is unchanged.
        #expect(request.headers["Authorization"] == "Bearer TOKEN-MADE-UP")
    }

    @Test func theDefaultTransportSessionIsPrivateAndUncached() {
        let configuration = URLSessionPSNTransport.makeSession().configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.urlCredentialStorage == nil)
    }

    @Test func leaveSkipsAnotherSessionsDeletion() async throws {
        let (_, other) = try await PSNSessionTests.started {
            $0.afterLeave = [PSNVector.sessionDeletedFrame("aaaaaaaa-1d3f-4e6a-9b7c-0d1e2f3a4b5c")]
        }
        #expect(await other.leave() == PSNLeaveResult(deleteSucceeded: true, deletionConfirmed: false))
        let (_, own) = try await PSNSessionTests.started {
            $0.afterLeave = [PSNVector.sessionDeletedFrame("aaaaaaaa-1d3f-4e6a-9b7c-0d1e2f3a4b5c"), PSNVector.sessionDeletedFrame()]
        }
        #expect(await own.leave().deletionConfirmed)
    }
}

func * <T>(lhs: [T], rhs: Int) -> [T] { Array([[T]](repeating: lhs, count: rhs).joined()) }
