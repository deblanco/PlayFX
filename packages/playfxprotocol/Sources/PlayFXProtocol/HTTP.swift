/// The minimal HTTP/1.1 pieces registration needs (registration.md sections 3.1 and 4.1).
enum MiniHTTP {
    static let crlf: [UInt8] = [0x0d, 0x0a]
    private static let terminator: [UInt8] = [0x0d, 0x0a, 0x0d, 0x0a]

    /// The request header, byte for byte as the spec has it: note the second line, a space then `HTTP/1.1`,
    /// the upper-case `HOST`, and the fixed LAN placeholder host. `rpVersion` is nil for PS4-8.
    static func registrationHeader(
        path: String, contentLength: Int, rpVersion: String?, host: String = "10.0.2.15"
    ) -> [UInt8] {
        var text = "POST \(path) HTTP/1.1\r\n"
        text += " HTTP/1.1\r\n"
        text += "HOST: \(host)\r\n"
        text += "User-Agent: remoteplay Windows\r\n"
        text += "Connection: close\r\n"
        text += "Content-Length: \(contentLength)\r\n"
        if let rpVersion { text += "RP-Version: \(rpVersion)\r\n" }
        text += "\r\n"
        return Array(text.utf8)
    }

    /// A parsed response header.
    struct ResponseHead: Equatable {
        var status: Int
        /// Header fields keyed by lower-cased name, values without the spaces and tabs around them.
        var headers: [String: String]
        /// Bytes of the header including the empty line.
        var length: Int

        /// `Content-Length` as a number, if present and decimal.
        var contentLength: Int? { headers["content-length"].flatMap { Int($0) } }

        /// `RP-Application-Reason` as a number (hex, with or without `0x`), if present.
        var applicationReason: UInt32? {
            guard var text = headers["rp-application-reason"] else { return nil }
            if text.hasPrefix("0x") || text.hasPrefix("0X") { text.removeFirst(2) }
            return UInt32(text, radix: 16)
        }
    }

    /// Result of looking for a complete header in the bytes received so far.
    enum HeadResult: Equatable {
        case needMore
        case head(ResponseHead)
        /// The bytes do not start like an HTTP/1.1 response.
        case invalid
    }

    /// Parses the header out of `bytes` once `\r\n\r\n` has arrived.
    static func parseHead(_ bytes: [UInt8]) -> HeadResult {
        let prefix = Array("HTTP/1.1 ".utf8)
        let check = min(bytes.count, prefix.count)
        guard bytes[0..<check].elementsEqual(prefix[0..<check]) else { return .invalid }
        guard let end = find(terminator, in: bytes) else { return .needMore }
        let lines = bytes[0..<end].split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { $0.last == UInt8(ascii: "\r") ? $0.dropLast() : $0 }
        let digits = lines[0].dropFirst(prefix.count).prefix { $0 != UInt8(ascii: " ") }
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let status = Int(String(decoding: digits, as: UTF8.self)) else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: UInt8(ascii: ":")) else { continue }
            // Spaces and tabs around a value are not part of it: a PS5 sends `Content-Length:        195`.
            headers[String(decoding: line[..<colon], as: UTF8.self).lowercased()] = trimmed(line[(colon + 1)...])
        }
        return .head(ResponseHead(status: status, headers: headers, length: end + terminator.count))
    }

    /// `value` as text without leading or trailing spaces and tabs.
    static func trimmed(_ value: ArraySlice<UInt8>) -> String {
        let isSpace = { (b: UInt8) in b == 0x20 || b == 0x09 }
        guard let first = value.firstIndex(where: { !isSpace($0) }),
              let last = value.lastIndex(where: { !isSpace($0) }) else { return "" }
        return String(decoding: value[first...last], as: UTF8.self)
    }

    private static func find(_ needle: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= needle.count else { return nil }
        for i in 0...(bytes.count - needle.count) where bytes[i] == needle[0] {
            if bytes[i..<i + needle.count].elementsEqual(needle) { return i }
        }
        return nil
    }

    /// Parses `Name: value` lines (CRLF or LF; an unterminated last line counts) into a dictionary.
    static func parseFields(_ bytes: [UInt8]) -> [String: String] {
        var fields: [String: String] = [:]
        for var line in bytes.split(separator: UInt8(ascii: "\n")) {
            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
            guard let colon = line.firstIndex(of: UInt8(ascii: ":")) else { continue }
            fields[String(decoding: line[..<colon], as: UTF8.self)] = trimmed(line[(colon + 1)...])
        }
        return fields
    }
}
