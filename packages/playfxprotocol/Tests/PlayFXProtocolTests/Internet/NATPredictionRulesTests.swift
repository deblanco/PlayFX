import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

/// holepunch.md section 3.3 against `NATPrediction.predict`: an independent model written from the spec's tables (by
/// the pattern of equal public addresses, not by the code's own structure) is compared over many inputs, and the cases
/// of a carrier NAT (four different mapped ports) are pinned.
@Suite struct NATPredictionRulesTests {
    struct Expected: Equatable {
        var increment: Int
        var random: Bool
        var port: Int
    }

    /// The spec's rules. `answers` are (address label, port). Four answers from one address use the steps modulo 2^16.
    static func model(_ answers: [(label: Character, port: Int)]) -> Expected? {
        let n = answers.count
        guard n > 0 else { return nil }
        let p = answers.map(\.port)
        let pattern = canonical(answers.map(\.label))
        func checked(_ step: Int, _ check: Int) -> Expected {
            step == check ? Expected(increment: step, random: false, port: 0)
                : Expected(increment: step == 0 ? check : step, random: true, port: 0)
        }
        func mod16(_ x: Int) -> Int { ((x % 65536) + 65536) % 65536 }
        var r: Expected
        switch (n, pattern) {
        case (1, _): return Expected(increment: 0, random: false, port: p[0])
        case (2, "AA"):
            let inc = p[1] - p[0]
            return Expected(increment: inc, random: false, port: p[1] + 2 * inc)
        case (2, _): return Expected(increment: 0, random: false, port: p[1])
        case (3, "AAA"):
            r = checked(p[1] - p[0], p[2] - p[1])
            if !r.random { r.increment = p[1] - p[0] }
            // random with increment 0 takes the later step; random with a nonzero one keeps it
            if r.random { r.increment = (p[1] - p[0]) == 0 ? p[2] - p[1] : p[1] - p[0] }
            r.port = p[2] + r.increment
            return r
        case (3, "ABA"): return Expected(increment: (p[2] - p[0]) / 2, random: false, port: p[2] + (p[2] - p[0]) / 2)
        case (3, "ABB"): return Expected(increment: p[2] - p[1], random: false, port: p[2] + p[2] - p[1])
        case (3, "AAB"): return Expected(increment: p[1] - p[0], random: false, port: p[2] + p[1] - p[0])
        case (3, _): return Expected(increment: 0, random: false, port: p[2])
        case (4, "AAAA"):
            let d1 = mod16(p[1] - p[0]), d2 = mod16(p[2] - p[1]), d3 = mod16(p[3] - p[2])
            if d1 == d2 || d1 == d3 { return Expected(increment: d1, random: false, port: p[3]) }
            if d2 == d3 { return Expected(increment: d2, random: false, port: p[3]) }
            return Expected(increment: d1 != 0 ? d1 : d2, random: true, port: p[3])
        case (4, "ABAA"): r = checked(p[3] - p[2], (p[2] - p[0]) / 2)
        case (4, "ABBA"), (4, "ABCA"): r = Expected(increment: (p[3] - p[0]) / 4, random: false, port: 0)
        case (4, "ABAB"), (4, "ABAC"): r = Expected(increment: (p[2] - p[0]) / 2, random: false, port: 0)
        case (4, "ABBB"): r = checked(p[3] - p[2], p[2] - p[1])
        case (4, "ABCB"): r = Expected(increment: (p[3] - p[0]) / 4, random: false, port: 0)
        case (4, "ABBC"): r = Expected(increment: (p[2] - p[0]) / 2, random: false, port: 0)
        case (4, "ABCC"): r = Expected(increment: p[2] - p[3], random: false, port: 0)
        case (4, "ABCD"): r = Expected(increment: 0, random: false, port: 0)
        case (4, "AABA"): r = checked(p[1] - p[0], (p[3] - p[1]) / 2)
        case (4, "AABB"), (4, "AABC"): r = Expected(increment: p[1] - p[0], random: false, port: 0)
        case (4, "AAAB"): r = checked(p[1] - p[0], p[2] - p[1])
        default: return nil
        }
        r.port = p[3]
        return r
    }

    /// "ABAC" style signature of the labels.
    static func canonical(_ labels: [Character]) -> String {
        var seen: [Character] = []
        return String(labels.map { label in
            if let index = seen.firstIndex(of: label) { return Character(UnicodeScalar(65 + UInt8(index))) }
            seen.append(label)
            return Character(UnicodeScalar(64 + UInt8(seen.count)))
        })
    }

    static func answers(_ list: [(Character, Int)]) -> [StunAnswer] {
        list.map { StunAnswer(address: "203.0.113.\($0.0.asciiValue! - 64)", port: UInt16($0.1)) }
    }

    @Test func theRulesAgreeWithTheSpecModelOverManyInputs() {
        var generator = SystemRandomNumberGenerator()
        // A small port range makes equal steps common; the second pool crosses the 16-bit edges (decreasing NATs).
        let pools: [ClosedRange<Int>] = [40000...40006, 100...140, 65520...65535, 1...8]
        var checkedCases = 0
        for _ in 0..<20000 {
            let n = Int.random(in: 1...4, using: &generator)
            let pool = pools.randomElement(using: &generator)!
            let labels = (0..<n).map { _ in Character(UnicodeScalar(65 + UInt8.random(in: 0...3, using: &generator))) }
            let list = labels.map { ($0, Int.random(in: pool, using: &generator)) }
            guard let expected = Self.model(list.map { (label: $0.0, port: $0.1) }) else { continue }
            let got = NATPrediction.predict(Self.answers(list))
            let mask = list.count == 4 && Set(labels).count == 1
            let incrementMatches = mask ? (got?.increment ?? 0) & 0xffff == expected.increment & 0xffff
                : got?.increment == expected.increment
            #expect(got?.randomAllocation == expected.random && incrementMatches
                && Int(got?.basePort ?? 0) == expected.port & 0xffff, "\(list) expected \(expected) got \(String(describing: got))")
            checkedCases += 1
        }
        #expect(checkedCases > 19000)
    }

    /// Four different mapped ports from one public address (a carrier NAT): random allocation, as the reference decides.
    @Test(arguments: [
        [40000, 40007, 39990, 40100], [50000, 50001, 50003, 50007], [1500, 62000, 8000, 30000],
        [40000, 40000, 40001, 40050], [40010, 40000, 40031, 40020],
    ])
    func fourDifferentPortsFromOneAddressAreRandomAllocation(ports: [Int]) throws {
        let prediction = try #require(NATPrediction.predict(Self.answers(ports.map { ("A", $0) })))
        #expect(prediction.randomAllocation, "\(ports)")
        #expect(Int(prediction.basePort) == ports[3])
        // Which means 75 guesses around the last port and the extra sockets, as the reference does.
        let built = try CandidateBuilder.build(CandidateInputs(
            localPort: 50123, interfaceAddress: "192.168.1.20", stun: prediction))
        #expect(built.randomAllocation)
        #expect(built.candidates.filter { $0.type == .stun }.count == 75)
    }

    @Test func theStepOfARandomAllocationIsTheFirstNonZeroOne() throws {
        let a = try #require(NATPrediction.predict(Self.answers([("A", 40000), ("A", 40007), ("A", 39990), ("A", 40100)])))
        #expect(a.increment == 7)
        let b = try #require(NATPrediction.predict(Self.answers([("A", 40000), ("A", 40000), ("A", 40001), ("A", 40050)])))
        #expect(b.increment == 1 && b.randomAllocation)  // d1 = 0, so d2
    }

    /// Four answers with a different public address each (the NAT hands out one per destination): the spec's row says step
    /// 0 and no random allocation, so only the one STUN candidate goes out.
    @Test func fourAddressesGiveNoStepAndNoGuessing() throws {
        let prediction = try #require(NATPrediction.predict(Self.answers([("A", 40000), ("B", 40007), ("C", 39990), ("D", 40100)])))
        #expect(prediction.increment == 0 && !prediction.randomAllocation && prediction.basePort == 40100)
    }

    /// The one place where the code differs from the reference: a decreasing NAT's step (65534 in the reference) is read as
    /// -2 here (holepunch.md section 4.4 suggests it). It never changes whether the allocation counts as random.
    @Test func aDecreasingStepIsReadAsNegative() throws {
        let prediction = try #require(NATPrediction.predict(Self.answers([("A", 40006), ("A", 40004), ("A", 40002), ("A", 40000)])))
        #expect(prediction.increment == -2 && !prediction.randomAllocation)
        let steps: [(label: Character, port: Int)] = [("A", 40006), ("A", 40004), ("A", 40002), ("A", 40000)]
        #expect(Self.model(steps)?.increment == 65534)
    }

    // MARK: Per-destination NATs (a client choice on top of the spec rule)

    static func built(_ ports: [Int], local: UInt16 = 50123, force: Bool = false) throws -> ClientCandidates {
        let prediction = try #require(NATPrediction.predict(Self.answers(ports.map { ("A", $0) })))
        return try CandidateBuilder.build(CandidateInputs(
            localPort: local, interfaceAddress: "192.168.1.20", stun: prediction, forcePortGuessing: force))
    }

    /// The iPhone hotspot's answers: the spec rule says step 0, not random; the ports differ, so they are guessed.
    @Test(arguments: [[9623, 9565, 9565, 9565], [64455, 64461, 64461, 64461], [9597, 9598, 9598, 9598]])
    func portsThatDifferWithoutAStepAreGuessed(ports: [Int]) throws {
        let prediction = try #require(NATPrediction.predict(Self.answers(ports.map { ("A", $0) })))
        #expect(prediction.increment == 0 && !prediction.randomAllocation && prediction.portsDiffer && prediction.isPerDestination)
        let built = try Self.built(ports)
        #expect(built.randomAllocation)
        let guesses = built.candidates.filter { $0.type == .stun }.map(\.port)
        #expect(guesses.count == 75 && guesses.first == UInt16(ports[3]))  // around the last answer's port
    }

    @Test func identicalPortsAreNotGuessed() throws {
        let prediction = try #require(NATPrediction.predict(Self.answers([40000, 40000, 40000, 40000].map { ("A", $0) })))
        #expect(!prediction.portsDiffer && !prediction.isPerDestination)
        let built = try Self.built([40000, 40000, 40000, 40000])
        #expect(!built.randomAllocation)
        #expect(built.candidates.filter { $0.type == .stun }.map(\.port) == [40000])  // the one translated port
        #expect(try !Self.built([50123, 50123, 50123, 50123], local: 50123).randomAllocation)
    }

    @Test func theOtherCasesAreUnchanged() throws {
        // A step: eight predicted ports, no extra sockets.
        let step = try Self.built([40000, 40002, 40004, 40006])
        #expect(!step.randomAllocation && step.candidates.filter { $0.type == .stun }.count == 8)
        // The spec's random allocation: guesses, as before.
        #expect(try Self.built([40000, 40007, 39990, 40100]).randomAllocation)
        // One answer, and two answers with a step.
        #expect(try !Self.built([40000]).randomAllocation)
        #expect(try !Self.built([40000, 40003]).randomAllocation)
        // Forcing still works for a stable NAT.
        #expect(try Self.built([61000, 61000, 61000, 61000], local: 50500, force: true).randomAllocation)
    }

    /// The data hole asks one server: it takes the ctrl hole's decision with it.
    @Test func theDataHoleInheritsThePerDestinationDecision() throws {
        let ctrl = try #require(NATPrediction.predict(Self.answers([9623, 9565, 9565, 9565].map { ("A", $0) })))
        let data = NATPrediction.forDataHole(answer: StunAnswer(address: "203.0.113.1", port: 9570), ctrl: ctrl)
        #expect(data.isPerDestination && data.basePort == 9570)
        let built = try CandidateBuilder.build(CandidateInputs(localPort: 50124, interfaceAddress: "192.168.1.20", stun: data))
        #expect(built.randomAllocation && built.candidates.filter { $0.type == .stun }.count == 75)
        // From a stable ctrl hole it stays plain.
        let stable = NATPrediction.forDataHole(
            answer: StunAnswer(address: "203.0.113.1", port: 9570),
            ctrl: NATPrediction.predict(Self.answers([40000, 40000, 40000, 40000].map { ("A", $0) })))
        #expect(!stable.isPerDestination)
        #expect(try !CandidateBuilder.build(CandidateInputs(localPort: 50124, interfaceAddress: "x", stun: stable)).randomAllocation)
    }
}
