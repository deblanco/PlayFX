import CommonCrypto
import CryptoKit
import Darwin
import Foundation

@testable import PlayFXProtocol

/// A console written from docs/protocol, for loopback tests: a UDP search responder (RES2/RES3) and a TCP
/// registration endpoint that unmasks the seed, derives the context, decrypts the request and answers.
/// It uses its own AES-CFB (CommonCrypto ECB per block) and CryptoKit HMAC, not the package's code.
final class FakeConsole: @unchecked Sendable {
    /// What the console does after reading a registration request.
    enum Reply {
        /// `HTTP/1.1 <status line>` with an RP-crypt encrypted body made from this plaintext.
        case encrypted(status: String, plaintext: String)
        /// A header only (e.g. a rejection).
        case header(String)
        /// These exact bytes, then close.
        case raw([UInt8])
        case close
        /// Say nothing and keep the connection open.
        case hang
    }

    struct Request {
        var header: [UInt8]
        var body: [UInt8]
        /// The decrypted inner text.
        var inner: String
    }

    let target: RPTarget
    let pin: UInt32
    private let handler: @Sendable (Request) -> Reply
    private let udpFD: Int32
    private let tcpFD: Int32
    let searchPort: UInt16
    let requestPort: UInt16
    private let stopping = Locked(false)
    let requests = Locked<[Request]>([])

    init(target: RPTarget, pin: UInt32, answersSearch: Bool = true, listensTCP: Bool = true,
         handler: @escaping @Sendable (Request) -> Reply) {
        self.target = target
        self.pin = pin
        self.handler = handler
        let (u, up) = Self.bindSocket(SOCK_DGRAM)
        let (t, tp) = Self.bindSocket(SOCK_STREAM)
        listen(t, 4)
        udpFD = u
        tcpFD = t
        searchPort = up
        requestPort = tp
        if answersSearch { Thread.detachNewThread { [self] in serveUDP() } }
        if listensTCP { Thread.detachNewThread { [self] in serveTCP() } }
    }

    /// Stops both servers.
    func stop() {
        stopping.with { $0 = true }
        close(udpFD)
        close(tcpFD)
    }

    static func bindSocket(_ type: Int32) -> (Int32, UInt16) {
        let fd = socket(AF_INET, type, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) }
        }
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    /// A UDP port nobody listens on.
    static func closedUDPPort() -> UInt16 {
        let (fd, port) = bindSocket(SOCK_DGRAM)
        close(fd)
        return port
    }

    /// A TCP port nobody listens on.
    static func closedTCPPort() -> UInt16 {
        let (fd, port) = bindSocket(SOCK_STREAM)
        close(fd)
        return port
    }

    // MARK: UDP

    private func serveUDP() {
        let expected = Array((target.isPS5 ? "SRC3" : "SRC2").utf8) + [0]
        while !stopping.with({ $0 }) {
            var pfd = pollfd(fd: udpFD, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 50) > 0 else { continue }
            var from = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            var buffer = [UInt8](repeating: 0, count: 64)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    buffer.withUnsafeMutableBytes { recvfrom(udpFD, $0.baseAddress, 64, 0, sa, &length) }
                }
            }
            guard count > 0 else { continue }
            // Noise first, to check the client keeps waiting for a RESx answer.
            let reply: [[UInt8]] = Array(buffer[0..<count]) == expected
                ? [Array("NOPE".utf8), Array((target.isPS5 ? "RES3" : "RES2").utf8) + [0]] : []
            for datagram in reply {
                withUnsafePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        _ = datagram.withUnsafeBytes { sendto(udpFD, $0.baseAddress, $0.count, 0, sa, length) }
                    }
                }
            }
        }
    }

    // MARK: TCP

    private func serveTCP() {
        while !stopping.with({ $0 }) {
            var pfd = pollfd(fd: tcpFD, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 50) > 0 else { continue }
            let fd = accept(tcpFD, nil, nil)
            guard fd >= 0 else { continue }
            handle(fd)
        }
    }

    private func handle(_ fd: Int32) {
        defer { close(fd) }
        var data: [UInt8] = []
        var expectedTotal: Int?
        while expectedTotal == nil || data.count < expectedTotal! {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 2000) > 0 else { return }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, 4096) }
            guard n > 0 else { return }
            data += chunk[0..<n]
            if expectedTotal == nil, let end = Self.indexOf([13, 10, 13, 10], in: data) {
                let head = String(decoding: data[0..<end], as: UTF8.self)
                let length = head.components(separatedBy: "\r\n")
                    .compactMap { $0.hasPrefix("Content-Length: ") ? Int($0.dropFirst(16)) : nil }.first ?? 0
                expectedTotal = end + 4 + length
            }
        }
        let headerEnd = Self.indexOf([13, 10, 13, 10], in: data)! + 4
        let header = Array(data[0..<headerEnd]), body = Array(data[headerEnd...])
        let context = unmask(body)
        let inner = String(decoding: Self.cfb(context, body[0x1e0...].map { $0 }, encrypt: false), as: UTF8.self)
        let request = Request(header: header, body: body, inner: inner)
        requests.with { $0.append(request) }
        switch handler(request) {
        case .encrypted(let status, let plaintext):
            let encrypted = Self.cfb(context, Array(plaintext.utf8), encrypt: true)
            write(fd, Array("HTTP/1.1 \(status)\r\nContent-Length: \(encrypted.count)\r\n\r\n".utf8) + encrypted)
        case .header(let text): write(fd, Array(text.utf8))
        case .raw(let bytes): write(fd, bytes)
        case .close: break
        case .hang: sleepSeconds(1.5)
        }
    }

    private func write(_ fd: Int32, _ bytes: [UInt8]) {
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    static func indexOf(_ needle: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= needle.count else { return nil }
        return (0...(bytes.count - needle.count)).first { bytes[$0..<$0 + needle.count].elementsEqual(needle) }
    }

    // MARK: Spec, console side (rpcrypt.md section 6, inverse)

    /// Recovers `S` from the masked seed in the body and derives `(K, S, H)`.
    private func unmask(_ body: [UInt8]) -> (key: [UInt8], seed: [UInt8], hmac: [UInt8]) {
        let pinBytes = (0..<4).map { UInt8(truncatingIfNeeded: pin >> UInt32(24 - 8 * $0)) }
        var key = [UInt8](repeating: 0, count: 16), seed = key
        switch target {
        case .ps4v8, .ps4v9:
            let m = Array(body[0x11c..<0x12c])
            for i in 0..<16 { seed[i] = (m[i] ^ RPTables.p9Mask[i]) &+ UInt8(i) &+ 0x29 }
            key = RPTables.p9RegistKey
            for j in 0..<4 { key[j] ^= pinBytes[j] }
            return (key, seed, RPTables.ivHmacKeyP9)
        case .ps4v10, .ps5v1:
            let m = Array(body[0x191..<0x199]) + Array(body[0x0c7..<0x0cf])
            let keyCol = Int(body[0x18d] & 0x1f), maskCol = Int(body[0] >> 3)
            let ps5 = target == .ps5v1
            let (rk, rm) = ps5 ? (RPTables.registKeyPs5, RPTables.registMaskPs5) : (RPTables.registKeyPs4, RPTables.registMaskPs4)
            let add: UInt8 = ps5 ? 0xd3 : 0x29
            for i in 0..<16 {
                seed[i] = (m[i] &- add &- UInt8(i)) ^ rm[i * 0x20 + maskCol]
                key[i] = rk[i * 0x20 + keyCol]
            }
            for j in 0..<4 { key[12 + j] ^= pinBytes[j] }
            return (key, seed, ps5 ? RPTables.ivHmacKeyPs5 : RPTables.ivHmacKeyPs4)
        }
    }

    /// AES-128-CFB128 at counter 0 from first principles (one ECB block at a time).
    static func cfb(_ context: (key: [UInt8], seed: [UInt8], hmac: [UInt8]), _ input: [UInt8], encrypt: Bool) -> [UInt8] {
        let mac = HMAC<SHA256>.authenticationCode(
            for: context.seed + [0, 0, 0, 0, 0, 0, 0, 0], using: SymmetricKey(data: context.hmac))
        var feedback = Array(Array(mac)[0..<16])
        var output = [UInt8]()
        var index = 0
        while index < input.count {
            var block = [UInt8](repeating: 0, count: 16)
            var moved = 0
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                    context.key, 16, nil, feedback, 16, &block, 16, &moved)
            let chunk = Array(input[index..<min(index + 16, input.count)])
            let out = zip(chunk, block).map { $0 ^ $1 }
            output += out
            if chunk.count == 16 { feedback = encrypt ? out : chunk }
            index += 16
        }
        return output
    }

    /// The made-up successful answer of test-vectors.md section 5.
    static func pairingPlaintext(ps5: Bool, regist: String = "6131623263336434") -> String {
        let xx = ps5 ? "PS5" : "PS4"
        return "\(xx)-RegistKey: \(regist)\r\nRP-KeyType: 2\r\nRP-Key: 00112233445566778899aabbccddeeff\r\n"
            + "\(xx)-Mac: 0a1b2c3d4e5f\r\n\(xx)-Nickname: \(xx)-TEST\r\n"
    }
}
