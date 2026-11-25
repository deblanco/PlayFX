import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

@Suite struct PSNPushChannelTests {
    static func open(
        _ socket: FakeWebSocket, timeouts: PSNTimeouts = PSNVector.fastTimeouts()
    ) async throws -> PSNPushChannel {
        try await PSNPushChannel.open(
            host: "push.example.test", accessToken: PSNVector.token, socket: socket, timeouts: timeouts)
    }

    /// Timeouts that keep the keep-alive quiet so only the behaviour under test runs.
    static func quiet() -> PSNTimeouts {
        var timeouts = PSNVector.fastTimeouts()
        timeouts.pingInterval = 60
        return timeouts
    }

    // MARK: Opening (section 5.2)

    @Test func opensWithTheSpecifiedHeaders() async throws {
        let socket = FakeWebSocket()
        let channel = try await Self.open(socket, timeouts: Self.quiet())
        #expect(socket.openedURL?.absoluteString == "wss://push.example.test/np/pushNotification")
        #expect(
            socket.openedHeaders == [
                "Authorization": "Bearer TOKEN-MADE-UP", "Sec-WebSocket-Protocol": "np-pushpacket",
                "User-Agent": "WebSocket++/0.8.2", "X-PSN-APP-TYPE": "REMOTE_PLAY", "X-PSN-APP-VER": "RemotePlay/1.0",
                "X-PSN-KEEP-ALIVE-STATUS-TYPE": "3", "X-PSN-OS-VER": "Windows/10.0", "X-PSN-PROTOCOL-VERSION": "2.1",
                "X-PSN-RECONNECTION": "false",
            ])
        #expect(await channel.isOpen)
        await channel.close()
        #expect(!(await channel.isOpen))
    }

    @Test func clientOpensTheChannelThroughTheServerLookup() async throws {
        let psn = FakePSN()
        let channel = try await PSNClient(accessToken: PSNVector.token, transport: psn, timeouts: Self.quiet())
            .openPushChannel(socket: psn.socket)
        #expect(psn.socket.openedURL?.host == "push.example.test")
        await channel.close()
    }

    @Test func rejectsAnInvalidHost() async {
        for host in ["", "a b", "evil.test/path?x"] {
            await #expect(throws: PSNError.invalidResponse(step: .pushServerAddress, reason: "bad host")) {
                _ = try await PSNPushChannel.open(
                    host: host, accessToken: PSNVector.token, socket: FakeWebSocket(), timeouts: Self.quiet())
            }
        }
    }

    @Test func openFailureAndTimeout() async {
        let failing = FakeWebSocket()
        failing.failOpen(with: URLError(.cannotConnectToHost))
        do {
            _ = try await Self.open(failing)
            Issue.record("opened")
        } catch let PSNError.webSocketFailed(description) {
            #expect(!description.isEmpty)
        } catch {
            Issue.record("wrong error \(error)")
        }
        #expect(failing.closeCount == 1)

        let hanging = FakeWebSocket()
        hanging.hangOpen()
        await #expect(throws: PSNError.timedOut(step: .webSocketConnect)) { _ = try await Self.open(hanging) }
        #expect(hanging.closeCount == 1)
    }

    @Test func openCancellation() async {
        let hanging = FakeWebSocket()
        hanging.hangOpen()
        let task = Task { try await Self.open(hanging, timeouts: PSNTimeouts()) }
        _ = await eventually { hanging.openedURL != nil }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("opened")
        } catch {
            #expect(error is CancellationError)
        }
    }

    // MARK: Notifications and the inbox

    @Test func decodesFramesInArrivalOrderAndBuffersThem() async throws {
        let socket = FakeWebSocket()
        let channel = try await Self.open(socket, timeouts: Self.quiet())
        socket.emit(.text(PSNVector.createdFrame))
        socket.emit(.binary(Data(PSNVector.memberFrame().utf8)))
        socket.emit(.text("not json"))
        socket.emit(.text(#"{"dataType":"psn:something:else"}"#))
        socket.emit(.text(PSNVector.customDataFrame()))
        // Take them out of order: each step takes the first of the type it waits for.
        let data = try await channel.inbox.take(step: .waitCustomData, timeout: 1) {
            if case .customDataUpdated = $0 { return true }
            return false
        }
        #expect(data == .customDataUpdated(customData1: PSNVector.customData1Text))
        let member = try await channel.inbox.take(step: .waitMemberJoined, timeout: 1) {
            if case .memberJoined = $0 { return true }
            return false
        }
        #expect(member == .memberJoined(deviceUniqueID: PSNVector.duid))
        let created = try await channel.inbox.take(step: .waitSessionCreated, timeout: 1) { _ in true }
        #expect(created == .sessionCreated(onlineID: "playfx-tester"))
        await channel.close()
    }

    @Test func aWaiterGetsALaterNotification() async throws {
        let socket = FakeWebSocket()
        let channel = try await Self.open(socket, timeouts: Self.quiet())
        let waiting = Task {
            try await channel.inbox.take(step: .waitMemberJoined, timeout: 5) {
                if case .memberJoined = $0 { return true }
                return false
            }
        }
        socket.emit(.text(PSNVector.customDataFrame()))  // not wanted: stays buffered
        socket.emit(.text(PSNVector.memberFrame()))
        #expect(try await waiting.value == .memberJoined(deviceUniqueID: PSNVector.duid))
        await channel.close()
    }

    @Test func takeTimesOutAndCancels() async throws {
        let channel = try await Self.open(FakeWebSocket(), timeouts: Self.quiet())
        await #expect(throws: PSNError.timedOut(step: .waitOffer)) {
            _ = try await channel.inbox.take(step: .waitOffer, timeout: 0.05) { _ in true }
        }
        let waiting = Task { try await channel.inbox.take(step: .waitOffer, timeout: 30) { _ in true } }
        waiting.cancel()
        do {
            _ = try await waiting.value
            Issue.record("returned")
        } catch {
            #expect(error is CancellationError)
        }
        // Cancelled before it even starts.
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await channel.inbox.take(step: .waitOffer, timeout: 30) { _ in true }
        }
        do {
            _ = try await early.value
            Issue.record("returned")
        } catch {
            #expect(error is CancellationError)
        }
        await channel.close()
    }

    // MARK: Deletion (section 5.4)

    @Test func deletionOfAnotherSessionIsIgnored() async throws {
        let socket = FakeWebSocket()
        let channel = try await Self.open(socket, timeouts: Self.quiet())
        await channel.inbox.bind(sessionID: PSNVector.sessionID)
        socket.emit(.text(PSNVector.sessionDeletedFrame("aaaaaaaa-1d3f-4e6a-9b7c-0d1e2f3a4b5c")))
        socket.emit(.text(PSNVector.memberDeletedFrame))
        _ = try await channel.inbox.take(step: .waitDeletion, timeout: 1) { $0 == .memberLeft }
        #expect(await channel.isOpen)
        await #expect(throws: PSNError.timedOut(step: .waitDeletion)) {
            _ = try await channel.inbox.take(step: .waitDeletion, timeout: 0.05) {
                if case .sessionDeleted = $0 { return true }
                return false
            }
        }
        await channel.close()
    }

    @Test func deletionOfThisSessionEndsPendingWaits() async throws {
        let socket = FakeWebSocket()
        let channel = try await Self.open(socket, timeouts: Self.quiet())
        await channel.inbox.bind(sessionID: PSNVector.sessionID)
        let waiting = Task { try await channel.inbox.take(step: .waitOffer, timeout: 5) { $0 == .memberLeft } }
        socket.emit(.text(PSNVector.sessionDeletedFrame()))
        await #expect(throws: PSNError.sessionEnded) { _ = try await waiting.value }
        #expect(!(await channel.isOpen))
        // The deletion itself stays takeable (leave waits for it), then later waits fail at once.
        let deleted = try await channel.inbox.take(step: .waitDeletion, timeout: 1) {
            if case .sessionDeleted = $0 { return true }
            return false
        }
        #expect(deleted == .sessionDeleted(sessionID: PSNVector.sessionID))
        await #expect(throws: PSNError.sessionEnded) { _ = try await channel.inbox.take(step: .waitOffer, timeout: 1) { _ in true } }
        await channel.close()
    }

    @Test func deletionWithoutAnIDEndsTheSession() async throws {
        let socket = FakeWebSocket()
        let channel = try await Self.open(socket, timeouts: Self.quiet())
        socket.emit(.text(PSNVector.sessionDeletedFrame(nil)))
        _ = await eventually { true }
        await #expect(throws: PSNError.sessionEnded) {
            _ = try await channel.inbox.take(step: .waitOffer, timeout: 1) { $0 == .memberLeft }
        }
        await channel.close()
    }

    // MARK: Close, errors and keep-alive (section 5.3)

    @Test func receiveErrorEndsTheChannel() async throws {
        let socket = FakeWebSocket()
        let channel = try await Self.open(socket, timeouts: Self.quiet())
        let waiting = Task { try await channel.inbox.take(step: .waitOffer, timeout: 5) { _ in true } }
        socket.drop()
        await #expect(throws: PSNError.pushChannelClosed) { _ = try await waiting.value }
        #expect(!(await channel.isOpen))
        await channel.close()
    }

    @Test func closeFailsPendingWaitsAndIsRepeatable() async throws {
        let socket = FakeWebSocket()
        let channel = try await Self.open(socket, timeouts: Self.quiet())
        let waiting = Task { try await channel.inbox.take(step: .waitOffer, timeout: 5) { _ in true } }
        await channel.close()
        await #expect(throws: PSNError.pushChannelClosed) { _ = try await waiting.value }
        await channel.close()
        #expect(socket.closeCount == 1)  // the socket is closed once, however often close() runs
    }

    @Test func pingsAtTheIntervalAndSurvivesWhilePongsCome() async throws {
        let socket = FakeWebSocket()
        let channel = try await Self.open(socket)
        #expect(await eventually { socket.pings >= 3 })
        #expect(await channel.isOpen)
        await channel.close()
    }

    @Test func aMissingPongKillsTheChannel() async throws {
        let socket = FakeWebSocket()
        socket.setPingBehavior(.hang)
        let channel = try await Self.open(socket)
        let waiting = Task { try await channel.inbox.take(step: .waitOffer, timeout: 5) { _ in true } }
        await #expect(throws: PSNError.pushChannelNotResponding) { _ = try await waiting.value }
        #expect(!(await channel.isOpen))
        #expect(await eventually { socket.closeCount >= 1 })
        await channel.close()
    }

    @Test func aFailedPingKillsTheChannel() async throws {
        let socket = FakeWebSocket()
        socket.setPingBehavior(.fail)
        let channel = try await Self.open(socket)
        let waiting = Task { try await channel.inbox.take(step: .waitOffer, timeout: 5) { _ in true } }
        await #expect(throws: PSNError.pushChannelClosed) { _ = try await waiting.value }
        await channel.close()
    }

    @Test func answersServerPingsWithTheSamePayload() async throws {
        let socket = FakeWebSocket()
        let channel = try await Self.open(socket, timeouts: Self.quiet())
        socket.emit(.ping(Data([1, 2, 3])))
        socket.emit(.ping(Data()))
        #expect(await eventually { socket.pongs.count == 2 })
        #expect(socket.pongs == [Data([1, 2, 3]), Data()])
        await channel.close()
    }
}
