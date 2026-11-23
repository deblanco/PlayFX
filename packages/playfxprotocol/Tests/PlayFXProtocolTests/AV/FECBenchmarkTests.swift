import Foundation
import Testing

@testable import PlayFXProtocol

/// Prints how long a recovery takes with each region-multiply method. The numbers only mean something in
/// a release build:
///
///     swift test -c release -Xswiftc -enable-testing --filter FECBenchmark
///
/// (with the extra flags `scripts/test.sh` adds). In a debug build it runs a few iterations just to check
/// that every method recovers the right bytes.
@Suite("AV: FEC benchmark")
struct FECBenchmarkTests {
    @Test("recover 6 of 60 units of 1400 bytes with each multiply method")
    func recoverSixOfSixty() {
        let k = 54
        let m = 6
        let size = 1400
        var rng = SeededRandom(60)
        let source = (0..<k).map { _ in (0..<size).map { _ in UInt8.random(in: 0...255, using: &rng) } }
        let units = source + ReferenceFEC.encode(source: source, m: m)
        let lost: Set<Int> = [3, 9, 20, 31, 40, 52]
        #if DEBUG
        let iterations = 3
        #else
        let iterations = 2000
        #endif
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: (k + m) * size)
        let present = UnsafeMutablePointer<Bool>.allocate(capacity: k + m)
        defer {
            storage.deallocate()
            present.deallocate()
        }
        var report: [String] = []
        for method in GF256.Method.available {
            let decoder = FECDecoder(method: method)
            func load() {
                for (u, bytes) in units.enumerated() {
                    present[u] = !lost.contains(u)
                    for t in 0..<size { storage[u * size + t] = lost.contains(u) ? 0 : bytes[t] }
                }
            }
            load()
            #expect(decoder.recover(k: k, m: m, size: size, storage: storage, present: present))
            for j in lost { #expect(Array(UnsafeBufferPointer(start: storage + j * size, count: size)) == source[j]) }
            let clock = ContinuousClock()
            var total = Duration.zero
            for _ in 0..<iterations {
                load()
                total += clock.measure {
                    _ = decoder.recover(k: k, m: m, size: size, storage: storage, present: present)
                }
            }
            let micros = Double(total.components.attoseconds) / 1e12 / Double(iterations)
                + Double(total.components.seconds) * 1e6 / Double(iterations)
            #if !DEBUG && arch(arm64)
            if method == GF256.Method.default {
                // The budget: recovering 6 of 60 units of 1400 bytes in an optimised arm64 build.
                #expect(micros < 100, "recovering took \(micros) us")
            }
            #endif
            report.append("\(method): \(String(format: "%.1f", micros)) us")
        }
        print("FEC benchmark, recover 6 of 60 units x 1400 bytes (\(iterations) iterations):")
        for line in report { print("  \(line)") }
    }
}
