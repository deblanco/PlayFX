import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

/// The small pieces of the session layer on their own: error mapping, the mailbox, the event gate.
@Suite struct StreamSessionUnitTests {
    @Test func sessionErrorsMapToTheEndReasonsOfSection11() {
        func code(_ error: SessionError, _ stage: StreamStartError.Stage) -> StreamEndCode? {
            StreamStartError.session(error, stage: stage).endReason?.code
        }
        #expect(code(.consoleBusy, .sessionInit) == .consoleBusy && code(.consoleBusy, .ctrl) == .consoleBusy)
        #expect(code(.remotePlayCrashed, .ctrl) == .remotePlayCrashed && code(.versionMismatch, .sessionInit) == .versionMismatch)
        #expect(code(.noAnswer(.connectionRefused), .sessionInit) == .sessionInitRefused)
        #expect(code(.noAnswer(.connectionRefused), .ctrl) == .ctrlRefused)
        #expect(code(.noAnswer(.timeout), .sessionInit) == .sessionInitUnknown && code(.noAnswer(.timeout), .ctrl) == .ctrlConnectFailed)
        #expect(code(.network(.permissionDenied), .sessionInit) == .sessionInitUnknown)
        #expect(code(.network(.permissionDenied), .ctrl) == .ctrlConnectFailed)
        #expect(code(.ctrlRejected(status: 403), .ctrl) == .ctrlFailed && code(.ctrlResetRepeatedly, .ctrl) == .ctrlFailed)
        #expect(code(.invalidResponse, .ctrl) == .ctrlFailed && code(.invalidResponse, .sessionInit) == .sessionInitUnknown)
        #expect(code(.refused(reason: 5), .sessionInit) == .sessionInitUnknown && code(.refused(reason: nil), .ctrl) == .ctrlFailed)
        #expect(code(.invalidInput, .sessionInit) == .sessionInitUnknown && code(.cryptoFailure, .ctrl) == .sessionInitUnknown)
        #expect(code(.cancelled, .ctrl) == .sessionInitUnknown)
        #expect(StreamStartError.cancelled.endReason == nil)
    }

    @Test func startErrorsHaveUserMessages() {
        #expect(StreamStartError.session(.consoleBusy, stage: .sessionInit).userMessage(console: .ps4).contains("PS4"))
        #expect(StreamStartError.stream(StreamEndReason(code: .streamFailed), detail: "x").userMessage(console: .ps5).contains("PS5"))
        #expect(StreamStartError.cancelled.userMessage(console: .ps5).isEmpty)
        #expect(StreamTransport.bsd.name == "bsd" && StreamTransport.nw.name == "nw")
    }

    @Test func theMailboxHandsOverTheFirstMatchAndDropsWhatCameBefore() {
        let box = Mailbox<Int>(capacity: 4)
        for n in 1...6 { box.post(n) }  // capacity 4: 3, 4, 5, 6 are left
        #expect(box.take(timeout: 0.1) { $0 == 4 ? "four" : nil } == "four")
        // 3 was dropped on the way to 4; 5 and 6 are still there.
        #expect(box.take(timeout: 0.05) { $0 == 3 ? "three" : nil } == nil)
        box.post(7)
        #expect(box.take(timeout: 0.1) { $0 == 7 ? true : nil } == true)
    }

    @Test func theMailboxWakesOnAPostAndGivesUpOnAbortOrTimeout() async {
        let box = Mailbox<Int>()
        Thread.detachNewThread {
            usleep(30_000)
            box.post(42)
        }
        #expect(box.take(timeout: 2) { $0 == 42 ? $0 : nil } == 42)
        let started = monotonicSeconds()
        #expect(box.take(timeout: 5, abort: { monotonicSeconds() - started > 0.05 }) { _ in 1 } == nil)
        #expect(monotonicSeconds() - started < 1)
        #expect(box.take(timeout: 0.03) { _ in 1 } == nil)
    }

    @Test func theGateStopsCallsAndWaitsForTheOnesInFlight() async throws {
        let calls = Locked(0)
        let gate = EventGate { _, _ in calls.with { $0 += 1 } }
        let handler = try #require(gate.enter())
        _ = handler
        let closed = Locked(false)
        Thread.detachNewThread {
            _ = gate.close()
            closed.with { $0 = true }
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        // `close` is waiting for the call in flight, and nobody new gets in.
        #expect(!closed.with { $0 })
        #expect(gate.enter() == nil)
        gate.leave()
        #expect(await waitUntil { closed.with { $0 } })
        #expect(gate.close() == nil)
    }

    @Test func theTimestampSourceNamesWhereReceiveTimesComeFrom() {
        var stats = TakionStats()
        let bsd = BSDDatagramTransport(host: "127.0.0.1", port: 9)
        #expect(StreamSession.timestampSource(of: bsd, stats) == "none")
        let nw = NWDatagramTransport(host: "127.0.0.1", port: 9)
        #expect(StreamSession.timestampSource(of: nw, stats) == "none yet")
        stats.datagramsReceived = 10
        stats.softwareTimestamps = 10
        #expect(StreamSession.timestampSource(of: nw, stats) == "callback time")
        stats.softwareTimestamps = 3
        #expect(StreamSession.timestampSource(of: nw, stats) == "receiveTime metadata")
    }
}
