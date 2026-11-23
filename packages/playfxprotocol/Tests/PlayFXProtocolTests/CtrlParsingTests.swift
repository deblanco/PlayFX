import Foundation
import Testing

@testable import PlayFXProtocol

@Suite struct CtrlParsingTests {
    static let head = Array("HTTP/1.1 200 OK\r\nContent-Length:        0\r\n\r\n".utf8)

    @Test func bytesAfterTheHeaderStartTheFrameStream() {
        var splitter = CtrlStreamSplitter()
        let items = splitter.feed(Self.head + hex("00000000 00fe 0000 00000002 0099 0000 abcd 0000"))
        #expect(items == [.head(Self.head), .frame(type: 0xfe, payload: []), .frame(type: 0x99, payload: [0xab, 0xcd])])
        // The 2 bytes left over are the start of the next header.
        #expect(splitter.feed(hex("0000 00fe 0000")) == [.frame(type: 0xfe, payload: [])])
    }

    @Test func oneByteAtATimeGivesTheSameItems() {
        let stream = Self.head + CtrlWire.frame(type: 0x33, payload: [1, 2, 3]) + CtrlWire.frame(type: 0xfe, payload: [])
        var whole = CtrlStreamSplitter()
        var split = CtrlStreamSplitter()
        var items: [CtrlStreamSplitter.Item] = []
        for byte in stream { items += split.feed([byte]) }
        #expect(items == whole.feed(stream))
        #expect(items.count == 3)
    }

    @Test func framesLargerThan512Bytes() {
        var splitter = CtrlStreamSplitter()
        let payload = (0..<5000).map { UInt8(truncatingIfNeeded: $0) }
        let items = splitter.feed(Self.head + CtrlWire.frame(type: 0x24, payload: payload))
        #expect(items.last == .frame(type: 0x24, payload: payload))
    }

    @Test func oversizeFrameStopsTheStream() {
        var splitter = CtrlStreamSplitter(maximumPayload: 100)
        let items = splitter.feed(Self.head + hex("00000065 0033 0000") + [UInt8](repeating: 0, count: 10))
        #expect(items == [.head(Self.head), .oversize(length: 101)])
        #expect(splitter.feed(CtrlWire.frame(type: 1, payload: [])).isEmpty)
        // Exactly at the limit is fine.
        var edge = CtrlStreamSplitter(maximumPayload: 4)
        #expect(edge.feed(Self.head + CtrlWire.frame(type: 1, payload: [1, 2, 3, 4])).count == 2)
    }

    @Test func endlessHeaderStopsTheStream() {
        var splitter = CtrlStreamSplitter(maximumHead: 64)
        #expect(splitter.feed([UInt8](repeating: 0x41, count: 64)).isEmpty)
        #expect(splitter.feed([0x41]) == [.oversize(length: 0)])
    }

    @Test func itemEncodingRoundTrips() {
        let items: [CtrlStreamSplitter.Item] = [
            .head(Self.head), .frame(type: 0x8004, payload: [9]), .frame(type: 0xfe, payload: []), .oversize(length: 77),
        ]
        for item in items { #expect(CtrlStreamSplitter.decode(CtrlStreamSplitter.encode(item)) == item) }
        #expect(CtrlStreamSplitter.decode([]) == nil)
        #expect(CtrlStreamSplitter.decode([9, 0, 0]) == nil)
        #expect(CtrlStreamSplitter.decode([2, 0, 0, 1]) == nil)
    }

    // MARK: Decoding

    @Test func inboundMessages() {
        typealias I = CtrlInbound
        #expect(I.decode(type: 0x04, payload: []) == .loginPINRequest)
        #expect(I.decode(type: 0x05, payload: [0]) == .loginResult(accepted: true))
        #expect(I.decode(type: 0x05, payload: [1]) == .loginResult(accepted: false))
        #expect(I.decode(type: 0x05, payload: [2]) == .unknown(type: 5, payload: [2]))
        #expect(I.decode(type: 0x05, payload: []) == .unknown(type: 5, payload: []))
        #expect(I.decode(type: 0xfe, payload: []) == .heartbeatRequest)
        #expect(I.decode(type: 0x33, payload: [4]) == .sessionID(payload: [4]))
        #expect(I.decode(type: 0x01, payload: [1]) == .displayNoticeA(set: true))
        #expect(I.decode(type: 0x01, payload: [0, 7]) == .displayNoticeA(set: false))
        #expect(I.decode(type: 0x01, payload: [5]) == .unknown(type: 1, payload: [5]))
        #expect(I.decode(type: 0x01, payload: []) == .unknown(type: 1, payload: []))
        #expect(I.decode(type: 0x16, payload: [1, 0xff]) == .displayNoticeB(payload: [1, 0xff], clearsState: true))
        #expect(I.decode(type: 0x16, payload: [0, 0xff, 3]) == .displayNoticeB(payload: [0, 0xff, 3], clearsState: false))
        #expect(I.decode(type: 0x16, payload: [1]) == .unknown(type: 0x16, payload: [1]))
        #expect(I.decode(type: 0x22, payload: [9, 9]) == .keyboardClosedByConsole)
        #expect(I.decode(type: 0x34, payload: []) == .unknown(type: 0x34, payload: []))
        #expect(I.decode(type: 0x7777, payload: [1]) == .unknown(type: 0x7777, payload: [1]))
    }

    @Test func keyboardMessages() {
        var opened = [UInt8](repeating: 0xee, count: 28)
        opened.appendBE32(5)
        opened += Array("héllo".utf8.prefix(5))
        #expect(CtrlInbound.decode(type: 0x21, payload: opened) == .keyboardOpened(text: "héll"))
        // A length that runs past the payload, and a payload shorter than its fixed part.
        opened[31] = 99
        #expect(CtrlInbound.decode(type: 0x21, payload: opened) == .unknown(type: 0x21, payload: opened))
        #expect(CtrlInbound.decode(type: 0x21, payload: [1, 2]) == .unknown(type: 0x21, payload: [1, 2]))

        var changed: [UInt8] = []
        changed.appendBE32(7)
        changed.appendBE32(0)
        changed.appendBE32(3)
        changed += [UInt8](repeating: 0, count: 24)
        changed.appendBE32(3)
        changed += Array("abc".utf8)
        #expect(CtrlInbound.decode(type: 0x24, payload: changed) == .keyboardTextChanged(sequence: 7, text: "abc"))
        #expect(CtrlInbound.decode(type: 0x24, payload: Array(changed.dropLast())).isUnknown)
        #expect(CtrlInbound.decode(type: 0x24, payload: [0]).isUnknown)
    }

    @Test func sessionIDValidation() {
        let good = [0x4a] + Array(SessionVector.sessionIDText.utf8)
        #expect(CtrlInbound.parseSessionID(good)?.id == SessionVector.sessionIDText)
        #expect(CtrlInbound.parseSessionID([0x10] + good.dropFirst())?.lengthByteExpected == false)
        #expect(CtrlInbound.parseSessionID([0x4a] + Array(repeating: 0x41, count: 24)) != nil)
        #expect(CtrlInbound.parseSessionID([0x4a] + Array(repeating: 0x41, count: 23)) == nil)
        #expect(CtrlInbound.parseSessionID([0x4a] + Array(repeating: 0x41, count: 78)) != nil)
        #expect(CtrlInbound.parseSessionID([0x4a] + Array(repeating: 0x41, count: 79)) == nil)
        #expect(CtrlInbound.parseSessionID([0x4a] + Array(repeating: 0x2f, count: 30)) == nil)
        #expect(CtrlInbound.parseSessionID([]) == nil)
    }

    // MARK: Messages for the user

    @Test func userMessages() {
        for (ps5, name) in [(true, "PS5"), (false, "PS4")] {
            #expect(SessionError.consoleBusy.userMessage(ps5: ps5) == "The \(name) is already streaming to another "
                + "device. End that session, or wait a few seconds and try again.")
            #expect(SessionError.remotePlayCrashed.userMessage(ps5: ps5)
                == "Remote Play on the \(name) stopped working. Restart the \(name) and try again.")
            #expect(SessionError.versionMismatch.userMessage(ps5: ps5) == "The \(name)'s Remote Play version doesn't "
                + "match PlayFX's. Update the \(name)'s system software and PlayFX.")
            #expect(SessionError.noAnswer(.timeout).userMessage(ps5: ps5)
                == "The \(name) didn't answer. Check that it's on and on the same network as this Mac.")
            #expect(SessionError.network(.permissionDenied).userMessage(ps5: ps5) == "Couldn't reach the \(name). Allow "
                + "PlayFX in System Settings › Privacy & Security › Local Network, and turn off any VPN.")
            #expect(SessionError.refused(reason: 0x80108b09).userMessage(ps5: ps5)
                == "The \(name) refused the session (reason 0x80108b09).")
        }
        #expect(SessionError.refused(reason: 0xab).userMessage(ps5: true) == "The PS5 refused the session (reason 0x000000ab).")
        #expect(SessionError.refused(reason: nil).userMessage(ps5: true).contains("no reason"))
        #expect(SessionError.ctrlRejected(status: 403).userMessage(ps5: false).contains("403"))
        #expect(SessionError.cancelled.userMessage(ps5: true).isEmpty)
        for error in [SessionError.invalidResponse, .invalidInput, .cryptoFailure] {
            #expect(!error.userMessage(ps5: true).isEmpty)
        }
    }

    @Test func failureMapping() {
        #expect(SessionError.from(.timeout) == .noAnswer(.timeout))
        #expect(SessionError.from(.connectionRefused) == .noAnswer(.connectionRefused))
        #expect(SessionError.from(.cancelled) == .cancelled)
        #expect(SessionError.from(.invalidData) == .invalidResponse)
        #expect(SessionError.from(.invalidInput) == .invalidInput)
        #expect(SessionError.from(.httpNotOK(status: 500)) == .ctrlRejected(status: 500))
        #expect(SessionError.from(.hostDown) == .network(.hostDown))
    }

    @Test func publicValuesDoNotPrintSecrets() throws {
        let id = SessionID(value: SessionVector.sessionIDText)
        #expect(id.length == 74 && !"\(id)".contains("ABCDEF") && !"\(id.debugDescription)".contains("ABCDEF"))
        let handoff = StreamHandoff(
            consoleAddress: "192.0.2.10", negotiatedVersion: .ps5v1, crypt: try SessionVector.context(.ps5v1),
            sessionID: id, streamHandshakeKey: [1], consoleModel: .ps5, streamingType: .h264, dualSenseEnabled: true)
        #expect(!"\(handoff)".contains("598fa9") && !handoff.debugDescription.contains("ABCDEF"))
        #expect(handoff.streamPort == 9296 && handoff.probePort == 9297)
        #expect(ControlEndReason.frameTooLarge(length: 9).description.contains("9"))
        let reasons: [ControlEndReason] = [
            .stoppedByClient, .consoleClosed, .connectionLost(.timeout), .heartbeatTimeout, .startupTimeout,
            .loginPINAfterSessionID, .invalidSessionID, .protocolError,
        ]
        #expect(Set(reasons.map(\.description)).count == reasons.count)
    }
}

extension CtrlInbound {
    var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }
}
