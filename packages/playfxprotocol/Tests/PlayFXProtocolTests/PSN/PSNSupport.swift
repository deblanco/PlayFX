import Foundation
import Testing
import os

@testable import PlayFXProtocol

// Test doubles and the vectors of psn.md section 12. Nothing here opens a socket to anything but loopback:
// HTTP goes through `FakePSN` (a `PSNTransport`), the push channel through `FakeWebSocket`.

enum PSNVector {
    static let token = "TOKEN-MADE-UP"
    static let pushContextID = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"
    static let sessionID = "2b5e4c0a-1d3f-4e6a-9b7c-0d1e2f3a4b5c"
    static let accountID: UInt64 = 1_234_567_890_123_456_789
    static let duid = "e0e1e2e3e4e5e6e7e8e9eaebecedeeefdfe0e1e2e3e4e5e6e7e8e9eaebecedee"
    static let data1 = (0x10...0x1f).map { UInt8($0) }
    static let data2 = (0x20...0x2f).map { UInt8($0) }
    static let localSid: UInt16 = 4660
    static let localHashedID = (0...19).map { UInt8($0) }
    static let customData1Text = "TURFeU16UTFOamM0T1RvN1BEMCtQdz09"
    static let customData1 = (0x30...0x3f).map { UInt8($0) }
    static let consoleHashedIDBase64 = "oKGio6SlpqeoqaqrrK2ur7CxsrM="

    static func parameters() throws -> PSNSessionParameters {
        try PSNSessionParameters(
            pushContextID: pushContextID, data1: data1, data2: data2, localSid: localSid,
            localHashedID: localHashedID)
    }

    static let p1 =
        #"{"remotePlaySessions":[{"members":[{"accountId":"me","deviceUniqueId":"me","platform":"me","pushContexts":[{"pushContextId":"9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"}]}]}]}"#
    static let p2 =
        #"{"commandDetail":{"commandType":"remotePlay","duid":"e0e1e2e3e4e5e6e7e8e9eaebecedeeefdfe0e1e2e3e4e5e6e7e8e9eaebecedee","messageDestination":"SQS","parameters":{"initialParams":"{\"accountId\":1234567890123456789,\"roomId\":0,\"sessionId\":\"2b5e4c0a-1d3f-4e6a-9b7c-0d1e2f3a4b5c\",\"clientType\":\"Windows\",\"data1\":\"EBESExQVFhcYGRobHB0eHw==\",\"data2\":\"ICEiIyQlJicoKSorLC0uLw==\"}"},"platform":"PS5"}}"#
    static let p5 =
        #"{"channel":"remote_play:1","payload":"ver=1.0, type=text, body={\"action\":\"RESULT\",\"reqId\":1,\"error\":0,\"connRequest\":{}}","to":[{"accountId":"1234567890123456789","deviceUniqueId":"e0e1e2e3e4e5e6e7e8e9eaebecedeeefdfe0e1e2e3e4e5e6e7e8e9eaebecedee","platform":"PS5"}]}"#
    static let p6 =
        #"{"channel":"remote_play:1","payload":"ver=1.0, type=text, body={\"action\":\"OFFER\",\"reqId\":2,\"error\":0,\"connRequest\":{\"sid\":4660,\"peerSid\":0,\"skey\":\"AAAAAAAAAAAAAAAAAAAAAA==\",\"natType\":2,\"candidate\":[{\"type\":\"STUN\",\"addr\":\"203.0.113.5\",\"mappedAddr\":\"0.0.0.0\",\"port\":40006,\"mappedPort\":0},{\"type\":\"STATIC\",\"addr\":\"203.0.113.5\",\"mappedAddr\":\"0.0.0.0\",\"port\":50123,\"mappedPort\":0},{\"type\":\"LOCAL\",\"addr\":\"192.168.1.20\",\"mappedAddr\":\"0.0.0.0\",\"port\":50123,\"mappedPort\":0}],\"defaultRouteMacAddr\":\"\",\"localPeerAddr\":{\"accountId\":\"1234567890123456789\",\"platform\":\"REMOTE_PLAY\"},\"localHashedId\":\"AAECAwQFBgcICQoLDA0ODxAREhM=\"}}","to":[{"accountId":"1234567890123456789","deviceUniqueId":"e0e1e2e3e4e5e6e7e8e9eaebecedeeefdfe0e1e2e3e4e5e6e7e8e9eaebecedee","platform":"PS5"}]}"#
    static let p7 =
        #"{"channel":"remote_play:1","payload":"ver=1.0, type=text, body={\"action\":\"ACCEPT\",\"reqId\":3,\"error\":0,\"connRequest\":{\"sid\":4660,\"peerSid\":43981,\"skey\":\"AAAAAAAAAAAAAAAAAAAAAA==\",\"natType\":0,\"candidate\":[{\"type\":\"STATIC\",\"addr\":\"198.51.100.7\",\"mappedAddr\":\"203.0.113.5\",\"port\":50123,\"mappedPort\":40006}],\"defaultRouteMacAddr\":\"\",\"localPeerAddr\":{\"accountId\":\"1234567890123456789\",\"platform\":\"REMOTE_PLAY\"},\"localHashedId\":\"\"}}","to":[{"accountId":"1234567890123456789","deviceUniqueId":"e0e1e2e3e4e5e6e7e8e9eaebecedeeefdfe0e1e2e3e4e5e6e7e8e9eaebecedee","platform":"PS5"}]}"#
    static let p9 =
        #"{"data":{"clientType":"Windows","data1":"EBESExQVFhcYGRobHB0eHw==","data2":"ICEiIyQlJicoKSorLC0uLw==","roomId": 0,"protocolVer":"10.0","sessionId":"2b5e4c0a-1d3f-4e6a-9b7c-0d1e2f3a4b5c"},"dataTypeSuffix":"remotePlay"}"#

    /// P4's console OFFER message text (after `body=`), with `localPeerAddr` missing its value.
    static func consoleOfferText(reqID: Int = 1, sid: Int = 43981) -> String {
        #"{"action":"OFFER","reqId":\#(reqID),"error":0,"connRequest":{"sid":\#(sid),"peerSid":0,"skey":"AAAAAAAAAAAAAAAAAAAAAA==","natType":2,"candidate":[{"type":"STATIC","addr":"198.51.100.7","mappedAddr":"0.0.0.0","port":50123,"mappedPort":0},{"type":"LOCAL","addr":"192.168.0.30","mappedAddr":"0.0.0.0","port":9303,"mappedPort":0}],"defaultRouteMacAddr":"0a:1b:2c:3d:4e:5f","localPeerAddr":,"localHashedId":"oKGio6SlpqeoqaqrrK2ur7CxsrM="}}"#
    }

    static func consoleAcceptText(reqID: Int = 7, sid: Int = 43981) -> String {
        #"{"action":"ACCEPT","reqId":\#(reqID),"error":0,"connRequest":{"sid":\#(sid),"peerSid":4660,"skey":"AAAAAAAAAAAAAAAAAAAAAA==","natType":0,"candidate":[{"type":"STATIC","addr":"203.0.113.5","mappedAddr":"198.51.100.7","port":40006,"mappedPort":50123}],"defaultRouteMacAddr":"","localPeerAddr":,"localHashedId":""}}"#
    }

    static func consoleResultText(reqID: Int) -> String {
        #"{"action":"RESULT","reqId":\#(reqID),"error":0,"connRequest":{}}"#
    }

    /// A `sessionMessage:created` frame carrying `messageText`.
    static func messageFrame(_ messageText: String) -> String {
        #"{"dataType":"psn:sessionManager:sys:rps:sessionMessage:created","body":{"data":{"sessionMessage":{"payload":"#
            + PSNJSON.quote("ver=1.0, type=text, body=" + messageText) + "}}}}"
    }

    static let createdFrame =
        #"{"dataType":"psn:sessionManager:sys:remotePlaySession:created","to":{"onlineId":"playfx-tester"},"body":{"data":{"sessionId":"2b5e4c0a-1d3f-4e6a-9b7c-0d1e2f3a4b5c"}}}"#
    static let clientJoinedFrame =
        #"{"dataType":"psn:sessionManager:sys:rps:members:created","body":{"data":{"members":[{"deviceUniqueId":"0000000000000000000000000000000000000000000000000000000000000000"}]}}}"#
    static func memberFrame(_ duid: String = duid) -> String {
        #"{"dataType":"psn:sessionManager:sys:rps:members:created","body":{"data":{"members":[{"deviceUniqueId":"\#(duid)"}]}}}"#
    }
    static func customDataFrame(_ text: String = customData1Text) -> String {
        #"{"dataType":"psn:sessionManager:sys:rps:customData1:updated","body":{"data":{"customData1":"\#(text)"}}}"#
    }
    static let memberDeletedFrame = #"{"dataType":"psn:sessionManager:sys:rps:members:deleted"}"#
    static func sessionDeletedFrame(_ id: String? = sessionID) -> String {
        let body = id.map { #","body":{"data":{"sessionId":"\#($0)"}}"# } ?? ""
        return #"{"dataType":"psn:sessionManager:sys:remotePlaySession:deleted"\#(body)}"#
    }

    /// Generous limits for tests whose success paths must not race a deadline on a loaded machine.
    static func patientTimeouts() -> PSNTimeouts {
        var timeouts = PSNTimeouts()
        timeouts.pingInterval = 60
        return timeouts
    }

    /// Short limits so the timeout paths run quickly; only tests that expect an expiry use them (an expiry that
    /// comes late is harmless, one that comes early would be a flake, so the success calls stay well inside).
    static func fastTimeouts() -> PSNTimeouts {
        var timeouts = PSNTimeouts()
        timeouts.deviceList = 1
        timeouts.request = 1
        timeouts.webSocketConnect = 1
        timeouts.pingInterval = 0.05
        timeouts.pongDeadline = 0.5
        timeouts.notification = 0.6
        timeouts.deletion = 0.3
        return timeouts
    }
}

extension PSNHTTPRequest {
    var bodyText: String { String(decoding: body ?? Data(), as: UTF8.self) }
}

/// An in-memory PSN: answers the HTTP calls and pushes notifications to `socket`, like the real service would.
/// Records every request, and every host, so tests can assert nothing else was contacted.
final class FakePSN: PSNTransport, @unchecked Sendable {
    struct Script: Sendable {
        var consoleListStatus = 200
        var consoleListBody =
            #"{"clients":[{"duid":"\#(PSNVector.duid)","device":{"name":"PS5-TEST","enabledFeatures":["remotePlay"]}}]}"#
        var pushHost = "push.example.test"
        var createStatus = 200
        var createBody =
            #"{"remotePlaySessions":[{"sessionId":"\#(PSNVector.sessionID)","members":[{"accountId":"1234567890123456789"}]}]}"#
        var startStatus = 200
        var messageStatus = 200
        var leaveStatus = 200
        var ps4WakeStatus = 200
        var ps4BaseURL = "https://userprofile.example.test/up"
        /// Notifications pushed after the create POST (the session exists, the client joined).
        var afterCreate: [String] = [PSNVector.createdFrame, PSNVector.clientJoinedFrame]
        /// Pushed after the start command or the PS4 wake (the console joins and sends its data).
        var afterStart: [String] = [PSNVector.memberFrame(), PSNVector.customDataFrame()]
        /// Pushed after the DELETE.
        var afterLeave: [String] = [PSNVector.memberDeletedFrame]
        /// Pushed for each message the client posts (the console's replies).
        var onMessage: @Sendable (PSNMessage) -> [String] = { _ in [] }
        /// Hang on the next request to this path suffix (never answers), to test timeouts.
        var hang: Set<String> = []
        var failure: (any Error)?
    }

    let socket: FakeWebSocket
    private let state = OSAllocatedUnfairLock(initialState: [PSNHTTPRequest]())
    private let scriptLock: OSAllocatedUnfairLock<Script>

    init(socket: FakeWebSocket = FakeWebSocket(), script: Script = Script()) {
        self.socket = socket
        self.scriptLock = OSAllocatedUnfairLock(initialState: script)
    }

    var script: Script {
        get { scriptLock.withLock { $0 } }
        set { scriptLock.withLock { $0 = newValue } }
    }

    var requests: [PSNHTTPRequest] { state.withLock { $0 } }

    func requests(containing text: String) -> [PSNHTTPRequest] {
        requests.filter { $0.url.absoluteString.contains(text) }
    }

    func send(_ request: PSNHTTPRequest) async throws -> PSNHTTPResponse {
        try Task.checkCancellation()
        state.withLock { $0.append(request) }
        let script = self.script
        let url = request.url.absoluteString
        if let failure = script.failure { throw failure }
        if script.hang.contains(where: { url.hasSuffix($0) || url.contains($0) }) {
            try await Task.sleep(for: .seconds(60))
        }
        func answer(_ status: Int, _ body: String = "{}", push: [String] = []) -> PSNHTTPResponse {
            if status < 400 { for frame in push { socket.emit(.text(frame)) } }
            return PSNHTTPResponse(status: status, body: Data(body.utf8))
        }
        switch (request.method, request.url.host ?? "", request.url.path) {
        case ("GET", "web.np.playstation.com", "/api/cloudAssistedNavigation/v2/users/me/clients"):
            return answer(script.consoleListStatus, script.consoleListBody)
        case ("GET", "mobile-pushcl.np.communication.playstation.net", "/np/serveraddr"):
            return answer(200, #"{"fqdn":"\#(script.pushHost)","other":1}"#)
        case ("POST", "web.np.playstation.com", "/api/sessionManager/v1/remotePlaySessions"):
            return answer(script.createStatus, script.createBody, push: script.afterCreate)
        case ("POST", "web.np.playstation.com", "/api/cloudAssistedNavigation/v2/users/me/commands"):
            return answer(script.startStatus, push: script.afterStart)
        case ("GET", "asm.np.community.playstation.net", _):
            return answer(200, #"{"url":"\#(script.ps4BaseURL)"}"#)
        case ("POST", "userprofile.example.test", _):
            return answer(script.ps4WakeStatus, push: script.afterStart)
        case ("POST", "web.np.playstation.com", _) where request.url.path.hasSuffix("/sessionMessage"):
            let body = PSNJSON.object(request.body ?? Data())
            let payload = (body?["payload"] as? String) ?? ""
            let replies = (try? PSNMessage.decode(payload: payload)).map(script.onMessage) ?? []
            return answer(script.messageStatus, push: replies.map { PSNVector.messageFrame($0) })
        case ("DELETE", "web.np.playstation.com", _):
            return answer(script.leaveStatus, push: script.afterLeave)
        case ("GET", "web.np.playstation.com", "/api/sessionManager/v1/remotePlaySessions"):
            return answer(200, #"{"remotePlaySessions":[]}"#)
        default:
            Issue.record("FakePSN: unexpected request \(request.method) \(url)")
            return PSNHTTPResponse(status: 599)
        }
    }

    /// Hosts the client talked to.
    var hosts: Set<String> { Set(requests.compactMap { $0.url.host }) }
}

/// A scriptable `PSNWebSocket`.
final class FakeWebSocket: PSNWebSocket, @unchecked Sendable {
    enum PingBehavior: Sendable { case pong, hang, fail }

    private struct State {
        var openedURL: URL?
        var openedHeaders: [String: String] = [:]
        var pongs: [Data] = []
        var pings = 0
        var closed = 0
        var pingBehavior = PingBehavior.pong
        var openError: (any Error)?
        var openHangs = false
    }

    private struct Inbound {
        var queue: [PSNWebSocketFrame] = []
        var ended: (any Error)?
        var waiter: CheckedContinuation<PSNWebSocketFrame, any Error>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let inbound = OSAllocatedUnfairLock(initialState: Inbound())

    var openedURL: URL? { state.withLock { $0.openedURL } }
    var openedHeaders: [String: String] { state.withLock { $0.openedHeaders } }
    var pongs: [Data] { state.withLock { $0.pongs } }
    var pings: Int { state.withLock { $0.pings } }
    var closeCount: Int { state.withLock { $0.closed } }
    func setPingBehavior(_ behavior: PingBehavior) { state.withLock { $0.pingBehavior = behavior } }
    func failOpen(with error: any Error) { state.withLock { $0.openError = error } }
    func hangOpen() { state.withLock { $0.openHangs = true } }

    func emit(_ frame: PSNWebSocketFrame) {
        let waiter = inbound.withLock { state -> CheckedContinuation<PSNWebSocketFrame, any Error>? in
            guard state.ended == nil else { return nil }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.queue.append(frame)
            return nil
        }
        waiter?.resume(returning: frame)
    }

    func drop(_ error: any Error = URLError(.networkConnectionLost)) {
        let waiter = inbound.withLock { state -> CheckedContinuation<PSNWebSocketFrame, any Error>? in
            if state.ended == nil { state.ended = error }
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(throwing: error)
    }

    func open(url: URL, headers: [String: String]) async throws {
        let (error, hangs) = state.withLock { state -> ((any Error)?, Bool) in
            state.openedURL = url
            state.openedHeaders = headers
            return (state.openError, state.openHangs)
        }
        if let error { throw error }
        if hangs { try await Task.sleep(for: .seconds(60)) }
    }

    func receive() async throws -> PSNWebSocketFrame {
        try await withCheckedThrowingContinuation { continuation in
            let ready = inbound.withLock { state -> Result<PSNWebSocketFrame, any Error>? in
                if !state.queue.isEmpty { return .success(state.queue.removeFirst()) }
                if let ended = state.ended { return .failure(ended) }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func ping() async throws {
        let behavior = state.withLock { state -> PingBehavior in
            state.pings += 1
            return state.pingBehavior
        }
        switch behavior {
        case .pong: return
        case .fail: throw URLError(.networkConnectionLost)
        case .hang: try await Task.sleep(for: .seconds(60))
        }
    }

    func sendPong(_ payload: Data) async throws { state.withLock { $0.pongs.append(payload) } }

    func close() async {
        state.withLock { $0.closed += 1 }
        drop(URLError(.cancelled))
    }
}

/// Polls until `condition` holds or `seconds` pass.
func eventually(_ seconds: TimeInterval = 2, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
