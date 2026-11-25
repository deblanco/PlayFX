import Foundation
import Security

/// The values the client makes once per PSN session (psn.md section 3, holepunch.md section 1).
public struct PSNSessionParameters: Sendable, Equatable {
    /// A UUID v4, lowercase, 36 characters (psn.md section 3.3).
    public let pushContextID: String
    /// 16 random bytes sent to the console in the start command (psn.md section 3.4).
    public let data1: [UInt8]
    public let data2: [UInt8]
    /// The client's sid in every message of both holes (16-bit).
    public let localSid: UInt16
    /// 20 random bytes, sent base64 in every OFFER (holepunch.md section 1).
    public let localHashedID: [UInt8]

    /// - Throws: `PSNError.invalidParameter` when a size is wrong.
    public init(pushContextID: String, data1: [UInt8], data2: [UInt8], localSid: UInt16, localHashedID: [UInt8]) throws
    {
        guard pushContextID.count == 36 else { throw PSNError.invalidParameter(reason: "pushContextID") }
        guard data1.count == 16 else { throw PSNError.invalidParameter(reason: "data1") }
        guard data2.count == 16 else { throw PSNError.invalidParameter(reason: "data2") }
        guard localHashedID.count == 20 else { throw PSNError.invalidParameter(reason: "localHashedID") }
        self.pushContextID = pushContextID
        self.data1 = data1
        self.data2 = data2
        self.localSid = localSid
        self.localHashedID = localHashedID
    }

    /// Fresh random values from the system's secure random generator.
    public static func random() -> PSNSessionParameters {
        func bytes(_ count: Int) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: count)
            if SecRandomCopyBytes(kSecRandomDefault, count, &out) != errSecSuccess {
                for index in out.indices { out[index] = UInt8.random(in: .min ... .max) }
            }
            return out
        }
        let sid = bytes(2)
        // The sizes are fixed above, so the initialiser can't fail.
        return (try? PSNSessionParameters(
            pushContextID: UUID().uuidString.lowercased(), data1: bytes(16), data2: bytes(16),
            localSid: UInt16(sid[0]) << 8 | UInt16(sid[1]), localHashedID: bytes(20)))!
    }
}

/// Which console to start (psn.md section 6.3 and 6.4).
public enum PSNStartTarget: Sendable, Equatable {
    /// A PS5 from the device list; its DUID must be the one that joins.
    case ps5(duid: String)
    /// The account's primary PS4; its DUID is learned from the join notification.
    case ps4
}

/// The console once it has joined and sent its data (psn.md section 6.3 step 1 and 2).
public struct PSNStartedConsole: Sendable, Equatable {
    public let duid: String
    public let platform: PSNPlatform
    /// The 16-byte `customData1` (`CD` of rpcrypt.md section 7).
    public let customData1: [UInt8]
}

/// A console message handed to the caller: its `reqId` and `connRequest`.
public struct PSNReceivedMessage: Sendable, Equatable {
    public let reqID: Int
    public let request: PSNConnRequest
}

/// What `leave()` managed.
public struct PSNLeaveResult: Sendable, Equatable {
    /// The DELETE was answered below 400 (a failed DELETE is ignored, psn.md section 8).
    public let deleteSucceeded: Bool
    /// A members-deleted or session-deleted notification came within the wait.
    public let deletionConfirmed: Bool
}

/// A remote-play session on PSN's session manager (psn.md sections 6 to 8): create it with the push channel
/// open, start the console, run the signalling of each hole, leave. Calls must not overlap. After a failed
/// `start`, `exchangeOffers` or `accept`, call `leave()`.
public actor PSNRemotePlaySession {
    /// The 36-character session ID.
    public nonisolated let sessionID: String
    /// The user's account ID from PSN's answer.
    public nonisolated let accountID: UInt64
    public nonisolated let parameters: PSNSessionParameters
    /// The user's online ID from the `created` notification (needed for a PS4).
    public private(set) var onlineID: String?
    /// Set by a successful `start`.
    public private(set) var console: PSNStartedConsole?

    static let maxBackgroundResults = 32
    private let client: PSNClient
    private let channel: PSNPushChannel
    /// The console's sid, its low 16 bits only (psn.md section 7.3).
    private var consoleSid = 0
    /// The console's sid as it was before the current hole's OFFER: the `peerSid` of the client's OFFER.
    private var pendingPeerSid = 0
    private var holesStarted = 0
    private var lastOfferReqID = 0
    /// True from the first console OFFER of a hole until it's established, and for good after the data hole's.
    private var offerSeen = false
    private var backgroundResults = 0
    private var leaving = false
    private var leaveTask: Task<PSNLeaveResult, Never>?
    private var responder: Task<Void, Never>?

    private init(client: PSNClient, channel: PSNPushChannel, created: PSNClient.CreatedSession, parameters: PSNSessionParameters) {
        self.client = client
        self.channel = channel
        self.sessionID = created.sessionID
        self.accountID = created.accountID
        self.parameters = parameters
    }

    /// Creates the session (psn.md section 6.1) and waits for its `created` notification and the client's own
    /// `members:created`. On failure after the session exists it is left again. Takes ownership of `channel`:
    /// it is closed on failure and by `leave()`.
    public static func create(client: PSNClient, channel: PSNPushChannel, parameters: PSNSessionParameters)
        async throws -> PSNRemotePlaySession
    {
        let created: PSNClient.CreatedSession
        do {
            created = try await client.createSession(pushContextID: parameters.pushContextID)
        } catch {
            await channel.close()
            throw error
        }
        let session = PSNRemotePlaySession(client: client, channel: channel, created: created, parameters: parameters)
        await channel.inbox.bind(sessionID: created.sessionID)
        do {
            try await session.awaitCreation()
        } catch {
            _ = await session.leave()
            throw error
        }
        return session
    }

    private func awaitCreation() async throws {
        let wait = client.timeouts.notification
        let created = try await channel.inbox.take(step: .waitSessionCreated, timeout: wait) {
            if case .sessionCreated = $0 { return true }
            return false
        }
        if case .sessionCreated(let id) = created { onlineID = id }
        _ = try await channel.inbox.take(step: .waitMemberJoined, timeout: wait) {
            if case .memberJoined = $0 { return true }
            return false
        }
    }

    /// Reads the session back (psn.md section 6.2). Optional; the answer is returned raw and nothing uses it.
    public func inspect(withView: Bool = true) async throws -> Data {
        try await client.inspectSession(sessionID: sessionID, withView: withView)
    }

    // MARK: Start

    /// Asks the console to join (PS5 start command or PS4 wake) and waits for its member notification and
    /// `customData1` (psn.md section 6.3 and 6.4). No join within the wait is `PSNError.consoleUnreachable`.
    public func start(_ target: PSNStartTarget) async throws -> PSNStartedConsole {
        let platform: PSNPlatform
        switch target {
        case .ps5(let duid):
            platform = .ps5
            guard let expected = decodeHex(Array(duid.utf8)), expected.count == 32 else {
                throw PSNError.invalidParameter(reason: "duid")
            }
            try await client.startPS5(
                consoleDUID: encodeHex(expected), accountID: accountID, sessionID: sessionID, data1: parameters.data1,
                data2: parameters.data2)
        case .ps4:
            platform = .ps4
            guard let onlineID else { throw PSNError.invalidState(reason: "no online ID for the PS4 wake") }
            try await client.wakePS4(
                onlineID: onlineID, sessionID: sessionID, data1: parameters.data1, data2: parameters.data2)
        }

        let wait = client.timeouts.notification
        // Only a well-formed device ID counts as a member joining; anything else is skipped (psn.md section 6.3).
        let joined = try await consoleWait(.waitMemberJoined, wait) {
            if case .memberJoined(let id?) = $0 { return decodeHex(Array(id.utf8))?.count == 32 }
            return false
        }
        guard case .memberJoined(let reported?) = joined, let reportedBytes = decodeHex(Array(reported.utf8)) else {
            throw PSNError.invalidResponse(step: .waitMemberJoined, reason: "deviceUniqueId")
        }
        if case .ps5(let duid) = target, decodeHex(Array(duid.utf8)) != reportedBytes { throw PSNError.consoleMismatch }

        // A value that isn't 32 characters isn't the console's data (psn.md section 6.3): keep waiting.
        let data = try await consoleWait(.waitCustomData, wait) {
            if case .customDataUpdated(let text) = $0 { return text?.count == 32 }
            return false
        }
        guard case .customDataUpdated(let text?) = data else { throw PSNError.invalidCustomData }
        let started = PSNStartedConsole(
            duid: encodeHex(reportedBytes), platform: platform, customData1: try PSNCustomData.decode(text))
        console = started
        return started
    }

    private func consoleWait(
        _ step: PSNStep, _ seconds: TimeInterval, matching: @escaping @Sendable (PSNNotification) -> Bool
    ) async throws -> PSNNotification {
        do {
            return try await channel.inbox.take(step: step, timeout: seconds, matching: matching)
        } catch PSNError.timedOut {
            throw PSNError.consoleUnreachable
        }
    }

    // MARK: Signalling (sections 7.5 and 7.6)

    /// One hole's OFFER exchange: waits for the console's OFFER, answers it with a RESULT, sends the client's
    /// OFFER with `candidates` and waits for the RESULT of its `reqId`. Returns the console's OFFER (its sid,
    /// hashed ID and candidates). Call it once for the ctrl hole and once for the data hole; the client's
    /// `reqId`s follow the reference's numbering (2, 3 for the ctrl hole's OFFER and ACCEPT, 5, 6 for the data
    /// hole's).
    public func exchangeOffers(candidates: [PSNCandidate]) async throws -> PSNReceivedMessage {
        let received = try await receiveOffer()
        try await sendOffer(candidates: candidates)
        return received
    }

    /// The first half of `exchangeOffers`: waits for the console's OFFER for this hole and answers it with a
    /// RESULT. The caller then builds its candidates (they need the socket's own address) and calls `sendOffer`.
    public func receiveOffer() async throws -> PSNReceivedMessage {
        await stopResponder()
        defer { startResponderIfNeeded() }
        pendingPeerSid = consoleSid
        let offer = try await awaitMessage(.waitOffer) { $0.action == .offer }
        guard let request = offer.connRequest else {
            throw PSNError.invalidMessage(reason: "OFFER without connRequest")
        }
        offerSeen = true
        consoleSid = request.sid & 0xffff
        try await send(PSNMessage(action: .result, reqID: offer.reqID, connRequest: nil))
        return PSNReceivedMessage(reqID: offer.reqID, request: request)
    }

    /// The second half: sends the client's OFFER and waits for the console's RESULT for its `reqId`.
    public func sendOffer(candidates: [PSNCandidate]) async throws {
        await stopResponder()
        defer { startResponderIfNeeded() }
        lastOfferReqID = 2 + 3 * holesStarted
        holesStarted += 1
        let mine = PSNConnRequest(
            sid: Int(parameters.localSid), peerSid: pendingPeerSid, natType: 2, candidates: candidates,
            localPeerAddress: localPeerAddress(), localHashedID: parameters.localHashedID)
        try await send(PSNMessage(action: .offer, reqID: lastOfferReqID, connRequest: mine))
        let expected = lastOfferReqID
        _ = try await awaitMessage(.waitResult) { $0.action == .result && $0.reqID == expected }
    }

    /// Ends a hole's exchange: sends the ACCEPT carrying `selected` (see `PSNCandidate.accepting`), waits for the
    /// console's ACCEPT and answers it with a RESULT. Returns the console's ACCEPT.
    public func accept(selected: PSNCandidate) async throws -> PSNReceivedMessage {
        try await sendAccept(selected: selected)
        return try await receiveAccept()
    }

    /// The first half of `accept`: sends the client's ACCEPT. The hole punch sends it as soon as a pair is selected.
    public func sendAccept(selected: PSNCandidate) async throws {
        await stopResponder()
        defer { startResponderIfNeeded() }
        guard lastOfferReqID > 0 else { throw PSNError.invalidState(reason: "accept before exchangeOffers") }
        let mine = PSNConnRequest(
            sid: Int(parameters.localSid), peerSid: consoleSid, natType: 0, candidates: [selected],
            localPeerAddress: localPeerAddress(), localHashedID: [])
        try await send(PSNMessage(action: .accept, reqID: lastOfferReqID + 1, connRequest: mine))
    }

    /// The second half: waits for the console's ACCEPT and answers it with a RESULT.
    public func receiveAccept() async throws -> PSNReceivedMessage {
        await stopResponder()
        defer { startResponderIfNeeded() }
        let theirs = try await awaitMessage(.waitAccept) { $0.action == .accept }
        guard let request = theirs.connRequest else {
            throw PSNError.invalidMessage(reason: "ACCEPT without connRequest")
        }
        consoleSid = request.sid & 0xffff
        try await send(PSNMessage(action: .result, reqID: theirs.reqID, connRequest: nil))
        // The first hole is done; the next console OFFER is the data hole's. After the data hole's, retransmitted
        // OFFERs are answered for the rest of the session.
        if holesStarted == 1 { offerSeen = false }
        return PSNReceivedMessage(reqID: theirs.reqID, request: request)
    }

    private func localPeerAddress() -> PSNPeerAddress {
        PSNPeerAddress(accountID: String(accountID), platform: "REMOTE_PLAY")
    }

    private func send(_ message: PSNMessage) async throws {
        guard let console else { throw PSNError.invalidState(reason: "console not started") }
        try await client.sendMessage(
            message, sessionID: sessionID, accountID: accountID, consoleDUID: console.duid, platform: console.platform)
    }

    /// The first console message `wanted` accepts. Other actions are dropped; `TERMINATE` ends the wait;
    /// further OFFERs of a hole already seen get a RESULT. The limit covers the whole wait.
    private func awaitMessage(_ step: PSNStep, wanted: (PSNMessage) -> Bool) async throws -> PSNMessage {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(client.timeouts.notification)
        while true {
            let remaining = max(0, (deadline - clock.now) / .seconds(1))
            let notification = try await channel.inbox.take(step: step, timeout: remaining) {
                if case .sessionMessage(let payload) = $0 { return payload != nil }
                return false
            }
            guard case .sessionMessage(let payload?) = notification else { continue }
            let message = try PSNMessage.decode(payload: payload)
            if message.action == .terminate { throw PSNError.terminated }
            if wanted(message) { return message }
            if message.action == .offer && offerSeen {
                try await send(PSNMessage(action: .result, reqID: message.reqID, connRequest: nil))
            }
        }
    }

    // MARK: Retransmitted OFFERs between the calls (section 7.6)

    private static let isOffer: @Sendable (PSNNotification) -> Bool = {
        guard case .sessionMessage(let payload?) = $0, let message = try? PSNMessage.decode(payload: payload) else {
            return false
        }
        return message.action == .offer
    }

    /// Answers the console's repeated OFFERs with a RESULT while no call is running: during the probes, and for
    /// the rest of the session once the data hole's OFFER is in. A hole's first OFFER is never taken here
    /// (`offerSeen` is false until the call waiting for it has it). At most `maxBackgroundResults` answers.
    private func startResponderIfNeeded() {
        guard offerSeen, responder == nil, !leaving, backgroundResults < Self.maxBackgroundResults else { return }
        responder = Task { await self.respondToRetransmissions() }
    }

    private func respondToRetransmissions() async {
        while !Task.isCancelled, backgroundResults < Self.maxBackgroundResults {
            guard let notification = try? await channel.inbox.take(step: .waitOffer, timeout: nil, matching: Self.isOffer),
                case .sessionMessage(let payload?) = notification,
                let message = try? PSNMessage.decode(payload: payload)
            else { return }
            backgroundResults += 1
            try? await send(PSNMessage(action: .result, reqID: message.reqID, connRequest: nil))
        }
    }

    private func stopResponder() async {
        let running = responder
        responder = nil
        running?.cancel()
        await running?.value
    }

    // MARK: Leave (section 8)

    /// Leaves the session: DELETE, a wait of up to 3 s for the deletion notification, then closes the push
    /// channel. A failed DELETE is ignored. It runs in a task of its own, so cancelling the caller (or `create`
    /// failing because it was cancelled) can't skip the DELETE and leave the session behind on PSN. Calls
    /// that overlap, or come later, share the first call's result.
    @discardableResult
    public func leave() async -> PSNLeaveResult {
        if let leaveTask { return await leaveTask.value }
        leaving = true
        let task = Task { await self.performLeave() }
        leaveTask = task
        return await task.value
    }

    private func performLeave() async -> PSNLeaveResult {
        await stopResponder()
        var deleted = false
        do {
            try await client.leaveSession(sessionID: sessionID)
            deleted = true
        } catch {}
        let id = sessionID
        let notification = try? await channel.inbox.take(step: .waitDeletion, timeout: client.timeouts.deletion) {
            switch $0 {
            case .memberLeft: return true
            case .sessionDeleted(let deleted): return deleted == nil || deleted == id
            default: return false
            }
        }
        await channel.close()
        return PSNLeaveResult(deleteSucceeded: deleted, deletionConfirmed: notification != nil)
    }
}
