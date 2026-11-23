import Foundation
import Network

/// The ctrl start request (ctrl.md section 3.1).
struct CtrlRequest {
    var bytes: [UInt8]
    /// The client's next ctrl counter after the encrypted headers.
    var nextLocalCounter: UInt64

    /// The 32-byte `clientDeviceId` (session.md section 6.2) around 16 random bytes.
    static func deviceID(random: [UInt8]) -> [UInt8] {
        [0x00, 0x18, 0x00, 0x00, 0x00, 0x07, 0x00, 0x40, 0x00, 0x80] + random + [UInt8](repeating: 0, count: 6)
    }

    /// Builds the request with its encrypted headers in the spec's order and counters. `streamingType` is
    /// sent for a PS5 only.
    static func build(
        host: String, port: UInt16, target: RPTarget, context: RPCryptContext, registKey: [UInt8],
        deviceID: [UInt8], streamingType: StreamingType
    ) throws -> CtrlRequest {
        var counter: UInt64 = 0
        func sealed(_ plaintext: [UInt8]) throws -> String {
            defer { counter += 1 }
            return try context.encrypted(plaintext, counter: counter).withUnsafeBytes {
                Data($0).base64EncodedString()
            }
        }
        var text = "GET \(target.ctrlPath) HTTP/1.1\r\n"
        text += "Host: \(host):\(port)\r\n"
        text += "User-Agent: remoteplay Windows\r\n"
        text += "Connection: keep-alive\r\n"
        text += "Content-Length: 0\r\n"
        text += "RP-Auth: \(try sealed(registKey))\r\n"
        text += "RP-Version: \(target.protocolVersion)\r\n"
        text += "RP-Did: \(try sealed(deviceID))\r\n"
        text += "RP-ControllerType: 3\r\n"
        text += "RP-ClientType: 11\r\n"
        text += "RP-OSType: \(try sealed(Array("Win10.0.0".utf8) + [0]))\r\n"
        text += "RP-ConPath: 1\r\n"
        if target.isPS5 { text += "RP-PadProcNo: 3\r\n" }
        if target == .ps4v10 || target.isPS5 { text += "RP-StartBitrate: \(try sealed([0, 0, 0, 0]))\r\n" }
        if target.isPS5 {
            let type = streamingType.rawValue
            text += "RP-StreamingType: \(try sealed([UInt8(type & 0xff), UInt8((type >> 8) & 0xff), 0, 0]))\r\n"
        }
        text += "\r\n"
        return CtrlRequest(bytes: Array(text.utf8), nextLocalCounter: counter)
    }
}

/// The video codec announced on ctrl (PS5 only; ctrl.md section 3.1).
public enum StreamingType: UInt32, Sendable, Equatable {
    case h264 = 1
    case h265 = 2
    case h265HDR = 3
}

/// The console model from `RP-Server-Type` (ctrl.md section 3.2).
public enum ConsoleModel: UInt8, Sendable, Equatable {
    case ps4 = 0
    case ps4Pro = 1
    case ps5 = 2
}

/// An `NWProtocolFramer` that cuts the ctrl byte stream into the response header and then whole frames, so
/// the connection's receive callback sees one item at a time (ctrl.md section 5). The cutting is
/// `CtrlStreamSplitter`; this class only plugs it into Network.framework. Output passes through unchanged:
/// the session builds whole frames, because their payload encryption depends on the counter at write time.
final class CtrlFramer: NWProtocolFramerImplementation {
    static let definition = NWProtocolFramer.Definition(implementation: CtrlFramer.self)
    static let label = "PlayFXProtocol.ctrl"

    private var splitter = CtrlStreamSplitter()

    required init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    func handleOutput(
        framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool
    ) {
        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            framer.markFailed(error: nil)
        }
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var chunk: [UInt8] = []
            let parsed = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { buffer, _ in
                guard let buffer, !buffer.isEmpty else { return 0 }
                chunk = Array(buffer)
                return buffer.count
            }
            guard parsed, !chunk.isEmpty else { return 1 }
            for item in splitter.feed(chunk) {
                framer.deliverInput(
                    data: Data(CtrlStreamSplitter.encode(item)),
                    message: NWProtocolFramer.Message(definition: Self.definition), isComplete: true)
            }
        }
    }

    /// A TCP connection to the console's ctrl port with this framer on top.
    static func makeConnection(host: String, port: UInt16) throws -> NWConnection {
        guard let port = NWEndpoint.Port(rawValue: port), !host.isEmpty else { throw FailureKind.badAddress }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.defaultProtocolStack.applicationProtocols.insert(
            NWProtocolFramer.Options(definition: definition), at: 0)
        return NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
    }
}
