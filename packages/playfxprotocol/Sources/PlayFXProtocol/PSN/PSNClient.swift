import Foundation

/// The HTTP side of PSN for internet play (psn.md sections 4 to 8): the console list, the push server's
/// address, and the session calls that `PSNRemotePlaySession` drives. It holds one access token; after a refresh,
/// make a new client.
///
/// Statuses follow psn.md section 1: the device list must answer exactly 200, every other call accepts any
/// status below 400; 401/403 are `PSNError.unauthorized`. Error bodies are never read.
public struct PSNClient: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let webHost = "https://web.np.playstation.com"

    private let accessToken: String
    private let transport: any PSNTransport
    /// The limits applied to every call and wait; tests shrink them.
    public let timeouts: PSNTimeouts

    public init(
        accessToken: String, transport: any PSNTransport = URLSessionPSNTransport(), timeouts: PSNTimeouts = .init()
    ) {
        self.accessToken = accessToken
        self.transport = transport
        self.timeouts = timeouts
    }

    /// Printing or dumping a client never shows the access token.
    public var description: String { "PSNClient(accessToken: <redacted>, timeouts: \(timeouts))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["accessToken": "<redacted>", "timeouts": timeouts], displayStyle: .struct)
    }

    // MARK: Console list (section 4)

    /// The account's PS5s (psn.md section 4: one page of 10, `platform=PS5`). Entries without a `duid`, a
    /// 64-hex `duid` or a `device.name` are skipped. An empty list is a valid answer: no PS5 on the account.
    public func consoles() async throws -> [PSNConsole] {
        let url = "\(Self.webHost)/api/cloudAssistedNavigation/v2/users/me/clients?platform=PS5&includeFields=device&limit=10&offset=0"
        let response = try await perform(
            .consoleList,
            try request(.consoleList, "GET", url, ["Accept-Language": "jp"], timeout: timeouts.deviceList)
        ) { $0 == 200 }
        guard let root = PSNJSON.object(response.body), let clients = root["clients"] as? [Any] else {
            throw PSNError.invalidResponse(step: .consoleList, reason: "no clients array")
        }
        return clients.compactMap { entry in
            guard let client = entry as? [String: Any], let duid = client["duid"] as? String,
                let bytes = decodeHex(Array(duid.utf8)), bytes.count == 32,
                let device = client["device"] as? [String: Any], let name = device["name"] as? String
            else { return nil }
            let features = (device["enabledFeatures"] as? [Any])?.compactMap { $0 as? String } ?? []
            return PSNConsole(name: name, duid: encodeHex(bytes), enabledFeatures: features)
        }
    }

    // MARK: Push server (section 5.1)

    /// The push WebSocket's host name (psn.md section 5.1).
    public func pushServerHost() async throws -> String {
        let url =
            "https://mobile-pushcl.np.communication.playstation.net/np/serveraddr?version=2.1&fields=keepAliveStatus&keepAliveStatusType=3"
        let response = try await perform(.pushServerAddress, try request(.pushServerAddress, "GET", url, [:], timeout: timeouts.request)) {
            $0 < 400
        }
        guard let host = PSNJSON.object(response.body)?["fqdn"] as? String, !host.isEmpty else {
            throw PSNError.invalidResponse(step: .pushServerAddress, reason: "no fqdn")
        }
        return host
    }

    /// Looks up the push server and opens the notification WebSocket on `socket` (psn.md section 5). It must be
    /// open before a session is created.
    public func openPushChannel(socket: any PSNWebSocket) async throws -> PSNPushChannel {
        try await PSNPushChannel.open(
            host: try await pushServerHost(), accessToken: accessToken, socket: socket, timeouts: timeouts)
    }

    // MARK: Session (sections 6 to 8)

    /// What PSN returned for a created session (psn.md section 6.1).
    struct CreatedSession: Equatable {
        var sessionID: String
        var accountID: UInt64
    }

    func createSession(pushContextID: String) async throws -> CreatedSession {
        let body =
            "{\"remotePlaySessions\":[{\"members\":[{\"accountId\":\"me\",\"deviceUniqueId\":\"me\",\"platform\":\"me\","
            + "\"pushContexts\":[{\"pushContextId\":\(PSNJSON.quote(pushContextID))}]}]}]}"
        let response = try await perform(
            .createSession, try jsonRequest(.createSession, "POST", "\(Self.webHost)/api/sessionManager/v1/remotePlaySessions", body)
        ) { $0 < 400 }
        let session = ((PSNJSON.object(response.body)?["remotePlaySessions"] as? [Any])?.first) as? [String: Any]
        guard let sessionID = session?["sessionId"] as? String, sessionID.count == 36, UUID(uuidString: sessionID) != nil
        else {
            throw PSNError.invalidResponse(step: .createSession, reason: "sessionId")
        }
        let member = (session?["members"] as? [Any])?.first as? [String: Any]
        guard let accountID = PSNJSON.uint64(member?["accountId"]) else {
            throw PSNError.invalidResponse(step: .createSession, reason: "accountId")
        }
        return CreatedSession(sessionID: sessionID, accountID: accountID)
    }

    /// Reads the session back (psn.md section 6.2). The answer is returned raw; nothing in it is used.
    func inspectSession(sessionID: String, withView: Bool) async throws -> Data {
        let url = "\(Self.webHost)/api/sessionManager/v1/remotePlaySessions" + (withView ? "?view=v1.0" : "")
        let headers = ["X-PSN-SESSION-MANAGER-SESSION-IDS": sessionID]
        return try await perform(.inspectSession, try request(.inspectSession, "GET", url, headers, timeout: timeouts.request)) { $0 < 400 }
            .body
    }

    /// The PS5 start command (psn.md section 6.3). `data1` and `data2` are 16 bytes each.
    func startPS5(consoleDUID: String, accountID: UInt64, sessionID: String, data1: [UInt8], data2: [UInt8])
        async throws
    {
        let initial =
            "{\"accountId\":\(accountID),\"roomId\":0,\"sessionId\":\(PSNJSON.quote(sessionID)),"
            + "\"clientType\":\"Windows\",\"data1\":\(PSNJSON.quote(PSNJSON.base64(data1))),"
            + "\"data2\":\(PSNJSON.quote(PSNJSON.base64(data2)))}"
        let body =
            "{\"commandDetail\":{\"commandType\":\"remotePlay\",\"duid\":\(PSNJSON.quote(consoleDUID)),"
            + "\"messageDestination\":\"SQS\",\"parameters\":{\"initialParams\":\(PSNJSON.quote(initial))},"
            + "\"platform\":\"PS5\"}}"
        var start = try jsonRequest(
            .startCommand, "POST", "\(Self.webHost)/api/cloudAssistedNavigation/v2/users/me/commands", body)
        start.headers["User-Agent"] = "RpNetHttpUtilImpl"
        _ = try await perform(.startCommand, start) { $0 < 400 }
    }

    /// The PS4 wake (psn.md section 6.4): the user-profile base URL, then the wake-up call for `onlineID`.
    func wakePS4(onlineID: String, sessionID: String, data1: [UInt8], data2: [UInt8]) async throws {
        let profileURL = "https://asm.np.community.playstation.net/asm/v1/apps/me/baseUrls/userProfile"
        var profile = try request(.ps4Profile, "GET", profileURL, ps4Headers(host: "asm.np.community.playstation.net"), timeout: timeouts.request)
        profile.headers["Content-Type"] = "application/json; charset=utf-8"
        let answer = try await perform(.ps4Profile, profile) { $0 < 400 }
        // The token goes to this URL, so it must be an HTTPS one (psn.md section 1).
        guard let base = PSNJSON.object(answer.body)?["url"] as? String, let baseURL = URL(string: base),
            baseURL.scheme?.lowercased() == "https", let host = baseURL.host, !host.isEmpty
        else { throw PSNError.invalidResponse(step: .ps4Profile, reason: "url") }

        let body =
            "{\"data\":{\"clientType\":\"Windows\",\"data1\":\(PSNJSON.quote(PSNJSON.base64(data1))),"
            + "\"data2\":\(PSNJSON.quote(PSNJSON.base64(data2))),\"roomId\": 0,\"protocolVer\":\"10.0\","
            + "\"sessionId\":\(PSNJSON.quote(sessionID))},\"dataTypeSuffix\":\"remotePlay\"}"
        let segment = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let encoded = onlineID.addingPercentEncoding(withAllowedCharacters: segment) ?? onlineID
        let wake = base.hasSuffix("/") ? String(base.dropLast()) : base
        var wakeRequest = try request(
            .ps4Wake, "POST", "\(wake)/v1/users/\(encoded)/remoteConsole/wakeUp?platform=PS4", ps4Headers(host: host),
            timeout: timeouts.request)
        wakeRequest.headers["Content-Type"] = "application/json; charset=utf-8"
        wakeRequest.body = Data(body.utf8)
        _ = try await perform(.ps4Wake, wakeRequest) { $0 < 400 }
    }

    /// Posts one session message (psn.md section 7.1) to the console.
    func sendMessage(
        _ message: PSNMessage, sessionID: String, accountID: UInt64, consoleDUID: String, platform: PSNPlatform
    ) async throws {
        let body =
            "{\"channel\":\"remote_play:1\",\"payload\":\(PSNJSON.quote(message.payload())),\"to\":[{\"accountId\":\"\(accountID)\","
            + "\"deviceUniqueId\":\(PSNJSON.quote(consoleDUID)),\"platform\":\(PSNJSON.quote(platform.rawValue))}]}"
        let url = "\(Self.webHost)/api/sessionManager/v1/remotePlaySessions/\(sessionID)/sessionMessage"
        _ = try await perform(.sessionMessage, try jsonRequest(.sessionMessage, "POST", url, body)) { $0 < 400 }
    }

    /// Leaves the session (psn.md section 8).
    func leaveSession(sessionID: String) async throws {
        let url = "\(Self.webHost)/api/sessionManager/v1/remotePlaySessions/\(sessionID)/members/me"
        let leave = try request(.leaveSession, "DELETE", url, ["Content-Type": "application/json; charset=utf-8"], timeout: timeouts.request)
        _ = try await perform(.leaveSession, leave) { $0 < 400 }
    }

    // MARK: Plumbing

    private func ps4Headers(host: String) -> [String: String] {
        ["Host": host, "Connection": "Keep-Alive", "User-Agent": "RpNetHttpUtilImpl"]
    }

    private func request(
        _ step: PSNStep, _ method: String, _ url: String, _ headers: [String: String], timeout: TimeInterval
    ) throws -> PSNHTTPRequest {
        var all = headers
        all["Authorization"] = "Bearer \(accessToken)"
        guard let parsed = URL(string: url) else {
            throw PSNError.invalidResponse(step: step, reason: "bad URL")
        }
        return PSNHTTPRequest(method: method, url: parsed, headers: all, timeout: timeout)
    }

    private func jsonRequest(_ step: PSNStep, _ method: String, _ url: String, _ body: String) throws
        -> PSNHTTPRequest
    {
        var json = try request(step,
            method, url, ["Content-Type": "application/json; charset=utf-8"], timeout: timeouts.request)
        json.body = Data(body.utf8)
        return json
    }

    /// Sends under the step's limit and maps failures to `PSNError`.
    private func perform(_ step: PSNStep, _ request: PSNHTTPRequest, accepting ok: (Int) -> Bool) async throws
        -> PSNHTTPResponse
    {
        let transport = self.transport
        let response: PSNHTTPResponse
        do {
            response = try await psnWithDeadline(request.timeout, error: .timedOut(step: step)) {
                try await transport.send(request)
            }
        } catch let error as PSNError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw PSNError.timedOut(step: step)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw PSNError.transport(step: step, description: error.localizedDescription)
        }
        if response.status == 401 || response.status == 403 {
            throw PSNError.unauthorized(step: step, status: response.status)
        }
        guard ok(response.status) else {
            if step == .ps4Wake && response.status == 404 { throw PSNError.ps4NotPrimary }
            throw PSNError.httpStatus(step: step, status: response.status)
        }
        return response
    }
}
