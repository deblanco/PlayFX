import CommonCrypto
import CryptoKit
import Darwin
import Foundation

@testable import PlayFXProtocol

/// The session cipher of ctrl.md section 1, from first principles (CryptoKit HMAC, one ECB block at a time),
/// with the known keys of session.md V-S3 so it shares no derivation code with the package.
struct SpecCipher {
    let key: [UInt8]
    let seed: [UInt8]
    let hmac: [UInt8]

    /// The cipher for the version in `Rp-Version` / `RP-Version`, for the made-up nonce and RP key.
    static func forVersion(_ version: String) -> SpecCipher {
        switch version {
        case "1.0": return SpecCipher(key: hex("598fa9a031d01820db25cab6e90bb19b"), seed: hex("ac7d50f394ea6588f0488f76e4170c8a"), hmac: RPTables.ivHmacKeyPs5)
        case "10.0": return SpecCipher(key: hex("f7e760687cea0ce70c1c129f67c087c8"), seed: hex("e978b89a1098296fb32415b9b5713be0"), hmac: RPTables.ivHmacKeyPs4)
        case "9.0": return SpecCipher(key: hex("35394aed0d6cda5620d3c3a748eb1adf"), seed: hex("d8905e42bce052e092e354911ad33688"), hmac: RPTables.ivHmacKeyP9)
        default:
            // PS4 8.0 has no vector in the spec; the package's derivation stands in.
            let context = try! RPCryptContext.session(target: .ps4v8, nonce: SessionVector.nonce, rpKey: SessionVector.rpKey)
            return SpecCipher(key: context.key, seed: context.seed, hmac: context.hmacKey)
        }
    }

    func apply(_ input: [UInt8], counter: UInt64, encrypt: Bool) -> [UInt8] {
        var message = seed
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8(truncatingIfNeeded: counter >> UInt64(shift))) }
        var feedback = Array(Array(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: hmac)))[0..<16])
        var output = [UInt8]()
        var index = 0
        while index < input.count {
            var block = [UInt8](repeating: 0, count: 16)
            var moved = 0
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                    key, 16, nil, feedback, 16, &block, 16, &moved)
            let chunk = Array(input[index..<min(index + 16, input.count)])
            let out = zip(chunk, block).map { $0 ^ $1 }
            output += out
            if chunk.count == 16 { feedback = encrypt ? out : chunk }
            index += 16
        }
        return output
    }
}

/// One accepted ctrl connection, from the console's side.
final class CtrlPeer: @unchecked Sendable {
    let fd: Int32
    let cipher: SpecCipher
    let requestText: String
    /// The console's counter for what it sends; the client's counter for what it receives.
    private(set) var sendCounter: UInt64 = 0
    private(set) var receiveCounter: UInt64
    private var buffer: [UInt8]
    /// Everything decoded from the client so far: (type, plaintext, raw payload on the wire).
    let received = Locked<[(type: UInt16, plain: [UInt8], wire: [UInt8])]>([])

    init(fd: Int32, cipher: SpecCipher, requestText: String, leftover: [UInt8]) {
        self.fd = fd
        self.cipher = cipher
        self.requestText = requestText
        buffer = leftover
        // The request used counters 0..k-1 (ctrl.md section 3.1).
        let version = Self.header("RP-Version", in: requestText) ?? ""
        receiveCounter = version == "1.0" ? 5 : version == "10.0" ? 4 : 3
    }

    static func header(_ name: String, in text: String) -> String? {
        text.components(separatedBy: "\r\n").first { $0.hasPrefix("\(name):") }
            .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
    }

    func header(_ name: String) -> String? { Self.header(name, in: requestText) }

    /// Internet play: the client skips one counter after the request (ctrl.md section 10), so its first encrypted
    /// message is one further on.
    func skipClientCounter() { receiveCounter += 1 }

    /// Decrypts an `RP-*` header value the client sent, at the counter the spec gives it.
    func decryptedHeader(_ name: String, counter: UInt64) -> [UInt8]? {
        header(name).flatMap { Data(base64Encoded: $0) }.map { cipher.apply(Array($0), counter: counter, encrypt: false) }
    }

    // MARK: Writing

    func write(_ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return }
            offset += n
        }
    }

    /// The response header, in the padded style of a real PS5 (`Content-Length:        0`). `serverType` nil
    /// leaves `RP-Server-Type` out (and the console's counter unused). `then` is sent in the same write.
    func sendHead(status: String = "200 OK", serverType: UInt8? = 2, extra: [String] = [], then: [UInt8] = []) {
        var text = "HTTP/1.1 \(status)\r\nConnection: keep-alive\r\nContent-Length:        0\r\n"
        if let serverType {
            let sealed = cipher.apply([serverType] + [UInt8](repeating: 0, count: 15), counter: 0, encrypt: true)
            text += "RP-Server-Type: \(Data(sealed).base64EncodedString())\r\n"
            sendCounter = 1
        }
        for line in extra { text += "\(line)\r\n" }
        write(Array(text.utf8) + [13, 10] + then)
    }

    /// The wire bytes of a frame; encrypts with the next counter when the plaintext is not empty.
    func frame(_ type: UInt16, _ plain: [UInt8] = []) -> [UInt8] {
        var payload = plain
        if !plain.isEmpty {
            payload = cipher.apply(plain, counter: sendCounter, encrypt: true)
            sendCounter += 1
        }
        let length = UInt32(payload.count)
        return [UInt8(length >> 24), UInt8(truncatingIfNeeded: length >> 16), UInt8(truncatingIfNeeded: length >> 8),
                UInt8(truncatingIfNeeded: length), UInt8(type >> 8), UInt8(type & 0xff), 0, 0] + payload
    }

    func send(_ type: UInt16, _ plain: [UInt8] = []) { write(frame(type, plain)) }

    // MARK: Reading

    /// The next frame from the client, decrypted at the spec's counter, or nil on close or timeout.
    func receive(timeout: Double = 2) -> (type: UInt16, plain: [UInt8], wire: [UInt8])? {
        let deadline = monotonicSeconds() + timeout
        while buffer.count < 8 || buffer.count < 8 + Int(UInt32(buffer[0]) << 24 | UInt32(buffer[1]) << 16 | UInt32(buffer[2]) << 8 | UInt32(buffer[3])) {
            guard fill(timeout: deadline - monotonicSeconds()) else { return nil }
        }
        let length = Int(UInt32(buffer[0]) << 24 | UInt32(buffer[1]) << 16 | UInt32(buffer[2]) << 8 | UInt32(buffer[3]))
        let type = UInt16(buffer[4]) << 8 | UInt16(buffer[5])
        let wire = Array(buffer[8..<8 + length])
        buffer.removeFirst(8 + length)
        var plain = wire
        if !wire.isEmpty {
            plain = cipher.apply(wire, counter: receiveCounter, encrypt: false)
            receiveCounter += 1
        }
        let frame = (type: type, plain: plain, wire: wire)
        received.with { $0.append(frame) }
        return frame
    }

    private func fill(timeout: Double) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard timeout > 0, poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return false }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, 4096) }
        guard n > 0 else { return false }
        buffer += chunk[0..<n]
        return true
    }

    /// Reads and records frames until the client closes (or `limit` seconds pass).
    func pump(limit: Double = 5) {
        let deadline = monotonicSeconds() + limit
        while monotonicSeconds() < deadline, receive(timeout: deadline - monotonicSeconds()) != nil {}
    }

    private let closed = Locked(false)

    /// A clean close of the console's side (FIN); the socket stays open for reading.
    func finish() { shutdown(fd, SHUT_WR) }

    /// An abortive close (RST).
    func reset() { closeNow(reset: true) }

    /// Closes the socket once; later calls do nothing.
    func closeNow(reset: Bool = false) {
        guard closed.with({ let was = $0; $0 = true; return !was }) else { return }
        if reset {
            var option = linger(l_onoff: 1, l_linger: 0)
            setsockopt(fd, SOL_SOCKET, SO_LINGER, &option, socklen_t(MemoryLayout<linger>.size))
        }
        close(fd)
    }

    /// Waits until the client closes the connection, ignoring anything it sends.
    func waitForClose(limit: Double = 5) { pump(limit: limit) }
}

/// A console on 127.0.0.1 that answers session init and ctrl on one port, like a real one. Each init
/// connection gets the next entry of `initReplies`; each ctrl connection runs `ctrl` on its own thread.
final class FakeSessionConsole: @unchecked Sendable {
    enum InitReply {
        /// 200 with `RP-Nonce` for the version in the request, in a padded header.
        case nonce
        /// A refusal: status line, `RP-Application-Reason` and optionally `RP-Version`.
        case refuse(status: String = "403 Forbidden", reason: String?, version: String? = nil)
        case raw([UInt8])
        case close
        case hang
    }

    let port: UInt16
    private let listenFD: Int32
    private let initReplies: @Sendable (Int) -> InitReply
    private let ctrl: @Sendable (CtrlPeer, Int) -> Void
    private let stopping = Locked(false)
    /// The request text of every session-init connection, in order.
    let initRequests = Locked<[String]>([])
    /// Ctrl connections accepted so far.
    let ctrlConnections = Locked(0)
    let peers = Locked<[CtrlPeer]>([])

    init(ctrl: @escaping @Sendable (CtrlPeer, Int) -> Void = { peer, _ in peer.sendHead(); peer.waitForClose() },
         initReplies: @escaping @Sendable (Int) -> InitReply = { _ in .nonce }) {
        self.initReplies = initReplies
        self.ctrl = ctrl
        // A write to a client that already closed must fail with EPIPE, not kill the test run.
        signal(SIGPIPE, SIG_IGN)
        (listenFD, port) = FakeConsole.bindSocket(SOCK_STREAM)
        listen(listenFD, 8)
        Thread.detachNewThread { [self] in accept() }
    }

    private let acceptDone = DispatchSemaphore(value: 0)

    /// Stops accepting and closes the listening socket, but only after the accept thread has left its loop: it
    /// polls the descriptor, and a number closed under it could be reused by another test's socket.
    func stop() {
        guard !stopping.with({ let was = $0; $0 = true; return was }) else { return }
        acceptDone.wait()
        close(listenFD)
    }

    private func accept() {
        while !stopping.with({ $0 }) {
            var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 50) > 0 else { continue }
            let fd = Darwin.accept(listenFD, nil, nil)
            guard fd >= 0 else { continue }
            Thread.detachNewThread { [self] in serve(fd) }
        }
        acceptDone.signal()
    }

    private func serve(_ fd: Int32) {
        var data: [UInt8] = []
        while FakeConsole.indexOf([13, 10, 13, 10], in: data) == nil {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 2000) > 0 else { close(fd); return }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, 4096) }
            guard n > 0 else { close(fd); return }
            data += chunk[0..<n]
        }
        let end = FakeConsole.indexOf([13, 10, 13, 10], in: data)! + 4
        let text = String(decoding: data[0..<end], as: UTF8.self)
        let leftover = Array(data[end...])
        if text.hasPrefix("GET /sce/rp/session/ctrl") || text.contains("/rp/sess/ctrl ") {
            let index = ctrlConnections.with { $0 += 1; return $0 - 1 }
            let version = CtrlPeer.header("RP-Version", in: text) ?? "1.0"
            let peer = CtrlPeer(fd: fd, cipher: .forVersion(version), requestText: text, leftover: leftover)
            peers.with { $0.append(peer) }
            ctrl(peer, index)
            peer.closeNow()
        } else {
            let index = initRequests.with { $0.append(text); return $0.count - 1 }
            answerInit(fd, text: text, reply: initReplies(index))
        }
    }

    private func answerInit(_ fd: Int32, text: String, reply: InitReply) {
        defer { close(fd) }
        func write(_ bytes: [UInt8]) { _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } }
        switch reply {
        case .nonce:
            write(Array(("HTTP/1.1 200 OK\r\nContent-Length:        0\r\nRP-Server-Type: ignored\r\n"
                + "RP-Nonce: AAECAwQFBgcICQoLDA0ODw==\r\n\r\n").utf8))
        case .refuse(let status, let reason, let version):
            var head = "HTTP/1.1 \(status)\r\nContent-Length:        0\r\n"
            if let reason { head += "RP-Application-Reason: \(reason)\r\n" }
            if let version { head += "RP-Version: \(version)\r\n" }
            write(Array((head + "\r\n").utf8))
        case .raw(let bytes): write(bytes)
        case .close: break
        case .hang: sleepSeconds(1.5)
        }
    }
}
