import Darwin
import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

@Suite(.serialized) struct InternetSocketTests {
    @Test func sendsReceivesAndConnects() throws {
        let a = try POSIXPunchSocket(bindHost: "127.0.0.1")
        let b = try POSIXPunchSocket(bindHost: "127.0.0.1")
        #expect(a.localPort != 0 && a.localPort != b.localPort)
        try a.send([1, 2, 3], to: "127.0.0.1", port: b.localPort)
        let packet = try #require(try b.receive(timeout: 1))
        #expect(packet == UDPPacket(bytes: [1, 2, 3], host: "127.0.0.1", port: a.localPort))
        #expect(try a.receive(timeout: 0.01) == nil)

        // Connected sockets ignore the address they are given and only hear their peer.
        try a.connect(host: "127.0.0.1", port: b.localPort)
        try b.connect(host: "127.0.0.1", port: a.localPort)
        try a.send([4], to: "", port: 0)
        #expect(try b.receive(timeout: 1)?.bytes == [4])
        let stranger = try POSIXPunchSocket(bindHost: "127.0.0.1")
        try stranger.send([5], to: "127.0.0.1", port: a.localPort)
        #expect(try a.receive(timeout: 0.1) == nil)
        try a.setTimeToLive(2)
        try a.setTimeToLive(64)
    }

    @Test func badAddressesAndClosing() throws {
        let socket = try POSIXPunchSocket(bindHost: "127.0.0.1")
        #expect(throws: FailureKind.badAddress) { try socket.send([1], to: "not an address", port: 1) }
        #expect(throws: FailureKind.badAddress) { try socket.connect(host: "nope", port: 1) }
        #expect(throws: (any Error).self) { _ = try POSIXPunchSocket(bindHost: "nope") }
        #expect(throws: (any Error).self) { _ = try POSIXPunchSocket(bindHost: "192.0.2.1") }  // not our address: bind fails
        socket.close()
        socket.close()
        #expect(throws: FailureKind.disconnected) { try socket.send([1], to: "127.0.0.1", port: 1) }
        #expect(throws: FailureKind.disconnected) { _ = try socket.receive(timeout: 0.01) }
        #expect(throws: FailureKind.disconnected) { try socket.setTimeToLive(1) }
        #expect(socket.releaseDescriptor() == nil)
    }

    /// close() while a receive is in flight: the descriptor stays valid until the call returns (a datagram sent after
    /// close() is still received, with no error), the descriptor can't be released meanwhile, and later calls fail.
    @Test func closingWhileReceiving() throws {
        let socket = try POSIXPunchSocket(bindHost: "127.0.0.1")
        let sender = try POSIXPunchSocket(bindHost: "127.0.0.1")
        let outcome = Locked<Result<UDPPacket?, any Error>?>(nil)
        let done = DispatchSemaphore(value: 0)
        Thread {
            outcome.with { $0 = Result { try socket.receive(timeout: 2) } }
            done.signal()
        }.start()
        sleepSeconds(0.1)
        #expect(socket.releaseDescriptor() == nil)  // a call is in flight
        socket.close()
        try sender.send([42], to: "127.0.0.1", port: socket.localPort)
        #expect(done.wait(timeout: .now() + 2) == .success)
        guard case .success(let packet)? = outcome.with({ $0 }) else { Issue.record("the receive failed"); return }
        #expect(packet?.bytes == [42])
        #expect(throws: FailureKind.disconnected) { _ = try socket.receive(timeout: 0.01) }
    }

    @Test func releasingTheDescriptor() throws {
        let socket = try POSIXPunchSocket(bindHost: "127.0.0.1")
        let fd = try #require(socket.releaseDescriptor())
        #expect(fd >= 0)
        #expect(socket.releaseDescriptor() == nil)
        close(fd)
    }

    @Test func raisingTheFileLimit() {
        let before = FileLimit.raiseSoftLimit(toAtLeast: 0)
        #expect(before > 0)
        #expect(FileLimit.raiseSoftLimit(toAtLeast: 1024) >= min(before, 1024))
        #expect(FileLimit.raiseSoftLimit(toAtLeast: UInt64.max) >= before)
    }

    @Test func initialTimeToLiveAndMulticast() throws {
        let socket = try POSIXPunchSocket(bindHost: "127.0.0.1", timeToLive: 2, multicastTimeToLive: 2)
        #expect(socket.localPort != 0)
    }

    @Test func interfaces() {
        let all = LocalInterfaces.all()
        #expect(all.contains { $0.address == "127.0.0.1" && $0.flags & IFF_LOOPBACK != 0 })
        let up = IFF_UP | IFF_RUNNING
        let list = [
            LocalInterface(name: "lo0", flags: up | IFF_LOOPBACK, address: "127.0.0.1"),
            LocalInterface(name: "en1", flags: IFF_UP, address: "10.0.0.9"),
            LocalInterface(name: "en0", flags: up, address: "192.168.1.20"),
            LocalInterface(name: "en2", flags: up, address: "192.168.1.21"),
        ]
        #expect(LocalInterfaces.firstUsableIPv4(list) == "192.168.1.20")
        #expect(LocalInterfaces.firstUsableIPv4([list[0], list[1]]) == nil)
        #expect(LocalInterfaces.firstUsableIPv4([]) == nil)
        // The route to loopback needs no packet.
        #expect(LocalInterfaces.address(toward: "127.0.0.1") == "127.0.0.1")
        #expect(LocalInterfaces.address(toward: "not an address") == nil)
    }
}
