import Foundation
import Testing

@testable import PlayFXProtocol

@Suite struct SimulatedLossTests {
    @Test func theRangeIsChecked() {
        #expect(SimulatedLoss(percent: 0) == nil)
        #expect(SimulatedLoss(percent: -1) == nil)
        #expect(SimulatedLoss(percent: 50.1) == nil)
        #expect(SimulatedLoss(percent: .nan) == nil)
        #expect(SimulatedLoss(percent: .infinity) == nil)
        #expect(SimulatedLoss(percent: 5, burst: 0) == nil)
        #expect(SimulatedLoss(percent: 5, burst: 1000) != nil && SimulatedLoss(percent: 5, burst: 1001) == nil)
        // A chance that rounds to zero could never drop anything.
        #expect(SimulatedLoss(percent: 1e-20) == nil && SimulatedLoss(percent: 1e-12, burst: 1000) == nil)
        #expect(SimulatedLoss(percent: 50)?.burst == 1)
        #expect(SimulatedLoss(percent: 0.01, burst: 7, seed: 9) == SimulatedLoss(percent: 0.01, burst: 7, seed: 9))
    }

    /// The runs of dropped datagrams (lengths) and the total, over `count` datagrams.
    private func runs(_ loss: SimulatedLoss, count: Int) -> (dropped: Int, runs: [Int]) {
        var gate = LossGate(loss)
        var dropped = 0
        var runs: [Int] = []
        var current = 0
        for _ in 0..<count {
            if gate.shouldDrop() {
                dropped += 1
                current += 1
            } else if current > 0 {
                runs.append(current)
                current = 0
            }
        }
        if current > 0 { runs.append(current) }
        return (dropped, runs)
    }

    @Test(arguments: [(1.0, 1), (5.0, 1), (20.0, 1), (50.0, 1), (5.0, 4), (20.0, 3), (50.0, 8)])
    func theLongRunShareIsThePercentWhateverTheBurst(percent: Double, burst: Int) throws {
        let loss = try #require(SimulatedLoss(percent: percent, burst: burst, seed: 42))
        let count = 400_000
        let result = runs(loss, count: count)
        let share = Double(result.dropped) / Double(count) * 100
        #expect(abs(share - percent) < max(0.25, percent * 0.05), "\(share) % for \(percent) % in bursts of \(burst)")
        // Every drop comes in whole bursts (a new burst can follow at once); the last run may be cut by the end.
        #expect(result.runs.dropLast().allSatisfy { $0 % burst == 0 })
        #expect(burst == 1 || result.runs.contains(burst))
    }

    @Test func theSameSeedDropsTheSameDatagramsAndAnotherSeedDoesNot() throws {
        func pattern(_ seed: UInt64) throws -> [Bool] {
            var gate = LossGate(try #require(SimulatedLoss(percent: 10, burst: 2, seed: seed)))
            return (0..<2000).map { _ in gate.shouldDrop() }
        }
        #expect(try pattern(1) == pattern(1))
        #expect(try pattern(1) != pattern(2))
    }

    @Test func aFilterDropsNothingUntilArmedAndCounts() throws {
        let filter = LossFilter(try #require(SimulatedLoss(percent: 50, seed: 3)))
        #expect((0..<100).allSatisfy { _ in !filter.shouldDrop() } && filter.dropped == 0)
        filter.arm()
        let drops = (0..<1000).filter { _ in filter.shouldDrop() }.count
        #expect(drops > 400 && drops < 600 && filter.dropped == drops)
    }

    private final class Recorder: TransportHandler, @unchecked Sendable {
        var received: [[UInt8]] = []
        var wakes = 0
        var failures: [Int32] = []
        func transportDidReceive(_ datagram: UnsafeMutableRawBufferPointer, at timestamp: UInt64, kernelTimestamp: Bool) {
            received.append(Array(datagram))
        }
        func transportNextWake() -> UInt64? { 77 }
        func transportWake(now: UInt64) { wakes += 1 }
        func transportFailed(errno: Int32) { failures.append(errno) }
    }

    @Test func theHandlerPassesOnWhatSurvivesAndForwardsEverythingElse() throws {
        let inner = Recorder()
        let filter = LossFilter(try #require(SimulatedLoss(percent: 50, seed: 11)), armed: true)
        let handler = LossyTransportHandler(inner: inner, filter: filter)
        var buffer = [UInt8](repeating: 0, count: 1)
        for n in 0..<200 {
            buffer[0] = UInt8(n)
            buffer.withUnsafeMutableBytes { handler.transportDidReceive($0, at: 1, kernelTimestamp: true) }
        }
        #expect(inner.received.count + filter.dropped == 200 && filter.dropped > 50 && inner.received.count > 50)
        #expect(handler.transportNextWake() == 77)
        handler.transportWake(now: 5)
        handler.transportFailed(errno: 9)
        #expect(inner.wakes == 1 && inner.failures == [9])
    }

    @Test func theTransportWrapperKeepsTheNameAndSendsUntouched() throws {
        let memory = MemoryTransport()
        let filter = LossFilter(try #require(SimulatedLoss(percent: 50)), armed: true)
        let lossy = LossyDatagramTransport(memory, filter: filter)
        #expect(lossy.name == "memory" && lossy.localPort == 1)
        let inner = Recorder()
        try lossy.start(handler: inner)
        #expect(memory.handler is LossyTransportHandler)
        try lossy.send([1, 2, 3])
        #expect(memory.sent == [[1, 2, 3]])
        lossy.reschedule()
        #expect(memory.reschedules == 1)
        lossy.stop()
        #expect(memory.stopped)
    }

    /// A transport that keeps its handler weakly, as `NWDatagramTransport` does.
    private final class WeakHandlerTransport: DatagramTransport, @unchecked Sendable {
        let name = "weak"
        let localPort: UInt16 = 0
        weak var handler: TransportHandler?
        var failStart = false
        func start(handler: TransportHandler) throws {
            self.handler = handler
            if failStart { throw FailureKind.disconnected }
        }
        func send(_ bytes: UnsafeRawBufferPointer) throws {}
        func reschedule() {}
        func stop() {}
    }

    @Test func theWrapperLivesFromStartToStopEvenForATransportThatHoldsItWeakly() throws {
        let stub = WeakHandlerTransport()
        let loss = try #require(SimulatedLoss(percent: 40, burst: 2, seed: 99))
        let filter = LossFilter(loss, armed: true)
        let lossy = LossyDatagramTransport(stub, filter: filter)
        let inner = Recorder()
        #expect(lossy.activeWrapper == nil)
        try lossy.start(handler: inner)
        // Nothing but the lossy transport holds the wrapper, and the stub's weak reference still sees it.
        var replay = LossGate(loss)
        var expected: [UInt8] = []
        // In its own scope so the test holds no strong reference to the wrapper afterwards.
        do {
            let handler = try #require(stub.handler)
            #expect(handler === lossy.activeWrapper)
            // What reaches the stub's handler is dropped or forwarded exactly as the gate (replayed) says.
            var buffer = [UInt8](repeating: 0, count: 1)
            for n in 0..<300 {
                buffer[0] = UInt8(n & 0xff)
                if !replay.shouldDrop() { expected.append(buffer[0]) }
                buffer.withUnsafeMutableBytes { handler.transportDidReceive($0, at: 1, kernelTimestamp: false) }
            }
        }
        #expect(inner.received.map { $0[0] } == expected)
        #expect(filter.dropped == 300 - expected.count && filter.dropped > 0)
        lossy.stop()
        #expect(lossy.activeWrapper == nil)
        #expect(stub.handler == nil)
    }

    @Test func aStartThatThrowsLeavesNoWrapperBehind() throws {
        let stub = WeakHandlerTransport()
        stub.failStart = true
        let lossy = LossyDatagramTransport(stub, filter: LossFilter(try #require(SimulatedLoss(percent: 5))))
        #expect(throws: FailureKind.disconnected) { try lossy.start(handler: Recorder()) }
        #expect(lossy.activeWrapper == nil && stub.handler == nil)
    }
}
