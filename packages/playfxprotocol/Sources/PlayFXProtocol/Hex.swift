/// Decodes a compile-time hex literal (generated tables). Traps on malformed input: the literals are generated.
func decodeHexLiteral(_ literal: StaticString) -> [UInt8] {
    let count = literal.utf8CodeUnitCount
    precondition(count % 2 == 0, "odd hex literal")
    return literal.withUTF8Buffer { text in
        [UInt8](unsafeUninitializedCapacity: count / 2) { out, initialized in
            for i in 0..<count / 2 {
                out[i] = (hexNibble(text[2 * i])! << 4) | hexNibble(text[2 * i + 1])!
            }
            initialized = count / 2
        }
    }
}

/// Value of one ASCII hex digit (either case), or nil.
func hexNibble(_ c: UInt8) -> UInt8? {
    switch c {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
    default: return nil
    }
}

/// Decodes hex text (pairs of digits, either case); nil when odd-length or not hex.
func decodeHex<S: Sequence>(_ text: S) -> [UInt8]? where S.Element == UInt8 {
    var out: [UInt8] = []
    var high: UInt8?
    for c in text {
        guard let n = hexNibble(c) else { return nil }
        if let h = high {
            out.append((h << 4) | n)
            high = nil
        } else {
            high = n
        }
    }
    return high == nil ? out : nil
}

/// Lowercase hex text of the bytes.
func encodeHex(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var out = [UInt8]()
    out.reserveCapacity(bytes.count * 2)
    for b in bytes {
        out.append(digits[Int(b >> 4)])
        out.append(digits[Int(b & 15)])
    }
    return String(decoding: out, as: UTF8.self)
}
