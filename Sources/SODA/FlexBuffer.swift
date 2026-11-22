import Foundation

/// A value in a FlexBuffer (custom TFLite ops' options): enough to read maps of scalars and strings.
struct FlexValue {
    private let bytes: [UInt8]
    private let position: Int
    /// The width of the value itself, and its type and (for offset types) the width of what it points to.
    private let width: Int
    private let type: Int
    private let childWidth: Int

    private static let null = 0, int = 1, uint = 2, float = 3, key = 4, string = 5, indirectInt = 6
    private static let indirectUInt = 7, indirectFloat = 8, map = 9, bool = 26

    /// The root of a buffer: the last byte is the root's width, the one before its packed type.
    init?(root bytes: [UInt8]) {
        guard bytes.count >= 3 else { return nil }
        let width = Int(bytes[bytes.count - 1]), packed = Int(bytes[bytes.count - 2])
        self.init(bytes, bytes.count - 2 - width, width: width, packed: packed)
    }

    private init(_ bytes: [UInt8], _ position: Int, width: Int, packed: Int) {
        (self.bytes, self.position, self.width) = (bytes, position, width)
        (type, childWidth) = (packed >> 2, 1 << (packed & 3))
    }

    private func unsigned(_ at: Int, _ width: Int) -> UInt64 {
        (0..<width).reduce(UInt64(0)) { $0 | UInt64(bytes[at + $1]) << (8 * $1) }
    }

    private func signed(_ at: Int, _ width: Int) -> Int64 {
        let shift = UInt64(64 - 8 * width)
        return Int64(bitPattern: unsigned(at, width) << shift) >> Int64(shift)
    }

    /// Where an offset value points.
    private var target: Int { position - Int(unsigned(position, width)) }

    var isNull: Bool { type == Self.null }

    var asInt: Int {
        switch type {
        case Self.int: Int(signed(position, width))
        case Self.uint, Self.bool: Int(unsigned(position, width))
        case Self.indirectInt: Int(signed(target, childWidth))
        case Self.indirectUInt: Int(unsigned(target, childWidth))
        case Self.float, Self.indirectFloat: Int(asFloat)
        default: 0
        }
    }

    var asBool: Bool { asInt != 0 }

    var asFloat: Float {
        let at = type == Self.indirectFloat ? target : position
        let w = type == Self.indirectFloat ? childWidth : width
        switch type {
        case Self.float, Self.indirectFloat:
            return w == 8 ? Float(Double(bitPattern: unsigned(at, 8))) : Float(bitPattern: UInt32(unsigned(at, 4)))
        case Self.int, Self.uint, Self.bool, Self.indirectInt, Self.indirectUInt: return Float(asInt)
        default: return 0
        }
    }

    /// A string's (or key's) bytes.
    var asBytes: [UInt8] {
        switch type {
        case Self.string:
            let start = target
            let count = Int(unsigned(start - childWidth, childWidth))
            return Array(bytes[start..<start + count])
        case Self.key:
            let start = target
            var end = start
            while end < bytes.count && bytes[end] != 0 { end += 1 }
            return Array(bytes[start..<end])
        default: return []
        }
    }

    var asString: String { String(decoding: asBytes, as: UTF8.self) }

    /// A map's value for `name` (a null value if there's none).
    subscript(name: String) -> FlexValue {
        let missing = FlexValue(bytes, 0, width: 1, packed: 0)
        guard type == Self.map else { return missing }
        let start = target, w = childWidth
        let count = Int(unsigned(start - w, w))
        // The keys: a vector of key offsets, with its own byte width.
        let keysAt = start - 3 * w
        let keys = keysAt - Int(unsigned(keysAt, w))
        let keyWidth = Int(unsigned(start - 2 * w, w))
        let wanted = Array(name.utf8)
        for i in 0..<count {
            let k = keys + i * keyWidth
            var at = k - Int(unsigned(k, keyWidth))
            var key: [UInt8] = []
            while bytes[at] != 0 {
                key.append(bytes[at])
                at += 1
            }
            if key == wanted {
                return FlexValue(bytes, start + i * w, width: w, packed: Int(bytes[start + count * w + i]))
            }
        }
        return missing
    }
}
