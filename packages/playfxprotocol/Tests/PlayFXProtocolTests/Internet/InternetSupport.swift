import Darwin
import Foundation
import Testing

@testable import PlayFXProtocol
@testable import PlayFXProtocolTestSupport

// Test doubles for internet play: nothing here may reach beyond the loopback interface.

/// A loopback-only HTTP client: refuses non-loopback hosts.
struct LoopbackGuardedHTTP: UPnPHTTPClient {
    func exchange(host: String, port: UInt16, request: [UInt8], timeout: Double) throws -> [UInt8] {
        guard isLoopback(host) else {
            Issue.record("test tried to reach non-loopback HTTP host \(host)")
            throw FailureKind.networkUnreachable
        }
        return try TCPHTTPClient().exchange(host: host, port: port, request: request, timeout: timeout)
    }
}

/// Two guarded sockets connected to each other on loopback.
func loopbackPair() throws -> (a: LoopbackGuardedPunchSocket, b: LoopbackGuardedPunchSocket) {
    let a = try loopbackSocket()
    let b = try loopbackSocket()
    try a.connect(host: "127.0.0.1", port: b.localPort)
    try b.connect(host: "127.0.0.1", port: a.localPort)
    return (a, b)
}

/// What a lossy link does to one datagram.
enum Fate {
    case deliver, drop, duplicate
    /// Delivered after the next datagram (a reorder).
    case hold
}

/// Wraps a socket and drops, duplicates or reorders datagrams per script, by 0-based index per direction.
final class LossyPunchSocket: UDPPunchSocket, @unchecked Sendable {
    let inner: any UDPPunchSocket
    private let sendFate: @Sendable (Int, [UInt8]) -> Fate
    private let receiveFate: @Sendable (Int, [UInt8]) -> Fate
    private struct State {
        var sends = 0
        var receives = 0
        var heldSend: [UInt8]?
        var heldReceive: UDPPacket?
        var incoming: [UDPPacket] = []
        var dropped = 0
    }
    private let state = Locked(State())

    init(_ inner: any UDPPunchSocket, send: @escaping @Sendable (Int, [UInt8]) -> Fate = { _, _ in .deliver },
         receive: @escaping @Sendable (Int, [UInt8]) -> Fate = { _, _ in .deliver }) {
        self.inner = inner
        sendFate = send
        receiveFate = receive
    }

    var droppedCount: Int { state.with { $0.dropped } }
    var localPort: UInt16 { inner.localPort }

    func send(_ bytes: [UInt8], to host: String, port: UInt16) throws {
        let index = state.with { s -> Int in defer { s.sends += 1 }; return s.sends }
        switch sendFate(index, bytes) {
        case .deliver:
            try inner.send(bytes, to: host, port: port)
            if let held = state.with({ s -> [UInt8]? in defer { s.heldSend = nil }; return s.heldSend }) {
                try inner.send(held, to: host, port: port)
            }
        case .drop: state.with { $0.dropped += 1 }
        case .duplicate:
            try inner.send(bytes, to: host, port: port)
            try inner.send(bytes, to: host, port: port)
        case .hold: state.with { $0.heldSend = bytes }
        }
    }

    func receive(timeout: Double) throws -> UDPPacket? {
        let deadline = monotonicSeconds() + timeout
        while true {
            if let next = state.with({ s -> UDPPacket? in s.incoming.isEmpty ? nil : s.incoming.removeFirst() }) {
                return next
            }
            let remaining = max(0, deadline - monotonicSeconds())
            guard let packet = try inner.receive(timeout: remaining) else { return nil }
            let index = state.with { s -> Int in defer { s.receives += 1 }; return s.receives }
            switch receiveFate(index, packet.bytes) {
            case .deliver:
                state.with { s in
                    s.incoming.append(packet)
                    if let held = s.heldReceive {
                        s.incoming.append(held)
                        s.heldReceive = nil
                    }
                }
            case .drop: state.with { $0.dropped += 1 }
            case .duplicate: state.with { $0.incoming += [packet, packet] }
            case .hold: state.with { $0.heldReceive = packet }
            }
            if remaining == 0 && state.with({ $0.incoming.isEmpty }) { return nil }
        }
    }

    func connect(host: String, port: UInt16) throws { try inner.connect(host: host, port: port) }
    func setTimeToLive(_ ttl: Int) throws { try inner.setTimeToLive(ttl) }
    func close() { inner.close() }
}

/// A TCP listener on 127.0.0.1 answering each connection with `respond(request text)`, one request per connection.
final class LoopbackHTTPServer: @unchecked Sendable {
    let port: UInt16
    let requests = Locked<[String]>([])
    private let listener: Int32
    private let respond: @Sendable (String) -> [UInt8]
    private let stopped = Locked(false)

    init(respond: @escaping @Sendable (String) -> [UInt8]) throws {
        self.respond = respond
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        listener = fd
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, 4)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else { throw SupportError("listen failed") }
        var named = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &named) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: named.sin_port)
        let thread = Thread { [self] in
            while !stopped.with({ $0 }) {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&pfd, 1, 50) > 0 else { continue }
                let client = accept(fd, nil, nil)
                if client >= 0 { serve(client) }
            }
            Darwin.close(fd)
        }
        thread.start()
    }

    deinit { stop() }

    func stop() {
        guard !stopped.with({ let old = $0; $0 = true; return old }) else { return }
        // The accept loop notices within 50 ms and the listener closes with the process; closing here could race it.
    }

    private func serve(_ client: Int32) {
        defer { Darwin.close(client) }
        var data: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            guard let end = data.firstRange(of: [0x0d, 0x0a, 0x0d, 0x0a]) else {
                let n = read(client, &buffer, buffer.count)
                if n <= 0 { return }
                data += buffer[0..<n]
                continue
            }
            let head = String(decoding: data[0..<end.lowerBound], as: UTF8.self).lowercased()
            let length = head.components(separatedBy: "\r\n").compactMap { line -> Int? in
                line.hasPrefix("content-length:") ? Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) : nil
            }.first ?? 0
            if data.count - end.upperBound >= length { break }
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { return }
            data += buffer[0..<n]
        }
        let text = String(decoding: data, as: UTF8.self)
        requests.with { $0.append(text) }
        let reply = respond(text)
        reply.withUnsafeBytes { _ = write(client, $0.baseAddress, $0.count) }
    }
}

/// An HTTP/1.1 response with a Content-Length.
func httpResponse(status: Int = 200, body: String, headers: String = "") -> [UInt8] {
    Array("HTTP/1.1 \(status) X\r\nContent-Length: \(body.utf8.count)\r\n\(headers)Connection: close\r\n\r\n\(body)".utf8)
}

/// Waits (up to `seconds`) for `condition`.
func eventually(_ seconds: Double = 3, _ condition: () -> Bool) -> Bool {
    let deadline = monotonicSeconds() + seconds
    while monotonicSeconds() < deadline {
        if condition() { return true }
        sleepSeconds(0.005)
    }
    return condition()
}
