import Foundation
import PlayFXProtocol

/// `pfxp bench-transport [--packets N] [--rate R]`: loopback only. A sender thread plays the console on 127.0.0.1
/// and sends N encrypted AV-sized packets at R per second (0 = as fast as possible); each receive transport
/// (BSD socket thread, Network.framework) receives, verifies the GMAC, decrypts, reorders and hands them up.
func benchTransport(_ args: [String]) throws {
    func number(_ name: String, _ fallback: Int) -> Int { option(name, in: args).flatMap { Int($0) } ?? fallback }
    let packets = number("packets", 20_000)
    let rate = number("rate", 20_000)
    print("loopback, \(packets) packets of 1400 bytes, rate \(rate == 0 ? "unlimited" : "\(rate)/s"), receive depth 32 for both")
    print("run       received  dropped   pkts/s  cpu ms/1000  p50 us  p99 us  max us  alloc/pkt  timestamps")
    // One discarded warm-up run of each, then A B A B so that neither transport always runs first.
    for name in ["bsd", "nw"] { _ = try TransportBench.run(transport: name, packets: min(packets, 2000), rate: rate) }
    for (n, name) in ["bsd", "nw", "bsd", "nw"].enumerated() {
        let r = try TransportBench.run(transport: name, packets: packets, rate: rate, countAllocations: true)
        let label = "\(name)#\(n / 2 + 1)".padding(toLength: 9, withPad: " ", startingAt: 0)
        let allocations = r.allocationsPerPacket.map { String(format: "%.2f", $0) } ?? "n/a"
        print(label + String(format: " %8d  %7d  %7.0f  %11.2f  %6.1f  %6.1f  %6.1f  ", r.packetsReceived, r.packetsDropped,
                             r.packetsPerSecond, r.cpuMillisPer1000, r.p50Micros, r.p99Micros, r.maxMicros)
              + allocations.padding(toLength: 9, withPad: " ", startingAt: 0) + "  " + r.timestampSource)
    }
}
