import CryptoKit
import Foundation
import Network
import Testing
import os

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

// The real URLSession adapters, with nothing but stubs and loopback behind them: HTTP through a URLProtocol that
// fails every request it has no answer for, the WebSocket against a small RFC 6455 server on 127.0.0.1.

final class PSNStubProtocol: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable {
        var method: String
        var url: String
        var headers: [String: String]
        var body: Data
    }

    struct Answer: Sendable {
        var status: Int
        var body: String
    }

    static let routes = OSAllocatedUnfairLock(initialState: [String: Answer]())
    static let seen = OSAllocatedUnfairLock(initialState: [Seen]())
    static let unstubbed = OSAllocatedUnfairLock(initialState: [String]())

    static func reset(_ routes: [String: Answer] = [:]) {
        Self.routes.withLock { $0 = routes }
        seen.withLock { $0 = [] }
        unstubbed.withLock { $0 = [] }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PSNStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let record = Seen(method: request.httpMethod ?? "", url: url, headers: request.allHTTPHeaderFields ?? [:], body: body)
        Self.seen.withLock { $0.append(record) }
        guard let answer = Self.routes.withLock({ $0[url] }) else {
            Self.unstubbed.withLock { $0.append(url) }
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if answer.status < 0 {
            client?.urlProtocol(self, didReceive: URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), cacheStoragePolicy: .notAllowed)
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct PSNURLSessionTransportTests {
    @Test func sendsTheRequestAndReturnsStatusAndBody() async throws {
        let url = "https://web.np.playstation.com/api/sessionManager/v1/remotePlaySessions"
        PSNStubProtocol.reset([url: .init(status: 201, body: #"{"ok":true}"#)])
        let transport = URLSessionPSNTransport(session: PSNStubProtocol.session())
        let response = try await transport.send(
            PSNHTTPRequest(
                method: "POST", url: URL(string: url)!, headers: ["Authorization": "Bearer TOKEN-MADE-UP", "X-A": "b"],
                body: Data(PSNVector.p1.utf8), timeout: 5))
        #expect(response == PSNHTTPResponse(status: 201, body: Data(#"{"ok":true}"#.utf8)))
        let seen = try #require(PSNStubProtocol.seen.withLock { $0.first })
        #expect(seen.method == "POST")
        #expect(seen.url == url)
        #expect(seen.headers["Authorization"] == "Bearer TOKEN-MADE-UP" && seen.headers["X-A"] == "b")
        #expect(String(decoding: seen.body, as: UTF8.self) == PSNVector.p1)
    }

    @Test func anyRequestWithoutAStubFails() async throws {
        PSNStubProtocol.reset()
        let transport = URLSessionPSNTransport(session: PSNStubProtocol.session())
        await #expect(throws: URLError.self) {
            _ = try await transport.send(PSNHTTPRequest(method: "GET", url: URL(string: "https://example.test/x")!, headers: [:], timeout: 5))
        }
        #expect(PSNStubProtocol.unstubbed.withLock { $0 } == ["https://example.test/x"])
    }

    @Test func nonHTTPAnswerIsRejected() async throws {
        let url = "https://example.test/odd"
        PSNStubProtocol.reset([url: .init(status: -1, body: "")])
        let transport = URLSessionPSNTransport(session: PSNStubProtocol.session())
        await #expect(throws: URLError.self) {
            _ = try await transport.send(PSNHTTPRequest(method: "GET", url: URL(string: url)!, headers: [:], timeout: 5))
        }
    }

    @Test func clientOverTheURLSessionTransport() async throws {
        let list = "https://web.np.playstation.com/api/cloudAssistedNavigation/v2/users/me/clients?platform=PS5&includeFields=device&limit=10&offset=0"
        PSNStubProtocol.reset([
            list: .init(status: 200, body: #"{"clients":[{"duid":"\#(PSNVector.duid)","device":{"name":"PS5-TEST","enabledFeatures":[]}}]}"#)
        ])
        let client = PSNClient(accessToken: PSNVector.token, transport: URLSessionPSNTransport(session: PSNStubProtocol.session()))
        #expect(try await client.consoles().map(\.name) == ["PS5-TEST"])
        let seen = try #require(PSNStubProtocol.seen.withLock { $0.first })
        #expect(seen.headers["Accept-Language"] == "jp" && seen.headers["Authorization"] == "Bearer TOKEN-MADE-UP")

        PSNStubProtocol.reset([list: .init(status: 401, body: "")])
        await #expect(throws: PSNError.unauthorized(step: .consoleList, status: 401)) { _ = try await client.consoles() }
        // The push server isn't stubbed: the call fails as a transport error and nothing leaves the process.
        PSNStubProtocol.reset()
        do {
            _ = try await client.pushServerHost()
            Issue.record("answered")
        } catch let PSNError.transport(step, _) {
            #expect(step == .pushServerAddress)
        }
        #expect(PSNStubProtocol.unstubbed.withLock { $0.count } == 1)
    }
}

// MARK: Loopback WebSocket server

/// Accepts one connection at a time on 127.0.0.1, does the WebSocket upgrade, sends what it's told and records
/// what the client sends.
final class LoopbackWebSocketServer: @unchecked Sendable {
    struct State {
        var requestHeaders: [String: String] = [:]
        var requestLine = ""
        var pongs: [Data] = []
        var pings: [Data] = []
        var closeSeen = false
        var buffer = Data()
        var upgraded = false
    }

    let listener: NWListener
    let state = OSAllocatedUnfairLock(initialState: State())
    private let rejectWith: Int?
    private let queue = DispatchQueue(label: "psn.loopback.ws")

    private let answerPings: Bool

    init(rejectWith status: Int? = nil, answerPings: Bool = true) throws {
        self.answerPings = answerPings
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        rejectWith = status
    }

    /// Starts listening and returns the port.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            read(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let once = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { [listener] newState in
                let finish: (Result<UInt16, Error>) -> Void = { result in
                    if once.withLock({ done in
                        defer { done = true }
                        return !done
                    }) { continuation.resume(with: result) }
                }
                switch newState {
                case .ready: finish(.success(listener.port?.rawValue ?? 0))
                case .failed(let error): finish(.failure(error))
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    var seen: State { state.withLock { $0 } }

    private func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, finished, error in
            if let data { handle(data, on: connection) }
            if error == nil && !finished { read(connection) }
        }
    }

    private func send(_ bytes: [UInt8], on connection: NWConnection) {
        connection.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    static func frame(opcode: UInt8, _ payload: [UInt8]) -> [UInt8] {
        [0x80 | opcode, UInt8(payload.count)] + payload
    }

    private func handle(_ data: Data, on connection: NWConnection) {
        let upgraded = state.withLock { state -> Bool in
            state.buffer.append(data)
            return state.upgraded
        }
        if !upgraded {
            let terminator = Data("\r\n\r\n".utf8)
            let text = state.withLock { $0.buffer }
            guard let end = text.range(of: terminator) else { return }
            let head = String(decoding: text[..<end.lowerBound], as: UTF8.self)
            var headers: [String: String] = [:]
            let lines = head.components(separatedBy: "\r\n")
            for line in lines.dropFirst() {
                if let colon = line.firstIndex(of: ":") {
                    headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            }
            let parsed = headers
            state.withLock {
                $0.requestLine = lines.first ?? ""
                $0.requestHeaders = parsed
                $0.buffer = Data(text[end.upperBound...])
            }
            if let status = rejectWith {
                send(Array("HTTP/1.1 \(status) Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), on: connection)
                return
            }
            let key = headers["sec-websocket-key"] ?? ""
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            var response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n"
            if let requested = headers["sec-websocket-protocol"] { response += "Sec-WebSocket-Protocol: \(requested)\r\n" }
            send(Array((response + "\r\n").utf8), on: connection)
            state.withLock { $0.upgraded = true }
            send(Self.frame(opcode: 1, Array(PSNVector.memberDeletedFrame.utf8)), on: connection)
            send(Self.frame(opcode: 9, Array("abc".utf8)), on: connection)
        }
        parseFrames(on: connection)
    }

    private func parseFrames(on connection: NWConnection) {
        while true {
            let frame: (opcode: UInt8, payload: Data)? = state.withLock { state in
                let bytes = [UInt8](state.buffer)
                guard bytes.count >= 2 else { return nil }
                let length = Int(bytes[1] & 0x7f)
                let masked = bytes[1] & 0x80 != 0
                let total = 2 + (masked ? 4 : 0) + length
                guard length < 126, bytes.count >= total else { return nil }
                var payload = Array(bytes[(2 + (masked ? 4 : 0))..<total])
                if masked { for index in payload.indices { payload[index] ^= bytes[2 + index % 4] } }
                state.buffer = Data(bytes[total...])
                return (bytes[0] & 0x0f, Data(payload))
            }
            guard let frame else { return }
            switch frame.opcode {
            case 9:
                state.withLock { $0.pings.append(frame.payload) }
                if answerPings { send(Self.frame(opcode: 10, [UInt8](frame.payload)), on: connection) }
            case 10: state.withLock { $0.pongs.append(frame.payload) }
            case 8: state.withLock { $0.closeSeen = true }
            default: break
            }
        }
    }
}

@Suite struct URLSessionPSNWebSocketTests {
    @Test func upgradesWithOurHeadersAndTalksFrames() async throws {
        let server = try LoopbackWebSocketServer()
        let port = try await server.start()
        defer { server.stop() }
        let socket = URLSessionPSNWebSocket()
        let headers = [
            "Authorization": "Bearer TOKEN-MADE-UP", "Sec-WebSocket-Protocol": "np-pushpacket",
            "User-Agent": "WebSocket++/0.8.2", "X-PSN-APP-TYPE": "REMOTE_PLAY", "X-PSN-APP-VER": "RemotePlay/1.0",
            "X-PSN-KEEP-ALIVE-STATUS-TYPE": "3", "X-PSN-OS-VER": "Windows/10.0", "X-PSN-PROTOCOL-VERSION": "2.1",
            "X-PSN-RECONNECTION": "false",
        ]
        try await socket.open(url: URL(string: "ws://127.0.0.1:\(port)/np/pushNotification")!, headers: headers)
        let seen = server.seen
        #expect(seen.requestLine.hasPrefix("GET /np/pushNotification HTTP/1.1"))
        for (name, value) in headers {
            #expect(seen.requestHeaders[name.lowercased()] == value, "\(name)")
        }
        #expect(seen.requestHeaders["sec-websocket-version"] == "13")

        // A text frame from the server.
        #expect(try await socket.receive() == .text(PSNVector.memberDeletedFrame))
        // Our ping comes back as a pong (URLSession only reads while a receive is pending, as the channel's
        // reader always has); the server's ping was answered by the system with the same payload.
        let pending = Task { try await socket.receive() }
        try await socket.ping()
        pending.cancel()
        #expect(await eventually { server.seen.pongs == [Data("abc".utf8)] })
        try await socket.sendPong(Data())
        await socket.close()
        #expect(await eventually { server.seen.closeSeen })
    }

    @Test func aRejectedUpgradeThrows() async throws {
        let server = try LoopbackWebSocketServer(rejectWith: 403)
        let port = try await server.start()
        defer { server.stop() }
        let socket = URLSessionPSNWebSocket()
        await #expect(throws: (any Error).self) {
            try await socket.open(url: URL(string: "ws://127.0.0.1:\(port)/np/pushNotification")!, headers: [:])
        }
        await socket.close()
    }

    @Test func nothingListeningThrows() async throws {
        let server = try LoopbackWebSocketServer()
        let port = try await server.start()
        server.stop()
        // Wait for the port to close rather than for a fixed time.
        _ = await eventually { server.listener.state == .cancelled }
        let socket = URLSessionPSNWebSocket()
        await #expect(throws: (any Error).self) {
            try await socket.open(url: URL(string: "ws://127.0.0.1:\(port)/x")!, headers: [:])
        }
        await socket.close()
    }

    @Test func useBeforeOpenFails() async {
        let socket = URLSessionPSNWebSocket()
        await #expect(throws: URLError.self) { _ = try await socket.receive() }
        await #expect(throws: URLError.self) { try await socket.ping() }
        await socket.close()
    }

    @Test func cancellingTheOpenStopsIt() async throws {
        // A server that accepts the TCP connection and never answers the upgrade.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let silent = try NWListener(using: parameters)
        let connections = OSAllocatedUnfairLock(initialState: 0)
        silent.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connections.withLock { $0 += 1 }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = OSAllocatedUnfairLock(initialState: false)
            silent.stateUpdateHandler = { state in
                if case .ready = state, !once.withLock({ done in defer { done = true }; return done }) {
                    continuation.resume(returning: silent.port?.rawValue ?? 0)
                }
            }
            silent.start(queue: .global())
        }
        defer { silent.cancel() }
        let socket = URLSessionPSNWebSocket()
        let task = Task { try await socket.open(url: URL(string: "ws://127.0.0.1:\(port)/x")!, headers: [:]) }
        _ = await eventually { connections.withLock { $0 } >= 1 }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        await socket.close()
    }
}
