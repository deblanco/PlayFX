import Foundation

/// Message type ids of the ctrl channel (ctrl.md section 6).
enum CtrlType {
    static let displayNoticeA: UInt16 = 0x0001
    static let loginPINRequest: UInt16 = 0x0004
    static let loginResult: UInt16 = 0x0005
    static let keyboardEnable: UInt16 = 0x000D
    static let controllerFeaturesConnect: UInt16 = 0x0011
    static let dualSenseEnable: UInt16 = 0x0013
    static let goHome: UInt16 = 0x0014
    static let displayNoticeB: UInt16 = 0x0016
    static let keyboardToggle: UInt16 = 0x0020
    static let keyboardOpened: UInt16 = 0x0021
    static let keyboardClosedByConsole: UInt16 = 0x0022
    static let keyboardSetText: UInt16 = 0x0023
    static let keyboardTextChanged: UInt16 = 0x0024
    static let keyboardClose: UInt16 = 0x0025
    static let microphoneConnect: UInt16 = 0x0030
    static let sessionID: UInt16 = 0x0033
    static let switchToStreamAck: UInt16 = 0x0034
    static let microphoneState: UInt16 = 0x0036
    static let goToBed: UInt16 = 0x0050
    static let heartbeatRequest: UInt16 = 0x00FE
    static let heartbeatReply: UInt16 = 0x01FE
    static let displayDevices: UInt16 = 0x0910
    static let loginPINReply: UInt16 = 0x8004
}

/// Big-endian helpers for payload fields.
extension Array where Element == UInt8 {
    mutating func appendBE32(_ value: UInt32) {
        append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                            UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    /// The big-endian `UInt32` at `offset`, or nil when it does not fit.
    func be32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return self[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

/// The 8-byte frame header and whole frames (ctrl.md section 5).
enum CtrlWire {
    static let headerSize = 8

    /// `payload` is what goes on the wire (already encrypted when non-empty).
    static func frame(type: UInt16, payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(headerSize + payload.count)
        out.appendBE32(UInt32(payload.count))
        out += [UInt8(type >> 8), UInt8(type & 0xff), 0, 0]
        return out + payload
    }
}

/// A message the client sends, with its plaintext payload (ctrl.md section 6).
struct CtrlOutgoing: Equatable {
    var type: UInt16
    var payload: [UInt8]

    static let heartbeatReply = CtrlOutgoing(type: CtrlType.heartbeatReply, payload: [])
    static let goToBed = CtrlOutgoing(type: CtrlType.goToBed, payload: [])
    static let goHome = CtrlOutgoing(type: CtrlType.goHome, payload: [0x00, 0xff] + [UInt8](repeating: 0, count: 14))
    static let microphoneConnect = CtrlOutgoing(type: CtrlType.microphoneConnect, payload: [0, 0])
    static let displayDevices = CtrlOutgoing(type: CtrlType.displayDevices, payload: [0, 0, 0, 0])
    static let keyboardEnable = CtrlOutgoing(
        type: CtrlType.keyboardEnable, payload: [0, 0, 0, 1, 0, 0, 0x05, 0xae] + [UInt8](repeating: 0, count: 8))
    static let keyboardToggle = CtrlOutgoing(type: CtrlType.keyboardToggle, payload: [1])
    static let dualSenseEnable = CtrlOutgoing(type: CtrlType.dualSenseEnable, payload: [0x00, 0x40, 0x00])
    static let controllerFeaturesConnect = CtrlOutgoing(
        type: CtrlType.controllerFeaturesConnect,
        payload: [0xa0, 0xab, 0x51, 0xbd, 0xd1, 0x7e, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00])

    /// The PIN as ASCII digits; nil unless it is 1 to 32 digits.
    static func loginPIN(_ digits: String) -> CtrlOutgoing? {
        let bytes = Array(digits.utf8)
        guard (1...32).contains(bytes.count), bytes.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return CtrlOutgoing(type: CtrlType.loginPINReply, payload: bytes)
    }

    /// `00 01 XX 59` (ctrl.md section 6.6). Which of `00` and `01` means muted is not known.
    static func microphoneState(_ value: UInt8) -> CtrlOutgoing {
        CtrlOutgoing(type: CtrlType.microphoneState, payload: [0x00, 0x01, value, 0x59])
    }

    static func keyboardSetText(sequence: UInt32, text: String) -> CtrlOutgoing {
        let bytes = Array(text.utf8)
        var payload: [UInt8] = []
        payload.appendBE32(sequence)
        payload.appendBE32(UInt32(bytes.count))
        payload += [UInt8](repeating: 0, count: 24)
        payload.appendBE32(UInt32(bytes.count))
        return CtrlOutgoing(type: CtrlType.keyboardSetText, payload: payload + bytes)
    }

    static func keyboardClose(accept: Bool) -> CtrlOutgoing {
        var payload: [UInt8] = []
        payload.appendBE32(accept ? 0 : 1)
        return CtrlOutgoing(type: CtrlType.keyboardClose, payload: payload)
    }

    /// The start-up feature messages, in the order of ctrl.md section 8.
    static func startup(dualSense: Bool, keyboard: Bool) -> [CtrlOutgoing] {
        var list: [CtrlOutgoing] = []
        if dualSense { list += [.dualSenseEnable, .controllerFeaturesConnect] }
        if keyboard { list += [.keyboardEnable, .keyboardToggle] }
        list += [.microphoneState(1), .microphoneState(1), .displayDevices]
        return list
    }
}

/// A message from the console, decoded from its plaintext payload.
enum CtrlInbound: Equatable {
    case displayNoticeA(set: Bool)
    case displayNoticeB(payload: [UInt8], clearsState: Bool)
    case loginPINRequest
    case loginResult(accepted: Bool)
    case sessionID(payload: [UInt8])
    case heartbeatRequest
    case keyboardOpened(text: String)
    case keyboardClosedByConsole
    case keyboardTextChanged(sequence: UInt32, text: String)
    /// Unknown types and known types whose payload does not fit their layout.
    case unknown(type: UInt16, payload: [UInt8])

    static func decode(type: UInt16, payload: [UInt8]) -> CtrlInbound {
        let unknown = CtrlInbound.unknown(type: type, payload: payload)
        switch type {
        case CtrlType.displayNoticeA:
            guard let first = payload.first, first <= 1 else { return unknown }
            return .displayNoticeA(set: first == 1)
        case CtrlType.displayNoticeB:
            guard payload.count >= 2 else { return unknown }
            return .displayNoticeB(payload: payload, clearsState: payload[0] == 0x01 && payload[1] == 0xff)
        case CtrlType.loginPINRequest:
            return .loginPINRequest
        case CtrlType.loginResult:
            guard payload.count == 1, payload[0] <= 1 else { return unknown }
            return .loginResult(accepted: payload[0] == 0)
        case CtrlType.sessionID:
            return .sessionID(payload: payload)
        case CtrlType.heartbeatRequest:
            return .heartbeatRequest
        case CtrlType.keyboardOpened:
            guard let text = text(in: payload, lengthAt: 28, textAt: 32) else { return unknown }
            return .keyboardOpened(text: text)
        case CtrlType.keyboardClosedByConsole:
            return .keyboardClosedByConsole
        case CtrlType.keyboardTextChanged:
            guard let sequence = payload.be32(at: 0), let text = text(in: payload, lengthAt: 8, textAt: 40)
            else { return unknown }
            return .keyboardTextChanged(sequence: sequence, text: text)
        default:
            return unknown
        }
    }

    private static func text(in payload: [UInt8], lengthAt: Int, textAt: Int) -> String? {
        guard let length = payload.be32(at: lengthAt), payload.count >= textAt, payload.count - textAt >= Int(length)
        else { return nil }
        return String(decoding: payload[textAt..<textAt + Int(length)], as: UTF8.self)
    }

    /// The session ID of a `0x33` payload (ctrl.md section 6.2): byte 0, then 24 to 78 characters of
    /// `A-Z a-z 0-9`. `lengthByteExpected` is false when byte 0 is not the usual `0x4A`.
    static func parseSessionID(_ payload: [UInt8]) -> (id: String, lengthByteExpected: Bool)? {
        guard payload.count >= 1 else { return nil }
        let characters = payload.dropFirst()
        guard (24...78).contains(characters.count), characters.allSatisfy({
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x61 && $0 <= 0x7a)
        }) else { return nil }
        return (String(decoding: characters, as: UTF8.self), payload[0] == 0x4a)
    }
}

/// Splits the bytes of the ctrl connection into the response header and then frames (ctrl.md sections 2, 5).
/// Any bytes after the header's blank line are the start of the frame stream.
struct CtrlStreamSplitter {
    enum Item: Equatable {
        /// The response header, up to and including its blank line.
        case head([UInt8])
        /// A frame; the payload is still encrypted.
        case frame(type: UInt16, payload: [UInt8])
        /// A header too large to be sane, or a frame over the limit (length 0 for a header).
        case oversize(length: UInt32)
    }

    private enum Phase { case head, frames, dead }
    private var phase = Phase.head
    private var buffer: [UInt8] = []
    let maximumHead: Int
    let maximumPayload: Int

    init(maximumHead: Int = 16 * 1024, maximumPayload: Int = 1 << 20) {
        self.maximumHead = maximumHead
        self.maximumPayload = maximumPayload
    }

    /// Adds received bytes and returns every complete item they finish.
    mutating func feed(_ bytes: [UInt8]) -> [Item] {
        guard phase != .dead else { return [] }
        buffer += bytes
        var items: [Item] = []
        var start = 0
        scan: while true {
            switch phase {
            case .dead:
                break scan
            case .head:
                guard let end = Self.endOfHead(buffer, from: start) else {
                    if buffer.count - start > maximumHead {
                        items.append(.oversize(length: 0))
                        phase = .dead
                    }
                    break scan
                }
                items.append(.head(Array(buffer[start..<end])))
                start = end
                phase = .frames
            case .frames:
                guard buffer.count - start >= CtrlWire.headerSize else { break scan }
                let length = buffer.be32(at: start)!
                if Int(length) > maximumPayload {
                    items.append(.oversize(length: length))
                    phase = .dead
                    break scan
                }
                let end = start + CtrlWire.headerSize + Int(length)
                guard buffer.count >= end else { break scan }
                let type = UInt16(buffer[start + 4]) << 8 | UInt16(buffer[start + 5])
                items.append(.frame(type: type, payload: Array(buffer[start + CtrlWire.headerSize..<end])))
                start = end
            }
        }
        buffer.removeFirst(start)
        if phase == .dead { buffer = [] }
        return items
    }

    /// Index just after the first `\r\n\r\n` at or after `start`.
    private static func endOfHead(_ bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count - start >= 4 else { return nil }
        for i in start...(bytes.count - 4)
        where bytes[i] == 0x0d && bytes[i + 1] == 0x0a && bytes[i + 2] == 0x0d && bytes[i + 3] == 0x0a {
            return i + 4
        }
        return nil
    }

    /// The item as the framer hands it to the connection: kind, big-endian type, payload.
    /// Kind 0 head, 1 frame, 2 oversize (payload: the length).
    static func encode(_ item: Item) -> [UInt8] {
        switch item {
        case .head(let bytes): return [0, 0, 0] + bytes
        case .frame(let type, let payload): return [1, UInt8(type >> 8), UInt8(type & 0xff)] + payload
        case .oversize(let length):
            var out: [UInt8] = [2, 0, 0]
            out.appendBE32(length)
            return out
        }
    }

    static func decode(_ bytes: [UInt8]) -> Item? {
        guard bytes.count >= 3 else { return nil }
        switch bytes[0] {
        case 0: return .head(Array(bytes[3...]))
        case 1: return .frame(type: UInt16(bytes[1]) << 8 | UInt16(bytes[2]), payload: Array(bytes[3...]))
        case 2: return bytes.be32(at: 3).map { .oversize(length: $0) }
        default: return nil
        }
    }
}
