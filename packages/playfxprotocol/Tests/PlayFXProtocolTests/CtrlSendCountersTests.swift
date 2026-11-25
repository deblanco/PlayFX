import Foundation
import Testing

@testable import PlayFXProtocol

/// Which counter each encrypted ctrl message takes (ctrl.md sections 4 and 10): never the same one twice.
@Suite struct CtrlSendCountersTests {
    @Test func theLanCountersRunOnFromTheRequest() {
        var counters = CtrlSendCounters(next: 5, skipsOne: false)
        #expect(counters.take(pinReply: false) == 5)
        // On the LAN a PIN reply is an ordinary message.
        #expect(counters.take(pinReply: true) == 6)
        #expect(counters.take(pinReply: false) == 7)
    }

    @Test func aPS5sFirstPINReplyTakesTheSkippedCounterThenTheOthersContinueAtSeven() {
        var counters = CtrlSendCounters(next: 5, skipsOne: true)
        #expect(counters.skipped == 5 && counters.next == 6)
        #expect(counters.take(pinReply: true) == 5)
        #expect(counters.take(pinReply: false) == 7)
        #expect(counters.take(pinReply: false) == 8)
    }

    @Test func aSecondPINReplyTakesAFreshCounter() {
        var counters = CtrlSendCounters(next: 5, skipsOne: true)
        #expect(counters.take(pinReply: true) == 5)
        #expect(counters.take(pinReply: true) == 7)
        #expect(counters.take(pinReply: true) == 8)
    }

    @Test func aPS4sPINReplyTakesAFreshCounter() {
        // A PS4 skips nothing, so there is no counter to take: the reply uses the next fresh one.
        var counters = CtrlSendCounters(next: 4, skipsOne: false)
        #expect(counters.skipped == nil)
        #expect(counters.take(pinReply: true) == 4)
        #expect(counters.take(pinReply: true) == 5)
    }

    @Test func whenNoPINIsAskedTheSkippedCounterStaysUnusedButIsNotTakenByOthers() {
        var counters = CtrlSendCounters(next: 5, skipsOne: true)
        #expect(counters.take(pinReply: false) == 6)
        #expect(counters.take(pinReply: true) == 5)
        // Like any message it advances the counter (ctrl.md section 10: "localCounter still advances").
        #expect(counters.take(pinReply: false) == 8)
    }

    @Test func noCounterIsEverUsedTwiceAcrossAnySequence() {
        for skipsOne in [false, true] {
            var counters = CtrlSendCounters(next: 5, skipsOne: skipsOne)
            var seen = Set<UInt64>()
            for step in 0..<200 {
                let counter = counters.take(pinReply: step % 3 == 0)
                #expect(counter != nil && seen.insert(counter!).inserted)
            }
        }
    }

    @Test func aRepeatedCounterIsRefused() {
        // A state that would hand out a used counter (it can't be reached through `take` alone): the guard says no.
        var counters = CtrlSendCounters(next: 5, skipped: 5)
        #expect(counters.take(pinReply: false) == 5)
        // `next` was 5 and is now 6, `skipped` is still 5 and used: asking for it again is refused.
        #expect(counters.take(pinReply: true) == nil)
    }
}
