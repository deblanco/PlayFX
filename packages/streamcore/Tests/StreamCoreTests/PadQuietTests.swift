import Foundation
import GameController
import os
import Testing
@testable import StreamCore

extension Serial {
    /// Serial: PadQuiet's outputs, its "ending" flag and its seams are process-wide.
    @Suite struct PadQuietTests {
        /// What happened, in order, across the stand-ins.
        final class Journal: Sendable {
            let entries = OSAllocatedUnfairLock(initialState: [String]())
            func add(_ entry: String) { entries.withLock { $0.append(entry) } }
            var all: [String] { entries.withLock { $0 } }
        }

        final class StandInOutput: PadOutput {
            let name: String
            let journal: Journal
            init(_ name: String, _ journal: Journal) {
                self.name = name
                self.journal = journal
                PadQuiet.register(self)
            }
            func quiet() { journal.add(name) }
        }

        /// Runs `body` with the triggers' release journaled (and where it ran), then puts everything back.
        func withStandIns(_ body: (Journal) async throws -> Void) async rethrows {
            let journal = Journal()
            let (realRelease, realEnd) = (PadQuiet.releaseTriggers, PadQuiet.end)
            PadQuiet.releaseTriggers = { journal.add(Thread.isMainThread ? "triggers (main)" : "triggers (elsewhere)") }
            PadQuiet.end = { journal.add("end \($0)") }
            defer {
                (PadQuiet.releaseTriggers, PadQuiet.end) = (realRelease, realEnd)
                PadQuiet.ending.withLock { $0 = false }
            }
            try await body(journal)
        }

        @Test func stopsEveryOutputThenReleasesTheTriggersOnTheMainQueue() async {
            await withStandIns { journal in
                let outputs = [StandInOutput("rumble", journal), StandInOutput("haptics", journal)]
                #expect(!PadQuiet.isEnding)
                #expect(PadQuiet.now()) // from a test's thread, not the main one
                #expect(PadQuiet.isEnding)
                #expect(journal.all == ["rumble", "haptics", "triggers (main)"])
                withExtendedLifetime(outputs) {}
            }
        }

        @Test func canRunAgainAndForgetsOutputsThatAreGone() async {
            await withStandIns { journal in
                let kept = StandInOutput("kept", journal)
                _ = StandInOutput("gone", journal) // released at once
                PadQuiet.now()
                sc_quiet_pads() // the app quitting after a signal, say: the same again
                #expect(journal.all == ["kept", "triggers (main)", "kept", "triggers (main)"])
                withExtendedLifetime(kept) {}
            }
        }

        @Test @MainActor func onTheMainQueueItRunsAtOnce() {
            let journal = Journal()
            let saved = PadQuiet.releaseTriggers
            PadQuiet.releaseTriggers = { journal.add(Thread.isMainThread ? "triggers (main)" : "triggers (elsewhere)") }
            defer {
                PadQuiet.releaseTriggers = saved
                PadQuiet.ending.withLock { $0 = false }
            }
            #expect(PadQuiet.now(timeout: 0)) // no waiting: done before it returns
            #expect(journal.all == ["triggers (main)"])
        }

        @Test func aStuckMainQueueDoesntHoldTheProcess() async {
            await withStandIns { journal in
                let output = StandInOutput("rumble", journal)
                DispatchQueue.main.async { Thread.sleep(forTimeInterval: 0.3) }
                #expect(!PadQuiet.now(timeout: 0.05)) // the outputs are stopped; the triggers wait for the main queue
                #expect(journal.all == ["rumble"])
                #expect(await waitUntil { journal.all.count == 2 })
                #expect(journal.all.last == "triggers (main)")
                withExtendedLifetime(output) {}
            }
        }

        @Test func nothingDrivesAPadOnceTheProcessIsEnding() async {
            await withStandIns { _ in
                let rumble = Rumble()
                PadQuiet.now()
                let looked = OSAllocatedUnfairLock(initialState: 0)
                let saved = Rumble.controllers
                Rumble.controllers = { looked.withLock { $0 += 1 }; return [] }
                defer { Rumble.controllers = saved }
                rumble.apply(left: 200, right: 100)
                rumble.stop() // waits for the apply
                #expect(rumble.levels == .init(left: 200, right: 100)) // asked for, but not sent to any pad
                #expect(looked.withLock { $0 } == 0)
                AdaptiveTriggers().apply(left: .weapon(start: 0.2, end: 0.6, strength: 1), right: .off)
                await MainActor.run {} // the queued apply: dropped

                PadQuiet.ending.withLock { $0 = false }
                rumble.apply(left: 10, right: 0)
                rumble.stop()
                #expect(looked.withLock { $0 } > 0)
            }
        }

        @Test func rumbleWithNothingPlayingQuietsAtOnce() {
            let rumble = Rumble()
            rumble.apply(left: 255, right: 0)
            let start = Date()
            rumble.quiet()
            #expect(Date().timeIntervalSince(start) < Rumble.quietTimeout) // no engine to wait for
        }

        @Test func signalsQuietThePadsBeforeTheProcessEnds() async {
            await withStandIns { journal in
                let output = StandInOutput("haptics", journal)
                #expect(PadQuiet.installSignalHandlers { journal.add("clean up") })
                #expect(!PadQuiet.installSignalHandlers()) // once
                sc_install_signal_handlers() // the app's call: already done
                #expect(PadQuiet.installedSignals == PadQuiet.signals.count)
                #expect(!PadQuiet.signals.contains(SIGKILL)) // can't be caught

                kill(getpid(), SIGHUP)
                #expect(await waitUntil { journal.all.contains("end \(SIGHUP)") })
                #expect(journal.all == ["clean up", "haptics", "triggers (main)", "end \(SIGHUP)"])
                withExtendedLifetime(output) {}
            }
        }
    }
}
