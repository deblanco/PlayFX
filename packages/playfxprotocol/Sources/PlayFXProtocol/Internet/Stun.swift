import Darwin
import Dispatch
import Foundation

// STUN Binding (RFC 5389 / RFC 8489) and the NAT port prediction of holepunch.md sections 3.2 and 3.3.

/// A lock-protected value for the hand-off between threads.
private final class Handoff<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
}

/// A public address and port a STUN server reported.
public struct StunAnswer: Sendable, Equatable {
    /// The public IPv4 address.
    public var address: String
    /// The public port.
    public var port: UInt16

    public init(address: String, port: UInt16) {
        self.address = address
        self.port = port
    }
}

/// A STUN server to ask.
public struct StunServer: Sendable, Equatable {
    /// Host name or IPv4 address.
    public var host: String
    /// UDP port.
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

/// What the STUN answers say about the NAT (holepunch.md section 3.3).
public struct NATPrediction: Sendable, Equatable {
    /// The public address: the last answer's.
    public var publicAddress: String
    /// The port the console is expected to see: the base of the STUN candidates.
    public var basePort: UInt16
    /// The step between the ports a NAT allocates for consecutive destinations (0 when it keeps the port).
    /// A decreasing NAT gives a negative value (the spec computes it mod 2^16; it is read as a signed 16-bit step).
    public var increment: Int
    /// The NAT allocates ports unpredictably, so the client guesses (holepunch.md section 4.3).
    public var randomAllocation: Bool

    public init(publicAddress: String, basePort: UInt16, increment: Int, randomAllocation: Bool) {
        self.publicAddress = publicAddress
        self.basePort = basePort
        self.increment = increment
        self.randomAllocation = randomAllocation
    }

    /// The data hole asks one server only: its answer is the base port, and the ctrl hole's `increment` and
    /// random-allocation flag are reused (none when the ctrl hole used UPnP).
    public static func forDataHole(answer: StunAnswer, ctrl: NATPrediction?) -> NATPrediction {
        NATPrediction(publicAddress: answer.address, basePort: answer.port, increment: ctrl?.increment ?? 0,
                      randomAllocation: ctrl?.randomAllocation ?? false)
    }

    /// Derives the prediction from up to four answers in the order they were obtained (holepunch.md section 3.3);
    /// nil without any answer.
    public static func predict(_ allAnswers: [StunAnswer]) -> NATPrediction? {
        let answers = Array(allAnswers.prefix(4))
        guard let last = answers.last else { return nil }
        let p = answers.map { Int($0.port) }
        let sameAddress = answers.allSatisfy { $0.address == last.address }
        var increment = 0
        var random = false
        var port = p[answers.count - 1]
        switch (answers.count, sameAddress) {
        case (1, _):
            break
        case (2, true):
            increment = p[1] - p[0]
            port = p[1] + 2 * increment
        case (2, false):
            break
        case (3, true):
            increment = p[1] - p[0]
            if p[2] - p[1] != increment {
                random = true
                if increment == 0 { increment = p[2] - p[1] }
            }
            port = p[2] + increment
        case (4, true):
            let d1 = (p[1] - p[0]) & 0xffff, d2 = (p[2] - p[1]) & 0xffff, d3 = (p[3] - p[2]) & 0xffff
            if d1 == d2 || d1 == d3 {
                increment = d1
            } else if d2 == d3 {
                increment = d2
            } else {
                random = true
                increment = d1 != 0 ? d1 : d2
            }
            if increment > 32767 { increment -= 65536 }
        default:
            (increment, random) = mixedPrediction(answers.map(\.address), p)
            if answers.count == 3 { port = p[2] + increment }
        }
        // The port is kept as a 16-bit value (holepunch.md section 3.3); only guesses and steps are range-mapped.
        return NATPrediction(publicAddress: last.address, basePort: UInt16(truncatingIfNeeded: port),
                             increment: increment, randomAllocation: random)
    }

    /// The exact rules of holepunch.md section 3.3 for three or four answers whose addresses differ, row by row,
    /// reproduced as the reference computes them. Several look unintended (a span over `a1` when it stands apart,
    /// `(p4 - p1) / 4`, the reversed `p3 - p4`); they are kept because the table lists them, and they only decide
    /// which ports are tried. Differences are signed, division truncates towards zero.
    static func mixedPrediction(_ a: [String], _ p: [Int]) -> (increment: Int, random: Bool) {
        /// `inc` from a step, random when `check` differs from it (and then `inc` takes `check` if it was 0).
        func checked(_ step: Int, against check: Int) -> (Int, Bool) {
            step == check ? (step, false) : (step == 0 ? check : step, true)
        }
        if a.count == 3 {
            if a[0] != a[1] && a[0] == a[2] { return ((p[2] - p[0]) / 2, false) }
            if a[0] != a[1] && a[1] == a[2] { return (p[2] - p[1], false) }
            if a[0] == a[1] && a[0] != a[2] { return (p[1] - p[0], false) }
            return (0, false)
        }
        if a[0] != a[1] {
            if a[0] == a[2] && a[0] == a[3] { return checked(p[3] - p[2], against: (p[2] - p[0]) / 2) }
            if a[0] == a[3] && a[0] != a[2] { return ((p[3] - p[0]) / 4, false) }
            if a[0] == a[2] && a[0] != a[3] { return ((p[2] - p[0]) / 2, false) }
            // a1 differs from all the others.
            if a[1] == a[2] && a[2] == a[3] { return checked(p[3] - p[2], against: p[2] - p[1]) }
            if a[1] == a[3] && a[1] != a[2] { return ((p[3] - p[0]) / 4, false) }
            if a[1] == a[2] && a[1] != a[3] { return ((p[2] - p[0]) / 2, false) }
            if a[2] == a[3] { return (p[2] - p[3], false) }
            return (0, false)
        }
        // a1 = a2, and the four are not all equal.
        if a[2] != a[1] && a[3] == a[1] { return checked(p[1] - p[0], against: (p[3] - p[1]) / 2) }
        if a[2] != a[1] { return (p[1] - p[0], false) }
        return checked(p[1] - p[0], against: p[2] - p[1])  // a1 = a2 = a3 != a4
    }
}

/// Port arithmetic of holepunch.md sections 4.3 and 4.4.
public enum PortGuess {
    /// A port brought into range the way a guess is (above 65535 wraps to 49152 upwards, below 1024 wraps down from
    /// 65535).
    public static func clamp(_ port: Int) -> UInt16 {
        if port > 65535 { return UInt16(clamping: 49152 + (port - 65536)) }
        if port < 1024 { return UInt16(clamping: max(0, 65535 - (1024 - port))) }
        return UInt16(port)
    }

    /// `count` guesses around `base`: `base`, `+1`, `-1`, `+2`, `-2`, ... (section 4.3).
    public static func guesses(around base: UInt16, count: Int) -> [UInt16] {
        (0..<count).map { i in
            let delta = i == 0 ? 0 : (i % 2 == 1 ? (i + 1) / 2 : -(i / 2))
            return clamp(Int(base) + delta)
        }
    }

    /// `count` ports from `base` in steps of `increment`, `base + inc`, `base + 2*inc`, ... (section 4.4).
    public static func steps(from base: UInt16, increment: Int, count: Int) -> [UInt16] {
        var previous = Int(base)
        var result: [UInt16] = []
        for _ in 0..<count {
            var next = previous + increment
            if next < 1024 && previous > 1024 {
                next = 65535 - (1024 - next)
            } else if next < 1 {
                next += 65535
            } else if next > 65535 {
                next = next - 65535 + 1024
            }
            result.append(UInt16(clamping: max(0, min(65535, next))))
            previous = next
        }
        return result
    }
}

/// How the client asks STUN: the parts that touch the outside world are replaceable.
public struct StunEnvironment: Sendable {
    /// Turns a server name into an IPv4 address; nil when it doesn't resolve.
    public var resolve: @Sendable (String) -> String?
    /// Seconds to wait for one server (holepunch.md section 3.2).
    public var timeout: Double
    /// Twelve transaction-id bytes.
    public var transactionID: @Sendable () -> [UInt8]
    /// Checked between servers and while waiting.
    public var isCancelled: @Sendable () -> Bool
    /// One line per server asked: its answer (masked address, port), or why there was none.
    public var log: @Sendable (String) -> Void

    public init(resolve: @escaping @Sendable (String) -> String? = { StunClient.resolveIPv4($0) }, timeout: Double = 5,
                transactionID: @escaping @Sendable () -> [UInt8] = { (0..<12).map { _ in UInt8.random(in: 0...255) } },
                isCancelled: @escaping @Sendable () -> Bool = { false },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.resolve = resolve
        self.timeout = timeout
        self.transactionID = transactionID
        self.isCancelled = isCancelled
        self.log = log
    }
}

/// STUN Binding requests and responses (holepunch.md section 3.2).
public enum StunClient {
    static let cookie: [UInt8] = [0x21, 0x12, 0xa4, 0x42]

    /// A Binding Request without attributes: 20 bytes.
    public static func bindingRequest(transactionID: [UInt8]) -> [UInt8] {
        precondition(transactionID.count == 12, "STUN transaction id is 12 bytes")
        return [0x00, 0x01, 0x00, 0x00] + cookie + transactionID
    }

    /// The mapped address of a Binding Success response (holepunch.md section 3.2): type `0101`, the length field
    /// matching the datagram, the same cookie and transaction id; the first `XOR-MAPPED-ADDRESS` or
    /// `MAPPED-ADDRESS` with an IPv4 value wins; other attributes are skipped unchecked. Nil otherwise.
    public static func parseBindingResponse(_ bytes: [UInt8], transactionID: [UInt8]) -> StunAnswer? {
        guard bytes.count >= 20, bytes[0] == 0x01, bytes[1] == 0x01,
              Int(bytes[2]) << 8 | Int(bytes[3]) == bytes.count - 20,
              Array(bytes[4..<8]) == cookie, Array(bytes[8..<20]) == transactionID else { return nil }
        var offset = 20
        while offset + 4 <= bytes.count {
            let type = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let start = offset + 4
            guard start + length <= bytes.count else { return nil }
            if (type == 0x0020 || type == 0x0001) && length >= 8 && bytes[start + 1] == 0x01 {
                var port = UInt16(bytes[start + 2]) << 8 | UInt16(bytes[start + 3])
                var address = Array(bytes[(start + 4)..<(start + 8)])
                if type == 0x0020 {
                    port ^= 0x2112
                    for i in 0..<4 { address[i] ^= cookie[i] }
                }
                return StunAnswer(address: address.map(String.init).joined(separator: "."), port: port)
            }
            offset = start + ((length + 3) & ~3)
        }
        return nil
    }

    /// Asks `servers` one after the other from `socket` (so the answer describes this socket's NAT mapping) until
    /// `wanted` have answered or the servers run out: 4 for the ctrl hole, 1 for the data hole (section 3.3).
    public static func collect(socket: any UDPPunchSocket, servers: [StunServer], wanted: Int,
                               environment: StunEnvironment = StunEnvironment()) -> [StunAnswer] {
        var answers: [StunAnswer] = []
        for server in servers where answers.count < wanted {
            if environment.isCancelled() { break }
            let name = "\(server.host):\(server.port)"
            guard let address = environment.resolve(server.host) else {
                environment.log("STUN \(name): did not resolve")
                continue
            }
            let transaction = environment.transactionID()
            guard (try? socket.send(bindingRequest(transactionID: transaction), to: address, port: server.port)) != nil
            else {
                environment.log("STUN \(name): the request could not be sent")
                continue
            }
            let deadline = monotonicSeconds() + environment.timeout
            var answered = false
            while !environment.isCancelled() {
                let remaining = deadline - monotonicSeconds()
                if remaining <= 0 { break }
                guard let packet = try? socket.receive(timeout: min(remaining, 0.25)) else {
                    sleepSeconds(0.01)
                    continue
                }
                if let answer = parseBindingResponse(packet.bytes, transactionID: transaction) {
                    answers.append(answer)
                    answered = true
                    environment.log("STUN \(name): mapped \(AddressMask.describe(answer.address)):\(answer.port), "
                        + "sent from local port \(socket.localPort)")
                    break
                }
            }
            if !answered && !environment.isCancelled() {
                environment.log("STUN \(name): no answer in \(Int(environment.timeout)) s")
            }
        }
        return answers
    }

    /// The first ten lines of the public server list, each `host:port` (holepunch.md section 3.2 servers, 1).
    public static func servers(fromHostList text: String) -> [StunServer] {
        text.split(whereSeparator: \.isNewline).prefix(10).compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: ":")
            guard parts.count == 2, let port = UInt16(parts[1]), !parts[0].isEmpty else { return nil }
            return StunServer(host: String(parts[0]), port: port)
        }
    }

    /// The built-in list in the order of holepunch.md section 3.2 before shuffling: Moonlight, then
    /// `stun.l.google.com` and `stun1` to `stun4`, each on 19302 then 19305.
    static let builtInTable: [StunServer] = [StunServer(host: "stun.moonlight-stream.org", port: 3478)]
        + ["stun", "stun1", "stun2", "stun3", "stun4"].flatMap { name in
            [UInt16(19302), 19305].map { StunServer(host: "\(name).l.google.com", port: $0) }
        }

    /// The built-in list shuffled the reference's way: for `i` from 10 down to 2, entry `i` swaps with entry
    /// `j = 1 + (random mod (i - 1))`. Entry 0 stays first; at `i = 2` entries 1 and 2 always swap.
    public static func builtInServers<G: RandomNumberGenerator>(using generator: inout G) -> [StunServer] {
        var list = builtInTable
        for i in stride(from: 10, through: 2, by: -1) {
            list.swapAt(i, 1 + Int(generator.next() % UInt64(i - 1)))
        }
        return list
    }

    /// The servers to ask in order: the fetched public list (when it could be fetched), then the built-in one.
    public static func serverList<G: RandomNumberGenerator>(fetchedHostList: String?, using generator: inout G)
        -> [StunServer] {
        (fetchedHostList.map(servers(fromHostList:)) ?? []) + builtInServers(using: &generator)
    }

    /// An IPv4 address for a host name (numeric text is returned as is); nil if it doesn't resolve or `timeout` seconds
    /// pass. `getaddrinfo` can't be cancelled, so it runs on a helper thread that is abandoned on a timeout.
    public static func resolveIPv4(_ host: String, timeout: Double = 3) -> String? {
        let result = Handoff<String?>(nil)
        let done = DispatchSemaphore(value: 0)
        Thread {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_DGRAM
            var found: UnsafeMutablePointer<addrinfo>?
            if getaddrinfo(host, nil, &hints, &found) == 0, let first = found {
                if let address = first.pointee.ai_addr {
                    var storage = sockaddr_storage()
                    memcpy(&storage, address, Int(first.pointee.ai_addrlen))
                    result.set(SocketAddress.text(of: storage))
                }
                freeaddrinfo(found)
            }
            done.signal()
        }.start()
        return done.wait(timeout: .now() + timeout) == .success ? result.get() : nil
    }
}
