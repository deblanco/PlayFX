import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

@Suite struct ControllerScriptTests {
    // MARK: Parsing

    @Test func theDocumentedExampleParses() throws {
        let script = try ControllerScript(parsing: "ps@2,circle@4,circle@5.5,cross+up@7:300,ly=-1@9:2000")
        #expect(script.entries.count == 5)
        #expect(script.entries[0] == .init(input: .buttons(["ps"]), start: 2, holdMilliseconds: 150))
        #expect(script.entries[3] == .init(input: .buttons(["cross", "up"]), start: 7, holdMilliseconds: 300))
        #expect(script.entries[4] == .init(input: .axis(.ly, -1), start: 9, holdMilliseconds: 2000))
        #expect(script.duration == 11)
        #expect(script.entries.map(\.label) == [
            "press ps (150 ms)", "press circle (150 ms)", "press circle (150 ms)", "press cross+up (300 ms)",
            "hold ly=-1 (2000 ms)",
        ])
    }

    @Test func namesAreCaseInsensitiveAndSpacesAroundEntriesAreIgnored() throws {
        let script = try ControllerScript(parsing: " Circle@1 , RX=0.5@2:10 ")
        #expect(script.entries.map(\.input) == [.buttons(["circle"]), .axis(.rx, 0.5)])
    }

    @Test func everyButtonNameParsesAndSetsItsBit() throws {
        let expected: [(String, ControllerButtons)] = [
            ("cross", .cross), ("circle", .circle), ("square", .square), ("triangle", .triangle), ("l1", .l1),
            ("r1", .r1), ("l3", .l3), ("r3", .r3), ("options", .options), ("share", .share), ("create", .share),
            ("ps", .ps), ("touchpad", .touchpad), ("up", .dpadUp), ("down", .dpadDown), ("left", .dpadLeft),
            ("right", .dpadRight),
        ]
        for (name, bits) in expected {
            let script = try ControllerScript(parsing: "\(name)@0")
            var want = ControllerState.idle
            want.buttons = bits
            #expect(script.state(at: 0) == want, "\(name)")
        }
        var triggers = ControllerState.idle
        triggers.l2 = 255
        triggers.r2 = 255
        #expect(try ControllerScript(parsing: "l2+r2@0").state(at: 0) == triggers)
    }

    @Test(arguments: [
        ("", "the script is empty"),
        ("circle@1,", "an entry is empty"),
        ("circle@1,,cross@2", "an entry is empty"),
        ("circle", "expected INPUT@SECONDS"),
        ("@1", "expected INPUT@SECONDS"),
        ("circle@1@2", "expected INPUT@SECONDS"),
        ("bogus@1", "unknown button or axis \"bogus\""),
        ("cross+bogus@1", "unknown button or axis \"bogus\""),
        ("cross+@1", "unknown button or axis \"\""),
        ("lz=1@1", "unknown button or axis \"lz\""),
        ("cross=1@1", "unknown button or axis \"cross\""),
        ("lx=1=2@1", "expected AXIS=VALUE"),
        ("=1@1", "unknown button or axis \"\""),
        ("circle@4:150,circle@4.15:150", "would not be released"),
        ("circle@4:150,circle@4.165:150", "would not be released"),
        ("cross+up@1,up@1.15", "would not be released"),
        ("l2@1,l2@1.15", "would not be released"),
        ("circle@x", "\"x\" is not a number"),
        ("circle@", "\"\" is not a number"),
        ("circle@nan", "is not a number"),
        ("circle@inf", "is not a number"),
        ("circle@1:", "\"\" is not a number"),
        ("circle@1:x", "\"x\" is not a number"),
        ("circle@1:1.5", "\"1.5\" is not a number"),
        ("circle@1:2:3", "is not a number"),
        ("circle@-0.5", "the time can't be negative"),
        ("circle@1:0", "the hold must be at least 1 ms"),
        ("circle@1:-5", "the hold must be at least 1 ms"),
        ("lx=x@1", "\"x\" is not a number"),
        ("lx=nan@1", "\"nan\" is not a number"),
        ("lx=1.5@1", "1.5 is out of range for lx (-1 to 1)"),
        ("ry=-1.01@1", "-1.01 is out of range for ry (-1 to 1)"),
        ("l2=-0.1@1", "-0.1 is out of range for l2 (0 to 1)"),
        ("r2=1.1@1", "1.1 is out of range for r2 (0 to 1)"),
    ])
    func badScriptsAreRefusedWithAClearMessage(text: String, message: String) {
        do {
            _ = try ControllerScript(parsing: text)
            Issue.record("\"\(text)\" should not parse")
        } catch let error as ControllerScriptError {
            #expect(error.description.contains(message), "\(error)")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func aReleaseOfOneFrameOrMoreIsAllowedAndOverlapsStillCombine() throws {
        _ = try ControllerScript(parsing: "circle@4:150,circle@4.17:150")
        _ = try ControllerScript(parsing: "circle@4:150,cross@4.15")  // another button: no release needed
        _ = try ControllerScript(parsing: "circle@4:1000,circle@4.5:100")  // an overlap is meant to combine
        _ = try ControllerScript(parsing: "lx=1@1:1000,lx=-1@2:1000")  // axes can change without a gap
    }

    @Test func theErrorsAreEquatableValues() {
        #expect(throws: ControllerScriptError.negativeTime("circle@-1")) { try ControllerScript(parsing: "circle@-1") }
        #expect(throws: ControllerScriptError.emptyScript) { try ControllerScript(parsing: "") }
        #expect(throws: ControllerScriptError.valueOutOfRange(entry: "ly=2@1", axis: "ly", value: 2)) {
            try ControllerScript(parsing: "ly=2@1")
        }
    }

    // MARK: The timeline

    @Test func aPressLastsItsHoldAndThenReturnsToNeutral() throws {
        let script = try ControllerScript(parsing: "circle@4,cross+up@7:300")
        var circle = ControllerState.idle
        circle.buttons = .circle
        #expect(script.state(at: 3.999) == .idle)
        #expect(script.state(at: 4) == circle)
        #expect(script.state(at: 4.149) == circle)
        #expect(script.state(at: 4.15) == .idle)
        var both = ControllerState.idle
        both.buttons = [.cross, .dpadUp]
        #expect(script.state(at: 7.2) == both)
        #expect(script.state(at: 7.3) == .idle)
        #expect(script.state(at: 100) == .idle)
    }

    @Test func overlappingEntriesCombine() throws {
        let script = try ControllerScript(parsing: "circle@1:1000,cross@1.5:200,lx=1@1:1000,ly=-1@1.5:200,lx=-1@1.5:200,l2=0.5@1:1000,l2@1.5:200")
        var state = ControllerState.idle
        state.buttons = .circle
        state.leftStickX = 32767
        state.l2 = 128
        #expect(script.state(at: 1.25) == state)
        // Both buttons, the later entry wins on lx, ly is up (negative), and the full l2 press beats the 0.5.
        state.buttons = [.circle, .cross]
        state.leftStickX = -32768
        state.leftStickY = -32768
        state.l2 = 255
        #expect(script.state(at: 1.6) == state)
        state.buttons = .circle
        state.leftStickX = 32767
        state.leftStickY = 0
        state.l2 = 128
        #expect(script.state(at: 1.8) == state)
    }

    @Test func axisValuesMapToTheWireRanges() throws {
        func state(_ text: String) throws -> ControllerState { try ControllerScript(parsing: text).state(at: 0) }
        #expect(try state("lx=1@0").leftStickX == 32767)
        #expect(try state("lx=-1@0").leftStickX == -32768)
        #expect(try state("ly=0@0").leftStickY == 0)
        #expect(try state("rx=0.5@0").rightStickX == 16384)
        #expect(try state("ry=-0.5@0").rightStickY == -16384)
        #expect(try state("l2=1@0").l2 == 255)
        #expect(try state("r2=0.5@0").r2 == 128)
        #expect(try state("r2=0@0").r2 == 0)
    }

    @Test func nextChangeIsTheNextStartOrEnd() throws {
        let script = try ControllerScript(parsing: "circle@4,cross@4.1:500")
        #expect(script.nextChange(after: 0) == 4)
        #expect(script.nextChange(after: 4) == 4.1)
        #expect(script.nextChange(after: 4.1) == 4.15)
        #expect(script.nextChange(after: 4.15) == 4.6)
        #expect(script.nextChange(after: 4.6) == nil)
        #expect(ControllerScript(entries: []).nextChange(after: 0) == nil)
        #expect(ControllerScript(entries: []).duration == 0)
        #expect(ControllerScript(entries: []).state(at: 1) == .idle)
    }
}

@Suite struct ControllerScriptPlayerTests {
    private func circle() -> ControllerState {
        var state = ControllerState.idle
        state.buttons = .circle
        return state
    }

    @Test func aOneMillisecondPressIsSentEvenWhenTheWakeUpIsLate() throws {
        var player = ControllerScript.Player(try ControllerScript(parsing: "circle@5:1"))
        #expect(player.step(to: 4.9).sends.isEmpty)
        let step = player.step(to: 5.2)  // woke 200 ms late: both boundaries are in the interval
        #expect(step.sends == [
            .init(time: 5, state: circle(), announcements: ["press circle (1 ms)"]),
            .init(time: 5.001, state: .idle, announcements: []),
        ])
        #expect(step.current == .idle && step.nextWake == nil)
        #expect(player.step(to: 5.2).sends.isEmpty)
    }

    @Test func aStallOverTheWholeScriptStillSendsEveryStateInOrder() throws {
        var player = ControllerScript.Player(try ControllerScript(parsing: "circle@1,cross@2:300,ly=-1@3:100"))
        let step = player.step(to: 60)
        #expect(step.sends.map(\.time) == [1, 1.15, 2, 2.3, 3, 3.1])
        #expect(step.sends.map(\.announcements.count) == [1, 0, 1, 0, 1, 0])
        #expect(step.sends[4].state.leftStickY == -32768)
        #expect(step.sends.last?.state == .idle && step.current == .idle)
    }

    @Test func steppingInSmallPiecesSendsTheSameAsOneBigStep() throws {
        let script = try ControllerScript(parsing: "circle@0,cross+up@0.5:300,rx=0.5@0.6:100,l2@1")
        var big = ControllerScript.Player(script)
        var small = ControllerScript.Player(script)
        let all = big.step(to: 2).sends
        var pieces: [ControllerScript.Step.Send] = []
        var t = 0.0
        while t < 2 {
            t += 0.037
            pieces += small.step(to: t).sends
        }
        #expect(pieces == all)
    }

    @Test func aStartThatChangesNothingIsStillAnnounced() throws {
        var player = ControllerScript.Player(try ControllerScript(parsing: "circle@1:1000,circle@1.5:100"))
        let sends = player.step(to: 1.6).sends
        #expect(sends.map(\.time) == [1, 1.5])
        #expect(sends[1].state == circle() && sends[1].announcements == ["press circle (100 ms)"])
    }

    @Test func nextWakeIsTheNextBoundary() throws {
        var player = ControllerScript.Player(try ControllerScript(parsing: "circle@4"))
        #expect(player.step(to: 1).nextWake == 4)
        #expect(player.step(to: 4.05).nextWake == 4.15)
        #expect(player.step(to: 4.2).nextWake == nil)
    }

    @Test func twoPressesOfOneButtonAreReleasedBetween() throws {
        var player = ControllerScript.Player(try ControllerScript(parsing: "circle@4:150,circle@4.17:150"))
        #expect(player.step(to: 10).sends.map(\.state) == [circle(), .idle, circle(), .idle])
    }

    @Test func afterTheScriptTheStateIsByteIdenticalToIdle() throws {
        let script = try ControllerScript(parsing: "ps@1,cross+up@2:300,lx=1@3,ly=-1@4:2000,rx=-1@5,ry=1@6,l2=1@7,r2@8")
        for t in [script.duration, script.duration + 0.001, 60] {
            let state = script.state(at: t)
            #expect(state == .idle)
            for ps5 in [true, false] {
                #expect(FeedbackState.body(state, ps5: ps5) == FeedbackState.body(.idle, ps5: ps5))
            }
            #expect(ControllerEvent.events(from: .idle, to: state).isEmpty)
            #expect(!FeedbackState.needsSend(old: .idle, new: state))
        }
        var player = ControllerScript.Player(script)
        #expect(player.step(to: 100).current == .idle)
    }

    @Test func theTraceNamesButtonsAndValues() {
        var state = ControllerState.idle
        state.buttons = [.cross, .dpadUp, .ps]
        state.leftStickY = -32768
        state.r2 = 255
        #expect(state.traceDescription == "buttons [cross+ps+up] lx 0 ly -32768 rx 0 ry 0 l2 0 r2 255")
        #expect(ControllerState.idle.traceDescription == "buttons [] lx 0 ly 0 rx 0 ry 0 l2 0 r2 0")
    }
}
