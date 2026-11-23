import Testing

@testable import PlayFXProtocol

@Suite struct StreamEndTests {
    @Test func messagesForEachKind() {
        let ps5 = StreamConsoleName.ps5, ps4 = StreamConsoleName.ps4
        #expect(
            StreamEndReason(code: .streamRemoteShutdown).userMessage(console: ps5)
                == "The PS5 ended the stream (it's shutting down or going to rest mode).")
        #expect(
            StreamEndReason(code: .streamFailed).userMessage(console: ps4) == "The connection to the PS4 was lost.")
        #expect(
            StreamEndReason(code: .ctrlFailed).userMessage(console: ps5) == "The connection to the PS5 was lost.")
        #expect(
            StreamEndReason(code: .consoleBusy).userMessage(console: ps5) == "The PS5 ended the stream (reason 4).")
        #expect(
            StreamEndReason(code: .streamRemoteDisconnected, remoteText: "x").userMessage(console: ps4)
                == "The PS4 ended the stream (reason 11).")
        #expect(StreamEndReason(code: .stoppedByClient).userMessage(console: ps5) == "The stream was stopped.")
        var someone = StreamEndReason(code: .streamRemoteDisconnected)
        someone.kind = .someoneStartedPlaying
        #expect(someone.userMessage(console: ps5) == "Someone started playing on the PS5, so the stream ended.")
        someone.kind = .anotherSessionTookOver
        #expect(someone.userMessage(console: ps4) == "Another device started Remote Play on the PS4.")
    }

    @Test func consoleDisconnects() {
        let shutdown = StreamEndReason(consoleDisconnect: "Server shutting down")
        #expect(shutdown.code == .streamRemoteShutdown && shutdown.kind == .consoleShuttingDown)
        #expect(!shutdown.isError && shutdown.retryClass == .final)
        #expect(shutdown.remoteText == "Server shutting down")
        let other = StreamEndReason(consoleDisconnect: "Something else")
        #expect(other.code == .streamRemoteDisconnected && other.kind == .other)
        #expect(other.isError && other.remoteText == "Something else" && other.retryClass == .final)
    }

    @Test func reasonTableIsExtensible() {
        // The table is a plain dictionary: a console reason seen later maps to a typed kind without code changes
        // elsewhere. Only the shutdown text is recorded in the spec.
        #expect(StreamEndReason.consoleReasonKinds.count == 1)
        #expect(StreamEndReason.consoleReasonKinds[DisconnectMessage.serverShuttingDownReason] == .consoleShuttingDown)
    }

    @Test func codesAndClasses() {
        #expect(StreamEndCode.allCases.map(\.rawValue) == Array(0...14))
        #expect(StreamEndReason(rawCode: 10).code == .streamFailed)
        #expect(StreamEndReason(rawCode: 99).code == .unknown)
        #expect(StreamEndReason(rawCode: -1).code == .unknown)
        let classes: [(StreamEndCode, StreamRetryClass, Bool)] = [
            (.unknown, .final, true), (.stoppedByClient, .stopped, false), (.consoleBusy, .busy, true),
            (.ctrlFailed, .dropped, true), (.streamFailed, .dropped, true), (.streamRemoteShutdown, .final, false),
            (.versionMismatch, .final, true),
        ]
        for (code, retry, error) in classes {
            let reason = StreamEndReason(code: code)
            #expect(reason.retryClass == retry && reason.isError == error, "\(code)")
        }
    }

    @Test func consoleNames() {
        #expect(StreamConsoleName(target: .ps5v1) == .ps5)
        #expect(StreamConsoleName(target: .ps4v10) == .ps4)
        #expect(StreamConsoleName(target: .ps4v9).rawValue == "PS4")
    }
}
