import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

/// holepunch.md sections 3.2 and 3.3 (vector H5) and the candidate lists of section 4 (vector H4).
@Suite(.serialized) struct StunTests {
    /// RFC 5769 section 2.2: IPv4 Binding Success response with SOFTWARE, MESSAGE-INTEGRITY and FINGERPRINT.
    /// (The integrity and fingerprint values are skipped unchecked by the parser, so their exact bytes don't matter.)
    static let rfc5769 = hex("""
        0101003c 2112a442 b7e7a701bc34d686fa87dfae
        8022000b 7465737420766563746f7220
        00200008 0001a147 e112a643
        00080014 2b91f599fd9e90c38c7489f92af9ba53f06be7d7
        80280004 c07d4c96
        """)
    static let transaction = hex("b7e7a701bc34d686fa87dfae")

    @Test func requestBytes() {
        let request = StunClient.bindingRequest(transactionID: Self.transaction)
        #expect(request == hex("000100002112a442b7e7a701bc34d686fa87dfae"))
        #expect(request.count == 20)
    }

    @Test func h5Rfc5769Sample() {
        #expect(Self.rfc5769.count == 80)
        #expect(StunClient.parseBindingResponse(Self.rfc5769, transactionID: Self.transaction)
            == StunAnswer(address: "192.0.2.1", port: 32853))
    }

    @Test func parseRejections() {
        let good = Self.rfc5769
        let t = Self.transaction
        #expect(StunClient.parseBindingResponse(good, transactionID: hex("000000000000000000000000")) == nil)
        var wrongType = good
        wrongType[1] = 0x11
        #expect(StunClient.parseBindingResponse(wrongType, transactionID: t) == nil)
        #expect(StunClient.parseBindingResponse(good + [0, 0, 0, 0], transactionID: t) == nil)
        #expect(StunClient.parseBindingResponse(Array(good.dropLast(4)), transactionID: t) == nil)
        var wrongCookie = good
        wrongCookie[4] = 0
        #expect(StunClient.parseBindingResponse(wrongCookie, transactionID: t) == nil)
        #expect(StunClient.parseBindingResponse(Array(good.prefix(10)), transactionID: t) == nil)
        // No address attribute at all.
        let bare = hex("010100000 02112a442".replacingOccurrences(of: " ", with: "")) + t
        #expect(StunClient.parseBindingResponse(bare, transactionID: t) == nil)
        // An attribute running past the end of the message.
        let overrun = hex("01010008 2112a442") + t + hex("00200010 00010000")
        #expect(StunClient.parseBindingResponse(overrun, transactionID: t) == nil)
    }

    @Test func mappedAddressIsNotXored() {
        let t = Self.transaction
        let body = hex("00010008 0001 7d00 c6336407")  // 198.51.100.7:32000
        let response = hex("0101000c 2112a442") + t + body
        #expect(StunClient.parseBindingResponse(response, transactionID: t) == StunAnswer(address: "198.51.100.7", port: 32000))
    }

    @Test func ipv6AttributeIsSkippedForALaterIPv4One() {
        let t = Self.transaction
        let v6 = hex("00200014 0002 0000 00000000000000000000000000000000")
        let v4 = hex("00200008 0001 a147 e112a643")
        let response = hex("01010024 2112a442") + t + v6 + v4
        #expect(StunClient.parseBindingResponse(response, transactionID: t) == StunAnswer(address: "192.0.2.1", port: 32853))
    }

    // MARK: Prediction (section 3.3)

    private func answers(_ ports: [UInt16], address: String = "203.0.113.5") -> [StunAnswer] {
        ports.map { StunAnswer(address: address, port: $0) }
    }

    @Test func predictionRows() throws {
        #expect(NATPrediction.predict([]) == nil)
        #expect(NATPrediction.predict(answers([40000])) == NATPrediction(
            publicAddress: "203.0.113.5", basePort: 40000, increment: 0, randomAllocation: false))
        // Two answers, same address: inc = p2 - p1, port p2 + 2 inc.
        #expect(NATPrediction.predict(answers([40000, 40003])) == NATPrediction(
            publicAddress: "203.0.113.5", basePort: 40009, increment: 3, randomAllocation: false))
        // Two answers, different addresses: inc 0, port p2, the last address.
        let two = [StunAnswer(address: "1.1.1.1", port: 40000), StunAnswer(address: "2.2.2.2", port: 41000)]
        #expect(NATPrediction.predict(two) == NATPrediction(publicAddress: "2.2.2.2", basePort: 41000, increment: 0,
                                                            randomAllocation: false))
        // Three answers: steady, then irregular, then irregular from a flat start.
        #expect(NATPrediction.predict(answers([40000, 40002, 40004])) == NATPrediction(
            publicAddress: "203.0.113.5", basePort: 40006, increment: 2, randomAllocation: false))
        #expect(NATPrediction.predict(answers([40000, 40002, 40009])) == NATPrediction(
            publicAddress: "203.0.113.5", basePort: 40011, increment: 2, randomAllocation: true))
        #expect(NATPrediction.predict(answers([40000, 40000, 40005])) == NATPrediction(
            publicAddress: "203.0.113.5", basePort: 40010, increment: 5, randomAllocation: true))
    }

    @Test func fourAnswers() {
        func predict(_ ports: [UInt16]) -> NATPrediction { NATPrediction.predict(answers(ports))! }
        #expect(predict([40000, 40002, 40004, 40006]) == NATPrediction(
            publicAddress: "203.0.113.5", basePort: 40006, increment: 2, randomAllocation: false))
        #expect(predict([40000, 40000, 40000, 40000]).increment == 0)
        // d1 equals d3 only.
        #expect(predict([40000, 40002, 40003, 40005]).increment == 2)
        #expect(!predict([40000, 40002, 40003, 40005]).randomAllocation)
        // d2 equals d3 only.
        #expect(predict([40000, 40001, 40003, 40005]).increment == 2)
        // All different: random, inc = d1; with d1 == 0, inc = d2.
        #expect(predict([40000, 40001, 40007, 40003]) == NATPrediction(
            publicAddress: "203.0.113.5", basePort: 40003, increment: 1, randomAllocation: true))
        #expect(predict([40000, 40000, 40004, 40005]).increment == 4)
        #expect(predict([40000, 40000, 40004, 40005]).randomAllocation)
        // DELIBERATE DEVIATION from holepunch.md section 4.4: the reference keeps 65534 for a NAT that decreases by 2\n        // and then steps oddly; we read steps above 32767 as negative, so decreasing allocations are predicted.
        let decreasing = predict([40006, 40004, 40002, 40000])
        #expect(decreasing.increment == -2 && decreasing.basePort == 40000 && !decreasing.randomAllocation)
    }

    /// Every row of holepunch.md section 3.3's exact table for answers whose addresses differ, including the rows the
    /// spec calls unintended (`(p4 - p1) / 4`, the reversed `p3 - p4`): the table is followed as written.
    @Test func mixedAddressTable() {
        func row(_ addresses: String, _ ports: [UInt16]) -> (inc: Int, random: Bool, port: UInt16) {
            let list = zip(addresses, ports).map { StunAnswer(address: "\($0.0).0.0.1", port: $0.1) }
            let result = NATPrediction.predict(list)!
            return (result.increment, result.randomAllocation, result.basePort)
        }
        // Three answers (port = p3 + inc).
        #expect(row("XYX", [1000, 2000, 1010]) == (5, false, 1015))
        #expect(row("XYY", [1000, 2000, 2008]) == (8, false, 2016))
        #expect(row("XYZ", [1000, 2000, 3000]) == (0, false, 3000))
        #expect(row("XXY", [1000, 1004, 5000]) == (4, false, 5004))
        // Four answers (port = p4); a1 differs from a2.
        #expect(row("XYXX", [1000, 2000, 1020, 1030]) == (10, false, 1030))  // check (p3-p1)/2 = 10 agrees
        #expect(row("XYXX", [1000, 2000, 1010, 1020]) == (10, true, 1020))  // disagrees: random, inc kept
        #expect(row("XYXX", [1000, 2000, 1010, 1010]) == (5, true, 1010))  // inc was 0: takes the check value
        #expect(row("XYZX", [1000, 2000, 3000, 1040]) == (10, false, 1040))  // (p4-p1)/4
        #expect(row("XYXZ", [1000, 2000, 1010, 5000]) == (5, false, 5000))  // (p3-p1)/2
        // a1 differs from all the others.
        #expect(row("XYYY", [1, 2000, 2010, 2020]) == (10, false, 2020))
        #expect(row("XYYY", [1, 2000, 2010, 2030]) == (20, true, 2030))
        #expect(row("XYYY", [1, 2000, 2010, 2010]) == (10, true, 2010))
        #expect(row("XYZY", [1000, 2000, 3000, 2040]) == (260, false, 2040))  // (p4-p1)/4 = 1040/4
        #expect(row("XYYZ", [1000, 2000, 2010, 5000]) == (505, false, 5000))  // (p3-p1)/2
        #expect(row("XYZZ", [100, 200, 3000, 3004]) == (-4, false, 3004))  // p3 - p4, the reversed order
        #expect(row("XYZW", [1, 2, 3, 4]) == (0, false, 4))
        // a1 = a2.
        #expect(row("XXYX", [1000, 1004, 5000, 1012]) == (4, false, 1012))  // check (p4-p2)/2 = 4 agrees
        #expect(row("XXYX", [1000, 1004, 5000, 1020]) == (4, true, 1020))
        #expect(row("XXYX", [1000, 1000, 5000, 1020]) == (10, true, 1020))  // inc was 0
        #expect(row("XXYZ", [1000, 1004, 5000, 6000]) == (4, false, 6000))
        #expect(row("XXXY", [1000, 1004, 1008, 5000]) == (4, false, 5000))
        #expect(row("XXXY", [1000, 1004, 1010, 5000]) == (4, true, 5000))
        #expect(row("XXXY", [1000, 1000, 1010, 5000]) == (10, true, 5000))
        // The public address is the last answer's.
        let list = ["a", "b", "b"].enumerated().map { StunAnswer(address: $0.element, port: UInt16(1000 + $0.offset)) }
        #expect(NATPrediction.predict(list)?.publicAddress == "b")
    }

    @Test func dataHoleReusesTheCtrlHolesIncrement() {
        let ctrl = NATPrediction(publicAddress: "203.0.113.5", basePort: 40006, increment: 2, randomAllocation: true)
        let data = NATPrediction.forDataHole(answer: StunAnswer(address: "203.0.113.5", port: 41000), ctrl: ctrl)
        #expect(data == NATPrediction(publicAddress: "203.0.113.5", basePort: 41000, increment: 2, randomAllocation: true))
        #expect(NATPrediction.forDataHole(answer: StunAnswer(address: "a", port: 5), ctrl: nil).increment == 0)
    }

    // MARK: Port arithmetic (sections 4.3, 4.4)

    /// DELIBERATE DEVIATION from holepunch.md section 4.4 (a client choice, see DESIGN notes): the reference's
    /// increments for four answers are 16-bit, so a decreasing NAT gives 65534 and the ports 41029, 42052, ...; the
    /// console doesn't care which ports we guess, so we predict 40004, 40002, ... instead.
    @Test func deliberateSignedIncrementDeviation() {
        let predicted = NATPrediction.predict(answers([40006, 40004, 40002, 40000]))!
        #expect(PortGuess.steps(from: predicted.basePort, increment: predicted.increment, count: 3) == [39998, 39996, 39994])
        // The reference's own arithmetic on 65534 (kept reachable through `steps`) gives its odd sequence.
        #expect(PortGuess.steps(from: 40006, increment: 65534, count: 2) == [41029, 42052])
    }

    @Test func basePortIsNotClamped() {
        // Section 3.3: kept as a 16-bit value; only guesses and steps are range-mapped.
        let high = NATPrediction.predict(answers([65000, 65300]))!
        #expect(high.basePort == UInt16(truncatingIfNeeded: 65300 + 600))
        let low = NATPrediction.predict(answers([2000, 1500]))!
        #expect(low.basePort == UInt16(truncatingIfNeeded: 1500 - 1000))
    }

    @Test func guessesAndSteps() {
        let guesses = PortGuess.guesses(around: 40003, count: 75)
        #expect(Array(guesses.prefix(9)) == [40003, 40004, 40002, 40005, 40001, 40006, 40000, 40007, 39999])
        #expect(guesses[73] == 40040 && guesses[74] == 39966 && guesses.count == 75)
        #expect(PortGuess.guesses(around: 65535, count: 3) == [65535, 49152, 65534])
        #expect(PortGuess.guesses(around: 1024, count: 3) == [1024, 1025, 65534])
        #expect(PortGuess.steps(from: 40006, increment: 2, count: 3) == [40008, 40010, 40012])
        // Above 65535: result - 65535 + 1024. Below 1024 from above: 65535 - (1024 - result).
        #expect(PortGuess.steps(from: 65534, increment: 3, count: 1) == [1026])
        #expect(PortGuess.steps(from: 1100, increment: -200, count: 1) == [65535 - (1024 - 900)])
        #expect(PortGuess.steps(from: 1000, increment: -2000, count: 1) == [65535 - 1000])
        #expect(PortGuess.clamp(70000) == 49152 + 4464 && PortGuess.clamp(5) == 65535 - 1019)
    }

    // MARK: Candidate lists (H4)

    private func list(_ ports: [UInt16], local: UInt16) throws -> [String] {
        let prediction = try #require(NATPrediction.predict(answers(ports)))
        let result = try CandidateBuilder.build(CandidateInputs(
            localPort: local, interfaceAddress: "192.168.1.20", stun: prediction))
        return result.candidates.map { "\($0.type.rawValue) \($0.address):\($0.port)" }
    }

    @Test func h4Increment() throws {
        let expected = [40008, 40010, 40012, 40014, 40016, 40018, 40020, 40022].map { "STUN 203.0.113.5:\($0)" }
            + ["STATIC 203.0.113.5:50123", "LOCAL 192.168.1.20:50123"]
        #expect(try list([40000, 40002, 40004, 40006], local: 50123) == expected)
    }

    @Test func h4RandomAllocation() throws {
        let result = try list([40000, 40001, 40007, 40003], local: 50124)
        #expect(result.count == 77)
        #expect(Array(result.prefix(9)) == [40003, 40004, 40002, 40005, 40001, 40006, 40000, 40007, 39999]
            .map { "STUN 203.0.113.5:\($0)" })
        #expect(result[73] == "STUN 203.0.113.5:40040" && result[74] == "STUN 203.0.113.5:39966")
        #expect(result[75] == "STATIC 203.0.113.5:50124" && result[76] == "LOCAL 192.168.1.20:50124")
        let built = try CandidateBuilder.build(CandidateInputs(
            localPort: 50124, interfaceAddress: "192.168.1.20",
            stun: NATPrediction.predict(answers([40000, 40001, 40007, 40003]))))
        #expect(built.randomAllocation)
    }

    @Test func h4NoPortTranslation() throws {
        #expect(try list([40000, 40000, 40000, 40000], local: 40000) == ["STATIC 203.0.113.5:40000", "LOCAL 192.168.1.20:40000"])
    }

    @Test func h4StunPortDiffers() throws {
        #expect(try list([61000, 61000, 61000, 61000], local: 50500)
            == ["STUN 203.0.113.5:61000", "STATIC 203.0.113.5:50500", "LOCAL 192.168.1.20:50500"])
    }

    @Test func h4Upnp() throws {
        let built = try CandidateBuilder.build(CandidateInputs(
            localPort: 50600, interfaceAddress: "10.9.9.9",
            upnp: UPnPMapping(lanAddress: "192.168.1.20", publicAddress: "203.0.113.5")))
        #expect(built.candidates == [
            PunchCandidate(type: .staticAddress, address: "203.0.113.5", port: 50600),
            PunchCandidate(type: .local, address: "192.168.1.20", port: 50600),
        ])
        #expect(!built.randomAllocation && built.first == built.candidates[0] && built.local == built.candidates[1])
    }

    @Test func forcedGuessingAndFailures() throws {
        let prediction = try #require(NATPrediction.predict(answers([61000, 61000, 61000, 61000])))
        let forced = try CandidateBuilder.build(CandidateInputs(
            localPort: 50500, interfaceAddress: "192.168.1.20", stun: prediction, forcePortGuessing: true, guessCount: 5))
        #expect(forced.randomAllocation && forced.candidates.count == 7 && forced.candidates[0].port == 61000)
        // Forcing changes nothing when the port is kept.
        let kept = try CandidateBuilder.build(CandidateInputs(
            localPort: 61000, interfaceAddress: "192.168.1.20", stun: prediction, forcePortGuessing: true))
        #expect(!kept.randomAllocation && kept.candidates.count == 2)
        #expect(throws: PunchError.noPublicAddress) {
            try CandidateBuilder.build(CandidateInputs(localPort: 1, interfaceAddress: "192.168.1.20"))
        }
        // Without any LAN address the LOCAL candidate is still sent, with an empty address (section 4.1).
        let noLan = try CandidateBuilder.build(CandidateInputs(localPort: 61000, interfaceAddress: nil, stun: prediction))
        #expect(noLan.local == PunchCandidate(type: .local, address: "", port: 61000) && noLan.candidates.count == 2)
    }

    // MARK: Server lists

    @Test func serverLists() {
        let text = (1...12).map { "s\($0).example:\(3000 + $0)" }.joined(separator: "\n") + "\n"
        let fetched = StunClient.servers(fromHostList: text)
        #expect(fetched.count == 10 && fetched[0] == StunServer(host: "s1.example", port: 3001))
        #expect(StunClient.servers(fromHostList: "bad\nhost:notaport\n:80\n  ok.example:5 \na:b:c\n").map(\.host) == ["ok.example"])
        // The 11-entry table of section 3.2, in order.
        let table = StunClient.builtInTable.map { "\($0.host):\($0.port)" }
        #expect(table == ["stun.moonlight-stream.org:3478", "stun.l.google.com:19302", "stun.l.google.com:19305",
                          "stun1.l.google.com:19302", "stun1.l.google.com:19305", "stun2.l.google.com:19302",
                          "stun2.l.google.com:19305", "stun3.l.google.com:19302", "stun3.l.google.com:19305",
                          "stun4.l.google.com:19302", "stun4.l.google.com:19305"])
        // The shuffle: i from 10 down to 2, swap entry i with entry 1 + (r mod (i - 1)). With r = 0 every swap uses
        // entry 1, which rotates entries 1...10 left by one; entry 0 never moves.
        var zeros = ScriptedGenerator(values: Array(repeating: 0, count: 9))
        let rotated = StunClient.builtInServers(using: &zeros).map { "\($0.host):\($0.port)" }
        #expect(rotated == [table[0]] + table[2...] + [table[1]])
        // With the last draw (i = 2) any value gives j = 1: entries 1 and 2 swap at the last step.
        var drawsOnlyAtTheEnd = ScriptedGenerator(values: [7, 7, 7, 7, 7, 7, 7, 7, UInt64.max])
        #expect(StunClient.builtInServers(using: &drawsOnlyAtTheEnd).count == 11)
        // Against an independent run of the same rule, for several seeds.
        for seed in 1...20 as ClosedRange<UInt64> {
            var generator = SeededGenerator(seed: seed)
            var reference = SeededGenerator(seed: seed)
            var expected = StunClient.builtInTable
            for i in stride(from: 10, through: 2, by: -1) { expected.swapAt(i, 1 + Int(reference.next() % UInt64(i - 1))) }
            let shuffled = StunClient.builtInServers(using: &generator)
            #expect(shuffled == expected && shuffled[0] == expected[0] && Set(shuffled.map(\.port)).count == 3)
        }
        var again = SeededGenerator(seed: 7)
        #expect(StunClient.serverList(fetchedHostList: text, using: &again).count == 21)
        var third = SeededGenerator(seed: 7)
        var fourth = SeededGenerator(seed: 7)
        #expect(StunClient.serverList(fetchedHostList: nil, using: &third) == StunClient.builtInServers(using: &fourth))
    }

    @Test func resolvesNumericAndLocalHosts() {
        #expect(StunClient.resolveIPv4("127.0.0.1") == "127.0.0.1")
        #expect(StunClient.resolveIPv4("localhost") == "127.0.0.1")
        #expect(StunClient.resolveIPv4("") == nil)
        // The lookup is bounded by its deadline (getaddrinfo itself can't be cancelled): no hang, whatever the answer.
        let start = monotonicSeconds()
        _ = StunClient.resolveIPv4("no-such-host.invalid", timeout: 0.001)
        #expect(monotonicSeconds() - start < 1)
    }

    // MARK: Asking servers (a fake server on loopback)

    /// Answers each Binding Request with the next scripted port; `silent` servers never answer.
    private final class FakeStun: @unchecked Sendable {
        let socket: LoopbackGuardedPunchSocket
        let requests = Locked(0)
        init(ports: [UInt16], silentFirst: Int = 0) throws {
            socket = try loopbackSocket()
            let socket = socket
            let requests = requests
            Thread {
                var script = ports
                while true {
                    let received: UDPPacket?
                    do { received = try socket.receive(timeout: 0.05) } catch { return }  // closed
                    guard let packet = received else { continue }
                    let count = requests.with { $0 += 1; return $0 }
                    guard count > silentFirst, packet.bytes.count == 20 else { continue }
                    let port = script.isEmpty ? 1 : script.removeFirst()
                    let xorPort = port ^ 0x2112
                    let attribute = hex("00200008 0001") + [UInt8(xorPort >> 8), UInt8(xorPort & 0xff)] + hex("e112a643")
                    let response = hex("0101000c 2112a442") + Array(packet.bytes[8..<20]) + attribute
                    try? socket.send(response, to: packet.host, port: packet.port)
                }
            }.start()
        }
    }

    @Test func collectsAnswersFromSeveralServers() throws {
        let server = try FakeStun(ports: [40000, 40002, 40004, 40006])
        defer { server.socket.close() }
        let client = try loopbackSocket()
        let servers = (0..<6).map { StunServer(host: "stun\($0).test", port: server.socket.localPort) }
        let answers = StunClient.collect(
            socket: client, servers: servers, wanted: 4,
            environment: StunEnvironment(resolve: { $0 == "stun1.test" ? nil : "127.0.0.1" }, timeout: 1))
        // stun1.test doesn't resolve and is skipped; four answers are enough, so the last two aren't asked.
        #expect(answers.map(\.port) == [40000, 40002, 40004, 40006])
        #expect(answers.allSatisfy { $0.address == "192.0.2.1" })
        #expect(server.requests.with { $0 } == 4)
        #expect(client.destinations.with { Set($0) } == ["127.0.0.1"])
    }

    @Test func silentServersTimeOutAndAreSkipped() throws {
        let quiet = try FakeStun(ports: [], silentFirst: 1000)
        let answering = try FakeStun(ports: [41000])
        defer { quiet.socket.close(); answering.socket.close() }
        let client = try loopbackSocket()
        let answers = StunClient.collect(
            socket: client,
            servers: [StunServer(host: "a", port: quiet.socket.localPort), StunServer(host: "b", port: answering.socket.localPort)],
            wanted: 1, environment: StunEnvironment(resolve: { _ in "127.0.0.1" }, timeout: 0.2))
        #expect(answers.map(\.port) == [41000])
    }

    @Test func cancellationStopsAsking() throws {
        let quiet = try FakeStun(ports: [], silentFirst: 1000)
        defer { quiet.socket.close() }
        let client = try loopbackSocket()
        let start = monotonicSeconds()
        let answers = StunClient.collect(
            socket: client, servers: [StunServer(host: "a", port: quiet.socket.localPort)], wanted: 1,
            environment: StunEnvironment(resolve: { _ in "127.0.0.1" }, timeout: 30,
                                         isCancelled: { monotonicSeconds() - start > 0.1 }))
        #expect(answers.isEmpty && monotonicSeconds() - start < 2)
        // Cancelled before the first server: nothing is sent.
        #expect(StunClient.collect(socket: client, servers: [StunServer(host: "a", port: 1)], wanted: 1,
                                   environment: StunEnvironment(isCancelled: { true })).isEmpty)
    }

    @Test func aSendFailureMovesOnToTheNextServer() throws {
        let answering = try FakeStun(ports: [42000])
        defer { answering.socket.close() }
        // The first "server" resolves to a non-IPv4 text: the send fails (before anything leaves the machine) and
        // the next server is asked.
        let client = try POSIXPunchSocket(bindHost: "127.0.0.1")
        let answers = StunClient.collect(
            socket: client,
            servers: [StunServer(host: "bad", port: 1), StunServer(host: "good", port: answering.socket.localPort)],
            wanted: 1,
            environment: StunEnvironment(resolve: { $0 == "bad" ? "not-an-address" : "127.0.0.1" }, timeout: 1))
        #expect(answers.map(\.port) == [42000])
    }
}

/// A generator that returns scripted values (then zeros).
struct ScriptedGenerator: RandomNumberGenerator {
    var values: [UInt64]
    mutating func next() -> UInt64 { values.isEmpty ? 0 : values.removeFirst() }
}

/// A deterministic generator (splitmix64).
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}
