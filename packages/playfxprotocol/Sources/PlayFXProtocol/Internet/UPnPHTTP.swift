import Foundation

// The blocking HTTP/1.x exchange UPnP needs (the gateway's description and its SOAP actions), behind a seam so tests
// can talk to a listener on loopback. What a gateway sends is untrusted: sizes and numbers are bounded here.

/// One HTTP request and its whole response, over TCP.
public protocol UPnPHTTPClient: Sendable {
    /// Sends `request` to `host:port` and returns the response bytes (header and body, complete), or throws.
    /// `host` is always a literal IPv4 address.
    func exchange(host: String, port: UInt16, request: [UInt8], timeout: Double) throws -> [UInt8]
}

/// A parsed HTTP response.
struct UPnPHTTPResponse: Equatable {
    /// The most a response may hold (header and body): 256 KiB.
    static let maxSize = 256 * 1024

    var status: Int
    /// Header fields keyed by lower-cased name.
    var headers: [String: String]
    var body: [UInt8]

    /// What `parse` found in the bytes so far.
    enum Outcome: Equatable {
        case incomplete
        /// Not HTTP/1.x, a bad or oversized length, or a malformed chunk: stop reading.
        case invalid
        case complete(UPnPHTTPResponse)

        var response: UPnPHTTPResponse? {
            if case .complete(let response) = self { return response }
            return nil
        }
    }

    /// The response in `bytes` once it is complete: the header, then `Content-Length` bytes, or the chunks of a
    /// chunked body, or (with `connectionClosed`) whatever came before the close.
    static func parse(_ bytes: [UInt8], connectionClosed: Bool) -> Outcome {
        guard bytes.count <= maxSize else { return .invalid }
        guard let end = bytes.firstRange(of: [0x0d, 0x0a, 0x0d, 0x0a]) else {
            return bytes.count > 16 * 1024 ? .invalid : .incomplete
        }
        let head = String(decoding: bytes[0..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ")
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."), let status = Int(statusLine[1]) else {
            return .invalid
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let start = end.upperBound
        func response(_ body: ArraySlice<UInt8>) -> Outcome {
            .complete(UPnPHTTPResponse(status: status, headers: headers, body: Array(body)))
        }
        if headers["transfer-encoding"]?.lowercased() == "chunked" {
            switch unchunk(bytes, from: start) {
            case .success(let body?): return response(body[...])
            case .success(nil): return connectionClosed ? .invalid : .incomplete
            case .failure: return .invalid
            }
        }
        if let text = headers["content-length"] {
            // Digits only (no sign), small enough that the number can't overflow or exceed the cap.
            guard !text.isEmpty, text.utf8.count <= 7, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let length = Int(text), length <= maxSize else { return .invalid }
            if bytes.count - start >= length { return response(bytes[start..<(start + length)]) }
            return connectionClosed ? response(bytes[start...]) : .incomplete
        }
        return connectionClosed ? response(bytes[start...]) : .incomplete
    }

    private struct BadChunk: Error {}

    /// The body of a chunked transfer from `start`: nil until the last chunk is in; an error for a malformed size.
    private static func unchunk(_ bytes: [UInt8], from start: Int) -> Result<[UInt8]?, BadChunk> {
        var body: [UInt8] = []
        var offset = start
        while true {
            // The size line is short: look for its CRLF in a small window only.
            let window = bytes[offset..<min(bytes.count, offset + 24)]
            guard let lineEnd = window.firstRange(of: [0x0d, 0x0a]) else {
                return window.count >= 24 ? .failure(BadChunk()) : .success(nil)
            }
            let digits = window[offset..<lineEnd.lowerBound].prefix { $0 != UInt8(ascii: ";") }
            let text = String(decoding: digits, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.utf8.count <= 6, text.utf8.allSatisfy({ hexNibble($0) != nil }),
                  let size = Int(text, radix: 16) else { return .failure(BadChunk()) }
            let dataStart = lineEnd.upperBound
            if size == 0 { return .success(body) }
            guard body.count + size <= maxSize else { return .failure(BadChunk()) }
            // size <= bytes.count - dataStart - 2, written so that nothing can overflow.
            guard size <= bytes.count - dataStart - 2 else { return .success(nil) }
            body += bytes[dataStart..<(dataStart + size)]
            offset = dataStart + size + 2
        }
    }
}

extension Array where Element == UInt8 {
    func firstRange(of needle: [UInt8]) -> Range<Int>? { self[...].firstRange(of: needle) }
}

extension ArraySlice where Element == UInt8 {
    func firstRange(of needle: [UInt8]) -> Range<Int>? {
        guard !needle.isEmpty, count >= needle.count else { return nil }
        for i in startIndex...(endIndex - needle.count) where self[i] == needle[0] {
            if self[i..<(i + needle.count)].elementsEqual(needle) { return i..<(i + needle.count) }
        }
        return nil
    }
}

/// `UPnPHTTPClient` over `NWConnection` (TCP), reading until the response is complete or the peer closes. A response
/// over 256 KiB, or a malformed one, is an error.
public struct TCPHTTPClient: UPnPHTTPClient {
    public init() {}

    public func exchange(host: String, port: UInt16, request: [UInt8], timeout: Double) throws -> [UInt8] {
        let deadline = monotonicSeconds() + timeout
        let connection = try NWBlockingTCPConnection(host: host, port: port)
        defer { connection.close() }
        try connection.connect(timeout: timeout)
        try connection.send(request, timeout: max(0.1, deadline - monotonicSeconds()))
        var received: [UInt8] = []
        while true {
            let remaining = deadline - monotonicSeconds()
            if remaining <= 0 { throw FailureKind.timeout }
            let chunk = try connection.receive(maximum: 16384, timeout: remaining)
            received += chunk
            switch UPnPHTTPResponse.parse(received, connectionClosed: chunk.isEmpty) {
            case .complete: return received
            case .invalid: throw FailureKind.invalidResponse
            case .incomplete: if chunk.isEmpty { throw FailureKind.invalidResponse }
            }
        }
    }
}
