import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

@Suite struct PSNSessionTests {
    static func setUp(
        _ configure: (inout FakePSN.Script) -> Void = { _ in }, timeouts: PSNTimeouts = PSNVector.fastTimeouts()
    ) async throws -> (FakePSN, PSNClient, PSNPushChannel) {
        let psn = FakePSN()
        var script = psn.script
        configure(&script)
        psn.script = script
        let client = PSNClient(accessToken: PSNVector.token, transport: psn, timeouts: timeouts)
        let channel = try await client.openPushChannel(socket: psn.socket)
        return (psn, client, channel)
    }

    static func started(
        _ configure: (inout FakePSN.Script) -> Void = { _ in }
    ) async throws -> (FakePSN, PSNRemotePlaySession) {
        var timeouts = PSNVector.fastTimeouts()
        timeouts.pingInterval = 60
        let (psn, client, channel) = try await setUp(configure, timeouts: timeouts)
        let session = try await PSNRemotePlaySession.create(
            client: client, channel: channel, parameters: try PSNVector.parameters())
        _ = try await session.start(.ps5(duid: PSNVector.duid))
        return (psn, session)
    }

    /// The message JSON the client posted, in order.
    static func posted(_ psn: FakePSN) -> [PSNMessage] {
        psn.requests(containing: "/sessionMessage").compactMap {
            guard let payload = PSNJSON.object($0.body ?? Data())?["payload"] as? String else { return nil }
            return try? PSNMessage.decode(payload: payload)
        }
    }

    /// A console that answers a client OFFER with a RESULT and a client ACCEPT with its own ACCEPT.
    static func cooperativeConsole(_ script: inout FakePSN.Script) {
        script.onMessage = { message in
            switch message.action {
            case .offer: return [PSNVector.consoleResultText(reqID: message.reqID)]
            case .accept: return [PSNVector.consoleAcceptText()]
            default: return []
            }
        }
    }

    // MARK: Create and start

    @Test func createAndStartPS5() async throws {
        let (psn, client, channel) = try await Self.setUp()
        let session = try await PSNRemotePlaySession.create(
            client: client, channel: channel, parameters: try PSNVector.parameters())
        #expect(session.sessionID == PSNVector.sessionID)
        #expect(session.accountID == PSNVector.accountID)
        #expect(await session.onlineID == "playfx-tester")
        #expect(await session.console == nil)

        let console = try await session.start(.ps5(duid: PSNVector.duid.uppercased()))
        #expect(console == PSNStartedConsole(duid: PSNVector.duid, platform: .ps5, customData1: PSNVector.customData1))
        #expect(await session.console == console)
        // The requests, in the order of psn.md section 8's picture.
        let calls = psn.requests.map { "\($0.method) \($0.url.path)" }
        #expect(
            calls == [
                "GET /np/serveraddr", "POST /api/sessionManager/v1/remotePlaySessions",
                "POST /api/cloudAssistedNavigation/v2/users/me/commands",
            ])
        #expect(psn.requests[1].bodyText == PSNVector.p1)
        #expect(psn.requests[2].bodyText == PSNVector.p2)
        _ = try await session.inspect()
        await session.leave()
    }

    @Test func startWorksWhenNotificationsArriveEarlyOrInTheOtherOrder() async throws {
        let (_, session) = try await Self.started {
            $0.afterCreate = [PSNVector.clientJoinedFrame, PSNVector.createdFrame]
            $0.afterStart = [PSNVector.customDataFrame(), PSNVector.memberFrame()]
        }
        #expect(await session.console?.customData1 == PSNVector.customData1)
        await session.leave()
    }

    @Test func ps5MismatchedDUIDFailsTheStart() async throws {
        let other = String(repeating: "ab", count: 32)
        let (_, client, channel) = try await Self.setUp { $0.afterStart = [PSNVector.memberFrame(other)] }
        let session = try await PSNRemotePlaySession.create(client: client, channel: channel, parameters: try PSNVector.parameters())
        await #expect(throws: PSNError.consoleMismatch) { _ = try await session.start(.ps5(duid: PSNVector.duid)) }
        await session.leave()
    }

    @Test func onlyMalformedMemberNotificationsLeaveTheConsoleUnreachable() async throws {
        for frame in [PSNVector.memberFrame("short"), PSNVector.memberFrame("zz" + String(repeating: "0", count: 62))] {
            let (_, client, channel) = try await Self.setUp { $0.afterStart = [frame] }
            let session = try await PSNRemotePlaySession.create(client: client, channel: channel, parameters: try PSNVector.parameters())
            await #expect(throws: PSNError.consoleUnreachable) { _ = try await session.start(.ps5(duid: PSNVector.duid)) }
            await session.leave()
        }
    }

    @Test func consoleThatNeverJoinsIsUnreachable() async throws {
        let (psn, client, channel) = try await Self.setUp { $0.afterStart = [] }
        let session = try await PSNRemotePlaySession.create(client: client, channel: channel, parameters: try PSNVector.parameters())
        await #expect(throws: PSNError.consoleUnreachable) { _ = try await session.start(.ps5(duid: PSNVector.duid)) }
        await session.leave()
        #expect(psn.requests(containing: "/members/me").count == 1)
    }

    @Test func joinWithoutCustomDataIsUnreachable() async throws {
        let (_, client, channel) = try await Self.setUp { $0.afterStart = [PSNVector.memberFrame()] }
        let session = try await PSNRemotePlaySession.create(client: client, channel: channel, parameters: try PSNVector.parameters())
        await #expect(throws: PSNError.consoleUnreachable) { _ = try await session.start(.ps5(duid: PSNVector.duid)) }
        await session.leave()
    }

    @Test func customDataOfTheWrongLengthIsSkipped() async throws {
        let (_, client, channel) = try await Self.setUp {
            $0.afterStart = [PSNVector.memberFrame(), PSNVector.customDataFrame("AAAA")]
        }
        let session = try await PSNRemotePlaySession.create(client: client, channel: channel, parameters: try PSNVector.parameters())
        await #expect(throws: PSNError.consoleUnreachable) { _ = try await session.start(.ps5(duid: PSNVector.duid)) }
        await session.leave()
    }

    @Test func undecodableCustomDataFails() async throws {
        let (_, client, channel) = try await Self.setUp {
            $0.afterStart = [PSNVector.memberFrame(), PSNVector.customDataFrame(String(repeating: "!", count: 32))]
        }
        let session = try await PSNRemotePlaySession.create(client: client, channel: channel, parameters: try PSNVector.parameters())
        await #expect(throws: PSNError.invalidCustomData) { _ = try await session.start(.ps5(duid: PSNVector.duid)) }
        await session.leave()
    }

    @Test func startCommandRefusedAndBadDUID() async throws {
        let (psn, client, channel) = try await Self.setUp { $0.startStatus = 403 }
        let session = try await PSNRemotePlaySession.create(client: client, channel: channel, parameters: try PSNVector.parameters())
        await #expect(throws: PSNError.unauthorized(step: .startCommand, status: 403)) {
            _ = try await session.start(.ps5(duid: PSNVector.duid))
        }
        await #expect(throws: PSNError.invalidParameter(reason: "duid")) { _ = try await session.start(.ps5(duid: "xyz")) }
        #expect(psn.requests(containing: "/commands").count == 1)
        await session.leave()
    }

    @Test func ps4WakeFlow() async throws {
        let (psn, client, channel) = try await Self.setUp()
        let session = try await PSNRemotePlaySession.create(client: client, channel: channel, parameters: try PSNVector.parameters())
        let console = try await session.start(.ps4)
        #expect(console.platform == .ps4)
        #expect(console.duid == PSNVector.duid)
        #expect(psn.requests(containing: "wakeUp?platform=PS4").first?.bodyText == PSNVector.p9)
        #expect(psn.requests(containing: "/commands").isEmpty)
        await session.leave()
    }

    @Test func ps4NeedsTheOnlineIDAndPrimaryConsole() async throws {
        let (_, client, channel) = try await Self.setUp {
            $0.afterCreate = [#"{"dataType":"psn:sessionManager:sys:remotePlaySession:created"}"#, PSNVector.clientJoinedFrame]
        }
        let session = try await PSNRemotePlaySession.create(client: client, channel: channel, parameters: try PSNVector.parameters())
        #expect(await session.onlineID == nil)
        await #expect(throws: PSNError.invalidState(reason: "no online ID for the PS4 wake")) { _ = try await session.start(.ps4) }
        await session.leave()

        let (_, client2, channel2) = try await Self.setUp { $0.ps4WakeStatus = 404 }
        let session2 = try await PSNRemotePlaySession.create(client: client2, channel: channel2, parameters: try PSNVector.parameters())
        await #expect(throws: PSNError.ps4NotPrimary) { _ = try await session2.start(.ps4) }
        await session2.leave()
    }

    // MARK: Create failures

    @Test func createRefusedClosesTheChannel() async throws {
        let (psn, client, channel) = try await Self.setUp { $0.createStatus = 401 }
        await #expect(throws: PSNError.unauthorized(step: .createSession, status: 401)) {
            _ = try await PSNRemotePlaySession.create(client: client, channel: channel, parameters: try PSNVector.parameters())
        }
        #expect(!(await channel.isOpen))
        #expect(psn.socket.closeCount == 1)
        #expect(psn.requests(containing: "/members/me").isEmpty)
    }

    @Test func createWithoutNotificationsLeavesTheSession() async throws {
        let (psn, client, channel) = try await Self.setUp { $0.afterCreate = [PSNVector.createdFrame] }
        await #expect(throws: PSNError.timedOut(step: .waitMemberJoined)) {
            _ = try await PSNRemotePlaySession.create(client: client, channel: channel, parameters: try PSNVector.parameters())
        }
        #expect(psn.requests(containing: "/members/me").count == 1)
        #expect(!(await channel.isOpen))

        let (psn2, client2, channel2) = try await Self.setUp { $0.afterCreate = [] }
        await #expect(throws: PSNError.timedOut(step: .waitSessionCreated)) {
            _ = try await PSNRemotePlaySession.create(client: client2, channel: channel2, parameters: try PSNVector.parameters())
        }
        #expect(psn2.requests(containing: "/members/me").count == 1)
    }

    @Test func createTimesOutWhenPSNHangs() async throws {
        let (_, _, channel) = try await Self.setUp()
        let hanging = FakePSN()
        hanging.script.hang = ["/remotePlaySessions"]
        let slow = PSNClient(accessToken: PSNVector.token, transport: hanging, timeouts: PSNVector.fastTimeouts())
        await #expect(throws: PSNError.timedOut(step: .createSession)) {
            _ = try await PSNRemotePlaySession.create(client: slow, channel: channel, parameters: try PSNVector.parameters())
        }
    }

    // MARK: Signalling (section 7.6, vectors P4 to P7)

    @Test func ctrlHoleExchange() async throws {
        let (psn, session) = try await Self.started(Self.cooperativeConsole)
        // The console's first OFFER can arrive before the client waits for it.
        psn.socket.emit(.text(PSNVector.messageFrame(PSNVector.consoleOfferText())))
        let offer = try await session.exchangeOffers(candidates: PSNCodecTests.candidates)
        #expect(offer.reqID == 1)
        #expect(offer.request.sid == 43981)
        #expect(offer.request.candidates.map(\.type) == [.staticAddress, .local])

        let selected = PSNCandidate.accepting(
            selected: offer.request.candidates[0], clientLocal: PSNCodecTests.candidates[2],
            clientFirstOffer: PSNCodecTests.candidates[0])
        let accept = try await session.accept(selected: selected)
        #expect(accept.reqID == 7)
        #expect(accept.request.candidates.first?.address == "203.0.113.5")

        // RESULT 1, OFFER 2 (P6), ACCEPT 3 (P7), RESULT 7: the bodies of the vectors, byte for byte.
        let bodies = psn.requests(containing: "/sessionMessage").map(\.bodyText)
        #expect(bodies.count == 4)
        #expect(bodies[0] == PSNVector.p5)
        #expect(bodies[1] == PSNVector.p6)
        #expect(bodies[2] == PSNVector.p7)
        #expect(bodies[3] == PSNVector.p5.replacingOccurrences(of: #"\"reqId\":1"#, with: #"\"reqId\":7"#))
        await session.leave()
    }

    @Test func dataHoleContinuesTheNumbering() async throws {
        let (psn, session) = try await Self.started(Self.cooperativeConsole)
        psn.socket.emit(.text(PSNVector.messageFrame(PSNVector.consoleOfferText())))
        _ = try await session.exchangeOffers(candidates: PSNCodecTests.candidates)
        let ctrlCandidate = PSNCandidate(type: .staticAddress, address: "198.51.100.7", mappedAddress: "203.0.113.5", port: 50123, mappedPort: 40006)
        _ = try await session.accept(selected: ctrlCandidate)

        // The data hole: the console's OFFER has another sid; the client's OFFER's peerSid is the ctrl hole's.
        psn.socket.emit(.text(PSNVector.messageFrame(PSNVector.consoleOfferText(reqID: 8, sid: 777))))
        _ = try await session.exchangeOffers(candidates: [PSNCandidate(type: .local, address: "192.168.1.20", port: 51000)])
        _ = try await session.accept(selected: ctrlCandidate)

        let sent = Self.posted(psn)
        #expect(sent.map(\.action) == [.result, .offer, .accept, .result, .result, .offer, .accept, .result])
        #expect(sent.map(\.reqID) == [1, 2, 3, 7, 8, 5, 6, 7])
        #expect(sent[1].connRequest?.peerSid == 0)
        #expect(sent[5].connRequest?.peerSid == 43981)
        #expect(sent[2].connRequest?.peerSid == 43981)
        #expect(sent[6].connRequest?.peerSid == 777)
        #expect(sent[5].connRequest?.sid == 4660)
        await session.leave()
    }

    @Test func retransmittedOffersGetAResultAndOtherMessagesAreDropped() async throws {
        let (psn, session) = try await Self.started { script in
            script.onMessage = { message in
                switch message.action {
                case .offer:
                    // Noise before the RESULT that counts: a retransmitted OFFER, a RESULT for another reqId and
                    // an ACCEPT (dropped: the client waits for a RESULT).
                    return [
                        PSNVector.consoleOfferText(reqID: 1), PSNVector.consoleResultText(reqID: 99),
                        PSNVector.consoleAcceptText(reqID: 50), PSNVector.consoleResultText(reqID: message.reqID),
                    ]
                case .accept:
                    return [PSNVector.consoleOfferText(reqID: 1), PSNVector.consoleResultText(reqID: 2), PSNVector.consoleAcceptText()]
                default: return []
                }
            }
        }
        psn.socket.emit(.text(PSNVector.messageFrame(PSNVector.consoleOfferText())))
        _ = try await session.exchangeOffers(candidates: PSNCodecTests.candidates)
        _ = try await session.accept(selected: PSNCodecTests.candidates[1])
        let sent = Self.posted(psn)
        // RESULT 1 (first OFFER), OFFER 2, RESULT 1 (the retransmission), ACCEPT 3, RESULT 1 (retransmission), RESULT 7.
        #expect(sent.map(\.action) == [.result, .offer, .result, .accept, .result, .result])
        #expect(sent.map(\.reqID) == [1, 2, 1, 3, 1, 7])
        await session.leave()
    }

    @Test func terminateEndsASignallingWait() async throws {
        let (psn, session) = try await Self.started { script in
            script.onMessage = { _ in [#"{"action":"TERMINATE","reqId":4,"error":1,"connRequest":{}}"#] }
        }
        psn.socket.emit(.text(PSNVector.messageFrame(PSNVector.consoleOfferText())))
        await #expect(throws: PSNError.terminated) { _ = try await session.exchangeOffers(candidates: PSNCodecTests.candidates) }
        await session.leave()
    }

    @Test func signallingTimeouts() async throws {
        let (psn, session) = try await Self.started()
        // No OFFER at all.
        await #expect(throws: PSNError.timedOut(step: .waitOffer)) { _ = try await session.exchangeOffers(candidates: []) }
        // An OFFER but no RESULT for ours.
        psn.socket.emit(.text(PSNVector.messageFrame(PSNVector.consoleOfferText())))
        await #expect(throws: PSNError.timedOut(step: .waitResult)) { _ = try await session.exchangeOffers(candidates: []) }
        // No console ACCEPT.
        await #expect(throws: PSNError.timedOut(step: .waitAccept)) { _ = try await session.accept(selected: PSNCodecTests.candidates[1]) }
        await session.leave()
    }

    @Test func signallingNeedsOrder() async throws {
        let (psn, client, channel) = try await Self.setUp()
        let session = try await PSNRemotePlaySession.create(client: client, channel: channel, parameters: try PSNVector.parameters())
        await #expect(throws: PSNError.invalidState(reason: "accept before exchangeOffers")) {
            _ = try await session.accept(selected: PSNCodecTests.candidates[1])
        }
        // An OFFER can't be answered before the console is known.
        psn.socket.emit(.text(PSNVector.messageFrame(PSNVector.consoleOfferText())))
        await #expect(throws: PSNError.invalidState(reason: "console not started")) {
            _ = try await session.exchangeOffers(candidates: [])
        }
        await session.leave()
    }

    @Test func garbageMessagesFailTheWait() async throws {
        let (psn, session) = try await Self.started()
        psn.socket.emit(.text(PSNVector.messageFrame("{broken")))
        do {
            _ = try await session.exchangeOffers(candidates: [])
            Issue.record("accepted garbage")
        } catch let PSNError.invalidMessage(reason) {
            #expect(reason == "not JSON")
        }
        // An OFFER without a connRequest object content, and a message notification with no payload, fail/skip.
        psn.socket.emit(.text(#"{"dataType":"psn:sessionManager:sys:rps:sessionMessage:created"}"#))
        psn.socket.emit(.text(PSNVector.messageFrame(#"{"action":"OFFER","reqId":1,"error":0,"connRequest":{}}"#)))
        await #expect(throws: PSNError.invalidMessage(reason: "OFFER without connRequest")) {
            _ = try await session.exchangeOffers(candidates: [])
        }
        await session.leave()
    }

    @Test func acceptWithoutConnRequestFails() async throws {
        let (psn, session) = try await Self.started { script in
            script.onMessage = { message in
                message.action == .offer
                    ? [PSNVector.consoleResultText(reqID: message.reqID)]
                    : [#"{"action":"ACCEPT","reqId":7,"error":0,"connRequest":{}}"#]
            }
        }
        psn.socket.emit(.text(PSNVector.messageFrame(PSNVector.consoleOfferText())))
        _ = try await session.exchangeOffers(candidates: [])
        await #expect(throws: PSNError.invalidMessage(reason: "ACCEPT without connRequest")) {
            _ = try await session.accept(selected: PSNCodecTests.candidates[1])
        }
        await session.leave()
    }

    @Test func messageRefusedByPSNFailsTheStep() async throws {
        let (psn, session) = try await Self.started { $0.messageStatus = 500 }
        psn.socket.emit(.text(PSNVector.messageFrame(PSNVector.consoleOfferText())))
        await #expect(throws: PSNError.httpStatus(step: .sessionMessage, status: 500)) {
            _ = try await session.exchangeOffers(candidates: [])
        }
        await session.leave()
    }

    @Test func channelLossAndSessionEndFailTheWait() async throws {
        let (psn, session) = try await Self.started()
        let waiting = Task { try await session.exchangeOffers(candidates: []) }
        psn.socket.emit(.text(PSNVector.sessionDeletedFrame()))
        await #expect(throws: PSNError.sessionEnded) { _ = try await waiting.value }
        let result = await session.leave()
        #expect(result.deleteSucceeded && result.deletionConfirmed)

        let (psn2, session2) = try await Self.started()
        let waiting2 = Task { try await session2.exchangeOffers(candidates: []) }
        psn2.socket.drop()
        await #expect(throws: PSNError.pushChannelClosed) { _ = try await waiting2.value }
        await session2.leave()
    }

    // MARK: Leave (section 8, vector P8)

    @Test func leaveSendsDeleteWaitsForConfirmationAndClosesTheSocket() async throws {
        let (psn, session) = try await Self.started()
        let result = await session.leave()
        #expect(result == PSNLeaveResult(deleteSucceeded: true, deletionConfirmed: true))
        let delete = try #require(psn.requests(containing: "/members/me").first)
        #expect(delete.method == "DELETE")
        #expect(delete.url.absoluteString == "https://web.np.playstation.com/api/sessionManager/v1/remotePlaySessions/\(PSNVector.sessionID)/members/me")
        #expect(psn.socket.closeCount == 1)
        // A second call does nothing.
        #expect(await session.leave() == result)
        #expect(psn.requests(containing: "/members/me").count == 1)
    }

    @Test func leaveIgnoresAFailedDeleteAndAMissingConfirmation() async throws {
        let (psn, session) = try await Self.started {
            $0.leaveStatus = 500
            $0.afterLeave = []
        }
        let result = await session.leave()
        #expect(result == PSNLeaveResult(deleteSucceeded: false, deletionConfirmed: false))
        #expect(psn.socket.closeCount == 1)
    }

    // MARK: No real network

    @Test func theWholeFlowOnlyTouchesTheFakes() async throws {
        let (psn, session) = try await Self.started(Self.cooperativeConsole)
        psn.socket.emit(.text(PSNVector.messageFrame(PSNVector.consoleOfferText())))
        _ = try await session.exchangeOffers(candidates: PSNCodecTests.candidates)
        await session.leave()
        #expect(psn.hosts == ["web.np.playstation.com", "mobile-pushcl.np.communication.playstation.net"])
        #expect(psn.socket.openedURL?.host == "push.example.test")
    }
}
