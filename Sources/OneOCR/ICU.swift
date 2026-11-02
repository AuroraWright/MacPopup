import Foundation

/// The system ICU (libicucore), which oneocr uses for Thai word breaks and for reordering right-to-left text.
enum ICU {
    private typealias UBrkOpen = @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<UInt16>?, Int32,
                                                 UnsafeMutablePointer<Int32>) -> OpaquePointer?
    private typealias UBrkStep = @convention(c) (OpaquePointer?) -> Int32
    private typealias Close = @convention(c) (OpaquePointer?) -> Void
    private typealias UBlockGetCode = @convention(c) (Int32) -> Int32
    private typealias UBidiOpen = @convention(c) () -> OpaquePointer?
    private typealias UBidiSetMode = @convention(c) (OpaquePointer?, Int32) -> Void
    private typealias UBidiSetOptions = @convention(c) (OpaquePointer?, UInt32) -> Void
    private typealias UBidiSetPara = @convention(c) (OpaquePointer?, UnsafePointer<UInt16>?, Int32, UInt8,
                                                     UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<Int32>) -> Void
    private typealias UBidiWrite = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt16>?, Int32, UInt16,
                                                   UnsafeMutablePointer<Int32>) -> Int32
    private typealias UBidiResultLength = @convention(c) (OpaquePointer?, UnsafeMutablePointer<Int32>) -> Int32
    private typealias UBidiVisualMap = @convention(c) (OpaquePointer?, UnsafeMutablePointer<Int32>?,
                                                       UnsafeMutablePointer<Int32>) -> Void

    private struct Functions {
        let brkOpen: UBrkOpen, brkFirst: UBrkStep, brkNext: UBrkStep, brkClose: Close
        let blockCode: UBlockGetCode
        let bidiOpen: UBidiOpen, bidiSetMode: UBidiSetMode, bidiSetOptions: UBidiSetOptions, bidiSetPara: UBidiSetPara
        let bidiWrite: UBidiWrite, bidiResultLength: UBidiResultLength, bidiVisualMap: UBidiVisualMap, bidiClose: Close
    }

    private static let f: Functions? = {
        guard let h = dlopen("/usr/lib/libicucore.A.dylib", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _: T.Type) -> T? { dlsym(h, name).map { unsafeBitCast($0, to: T.self) } }
        guard let a = sym("ubrk_open", UBrkOpen.self), let b = sym("ubrk_first", UBrkStep.self),
              let c = sym("ubrk_next", UBrkStep.self), let d = sym("ubrk_close", Close.self),
              let e = sym("ublock_getCode", UBlockGetCode.self), let g = sym("ubidi_open", UBidiOpen.self),
              let i = sym("ubidi_setReorderingMode", UBidiSetMode.self),
              let j = sym("ubidi_setReorderingOptions", UBidiSetOptions.self),
              let k = sym("ubidi_setPara", UBidiSetPara.self), let l = sym("ubidi_writeReordered", UBidiWrite.self),
              let m = sym("ubidi_getResultLength", UBidiResultLength.self),
              let n = sym("ubidi_getVisualMap", UBidiVisualMap.self), let o = sym("ubidi_close", Close.self)
        else { return nil }
        return Functions(brkOpen: a, brkFirst: b, brkNext: c, brkClose: d, blockCode: e, bidiOpen: g, bidiSetMode: i,
                         bidiSetOptions: j, bidiSetPara: k, bidiWrite: l, bidiResultLength: m, bidiVisualMap: n, bidiClose: o)
    }()

    static var available: Bool { f != nil }

    static let blockThai: Int32 = 25

    /// UnicodeString::char32At.
    static func char32At(_ u: [UInt16], _ i: Int) -> Int32 {
        let c = u[i]
        if UTF16.isLeadSurrogate(c), i + 1 < u.count, UTF16.isTrailSurrogate(u[i + 1]) {
            return Int32(0x10000 + ((Int(c) - 0xD800) << 10) + (Int(u[i + 1]) - 0xDC00))
        }
        if UTF16.isTrailSurrogate(c), i > 0, UTF16.isLeadSurrogate(u[i - 1]) {
            return Int32(0x10000 + ((Int(u[i - 1]) - 0xD800) << 10) + (Int(c) - 0xDC00))
        }
        return Int32(c)
    }

    static func blockCode(_ cp: Int32) -> Int32 { f?.blockCode(cp) ?? 0 }

    /// The boundaries of a word BreakIterator for the locale, nil without ICU.
    static func wordBreaks(_ text: [UInt16], locale: String) -> [Int]? {
        guard let f else { return nil }
        var status: Int32 = 0
        return text.withUnsafeBufferPointer { buf -> [Int]? in
            guard let bi = f.brkOpen(1, locale, buf.baseAddress, Int32(buf.count), &status), status <= 0 else { return nil }
            defer { f.brkClose(bi) }
            var out: [Int] = []
            var b = f.brkFirst(bi)
            while b != -1 {
                out.append(Int(b))
                b = f.brkNext(bi)
            }
            return out
        }
    }

    /// ubidi with the reordering mode and paragraph level: writeReordered(options) and the visual map; nil on an ICU
    /// error or without ICU.
    static func reorder(_ text: [UInt16], mode: Int32, level: UInt8, options: UInt16) -> (text: [UInt16], map: [Int])? {
        guard let f, let bidi = f.bidiOpen() else { return nil }
        defer { f.bidiClose(bidi) }
        f.bidiSetMode(bidi, mode)
        f.bidiSetOptions(bidi, 0)
        var status: Int32 = 0
        return text.withUnsafeBufferPointer { buf -> ([UInt16], [Int])? in
            f.bidiSetPara(bidi, buf.baseAddress, Int32(buf.count), level, nil, &status)
            if status > 0 { return nil }
            var out = [UInt16](repeating: 0, count: 2 * buf.count + 16)
            let n = out.withUnsafeMutableBufferPointer { f.bidiWrite(bidi, $0.baseAddress, Int32($0.count), options, &status) }
            if status > 0 { return nil }
            let len = f.bidiResultLength(bidi, &status)
            if status > 0 { return nil }
            var map = [Int32](repeating: 0, count: max(Int(len), 1))
            map.withUnsafeMutableBufferPointer { f.bidiVisualMap(bidi, $0.baseAddress, &status) }
            if status > 0 { return nil }
            return (Array(out[0..<Int(n)]), map[0..<Int(len)].map(Int.init))
        }
    }
}
