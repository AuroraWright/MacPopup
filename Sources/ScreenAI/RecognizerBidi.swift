import Foundation

// Visual -> logical reordering of recognized symbols: aksara::StandardTextReorderer::SymbolsToResult over
// i18n_bidi::BiDiConverter (ICU ubidi, UBIDI_REORDER_INVERSE_LIKE_DIRECT for display -> logical,
// UBIDI_REORDER_DEFAULT for logical -> display, UBIDI_KEEP_BASE_COMBINING, paragraph level 1 iff base_dir_rtl and
// the text has any RTL character, else 0). Port of ICU's ubidi level resolution (the state tables of ubidi.cpp) for
// one paragraph without explicit embeddings or isolates (the recognizers never emit them).

// ICU DirProp order (ubidiimp.h); ENL/ENR are EN resolved by W7 / not subject to W7.
private let kL: UInt8 = 0, kR: UInt8 = 1, kEN: UInt8 = 2, kES: UInt8 = 3, kET: UInt8 = 4, kAN: UInt8 = 5
private let kCS: UInt8 = 6, kB: UInt8 = 7, kS: UInt8 = 8, kWS: UInt8 = 9, kON: UInt8 = 10, kLRE: UInt8 = 11
private let kLRO: UInt8 = 12, kAL: UInt8 = 13, kRLE: UInt8 = 14, kRLO: UInt8 = 15, kPDF: UInt8 = 16
private let kNSM: UInt8 = 17, kBN: UInt8 = 18, kFSI: UInt8 = 19, kLRI: UInt8 = 20, kRLI: UInt8 = 21
private let kPDI: UInt8 = 22, kENL: UInt8 = 23, kENR: UInt8 = 24

/// Binary search for the row of `table` (rows of `n` values) whose first value is `cp`.
private func findRow(_ table: [UInt32], _ n: Int, _ cp: UInt32) -> Int? {
    var lo = 0, hi = table.count / n
    while lo < hi {
        let mid = (lo + hi) / 2
        if table[mid * n] < cp { lo = mid + 1 } else { hi = mid }
    }
    return lo < table.count / n && table[lo * n] == cp ? lo * n : nil
}

/// The recognized text has no explicit embeddings or isolates: their codes are treated as BN / ON.
private func classOf(_ cp: UInt32) -> UInt8 {
    var lo = 0, hi = kBidiClass.count / 3
    while lo < hi {
        let mid = (lo + hi) / 2
        if kBidiClass[mid * 3 + 1] < cp { lo = mid + 1 } else { hi = mid }
    }
    if lo == kBidiClass.count / 3 || kBidiClass[lo * 3] > cp { return kL }
    let c = UInt8(kBidiClass[lo * 3 + 2])
    if c == kLRE || c == kLRO || c == kRLE || c == kRLO || c == kPDF { return kBN }
    if c == kFSI || c == kLRI || c == kRLI || c == kPDI { return kON }
    return c
}

/// u_charMirror: the Bidi_Mirroring_Glyph of `cp`, or `cp` itself.
func bidiMirrorGlyph(_ cp: UInt32) -> UInt32 {
    if let r = findRow(kBidiMirror, 2, cp) { return kBidiMirror[r + 1] }
    return cp
}

@inline(__always) private func flag(_ c: UInt8) -> UInt32 { 1 << UInt32(c) }
private let maskLtr = flag(kL) | flag(kEN) | flag(kENL) | flag(kENR) | flag(kAN) | flag(kLRE) | flag(kLRO) | flag(kLRI)
private let maskRtl = flag(kR) | flag(kAL) | flag(kRLE) | flag(kRLO) | flag(kRLI)
private let maskBnExplicit = flag(kBN) | flag(kLRE) | flag(kLRO) | flag(kRLE) | flag(kRLO) | flag(kPDF)
private let maskBS = flag(kB) | flag(kS)
private let maskIso = flag(kLRI) | flag(kRLI) | flag(kFSI) | flag(kPDI)
private let maskWs = maskBS | flag(kWS) | maskBnExplicit | maskIso
private let maskPossibleN = flag(kON) | flag(kCS) | flag(kES) | flag(kET) | maskWs

private enum Mode { case `default`, inverseLikeDirect }  // UBIDI_REORDER_DEFAULT / UBIDI_REORDER_INVERSE_LIKE_DIRECT

/// Paired brackets (N0): BracketData with a single isolating run.
private struct Brackets {
    struct Opening {
        var position: Int
        /// The closing bracket; -position of the closing one when unstable; 0 when neutralized.
        var match: Int32
        var contextPos: Int
        var flags: UInt8
        var contextDir: UInt8
    }

    static let foundL: UInt8 = 1, foundR: UInt8 = 2
    let text: [UInt32]
    let level: Int
    var openings: [Opening] = []
    var lastStrong: UInt8, lastBase: UInt8, contextDir: UInt8
    var contextPos = 0

    init(_ text: [UInt32], _ level: Int) {
        self.text = text
        self.level = level
        lastStrong = UInt8(level & 1)
        lastBase = lastStrong
        contextDir = lastStrong
    }

    mutating func addOpening(_ match: Int32, _ pos: Int) {
        openings.append(Opening(position: pos, match: match, contextPos: contextPos, flags: 0, contextDir: contextDir))
    }

    mutating func fixN0c(_ openingIndex: Int, _ newPropPos: Int, _ newProp: UInt8, _ props: inout [UInt8]) {
        var k = openingIndex + 1
        while k < openings.count {
            defer { k += 1 }
            let q = openings[k]
            if q.match >= 0 { continue }
            if newPropPos < q.contextPos { break }
            if newPropPos >= q.position { continue }
            if newProp == q.contextDir { break }
            let openingPos = q.position, closingPos = Int(-q.match)
            props[openingPos] = newProp
            props[closingPos] = newProp
            openings[k].match = 0
            fixN0c(k, openingPos, newProp, &props)
            fixN0c(k, closingPos, newProp, &props)
        }
    }

    /// bracketProcessClosing
    mutating func processClosing(_ openIdx: Int, _ pos: Int, _ props: inout [UInt8]) -> UInt8 {
        let o = openings[openIdx]
        let direction = UInt8(level & 1)
        var stable = true
        var newProp: UInt8
        if (direction == 0 && o.flags & Self.foundL != 0) || (direction == 1 && o.flags & Self.foundR != 0) {  // N0b
            newProp = direction
        } else if o.flags & (Self.foundL | Self.foundR) != 0 {  // N0c
            stable = openIdx == 0
            newProp = direction != o.contextDir ? o.contextDir : direction
        } else {  // N0d
            openings.removeSubrange(openIdx...)
            return kON
        }
        let openingPos = o.position
        props[openingPos] = newProp
        props[pos] = newProp
        fixN0c(openIdx, openingPos, newProp, &props)
        if stable {
            openings.removeSubrange(openIdx...)
            while let last = openings.last, last.position == openingPos { openings.removeLast() }
        } else {
            openings[openIdx].match = Int32(-pos)
            var k = openIdx - 1
            while k >= 0 && openings[k].position == openingPos {
                openings[k].match = 0
                k -= 1
            }
            k = openIdx + 1
            while k < openings.count {
                if openings[k].position >= pos { break }
                if openings[k].match > 0 { openings[k].match = 0 }
                k += 1
            }
        }
        return newProp
    }

    /// bracketProcessChar
    mutating func processChar(_ pos: Int, _ props: inout [UInt8]) {
        let prop = props[pos]
        var newProp: UInt8
        if prop == kON {
            var c = text[pos]
            var idx = openings.count - 1
            while idx >= 0 {
                defer { idx -= 1 }
                if openings[idx].match != Int32(bitPattern: c) { continue }
                newProp = processClosing(idx, pos, &props)
                if newProp == kON {  // N0d
                    c = 0
                    break
                }
                lastBase = kON
                contextDir = newProp
                contextPos = pos
                return
            }
            if c != 0, let r = findRow(kBidiBracket, 3, c), kBidiBracket[r + 2] == 1 {
                let pair = kBidiBracket[r + 1]
                if pair == 0x232A {
                    addOpening(0x3009, pos)
                } else if pair == 0x3009 {
                    addOpening(0x232A, pos)
                }
                addOpening(Int32(pair), pos)
            }
        }
        if prop <= kR || prop == kAL {
            newProp = prop == kL ? kL : kR
            lastBase = prop
            lastStrong = prop
            contextDir = newProp
            contextPos = pos
        } else if prop == kEN {
            lastBase = kEN
            if lastStrong == kL {
                newProp = kL  // W7
                props[pos] = kENL
                contextDir = kL
            } else {
                newProp = kR  // N0
                props[pos] = lastStrong == kAL ? kAN : kENR  // W2
                contextDir = kR
            }
            contextPos = pos
        } else if prop == kAN {
            newProp = kR
            lastBase = kAN
            contextDir = kR
            contextPos = pos
        } else if prop == kNSM {
            newProp = lastBase
            if newProp == kON { props[pos] = newProp }
        } else {
            newProp = prop
            lastBase = prop
        }
        if newProp <= kR || newProp == kAL {
            let f = newProp == kL ? Self.foundL : Self.foundR
            for i in openings.indices where pos > openings[i].position { openings[i].flags |= f }
        }
    }
}

private func s5(_ action: UInt8, _ state: UInt8) -> UInt8 { state + (action << 5) }
private func s4(_ action: UInt8, _ state: UInt8) -> UInt8 { state + (action << 4) }
private let dirPropL: UInt8 = 0, dirPropR: UInt8 = 1, dirPropEN: UInt8 = 2, dirPropAN: UInt8 = 3, dirPropON: UInt8 = 4
private let dirPropS: UInt8 = 5, dirPropB: UInt8 = 6
private let groupProp: [UInt8] = [0, 1, 2, 7, 8, 3, 9, 6, 5, 4, 4, 10, 10, 12, 10, 10, 10, 11, 10, 4, 4, 4, 4, 13, 14]
private let impTabProps: [[UInt8]] = [
    [1, 2, 4, 5, 7, 15, 17, 7, 9, 7, 0, 7, 3, 18, 21, dirPropON],
    [1, s5(1, 2), s5(1, 4), s5(1, 5), s5(1, 7), s5(1, 15), s5(1, 17), s5(1, 7), s5(1, 9), s5(1, 7), 1, 1, s5(1, 3),
     s5(1, 18), s5(1, 21), dirPropL],
    [s5(1, 1), 2, s5(1, 4), s5(1, 5), s5(1, 7), s5(1, 15), s5(1, 17), s5(1, 7), s5(1, 9), s5(1, 7), 2, 2, s5(1, 3),
     s5(1, 18), s5(1, 21), dirPropR],
    [s5(1, 1), s5(1, 2), s5(1, 6), s5(1, 6), s5(1, 8), s5(1, 16), s5(1, 17), s5(1, 8), s5(1, 8), s5(1, 8), 3, 3, 3,
     s5(1, 18), s5(1, 21), dirPropR],
    [s5(1, 1), s5(1, 2), 4, s5(1, 5), s5(1, 7), s5(1, 15), s5(1, 17), s5(2, 10), 11, s5(2, 10), 4, 4, s5(1, 3), 18, 21,
     dirPropEN],
    [s5(1, 1), s5(1, 2), s5(1, 4), 5, s5(1, 7), s5(1, 15), s5(1, 17), s5(1, 7), s5(1, 9), s5(2, 12), 5, 5, s5(1, 3),
     s5(1, 18), s5(1, 21), dirPropAN],
    [s5(1, 1), s5(1, 2), 6, 6, s5(1, 8), s5(1, 16), s5(1, 17), s5(1, 8), s5(1, 8), s5(2, 13), 6, 6, s5(1, 3), 18, 21,
     dirPropAN],
    [s5(1, 1), s5(1, 2), s5(1, 4), s5(1, 5), 7, s5(1, 15), s5(1, 17), 7, s5(2, 14), 7, 7, 7, s5(1, 3), s5(1, 18),
     s5(1, 21), dirPropON],
    [s5(1, 1), s5(1, 2), s5(1, 6), s5(1, 6), 8, s5(1, 16), s5(1, 17), 8, 8, 8, 8, 8, s5(1, 3), s5(1, 18), s5(1, 21),
     dirPropON],
    [s5(1, 1), s5(1, 2), 4, s5(1, 5), 7, s5(1, 15), s5(1, 17), 7, 9, 7, 9, 9, s5(1, 3), 18, 21, dirPropON],
    [s5(3, 1), s5(3, 2), 4, s5(3, 5), s5(4, 7), s5(3, 15), s5(3, 17), s5(4, 7), s5(4, 14), s5(4, 7), 10, s5(4, 7),
     s5(3, 3), 18, 21, dirPropEN],
    [s5(1, 1), s5(1, 2), 4, s5(1, 5), s5(1, 7), s5(1, 15), s5(1, 17), s5(1, 7), 11, s5(1, 7), 11, 11, s5(1, 3), 18, 21,
     dirPropEN],
    [s5(3, 1), s5(3, 2), s5(3, 4), 5, s5(4, 7), s5(3, 15), s5(3, 17), s5(4, 7), s5(4, 14), s5(4, 7), 12, s5(4, 7),
     s5(3, 3), s5(3, 18), s5(3, 21), dirPropAN],
    [s5(3, 1), s5(3, 2), 6, 6, s5(4, 8), s5(3, 16), s5(3, 17), s5(4, 8), s5(4, 8), s5(4, 8), 13, s5(4, 8), s5(3, 3),
     18, 21, dirPropAN],
    [s5(1, 1), s5(1, 2), s5(4, 4), s5(1, 5), 7, s5(1, 15), s5(1, 17), 7, 14, 7, 14, 14, s5(1, 3), s5(4, 18),
     s5(4, 21), dirPropON],
    [s5(1, 1), s5(1, 2), s5(1, 4), s5(1, 5), s5(1, 7), 15, s5(1, 17), s5(1, 7), s5(1, 9), s5(1, 7), 15, s5(1, 7),
     s5(1, 3), s5(1, 18), s5(1, 21), dirPropS],
    [s5(1, 1), s5(1, 2), s5(1, 6), s5(1, 6), s5(1, 8), 16, s5(1, 17), s5(1, 8), s5(1, 8), s5(1, 8), 16, s5(1, 8),
     s5(1, 3), s5(1, 18), s5(1, 21), dirPropS],
    [s5(1, 1), s5(1, 2), s5(1, 4), s5(1, 5), s5(1, 7), s5(1, 15), 17, s5(1, 7), s5(1, 9), s5(1, 7), 17, s5(1, 7),
     s5(1, 3), s5(1, 18), s5(1, 21), dirPropB],
    [s5(1, 1), s5(1, 2), 18, s5(1, 5), s5(1, 7), s5(1, 15), s5(1, 17), s5(2, 19), 20, s5(2, 19), 18, 18, s5(1, 3), 18,
     21, dirPropL],
    [s5(3, 1), s5(3, 2), 18, s5(3, 5), s5(4, 7), s5(3, 15), s5(3, 17), s5(4, 7), s5(4, 14), s5(4, 7), 19, s5(4, 7),
     s5(3, 3), 18, 21, dirPropL],
    [s5(1, 1), s5(1, 2), 18, s5(1, 5), s5(1, 7), s5(1, 15), s5(1, 17), s5(1, 7), 20, s5(1, 7), 20, 20, s5(1, 3), 18,
     21, dirPropL],
    [s5(1, 1), s5(1, 2), 21, s5(1, 5), s5(1, 7), s5(1, 15), s5(1, 17), s5(2, 22), 23, s5(2, 22), 21, 21, s5(1, 3), 18,
     21, dirPropAN],
    [s5(3, 1), s5(3, 2), 21, s5(3, 5), s5(4, 7), s5(3, 15), s5(3, 17), s5(4, 7), s5(4, 14), s5(4, 7), 22, s5(4, 7),
     s5(3, 3), 18, 21, dirPropAN],
    [s5(1, 1), s5(1, 2), 21, s5(1, 5), s5(1, 7), s5(1, 15), s5(1, 17), s5(1, 7), 23, s5(1, 7), 23, 23, s5(1, 3), 18,
     21, dirPropAN],
]
private let impTabLDefault: [[UInt8]] = [
    [0, 1, 0, 2, 0, 0, 0, 0], [0, 1, 3, 3, s4(1, 4), s4(1, 4), 0, 1], [0, 1, 0, 2, s4(1, 5), s4(1, 5), 0, 2],
    [0, 1, 3, 3, s4(1, 4), s4(1, 4), 0, 2], [0, s4(2, 1), s4(3, 3), s4(3, 3), 4, 4, 0, 0],
    [0, s4(2, 1), 0, s4(3, 2), 5, 5, 0, 0],
]
private let impTabRDefault: [[UInt8]] = [
    [1, 0, 2, 2, 0, 0, 0, 0], [1, 0, 1, 3, s4(1, 4), s4(1, 4), 0, 1], [1, 0, 2, 2, 0, 0, 0, 1],
    [1, 0, 1, 3, 5, 5, 0, 1], [s4(2, 1), 0, s4(2, 1), 3, 4, 4, 0, 0], [1, 0, 1, 3, 5, 5, 0, 0],
]
private let impTabRInverseLikeDirect: [[UInt8]] = [
    [1, 0, 2, 2, 0, 0, 0, 0],
    [1, 0, 1, 2, s4(1, 3), s4(1, 3), 0, 1],
    [1, 0, 2, 2, 0, 0, 0, 1],
    [s4(2, 1), s4(3, 0), 6, 4, 3, 3, s4(3, 0), 0],
    [s4(2, 1), s4(3, 0), 6, 4, 5, 5, s4(3, 0), 3],
    [s4(2, 1), s4(3, 0), 6, 4, 5, 5, s4(3, 0), 2],
    [s4(2, 1), s4(3, 0), 6, 4, 3, 3, s4(3, 0), 1],
]
private let impAct0: [UInt8] = [0, 1, 2, 3, 4]
private let impAct1: [UInt8] = [0, 1, 13, 14]

private struct LevState {
    var tab: [[UInt8]]
    var act: [UInt8]
    var startOn = -1, state = 0, runLevel = 0

    mutating func processPropertySeq(_ prop: UInt8, _ start0: Int, _ limit: Int, _ levels: inout [UInt8]) {
        var start = start0
        let cell = tab[state][Int(prop)]
        state = Int(cell & 0x0F)
        let action = act[Int(cell >> 4)]
        let addLevel = Int(tab[state][7])
        switch action {
        case 1:  // init ON seq
            startOn = start0
        case 2:  // prepend ON seq to current seq
            start = startOn
        case 3:  // EN/AN after R+ON
            if startOn < start0 { for k in startOn..<start0 { levels[k] = UInt8(runLevel + 1) } }
        case 4:  // EN/AN before R for NUMBERS_SPECIAL
            if startOn < start0 { for k in startOn..<start0 { levels[k] = UInt8(runLevel + 2) } }
        case 13:  // L after L+ON+EN/AN/ON
            let level = runLevel
            var k = start0 - 1
            while k >= startOn {
                if Int(levels[k]) == level + 3 {
                    while k >= 0 && Int(levels[k]) == level + 3 {
                        levels[k] -= 2
                        k -= 1
                    }
                    while k >= 0 && Int(levels[k]) == level { k -= 1 }
                }
                if k < 0 { break }
                if Int(levels[k]) == level + 2 {
                    levels[k] = UInt8(level)
                } else {
                    levels[k] = UInt8(level + 1)
                }
                k -= 1
            }
        case 14:  // R after L+ON+EN/AN/ON
            let level = runLevel + 1
            var k = start0 - 1
            while k >= startOn {
                if Int(levels[k]) > level { levels[k] -= 2 }
                k -= 1
            }
        default:
            break
        }
        if addLevel != 0 || start < start0 {
            let level = UInt8(runLevel + addLevel)
            var k = max(start, 0)
            while k < limit {
                levels[k] = level
                k += 1
            }
        }
    }
}

private enum Direction { case ltr, rtl, mixed }

/// ubidi_setPara for one paragraph at `para` level (0/1) without explicit embeddings; `levels` gets the resolved
/// level of every code point (all `para` unless the direction is mixed).
private func resolveLevels(_ text: [UInt32], _ para: Int, _ mode: Mode, _ levels: inout [UInt8]) -> Direction {
    let n = text.count
    var props = [UInt8](repeating: 0, count: n)
    var flags: UInt32 = 0
    var lastArabicPos = -1
    for i in 0..<n {  // getDirProps
        props[i] = classOf(text[i])
        flags |= flag(props[i])
        if props[i] == kAL { lastArabicPos = i }
    }
    flags |= flag(para & 1 != 0 ? kR : kL)
    levels = [UInt8](repeating: UInt8(para), count: n)
    // directionFromFlags
    if !(flags & maskRtl != 0 || (flags & flag(kAN) != 0 && flags & maskPossibleN != 0)) { return .ltr }
    if flags & maskLtr == 0 { return .rtl }
    // resolveExplicitLevels: no embeddings; bracket matching except for inverse BiDi
    if mode == .default {
        var brackets = Brackets(text, para)
        for i in 0..<n where props[i] != kBN && props[i] != kB { brackets.processChar(i, &props) }
    }
    // resolveImplicitLevels(0, n, sor, eor)
    var ls: LevState
    if para & 1 != 0 {
        ls = LevState(tab: mode == .default ? impTabRDefault : impTabRInverseLikeDirect,
                      act: mode == .default ? impAct0 : impAct1)
    } else {
        ls = LevState(tab: impTabLDefault, act: impAct0)
    }
    ls.runLevel = para
    let sor = UInt8(para & 1), eor = sor
    let inverseRtl = 0 < lastArabicPos && para & 1 != 0 && mode == .inverseLikeDirect
    var start1 = 0, start2 = 0
    var stateImp = n > 0 && props[0] == kNSM ? 1 + Int(sor) : 0
    ls.processPropertySeq(sor, 0, 0, &levels)
    var nextStrongProp = kR
    var nextStrongPos = -1
    for i in 0...n {
        var gprop: UInt8
        if i >= n {
            gprop = eor
        } else {
            var prop = props[i]
            if inverseRtl {
                if prop == kAL {
                    prop = kR  // AL before EN does not make it AN
                } else if prop == kEN {
                    if nextStrongPos <= i {
                        nextStrongProp = kR
                        nextStrongPos = n
                        for j in (i + 1)..<max(n, i + 1) where props[j] == kL || props[j] == kR || props[j] == kAL {
                            nextStrongProp = props[j]
                            nextStrongPos = j
                            break
                        }
                    }
                    if nextStrongProp == kAL { prop = kAN }
                }
            }
            gprop = groupProp[Int(prop)]
        }
        let oldStateImp = stateImp
        let cell = impTabProps[oldStateImp][Int(gprop)]
        stateImp = Int(cell & 0x1F)
        var action = Int(cell >> 5)
        if i == n && action == 0 { action = 1 }
        if action != 0 {
            let res = impTabProps[oldStateImp][15]
            switch action {
            case 1:
                ls.processPropertySeq(res, start1, i, &levels)
                start1 = i
            case 2:
                start2 = i
            case 3:
                ls.processPropertySeq(res, start1, start2, &levels)
                ls.processPropertySeq(dirPropON, start2, i, &levels)
                start1 = i
            case 4:
                ls.processPropertySeq(res, start1, start2, &levels)
                start1 = start2
                start2 = i
            default:
                break
            }
        }
    }
    ls.processPropertySeq(eor, n, n, &levels)
    // adjustWSLevels (L1)
    if flags & maskWs != 0 {
        var i = n
        while i > 0 {
            while i > 0 {
                i -= 1
                guard flag(props[i]) & maskWs != 0 else { break }
                levels[i] = UInt8(para)
            }
            while i > 0 {
                i -= 1
                let f = flag(props[i])
                if f & maskBnExplicit != 0 {
                    levels[i] = levels[i + 1]
                } else if f & maskBS != 0 {
                    levels[i] = UInt8(para)
                    break
                }
            }
        }
    }
    return .mixed
}

/// Visual order (visual[j] = logical index) by L2 (ubidi_getVisualMap).
private func visualOrder(_ level: [UInt8]) -> [Int] {
    let n = level.count
    var order = Array(0..<n)
    var maxLevel = 0, minOdd = 1000
    for l in level {
        maxLevel = max(maxLevel, Int(l))
        if l & 1 != 0 { minOdd = min(minOdd, Int(l)) }
    }
    var lv = maxLevel
    while lv >= minOdd && lv >= 1 {
        var i = 0
        while i < n {
            if Int(level[order[i]]) < lv {
                i += 1
                continue
            }
            var j = i
            while j < n && Int(level[order[j]]) >= lv { j += 1 }
            order[i..<j].reverse()
            i = j
        }
        lv -= 1
    }
    return order
}

/// ubidi_writeReordered: odd-level runs are written reversed; with `keepBaseCombining` combining marks stay after
/// their base character, with `mirroring` the base character of a reversed run is mirrored.
private func writeReordered(_ cps: [UInt32], _ level: [UInt8], _ keepBaseCombining: Bool, _ mirroring: Bool)
    -> [UInt32]
{
    let n = cps.count
    var out: [UInt32] = []
    out.reserveCapacity(n)
    var runs: [(start: Int, end: Int, level: UInt8)] = []
    var i = 0
    while i < n {
        var j = i
        while j < n && level[j] == level[i] { j += 1 }
        runs.append((i, j, level[i]))
        i = j
    }
    for r in visualOrder(runs.map(\.level)) {
        let run = runs[r]
        if run.level & 1 == 0 {
            out.append(contentsOf: cps[run.start..<run.end])
            continue
        }
        var end = run.end
        while end > run.start {
            var k = end - 1
            if keepBaseCombining {  // IS_COMBINING: Mn/Me (bidi NSM)
                while k > run.start && classOf(cps[k]) == kNSM { k -= 1 }
            }
            out.append(mirroring ? bidiMirrorGlyph(cps[k]) : cps[k])
            out.append(contentsOf: cps[(k + 1)..<end])
            end = k
        }
    }
    return out
}

private func string(_ cps: [UInt32]) -> String {
    var s = String.UnicodeScalarView()
    for c in cps { s.append(Unicode.Scalar(c) ?? "\u{FFFD}") }
    return String(s)
}

func codePoints(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value) }

/// i18n_bidi::BiDiConverter::ConvertUtf8Text: `map` gets ubidi_getLogicalMap (output index of every input code point;
/// identity for UBIDI_LTR text, which is returned unchanged).
private func convert(_ text: String, _ para: Int, _ mode: Mode, _ keepBaseCombining: Bool, _ mirroring: Bool,
                     _ map: inout [Int]) -> String {
    let cps = codePoints(text)
    let n = cps.count
    var level: [UInt8] = []
    let dir = resolveLevels(cps, para, mode, &level)
    map = Array(0..<n)
    if dir == .ltr { return text }
    let visual = visualOrder(level)
    for j in 0..<n { map[visual[j]] = j }
    return string(writeReordered(cps, level, keepBaseCombining, mirroring))
}

/// StandardTextReorderer::SymbolsToResult: symbols (in recognition = visual order) -> logical line text and the byte
/// offset of every symbol in it (-1 when the symbol's text isn't found at its offset).
func symbolsVisualToLogical(_ symbols: [String], baseDirRtl: Bool) -> (text: String, offsets: [Int]) {
    var display = ""
    var unused: [Int] = []
    for s in symbols {  // InternalReorder: LogicalToDisplay
        let para = baseDirRtl && hasAnyRtl(s) ? 1 : 0
        display += convert(s, para, .default, true, false, &unused)
    }
    var map: [Int] = []
    let para = baseDirRtl && hasAnyRtl(display) ? 1 : 0
    let text = convert(display, para, .inverseLikeDirect, true, false, &map)  // DisplayToLogical
    let bytes = Array(text.utf8)
    // The byte offset of every code point of the logical text.
    var cpOffset: [Int] = []
    for i in bytes.indices where bytes[i] & 0xC0 != 0x80 { cpOffset.append(i) }
    var offsets = [Int](repeating: -1, count: symbols.count)
    var cp = 0
    for (k, s) in symbols.enumerated() {
        if s.isEmpty { continue }
        var first = bytes.count
        for _ in 0..<s.unicodeScalars.count {
            if cp < map.count { first = min(first, map[cp]) }
            cp += 1
        }
        if first >= cpOffset.count { continue }
        let off = cpOffset[first]
        let sb = Array(s.utf8)
        if off + sb.count <= bytes.count && bytes[off..<(off + sb.count)].elementsEqual(sb) { offsets[k] = off }
    }
    return (text, offsets)
}

/// aksara::MirroringSymbolManipulator::ActuallyTransform: if the text has any RTL character, every code point at an
/// odd level of an RTL paragraph (UBIDI_REORDER_INVERSE_LIKE_DIRECT) is replaced by its Bidi_Mirroring_Glyph; the
/// order is unchanged.
func mirrorRtlText(_ text: String) -> String {
    if !hasAnyRtl(text) { return text }
    var map: [Int] = []
    let cps = codePoints(convert(text, 1, .inverseLikeDirect, false, true, &map))
    return string(map.map { cps[$0] })
}
