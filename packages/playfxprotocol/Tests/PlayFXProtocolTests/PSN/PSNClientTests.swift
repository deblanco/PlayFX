import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

@Suite struct PSNClientTests {
    static func client(_ psn: FakePSN) -> PSNClient {
        PSNClient(accessToken: PSNVector.token, transport: psn, timeouts: PSNVector.fastTimeouts())
    }

    // MARK: Console list (section 4)

    @Test func consoleListRequestAndParse() async throws {
        let psn = FakePSN()
        let consoles = try await Self.client(psn).consoles()
        #expect(consoles == [PSNConsole(name: "PS5-TEST", duid: PSNVector.duid, enabledFeatures: ["remotePlay"])])
        #expect(consoles[0].remotePlayEnabled)
        #expect(consoles[0].platform == .ps5)
        let request = try #require(psn.requests.first)
        #expect(request.method == "GET")
        #expect(
            request.url.absoluteString
                == "https://web.np.playstation.com/api/cloudAssistedNavigation/v2/users/me/clients?platform=PS5&includeFields=device&limit=10&offset=0"
        )
        #expect(request.headers == ["Accept-Language": "jp", "Authorization": "Bearer TOKEN-MADE-UP"])
        #expect(request.body == nil)
        #expect(request.timeout == 1)
    }

    @Test func consoleListSkipsBadEntriesAndNormalises() async throws {
        let upper = PSNVector.duid.uppercased()
        let psn = FakePSN()
        psn.script.consoleListBody = """
            {"clients":[
              {"duid":"\(upper)","device":{"name":"Upper","enabledFeatures":["remotePlay","x",3]}},
              {"duid":"abcd","device":{"name":"Short","enabledFeatures":[]}},
              {"device":{"name":"NoDuid","enabledFeatures":[]}},
              {"duid":"\(PSNVector.duid)","device":{"enabledFeatures":[]}},
              {"duid":"\(PSNVector.duid)"},
              {"duid":"\(PSNVector.duid)","device":{"name":"Off"}},
              "junk"
            ]}
            """
        let consoles = try await Self.client(psn).consoles()
        #expect(consoles.map(\.name) == ["Upper", "Off"])
        #expect(consoles[0].duid == PSNVector.duid)
        #expect(consoles[0].enabledFeatures == ["remotePlay", "x"])
        #expect(consoles[1].enabledFeatures.isEmpty && !consoles[1].remotePlayEnabled)
    }

    @Test func emptyConsoleList() async throws {
        let psn = FakePSN()
        psn.script.consoleListBody = #"{"clients":[]}"#
        #expect(try await Self.client(psn).consoles().isEmpty)
    }

    @Test func consoleListErrors() async {
        func fail(_ configure: (inout FakePSN.Script) -> Void) async -> PSNError? {
            let psn = FakePSN()
            var script = psn.script
            configure(&script)
            psn.script = script
            do {
                _ = try await Self.client(psn).consoles()
                return nil
            } catch {
                return error as? PSNError
            }
        }
        #expect(await fail { $0.consoleListStatus = 401 } == .unauthorized(step: .consoleList, status: 401))
        #expect(await fail { $0.consoleListStatus = 403 } == .unauthorized(step: .consoleList, status: 403))
        #expect(await fail { $0.consoleListStatus = 500 } == .httpStatus(step: .consoleList, status: 500))
        // The list must answer exactly 200.
        #expect(await fail { $0.consoleListStatus = 204 } == .httpStatus(step: .consoleList, status: 204))
        #expect(await fail { $0.consoleListBody = "<html>" } == .invalidResponse(step: .consoleList, reason: "no clients array"))
        #expect(await fail { $0.consoleListBody = #"{"clients":{}}"# } == .invalidResponse(step: .consoleList, reason: "no clients array"))
        #expect(await fail { $0.hang = ["clients?platform=PS5&includeFields=device&limit=10&offset=0"] } == .timedOut(step: .consoleList))
        #expect(await fail { $0.failure = URLError(.timedOut) } == .timedOut(step: .consoleList))
        let transport = await fail { $0.failure = URLError(.notConnectedToInternet) }
        guard case .transport(.consoleList, _) = transport else {
            Issue.record("expected a transport error, got \(String(describing: transport))")
            return
        }
    }

    @Test func cancellationIsNotAnError() async {
        let psn = FakePSN()
        psn.script.hang = ["clients?platform=PS5&includeFields=device&limit=10&offset=0"]
        let client = PSNClient(accessToken: PSNVector.token, transport: psn, timeouts: PSNTimeouts())
        let task = Task { try await client.consoles() }
        _ = await eventually { !psn.requests.isEmpty }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("returned")
        } catch {
            #expect(error is CancellationError)
        }
    }

    // MARK: Push server (section 5.1)

    @Test func pushServerRequest() async throws {
        let psn = FakePSN()
        #expect(try await Self.client(psn).pushServerHost() == "push.example.test")
        let request = try #require(psn.requests.first)
        #expect(
            request.url.absoluteString
                == "https://mobile-pushcl.np.communication.playstation.net/np/serveraddr?version=2.1&fields=keepAliveStatus&keepAliveStatusType=3"
        )
        #expect(request.headers == ["Authorization": "Bearer TOKEN-MADE-UP"])
        #expect(request.timeout == 1)
    }

    @Test func pushServerBadAnswer() async {
        let psn = FakePSN()
        psn.script.pushHost = ""
        await #expect(throws: PSNError.invalidResponse(step: .pushServerAddress, reason: "no fqdn")) {
            _ = try await Self.client(psn).pushServerHost()
        }
    }

    // MARK: Session calls (vectors P1, P2, P5 to P9)

    @Test func createSessionVectorP1() async throws {
        let psn = FakePSN()
        let created = try await Self.client(psn).createSession(pushContextID: PSNVector.pushContextID)
        #expect(created == PSNClient.CreatedSession(sessionID: PSNVector.sessionID, accountID: PSNVector.accountID))
        let request = try #require(psn.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://web.np.playstation.com/api/sessionManager/v1/remotePlaySessions")
        #expect(request.bodyText == PSNVector.p1)
        #expect(
            request.headers == [
                "Authorization": "Bearer TOKEN-MADE-UP", "Content-Type": "application/json; charset=utf-8",
            ])
    }

    @Test func createSessionAnswerShapes() async throws {
        func create(_ body: String, status: Int = 200) async throws -> PSNClient.CreatedSession {
            let psn = FakePSN()
            psn.script.createBody = body
            psn.script.createStatus = status
            return try await Self.client(psn).createSession(pushContextID: PSNVector.pushContextID)
        }
        let id = PSNVector.sessionID
        let numeric = try await create(#"{"remotePlaySessions":[{"sessionId":"\#(id)","members":[{"accountId":18446744073709551615}]}]}"#)
        #expect(numeric.accountID == UInt64.max)
        // Any status below 400 counts as success.
        let created = try await create(#"{"remotePlaySessions":[{"sessionId":"\#(id)","members":[{"accountId":7}]}]}"#, status: 201)
        #expect(created.accountID == 7)
        for body in [
            "x", "{}", #"{"remotePlaySessions":[]}"#, #"{"remotePlaySessions":[{"sessionId":"short","members":[{"accountId":1}]}]}"#,
        ] {
            await #expect(throws: PSNError.invalidResponse(step: .createSession, reason: "sessionId")) { _ = try await create(body) }
        }
        for body in [
            #"{"remotePlaySessions":[{"sessionId":"\#(id)"}]}"#,
            #"{"remotePlaySessions":[{"sessionId":"\#(id)","members":[{"accountId":"abc"}]}]}"#,
        ] {
            await #expect(throws: PSNError.invalidResponse(step: .createSession, reason: "accountId")) { _ = try await create(body) }
        }
        await #expect(throws: PSNError.httpStatus(step: .createSession, status: 400)) { _ = try await create("{}", status: 400) }
        await #expect(throws: PSNError.unauthorized(step: .createSession, status: 401)) { _ = try await create("{}", status: 401) }
    }

    @Test func inspectRequests() async throws {
        let psn = FakePSN()
        let client = Self.client(psn)
        _ = try await client.inspectSession(sessionID: PSNVector.sessionID, withView: true)
        _ = try await client.inspectSession(sessionID: PSNVector.sessionID, withView: false)
        let urls = psn.requests.map(\.url.absoluteString)
        #expect(urls == [
            "https://web.np.playstation.com/api/sessionManager/v1/remotePlaySessions?view=v1.0",
            "https://web.np.playstation.com/api/sessionManager/v1/remotePlaySessions",
        ])
        #expect(psn.requests[0].headers == [
            "Authorization": "Bearer TOKEN-MADE-UP", "X-PSN-SESSION-MANAGER-SESSION-IDS": PSNVector.sessionID,
        ])
    }

    @Test func startPS5VectorP2() async throws {
        let psn = FakePSN()
        try await Self.client(psn).startPS5(
            consoleDUID: PSNVector.duid, accountID: PSNVector.accountID, sessionID: PSNVector.sessionID,
            data1: PSNVector.data1, data2: PSNVector.data2)
        let request = try #require(psn.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://web.np.playstation.com/api/cloudAssistedNavigation/v2/users/me/commands")
        #expect(request.bodyText == PSNVector.p2)
        #expect(
            request.headers == [
                "Authorization": "Bearer TOKEN-MADE-UP", "Content-Type": "application/json; charset=utf-8",
                "User-Agent": "RpNetHttpUtilImpl",
            ])
    }

    @Test func startPS5Errors() async {
        let psn = FakePSN()
        psn.script.startStatus = 400
        await #expect(throws: PSNError.httpStatus(step: .startCommand, status: 400)) {
            try await Self.client(psn).startPS5(
                consoleDUID: PSNVector.duid, accountID: 1, sessionID: PSNVector.sessionID, data1: PSNVector.data1,
                data2: PSNVector.data2)
        }
    }

    @Test func messagesVectorsP5P6P7() async throws {
        let psn = FakePSN()
        let client = Self.client(psn)
        let peer = PSNCodecTests.peer()
        let offer = PSNMessage(
            action: .offer, reqID: 2,
            connRequest: PSNConnRequest(
                sid: 4660, peerSid: 0, natType: 2, candidates: PSNCodecTests.candidates, localPeerAddress: peer,
                localHashedID: PSNVector.localHashedID))
        let accept = PSNMessage(
            action: .accept, reqID: 3,
            connRequest: PSNConnRequest(
                sid: 4660, peerSid: 43981, natType: 0,
                candidates: [PSNCandidate(type: .staticAddress, address: "198.51.100.7", mappedAddress: "203.0.113.5", port: 50123, mappedPort: 40006)],
                localPeerAddress: peer, localHashedID: []))
        for message in [PSNMessage(action: .result, reqID: 1, connRequest: nil), offer, accept] {
            try await client.sendMessage(
                message, sessionID: PSNVector.sessionID, accountID: PSNVector.accountID, consoleDUID: PSNVector.duid,
                platform: .ps5)
        }
        #expect(psn.requests.map(\.bodyText) == [PSNVector.p5, PSNVector.p6, PSNVector.p7])
        for request in psn.requests {
            #expect(request.method == "POST")
            #expect(
                request.url.absoluteString
                    == "https://web.np.playstation.com/api/sessionManager/v1/remotePlaySessions/\(PSNVector.sessionID)/sessionMessage"
            )
            #expect(
                request.headers == [
                    "Authorization": "Bearer TOKEN-MADE-UP", "Content-Type": "application/json; charset=utf-8",
                ])
        }
    }

    @Test func messageToPS4AndAccountAboveInt64() async throws {
        let psn = FakePSN()
        try await Self.client(psn).sendMessage(
            PSNMessage(action: .result, reqID: 4, connRequest: nil), sessionID: PSNVector.sessionID,
            accountID: UInt64.max, consoleDUID: PSNVector.duid, platform: .ps4)
        let body = psn.requests[0].bodyText
        #expect(body.hasSuffix(#""to":[{"accountId":"18446744073709551615","deviceUniqueId":"\#(PSNVector.duid)","platform":"PS4"}]}"#))
    }

    @Test func messageErrors() async {
        let psn = FakePSN()
        psn.script.messageStatus = 503
        await #expect(throws: PSNError.httpStatus(step: .sessionMessage, status: 503)) {
            try await Self.client(psn).sendMessage(
                PSNMessage(action: .result, reqID: 1, connRequest: nil), sessionID: PSNVector.sessionID, accountID: 1,
                consoleDUID: PSNVector.duid, platform: .ps5)
        }
    }

    @Test func leaveVectorP8() async throws {
        let psn = FakePSN()
        try await Self.client(psn).leaveSession(sessionID: PSNVector.sessionID)
        let request = try #require(psn.requests.first)
        #expect(request.method == "DELETE")
        #expect(
            request.url.absoluteString
                == "https://web.np.playstation.com/api/sessionManager/v1/remotePlaySessions/\(PSNVector.sessionID)/members/me")
        #expect(
            request.headers == [
                "Authorization": "Bearer TOKEN-MADE-UP", "Content-Type": "application/json; charset=utf-8",
            ])
        #expect(request.body == nil)
    }

    // MARK: PS4 wake (section 6.4, vector P9)

    @Test func ps4WakeVectorP9() async throws {
        let psn = FakePSN()
        try await Self.client(psn).wakePS4(
            onlineID: "playfx-tester", sessionID: PSNVector.sessionID, data1: PSNVector.data1, data2: PSNVector.data2)
        #expect(psn.requests.count == 2)
        let profile = psn.requests[0]
        #expect(profile.method == "GET")
        #expect(profile.url.absoluteString == "https://asm.np.community.playstation.net/asm/v1/apps/me/baseUrls/userProfile")
        #expect(
            profile.headers == [
                "Authorization": "Bearer TOKEN-MADE-UP", "Host": "asm.np.community.playstation.net",
                "Connection": "Keep-Alive", "Content-Type": "application/json; charset=utf-8",
                "User-Agent": "RpNetHttpUtilImpl",
            ])
        let wake = psn.requests[1]
        #expect(wake.method == "POST")
        #expect(wake.url.absoluteString == "https://userprofile.example.test/up/v1/users/playfx-tester/remoteConsole/wakeUp?platform=PS4")
        #expect(wake.bodyText == PSNVector.p9)
        #expect(
            wake.headers == [
                "Authorization": "Bearer TOKEN-MADE-UP", "Host": "userprofile.example.test",
                "Connection": "Keep-Alive", "Content-Type": "application/json; charset=utf-8",
                "User-Agent": "RpNetHttpUtilImpl",
            ])
    }

    @Test func ps4WakeEncodesOnlineIDAndTrailingSlash() async throws {
        let psn = FakePSN()
        psn.script.ps4BaseURL = "https://userprofile.example.test/up/"
        try await Self.client(psn).wakePS4(
            onlineID: "a b/c", sessionID: PSNVector.sessionID, data1: PSNVector.data1, data2: PSNVector.data2)
        #expect(psn.requests[1].url.absoluteString == "https://userprofile.example.test/up/v1/users/a%20b%2Fc/remoteConsole/wakeUp?platform=PS4")
    }

    @Test func ps4WakeErrors() async {
        let psn = FakePSN()
        psn.script.ps4WakeStatus = 404
        await #expect(throws: PSNError.ps4NotPrimary) {
            try await Self.client(psn).wakePS4(onlineID: "x", sessionID: PSNVector.sessionID, data1: PSNVector.data1, data2: PSNVector.data2)
        }
        psn.script.ps4WakeStatus = 500
        await #expect(throws: PSNError.httpStatus(step: .ps4Wake, status: 500)) {
            try await Self.client(psn).wakePS4(onlineID: "x", sessionID: PSNVector.sessionID, data1: PSNVector.data1, data2: PSNVector.data2)
        }
        psn.script.ps4BaseURL = ""
        await #expect(throws: PSNError.invalidResponse(step: .ps4Profile, reason: "url")) {
            try await Self.client(psn).wakePS4(onlineID: "x", sessionID: PSNVector.sessionID, data1: PSNVector.data1, data2: PSNVector.data2)
        }
    }

    // MARK: Nothing leaves the fakes

    @Test func onlyPSNHostsAreAddressed() async throws {
        let psn = FakePSN()
        let client = Self.client(psn)
        _ = try await client.consoles()
        _ = try await client.pushServerHost()
        _ = try await client.createSession(pushContextID: PSNVector.pushContextID)
        #expect(psn.hosts == ["web.np.playstation.com", "mobile-pushcl.np.communication.playstation.net"])
    }

    @Test func timeoutDefaultsMatchSection10() {
        let timeouts = PSNTimeouts()
        #expect(timeouts.deviceList == 5 && timeouts.request == 10 && timeouts.webSocketConnect == 30)
        #expect(timeouts.pingInterval == 5 && timeouts.pongDeadline == 5)
        #expect(timeouts.notification == 30 && timeouts.deletion == 3)
    }
}
