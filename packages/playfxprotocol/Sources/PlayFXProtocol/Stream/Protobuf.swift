/// A hand-written proto2 wire-format writer and reader (stream.md section 3.1). Only what the stream
/// messages need: varint, length-delimited, fixed32 and fixed64. Nothing here traps on any input.

/// Why a protobuf payload could not be read.
public enum ProtobufError: Error, Sendable, Equatable {
    /// The bytes ended inside a tag, varint, fixed value or length-delimited field.
    case truncated
    /// A varint longer than 10 bytes.
    case malformedVarint
    /// A length-delimited field claims more bytes than remain.
    case lengthPastEnd
    /// A wire type this reader does not know (6 and 7), or an unmatched end-group.
    case badWireType
    /// Field number 0, or one that does not fit in 29 bits.
    case badFieldNumber
    /// Groups nested deeper than `ProtobufReader.maximumGroupDepth`.
    case tooDeep
    /// A required field is absent (the name is this spec's field name).
    case missingField(String)
    /// A value does not fit its declared type, or a fixed-size field has the wrong size.
    case badValue(String)
}

/// One field read off the wire.
public struct ProtobufField: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes([UInt8])
        case fixed32(UInt32)
    }

    public var number: Int
    public var value: Value

    /// The varint, if this is one.
    public var varint: UInt64? { if case .varint(let v) = value { v } else { nil } }
    /// The length-delimited bytes, if this is a length-delimited field.
    public var bytes: [UInt8]? { if case .bytes(let b) = value { b } else { nil } }
}

/// Appends protobuf fields to a byte array. Senders write fields in ascending order and write every required
/// field (stream.md section 3.1); that is the caller's job, this type only encodes.
public struct ProtobufWriter: Sendable {
    public private(set) var encoded: [UInt8] = []

    public init() {}

    public mutating func appendVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            encoded.append(UInt8(truncatingIfNeeded: v) | 0x80)
            v >>= 7
        }
        encoded.append(UInt8(v))
    }

    private mutating func tag(_ field: Int, _ wireType: UInt64) {
        appendVarint(UInt64(field) << 3 | wireType)
    }

    public mutating func varint(_ field: Int, _ value: UInt64) {
        tag(field, 0)
        appendVarint(value)
    }

    public mutating func bool(_ field: Int, _ value: Bool) { varint(field, value ? 1 : 0) }

    /// An `int32` (negative values take 10 bytes, sign-extended to 64 bits, as protobuf requires).
    public mutating func int32(_ field: Int, _ value: Int32) { varint(field, UInt64(bitPattern: Int64(value))) }

    public mutating func bytes(_ field: Int, _ value: [UInt8]) {
        tag(field, 2)
        appendVarint(UInt64(value.count))
        encoded.append(contentsOf: value)
    }

    public mutating func string(_ field: Int, _ value: String) { bytes(field, Array(value.utf8)) }

    public mutating func fixed32(_ field: Int, _ value: UInt32) {
        tag(field, 5)
        for i in 0..<4 { encoded.append(UInt8(truncatingIfNeeded: value >> UInt32(8 * i))) }
    }

    public mutating func fixed64(_ field: Int, _ value: UInt64) {
        tag(field, 1)
        for i in 0..<8 { encoded.append(UInt8(truncatingIfNeeded: value >> UInt64(8 * i))) }
    }

    public mutating func float(_ field: Int, _ value: Float) { fixed32(field, value.bitPattern) }
    public mutating func double(_ field: Int, _ value: Double) { fixed64(field, value.bitPattern) }

    /// A nested message as a length-delimited field.
    public mutating func message(_ field: Int, _ value: ProtobufWriter) { bytes(field, value.encoded) }
}

/// Reads fields one at a time, in wire order. Unknown fields are returned like any other (the caller ignores
/// the numbers it doesn't know); groups, which proto2 allows and nothing here uses, are skipped whole.
public struct ProtobufReader: Sendable {
    /// Nesting limit when skipping deprecated groups.
    public static let maximumGroupDepth = 16

    private let data: [UInt8]
    private var position = 0

    public init(_ data: [UInt8]) { self.data = data }

    public var isAtEnd: Bool { position >= data.count }

    /// The next field, or nil at the end of the input.
    public mutating func next() throws -> ProtobufField? {
        while true {
            if isAtEnd { return nil }
            let key = try readVarint()
            let number = key >> 3
            guard number >= 1, number <= 0x1fff_ffff else { throw ProtobufError.badFieldNumber }
            let field = Int(number)
            switch key & 7 {
            case 0: return ProtobufField(number: field, value: .varint(try readVarint()))
            case 1: return ProtobufField(number: field, value: .fixed64(try readFixed(8)))
            case 2:
                let length = try readVarint()
                guard length <= UInt64(data.count - position) else { throw ProtobufError.lengthPastEnd }
                let end = position + Int(length)
                defer { position = end }
                return ProtobufField(number: field, value: .bytes(Array(data[position..<end])))
            case 5: return ProtobufField(number: field, value: .fixed32(UInt32(truncatingIfNeeded: try readFixed(4))))
            case 3: try skipGroup(depth: 1)
            default: throw ProtobufError.badWireType
            }
        }
    }

    /// Every field, in order.
    public static func fields(of data: [UInt8]) throws -> [ProtobufField] {
        var reader = ProtobufReader(data)
        var out: [ProtobufField] = []
        while let field = try reader.next() { out.append(field) }
        return out
    }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        for i in 0..<10 {
            guard position < data.count else { throw ProtobufError.truncated }
            let byte = data[position]
            position += 1
            result |= UInt64(byte & 0x7f) << UInt64(7 * i)
            if byte & 0x80 == 0 { return result }
        }
        throw ProtobufError.malformedVarint
    }

    private mutating func readFixed(_ count: Int) throws -> UInt64 {
        guard count <= data.count - position else { throw ProtobufError.truncated }
        var value: UInt64 = 0
        for i in 0..<count { value |= UInt64(data[position + i]) << UInt64(8 * i) }
        position += count
        return value
    }

    /// Skips the body of a group whose start tag was just read, up to its matching end tag.
    private mutating func skipGroup(depth: Int) throws {
        guard depth <= Self.maximumGroupDepth else { throw ProtobufError.tooDeep }
        while true {
            guard !isAtEnd else { throw ProtobufError.truncated }
            let key = try readVarint()
            guard key >> 3 >= 1 else { throw ProtobufError.badFieldNumber }
            switch key & 7 {
            case 0: _ = try readVarint()
            case 1: _ = try readFixed(8)
            case 2:
                let length = try readVarint()
                guard length <= UInt64(data.count - position) else { throw ProtobufError.lengthPastEnd }
                position += Int(length)
            case 5: _ = try readFixed(4)
            case 3: try skipGroup(depth: depth + 1)
            case 4: return
            default: throw ProtobufError.badWireType
            }
        }
    }
}

/// Helpers for reading messages field by field.
extension Array where Element == ProtobufField {
    /// The last occurrence of a field (protobuf: the last value wins for a singular field).
    func last(_ number: Int) -> ProtobufField? { last { $0.number == number } }

    func requiredVarint(_ number: Int, _ name: String) throws -> UInt64 {
        guard let field = last(number), let v = field.varint else { throw ProtobufError.missingField(name) }
        return v
    }

    func requiredBytes(_ number: Int, _ name: String) throws -> [UInt8] {
        guard let field = last(number), let b = field.bytes else { throw ProtobufError.missingField(name) }
        return b
    }

    func optionalVarint(_ number: Int) -> UInt64? { last(number)?.varint }
    func optionalBytes(_ number: Int) -> [UInt8]? { last(number)?.bytes }

    func requiredUInt32(_ number: Int, _ name: String) throws -> UInt32 {
        let v = try requiredVarint(number, name)
        // protobuf truncates an oversized varint into uint32; so do we.
        return UInt32(truncatingIfNeeded: v)
    }

    func optionalUInt32(_ number: Int) -> UInt32? { optionalVarint(number).map { UInt32(truncatingIfNeeded: $0) } }

    func requiredBool(_ number: Int, _ name: String) throws -> Bool { try requiredVarint(number, name) != 0 }
    func optionalBool(_ number: Int) -> Bool? { optionalVarint(number).map { $0 != 0 } }

    func requiredString(_ number: Int, _ name: String) throws -> String {
        String(decoding: try requiredBytes(number, name), as: UTF8.self)
    }

    func optionalString(_ number: Int) -> String? { optionalBytes(number).map { String(decoding: $0, as: UTF8.self) } }

    /// All length-delimited values of a repeated field, in order.
    func allBytes(_ number: Int) -> [[UInt8]] { compactMap { $0.number == number ? $0.bytes : nil } }
    /// All varint values of a repeated field, in order.
    func allVarints(_ number: Int) -> [UInt64] { compactMap { $0.number == number ? $0.varint : nil } }
}
