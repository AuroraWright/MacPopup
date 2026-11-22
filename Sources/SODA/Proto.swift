import Foundation

/// Reads the fields of one serialized protobuf message: the packs keep their configuration in binary protos, of which
/// only a handful of fields are needed.
struct ProtoReader {
    enum WireType: Int { case varint = 0, fixed64 = 1, lengthDelimited = 2, fixed32 = 5 }

    private let data: [UInt8]
    private var position: Int
    private let end: Int
    private(set) var field = 0
    private(set) var wireType = WireType.varint
    private(set) var value: UInt64 = 0
    private var bytesRange = 0..<0
    /// False once the message turned out malformed (`next()` then returns false).
    private(set) var ok = true

    init(_ data: [UInt8]) {
        self.init(data, 0..<data.count)
    }

    init(_ data: [UInt8], _ range: Range<Int>) {
        (self.data, position, end) = (data, range.lowerBound, range.upperBound)
    }

    /// Moves to the next field; false at the end of the message or on malformed input.
    mutating func next() -> Bool {
        guard position < end else { return false }
        guard let tag = readVarint() else { return fail() }
        field = Int(tag >> 3)
        switch Int(tag & 7) {
        case 0:
            guard let v = readVarint() else { return fail() }
            (wireType, value) = (.varint, v)
        case 1:
            guard end - position >= 8 else { return fail() }
            value = (0..<8).reduce(0) { $0 | UInt64(data[position + $1]) << (8 * $1) }
            (wireType, position) = (.fixed64, position + 8)
        case 5:
            guard end - position >= 4 else { return fail() }
            value = (0..<4).reduce(0) { $0 | UInt64(data[position + $1]) << (8 * $1) }
            (wireType, position) = (.fixed32, position + 4)
        case 2:
            guard let length = readVarint(), length <= UInt64(end - position) else { return fail() }
            wireType = .lengthDelimited
            bytesRange = position..<position + Int(length)
            position += Int(length)
        default:
            return fail()
        }
        return true
    }

    var int: Int { Int(truncatingIfNeeded: value) }
    var bool: Bool { value != 0 }
    var float: Float { Float(bitPattern: UInt32(truncatingIfNeeded: value)) }
    var bytes: [UInt8] { Array(data[bytesRange]) }
    var string: String { String(decoding: data[bytesRange], as: UTF8.self) }
    /// The field's payload as a message of its own.
    var message: ProtoReader { ProtoReader(data, bytesRange) }

    /// A packed or single varint field.
    var ints: [Int] {
        if wireType == .varint { return [int] }
        guard wireType == .lengthDelimited else { return [] }
        var packed = message, values: [Int] = []
        while packed.position < packed.end, let v = packed.readVarint() { values.append(Int(truncatingIfNeeded: v)) }
        return values
    }

    /// A packed or single float field.
    var floats: [Float] {
        if wireType == .fixed32 { return [float] }
        guard wireType == .lengthDelimited else { return [] }
        return stride(from: bytesRange.lowerBound, to: bytesRange.upperBound - 3, by: 4).map { i in
            Float(bitPattern: UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24)
        }
    }

    private mutating func readVarint() -> UInt64? {
        var v: UInt64 = 0
        var shift: UInt64 = 0
        while shift < 64, position < end {
            let b = data[position]
            position += 1
            v |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return v }
            shift += 7
        }
        return nil
    }

    private mutating func fail() -> Bool {
        (ok, position) = (false, end)
        return false
    }

    /// The payload of extension (or field) `number`, the first one there is.
    func find(_ number: Int) -> ProtoReader? {
        var r = self
        while r.next() {
            if r.field == number && r.wireType == .lengthDelimited { return r.message }
        }
        return nil
    }

    /// The first string field `number`, or "".
    func firstString(_ number: Int) -> String {
        var r = self
        while r.next() {
            if r.field == number && r.wireType == .lengthDelimited { return r.string }
        }
        return ""
    }

    /// Calls `body` with each field.
    func forEach(_ body: (ProtoReader) -> Void) {
        var r = self
        while r.next() { body(r) }
    }
}

extension Optional where Wrapped == ProtoReader {
    /// Calls `body` with each field of the message, if there is one.
    func forEach(_ body: (ProtoReader) -> Void) {
        self?.forEach(body)
    }

    func firstString(_ number: Int) -> String {
        self?.firstString(number) ?? ""
    }

    func find(_ number: Int) -> ProtoReader? {
        self?.find(number)
    }
}

/// Protocol buffer wire format output.
struct ProtoWriter {
    private(set) var data: [UInt8] = []

    mutating func varint(_ field: Int, _ v: UInt64) {
        tag(field, 0)
        put(v)
    }

    mutating func bool(_ field: Int, _ v: Bool) { varint(field, v ? 1 : 0) }

    mutating func float(_ field: Int, _ v: Float) {
        tag(field, 5)
        withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func bytes(_ field: Int, _ v: [UInt8]) {
        tag(field, 2)
        put(UInt64(v.count))
        data += v
    }

    mutating func message(_ field: Int, _ m: ProtoWriter) { bytes(field, m.data) }

    private mutating func tag(_ field: Int, _ wireType: Int) { put(UInt64(field << 3 | wireType)) }

    private mutating func put(_ v: UInt64) {
        var v = v
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }
}
