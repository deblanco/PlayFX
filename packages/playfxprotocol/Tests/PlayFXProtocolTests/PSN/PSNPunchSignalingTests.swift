import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

/// The adapter between the hole punch and the PSN session (psn.md section 7, holepunch.md sections 4.5 and 6).
@Suite struct PSNPunchSignalingTests {
    static func offerText(sid: Int, peerSid: Int = 0, candidates: String? = nil) -> String {
        let list = candidates ?? #"{"type":"STATIC","addr":"198.51.100.7","mappedAddr":"0.0.0.0","port":50123,"mappedPort":0},{"type":"LOCAL","addr":"192.168.0.30","mappedAddr":"0.0.0.0","port":9303,"mappedPort":0}"#
        return #"{"action":"OFFER","reqId":1,"error":0,"connRequest":{"sid":\#(sid),"peerSid":\#(peerSid),"skey":"AAAAAAAAAAAAAAAAAAAAAA==","natType":2,"candidate":[\#(list)],"defaultRouteMacAddr":"","localPeerAddr":,"localHashedId":"\#(PSNVector.consoleHashedIDBase64)"}}"#
    }

    static func adapter(_ configure: (inout FakePSN.Script) -> Void = { _ in }) async throws
        -> (FakePSN, PSNRemotePlaySession, PSNPunchSignaling)
    {
        let (psn, session) = try await PSNSessionTests.started(configure)
        return (psn, session, PSNPunchSignaling(session: session))
    }

    @Test func theConsolesOfferKeepsTheLow16BitsOfItsSid() async throws {
        let (_, session, signaling) = try await Self.adapter {
            $0.afterStart = [PSNVector.memberFrame(), PSNVector.customDataFrame(), PSNVector.messageFrame(Self.offerText(sid: 0x1_abcd, peerSid: 7))]
        }
        let offer = try await runBlocking { try signaling.receiveConsoleOffer(timeout: 5) }
        #expect(offer.sid == 0xabcd && offer.peerSid == 7)
        #expect(offer.hashedID == hex("a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3"))
        #expect(offer.candidates == [
            PunchCandidate(type: .staticAddress, address: "198.51.100.7", port: 50123),
            PunchCandidate(type: .local, address: "192.168.0.30", port: 9303),
        ])
        await session.leave()
    }

    @Test func theClientsOfferAndAcceptAreTheSpecsMessages() async throws {
        let (psn, session, signaling) = try await Self.adapter {
            PSNSessionTests.cooperativeConsole(&$0)
            $0.afterStart = [PSNVector.memberFrame(), PSNVector.customDataFrame(), PSNVector.messageFrame(Self.offerText(sid: 43981))]
        }
        _ = try await runBlocking { try signaling.receiveConsoleOffer(timeout: 5) }
        // No LAN address: the LOCAL candidate goes out with an empty address (holepunch.md section 4.1).
        let candidates = [
            PunchCandidate(type: .stun, address: "203.0.113.5", port: 40006),
            PunchCandidate(type: .staticAddress, address: "203.0.113.5", port: 50123),
            PunchCandidate(type: .local, address: "", port: 50123),
        ]
        let offer = PunchOffer(sid: 4660, peerSid: 0, hashedID: PSNVector.localHashedID, candidates: candidates)
        try await runBlocking { try signaling.sendOffer(offer, timeout: 5) }
        let accepted = PunchCandidate(
            type: .staticAddress, address: "198.51.100.7", port: 50123, mappedAddress: "203.0.113.5", mappedPort: 40006)
        try await runBlocking { try signaling.sendAccept(PunchAccept(sid: 4660, peerSid: 43981, candidate: accepted)) }
        let theirs = try await runBlocking { try signaling.receiveConsoleAccept(timeout: 5) }
        #expect(theirs.sid == 43981 && theirs.candidate.address == "203.0.113.5")

        let posted = PSNSessionTests.posted(psn)
        let sentOffer = try #require(posted.first { $0.action == .offer }?.connRequest)
        #expect(sentOffer.natType == 2 && sentOffer.skey == [UInt8](repeating: 0, count: 16))
        #expect(sentOffer.localPeerAddress == PSNPeerAddress(accountID: String(PSNVector.accountID), platform: "REMOTE_PLAY"))
        #expect(sentOffer.localHashedID == PSNVector.localHashedID && sentOffer.defaultRouteMACAddress == "")
        #expect(sentOffer.candidates.map(\.address) == ["203.0.113.5", "203.0.113.5", ""])
        #expect(sentOffer.candidates.map(\.type) == [.stun, .staticAddress, .local])
        let sentAccept = try #require(posted.first { $0.action == .accept }?.connRequest)
        #expect(sentAccept.natType == 0 && sentAccept.localHashedID.isEmpty && sentAccept.peerSid == 43981)
        #expect(sentAccept.candidates == [PSNCandidate(
            type: .staticAddress, address: "198.51.100.7", mappedAddress: "203.0.113.5", port: 50123, mappedPort: 40006)])
        await session.leave()
    }

    /// psn.md section 7.3: only the low 16 bits of the console's sid are kept, and that is what goes back as `peerSid`.
    @Test func thePeerSidWeSendIsTheConsolesSidTruncatedTo16Bits() async throws {
        let (psn, session, signaling) = try await Self.adapter {
            PSNSessionTests.cooperativeConsole(&$0)
            $0.afterStart = [PSNVector.memberFrame(), PSNVector.customDataFrame(), PSNVector.messageFrame(Self.offerText(sid: 0x1_abcd))]
        }
        _ = try await runBlocking { try signaling.receiveConsoleOffer(timeout: 5) }
        try await runBlocking {
            try signaling.sendOffer(PunchOffer(sid: 4660, peerSid: 0, hashedID: PSNVector.localHashedID, candidates: []), timeout: 5)
        }
        try await runBlocking {
            try signaling.sendAccept(PunchAccept(sid: 4660, peerSid: 0xabcd, candidate: PunchCandidate(type: .local, address: "", port: 1)))
        }
        let accept = try #require(PSNSessionTests.posted(psn).first { $0.action == .accept }?.connRequest)
        #expect(accept.peerSid == 0xabcd)
        await session.leave()
    }

    @Test func aConsoleAcceptWithoutACandidateIsNoFailure() async throws {
        let accept = #"{"action":"ACCEPT","reqId":7,"error":0,"connRequest":{"sid":1,"peerSid":2,"skey":"AAAAAAAAAAAAAAAAAAAAAA==","natType":0,"candidate":[],"defaultRouteMacAddr":"","localPeerAddr":,"localHashedId":""}}"#
        let (_, session, signaling) = try await Self.adapter {
            $0.afterStart = [PSNVector.memberFrame(), PSNVector.customDataFrame(), PSNVector.messageFrame(Self.offerText(sid: 1))]
            $0.onMessage = { message in
                switch message.action {
                case .offer: [PSNVector.consoleResultText(reqID: message.reqID)]
                case .accept: [accept]
                default: []
                }
            }
        }
        _ = try await runBlocking { try signaling.receiveConsoleOffer(timeout: 5) }
        try await runBlocking {
            try signaling.sendOffer(PunchOffer(sid: 4660, peerSid: 0, hashedID: PSNVector.localHashedID, candidates: []), timeout: 5)
        }
        try await runBlocking {
            try signaling.sendAccept(PunchAccept(sid: 4660, peerSid: 1, candidate: PunchCandidate(type: .local, address: "", port: 1)))
        }
        let theirs = try await runBlocking { try signaling.receiveConsoleAccept(timeout: 5) }
        #expect(theirs.sid == 1 && theirs.peerSid == 2 && theirs.candidate.port == 0)
        await session.leave()
    }

    @Test func aPSNFailureIsKeptAndTheHolePunchSeesASignalingFailure() async throws {
        let (_, session, signaling) = try await Self.adapter()
        // No OFFER arrives: the wait times out (0.6 s in these tests).
        do {
            _ = try await runBlocking { try signaling.receiveConsoleOffer(timeout: 0.1) }
            Issue.record("should have failed")
        } catch let error as PunchError {
            #expect(error == .signalingFailed("timedOut(step: PlayFXProtocol.PSNStep.waitOffer)"))
        }
        #expect(signaling.failure == .timedOut(step: .waitOffer))
        await session.leave()
    }

    @Test func aTerminateFromTheConsoleIsAFailure() async throws {
        let terminate = #"{"action":"TERMINATE","reqId":3,"error":0,"connRequest":{}}"#
        let (_, session, signaling) = try await Self.adapter {
            $0.afterStart = [PSNVector.memberFrame(), PSNVector.customDataFrame(), PSNVector.messageFrame(terminate)]
        }
        await #expect(throws: PunchError.self) { try await runBlocking { try signaling.receiveConsoleOffer(timeout: 5) } }
        #expect(signaling.failure == .terminated)
        await session.leave()
    }

    @Test func cancellingEndsTheCallInProgressAndEveryLaterOne() async throws {
        let (_, session, signaling) = try await Self.adapter()
        let waiting = Task { try await runBlocking { try signaling.receiveConsoleOffer(timeout: 30) } }
        try await Task.sleep(nanoseconds: 100_000_000)
        signaling.cancel()
        do {
            _ = try await waiting.value
            Issue.record("should have failed")
        } catch {
            #expect(error as? PunchError == .cancelled)
        }
        await #expect(throws: PunchError.cancelled) { try await runBlocking { try signaling.receiveConsoleAccept(timeout: 5) } }
        #expect(signaling.failure == nil)
        await session.leave()
    }
}
