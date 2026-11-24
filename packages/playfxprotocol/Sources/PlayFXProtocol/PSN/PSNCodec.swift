import Foundation

/// Hand-written JSON for the PSN bodies: the key order and the absence of spaces are part of the spec
/// (psn.md section 6.3, vectors P1 to P9), so requests are built as text and only answers go through
/// `JSONSerialization`.
enum PSNJSON {
    /// A JSON string literal, quotes included. `/` is not escaped.
    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += "\\u" + String(repeating: "0", count: 4 - String(scalar.value, radix: 16).count)
                        + String(scalar.value, radix: 16)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// The top-level object of a JSON document, or nil.
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// An integral JSON number as `Int` (booleans and fractions are nil).
    static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(number.stringValue)
    }

    /// An unsigned 64-bit value from a JSON string of digits or a JSON number.
    static func uint64(_ value: Any?) -> UInt64? {
        if let text = value as? String { return UInt64(text) }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return UInt64(number.stringValue)
    }

    static func base64(_ bytes: [UInt8]) -> String { Data(bytes).base64EncodedString() }
}

extension PSNNotification {
    /// Decodes one WebSocket frame. Nil for frames that aren't a JSON object and for `dataType` values the
    /// client doesn't use (psn.md section 5.4).
    public static func decode(frame: Data) -> PSNNotification? {
        guard let root = PSNJSON.object(frame), let type = root["dataType"] as? String else { return nil }
        let body = (root["body"] as? [String: Any])?["data"] as? [String: Any]
        switch type {
        case "psn:sessionManager:sys:remotePlaySession:created":
            return .sessionCreated(onlineID: (root["to"] as? [String: Any])?["onlineId"] as? String)
        case "psn:sessionManager:sys:rps:members:created":
            let first = (body?["members"] as? [Any])?.first as? [String: Any]
            return .memberJoined(deviceUniqueID: first?["deviceUniqueId"] as? String)
        case "psn:sessionManager:sys:rps:customData1:updated":
            return .customDataUpdated(customData1: body?["customData1"] as? String)
        case "psn:sessionManager:sys:rps:sessionMessage:created":
            return .sessionMessage(payload: (body?["sessionMessage"] as? [String: Any])?["payload"] as? String)
        case "psn:sessionManager:sys:rps:members:deleted":
            return .memberLeft
        case "psn:sessionManager:sys:remotePlaySession:deleted":
            return .sessionDeleted(sessionID: body?["sessionId"] as? String)
        default:
            return nil
        }
    }
}

/// `customData1` (psn.md section 6.5, rpcrypt.md section 7's `CD`).
public enum PSNCustomData {
    /// Decodes the 32-character notification value: base64 of 24 ASCII characters, which are base64 of the
    /// 16-byte value. Up to 4 extra bytes after the 16 are ignored; fewer than 16 fail.
    public static func decode(_ text: String) throws -> [UInt8] {
        guard let outer = Data(base64Encoded: text), let inner = String(data: outer, encoding: .ascii),
            let raw = Data(base64Encoded: inner), raw.count >= 16, raw.count <= 20
        else { throw PSNError.invalidCustomData }
        return Array(raw.prefix(16))
    }
}

extension PSNMessage {
    /// The message JSON of psn.md section 7.2 and 7.3, in the reference's key order.
    public func json() -> String {
        var out = "{\"action\":\(PSNJSON.quote(action.rawValue)),\"reqId\":\(reqID),\"error\":\(error),\"connRequest\":"
        if let request = connRequest {
            out += request.json()
        } else {
            out += "{}"
        }
        return out + "}"
    }

    /// The `payload` text of a session message: `ver=1.0, type=text, body=<json>` (psn.md section 7.1).
    public func payload() -> String { "ver=1.0, type=text, body=" + json() }

    /// Parses a received `payload` (psn.md section 7.5): everything after the first `body=`, with a missing
    /// `localPeerAddr` value repaired, then the required fields checked. A `TERMINATE`'s `connRequest` is not
    /// inspected.
    public static func decode(payload: String) throws -> PSNMessage {
        guard let marker = payload.range(of: "body=") else { throw PSNError.invalidMessage(reason: "no body=") }
        let text = repairLocalPeerAddr(String(payload[marker.upperBound...]))
        guard let root = PSNJSON.object(Data(text.utf8)) else { throw PSNError.invalidMessage(reason: "not JSON") }
        guard let actionText = root["action"] as? String else { throw PSNError.invalidMessage(reason: "action") }
        guard let action = PSNMessageAction(rawValue: actionText) else {
            throw PSNError.invalidMessage(reason: "unknown action \(actionText)")
        }
        guard let reqID = PSNJSON.int(root["reqId"]) else { throw PSNError.invalidMessage(reason: "reqId") }
        guard let error = PSNJSON.int(root["error"]) else { throw PSNError.invalidMessage(reason: "error") }
        // A TERMINATE needs nothing but its action: it is read even without a connRequest.
        if action == .terminate { return PSNMessage(action: action, reqID: reqID, error: error, connRequest: nil) }
        guard let request = root["connRequest"] as? [String: Any] else {
            throw PSNError.invalidMessage(reason: "connRequest")
        }
        if request.isEmpty {
            return PSNMessage(action: action, reqID: reqID, error: error, connRequest: nil)
        }
        return PSNMessage(action: action, reqID: reqID, error: error, connRequest: try PSNConnRequest(json: request))
    }

    /// Inserts `{}` where `"localPeerAddr":` is followed directly by `,` or `}` (the console's invalid JSON).
    static func repairLocalPeerAddr(_ text: String) -> String {
        let key = "\"localPeerAddr\":"
        var out = ""
        var rest = Substring(text)
        while let found = rest.range(of: key) {
            out += rest[..<found.upperBound]
            rest = rest[found.upperBound...]
            if let next = rest.drop(while: { $0 == " " }).first, next == "," || next == "}" { out += "{}" }
        }
        return out + rest
    }
}

extension PSNConnRequest {
    /// The `connRequest` object in the reference's key order (psn.md section 7.3).
    func json() -> String {
        let peer = localPeerAddress.map {
            "{\"accountId\":\(PSNJSON.quote($0.accountID)),\"platform\":\(PSNJSON.quote($0.platform))}"
        }
        return "{\"sid\":\(sid),\"peerSid\":\(peerSid),\"skey\":\(PSNJSON.quote(PSNJSON.base64(skey))),"
            + "\"natType\":\(natType),\"candidate\":[\(candidates.map { $0.json() }.joined(separator: ","))],"
            + "\"defaultRouteMacAddr\":\(PSNJSON.quote(defaultRouteMACAddress)),\"localPeerAddr\":\(peer ?? "{}"),"
            + "\"localHashedId\":\(PSNJSON.quote(localHashedID.isEmpty ? "" : PSNJSON.base64(localHashedID)))}"
    }

    init(json: [String: Any]) throws {
        func fail(_ key: String) -> PSNError { PSNError.invalidMessage(reason: "connRequest.\(key)") }
        guard let sid = PSNJSON.int(json["sid"]) else { throw fail("sid") }
        guard let peerSid = PSNJSON.int(json["peerSid"]) else { throw fail("peerSid") }
        guard let skeyText = json["skey"] as? String, let skey = Data(base64Encoded: skeyText) else {
            throw fail("skey")
        }
        guard let natType = PSNJSON.int(json["natType"]) else { throw fail("natType") }
        guard let list = json["candidate"] as? [Any] else { throw fail("candidate") }
        guard let mac = json["defaultRouteMacAddr"] as? String else { throw fail("defaultRouteMacAddr") }
        guard let hashedText = json["localHashedId"] as? String, let hashed = Data(base64Encoded: hashedText) else {
            throw fail("localHashedId")
        }
        var peer: PSNPeerAddress?
        if let object = json["localPeerAddr"] as? [String: Any], let account = object["accountId"] as? String,
            let platform = object["platform"] as? String
        {
            peer = PSNPeerAddress(accountID: account, platform: platform)
        }
        self.init(
            sid: sid, peerSid: peerSid, skey: [UInt8](skey), natType: natType,
            candidates: try list.map { try PSNCandidate(json: $0) }, defaultRouteMACAddress: mac,
            localPeerAddress: peer, localHashedID: [UInt8](hashed))
    }
}

extension PSNCandidate {
    /// The candidate object (psn.md section 7.4).
    func json() -> String {
        "{\"type\":\(PSNJSON.quote(type.rawValue)),\"addr\":\(PSNJSON.quote(address)),"
            + "\"mappedAddr\":\(PSNJSON.quote(mappedAddress)),\"port\":\(port),\"mappedPort\":\(mappedPort)}"
    }

    /// Reads a received candidate: all five keys are required; an unknown `type` is read as `STATIC`.
    init(json value: Any) throws {
        func fail(_ key: String) -> PSNError { PSNError.invalidMessage(reason: "candidate.\(key)") }
        guard let json = value as? [String: Any] else { throw fail("object") }
        guard let typeText = json["type"] as? String else { throw fail("type") }
        guard let address = json["addr"] as? String else { throw fail("addr") }
        guard let mapped = json["mappedAddr"] as? String else { throw fail("mappedAddr") }
        guard let port = PSNJSON.int(json["port"]).flatMap({ UInt16(exactly: $0) }) else { throw fail("port") }
        guard let mappedPort = PSNJSON.int(json["mappedPort"]).flatMap({ UInt16(exactly: $0) }) else {
            throw fail("mappedPort")
        }
        self.init(
            type: PSNCandidateType(rawValue: typeText) ?? .staticAddress, address: address, mappedAddress: mapped,
            port: port, mappedPort: mappedPort)
    }
}
