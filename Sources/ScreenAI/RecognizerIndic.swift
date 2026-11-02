import Foundation

// Visual -> logical joining of recognized Indic symbols: aksara::StandardTextReorderer::JoinAtomsToSymbols with the
// registered SymbolAtomManipulators (Bengali, Devanagari, Gujarati, Kannada, Mirroring, Tamil, Telugu; applied last
// to first). The recognizers emit pre-base vowel signs, reph/arkavottu and split two-part vowels in visual order;
// each manipulator's JoinAndReorderStrings rewrites the label sequence into logical order and
// SplittingSymbolAtomManipulator::JoinSymbols groups the labels whose text was permuted into one symbol. Mirroring
// maps bracket glyphs of RTL text to their logical characters.
//
// Everything works on UTF-8 bytes: Swift's String comparisons would treat the composed and decomposed vowel signs
// the original tells apart as equal.

private typealias Bytes = [UInt8]

private func b(_ s: String) -> Bytes { Array(s.utf8) }

private func endsWith(_ s: Bytes, _ suffix: Bytes) -> Bool {
    s.count >= suffix.count && s[(s.count - suffix.count)...].elementsEqual(suffix)
}

private func startsWith(_ s: Bytes, _ prefix: Bytes) -> Bool {
    s.count >= prefix.count && s[..<prefix.count].elementsEqual(prefix)
}

/// The first index of `needle` in `s` at or after `from`.
private func find(_ s: Bytes, _ needle: Bytes, from: Int = 0) -> Int? {
    guard !needle.isEmpty, s.count >= needle.count else { return needle.isEmpty ? from : nil }
    var i = from
    while i + needle.count <= s.count {
        if s[i] == needle[0] && s[i..<(i + needle.count)].elementsEqual(needle) { return i }
        i += 1
    }
    return nil
}

private func scalars(_ s: Bytes) -> [UInt32] { String(decoding: s, as: UTF8.self).unicodeScalars.map(\.value) }

private func utf8Len(_ c: UInt32) -> Int { c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4 }

private func concat(_ v: [Bytes]) -> Bytes { v.flatMap { $0 } }

/// A symbol during joining: its text and the labels (atoms) it is made of, as indices into the input symbols.
private struct Piece {
    var text: Bytes
    var atoms: [Int]
}

// MARK: - JoinAndReorderStrings of every manipulator

/// devanagari_symbol_manipulator.cc: the pre-base vowel sign i moves behind the following consonant cluster (pieces
/// ending with virama plus the next piece), before a trailing candrabindu/anusvara of that cluster.
private func joinDevanagari(_ v: [Bytes]) -> Bytes {
    let kI = b("\u{093F}"), virama = b("\u{094D}")
    var out = Bytes()
    let n = v.count
    var i = 0
    while i < n {
        defer { i += 1 }
        if v[i] != kI {
            out += v[i]
            continue
        }
        var j = i + 1
        while j < n {
            out += v[j]
            if !v[j].isEmpty && (v[j].count < 3 || !endsWith(v[j], virama)) { break }
            j += 1
        }
        // MaybeInsertPenultimate
        var inserted = false
        for mark in [b("\u{0901}"), b("\u{0902}")] where endsWith(out, mark) {
            out.insert(contentsOf: kI, at: out.count - 3)
            inserted = true
            break
        }
        if !inserted { out += kI }
        i = j
    }
    return out
}

/// gujarati_symbol_manipulator.cc
private func joinGujarati(_ v: [Bytes]) -> Bytes {
    let kI = b("\u{0ABF}")
    var out = Bytes()
    let n = v.count
    var i = 0
    while i < n {
        if i + 1 < n && v[i] == kI {
            var k = i + 1
            while k + 1 < n && v[k].isEmpty { k += 1 }
            out += v[k] + kI
            i = k + 1
        } else {
            out += v[i]
            i += 1
        }
    }
    // regex_replace "(ઁ|ં)િ" -> "િ$1"
    let marks = [b("\u{0A81}"), b("\u{0A82}")]
    var res = Bytes()
    var p = 0
    while p < out.count {
        if p + 6 <= out.count, marks.contains(where: { out[p..<(p + 3)].elementsEqual($0) }),
           out[(p + 3)..<(p + 6)].elementsEqual(kI)
        {
            res += kI
            res += out[p..<(p + 3)]
            p += 6
        } else {
            res.append(out[p])
            p += 1
        }
    }
    return res
}

/// std::regex_replace of a pattern "(\n|^)X(\n|$)" (or "(^|\n)..." with `caretFirst`) over labels joined by "\n".
/// `body` gets the position after the leading delimiter and returns where the trailing delimiter must be and what
/// replaces X, or nil. `.` in the original's patterns doesn't match "\n" or "\r", so a match never spans labels.
private func replaceDelimited(_ s: Bytes, caretFirst: Bool, _ body: (Int) -> (end: Int, replacement: Bytes)?) -> Bytes {
    let nl = UInt8(ascii: "\n")
    var out = Bytes()
    var pos = 0
    func tryAt(_ p: Int) -> (end: Int, out: Bytes)? {
        for useCaret in caretFirst ? [true, false] : [false, true] {
            let start: Int
            if useCaret {
                guard p == 0 else { continue }
                start = 0
            } else {
                guard p < s.count && s[p] == nl else { continue }
                start = p + 1
            }
            guard let m = body(start) else { continue }
            var r = useCaret ? Bytes() : [nl]
            r += m.replacement
            if m.end == s.count { return (m.end, r) }
            if m.end < s.count && s[m.end] == nl { return (m.end + 1, r + [nl]) }
        }
        return nil
    }
    var p = 0
    while p <= s.count {
        if let m = tryAt(p) {
            out += s[pos..<p]
            out += m.out
            pos = m.end
            p = m.end
            if p == s.count { break }
            continue
        }
        p += 1
    }
    out += s[min(pos, s.count)...]
    return out
}

/// kannada_symbol_manipulator.cc: the arkavottu (reph, recognized as a subscript ra after its consonant) moves in
/// front of the consonant as RA + virama; a vowel sign aa/u recognized before it is kept behind the consonant.
private func joinKannada(_ v: [Bytes]) -> Bytes {
    let nl = UInt8(ascii: "\n"), cr = UInt8(ascii: "\r")
    var s = Bytes()
    for (i, p) in v.enumerated() {
        if i > 0 { s.append(nl) }
        s += p
    }
    // "\n+" -> "\n"
    var collapsed = Bytes()
    for c in s where !(c == nl && collapsed.last == nl) { collapsed.append(c) }
    s = collapsed
    let subRa = b("\u{0CCD}\u{0CB0}")
    let vowels = [b("\u{0CBE}"), b("\u{0CC1}")]
    // "(\n|^)(ಾ|ು)\n(್ರ)(\n|$)" -> "$1$3\n$2$4"
    s = replaceDelimited(s, caretFirst: false) { [s] q in
        for vowel in vowels {
            let e = q + vowel.count
            if e + 1 + subRa.count <= s.count && s[q..<e].elementsEqual(vowel) && s[e] == nl
                && s[(e + 1)..<(e + 1 + subRa.count)].elementsEqual(subRa)
            {
                return (e + 1 + subRa.count, subRa + [nl] + vowel)
            }
        }
        return nil
    }
    // "(^|\n)(.*)\n(್ರ)(\n|$)" -> "$1$3\n$2$4"
    s = replaceDelimited(s, caretFirst: true) { [s] q in
        var e = q
        while e < s.count && s[e] != nl && s[e] != cr { e += 1 }
        guard e + 1 + subRa.count <= s.count && s[e] == nl && s[(e + 1)..<(e + 1 + subRa.count)].elementsEqual(subRa)
        else { return nil }
        return (e + 1 + subRa.count, subRa + [nl] + Array(s[q..<e]))
    }
    // "(\n|^)್ರ(\n|$)" -> "$1ರ್$2"
    s = replaceDelimited(s, caretFirst: false) { [s] q in
        guard q + subRa.count <= s.count && s[q..<(q + subRa.count)].elementsEqual(subRa) else { return nil }
        return (q + subRa.count, b("\u{0CB0}\u{0CCD}"))
    }
    return s.filter { $0 != nl }
}

/// tamil_symbol_manipulator.cc: a left vowel sign (e, ee, ai) swaps with the following piece.
private func joinTamil(_ input: [Bytes]) -> Bytes {
    var v = input.filter { !$0.isEmpty }
    let left = [b("\u{0BC6}"), b("\u{0BC7}"), b("\u{0BC8}")]
    var i = 0
    while i < v.count {
        if left.contains(v[i]) && i + 1 < v.count {
            v.swapAt(i, i + 1)
            i += 1
        }
        i += 1
    }
    return concat(v)
}

/// telugu_symbol_manipulator.cc: vowel signs of a piece move behind the following virama (subscript) pieces.
private func isTeluguNonSepMark(_ c: UInt32) -> Bool {
    (c >= 0x0C3E && c <= 0x0C44) || (c >= 0x0C46 && c <= 0x0C4C) || c == 0x0C55 || c == 0x0C56 || c == 0x0C62
        || c == 0x0C63 || c == 0x0C00
}

private func joinTelugu(_ input: [Bytes]) -> Bytes {
    var v = input.filter { !$0.isEmpty }
    let virama = b("\u{0C4D}")
    let n = v.count
    var i = 0
    while i < n {
        defer { i += 1 }
        // FullMatch "(.*?)([marks]+)": base = shortest prefix, marks = longest all-mark suffix (non-empty)
        let cps = scalars(v[i])
        var m = cps.count
        while m > 0 && isTeluguNonSepMark(cps[m - 1]) { m -= 1 }
        if m == cps.count { continue }
        let baseBytes = cps[..<m].reduce(0) { $0 + utf8Len($1) }
        var base = Array(v[i][..<baseBytes])
        let marks = Array(v[i][baseBytes...])
        var j = i + 1, k = i
        while j < n && v[j].count >= 3 && startsWith(v[j], virama) {
            v[k] = base + v[j]
            base = []
            j += 1
            k += 1
        }
        v[k] = base + marks
        i = k
    }
    return concat(v)
}

/// bengali_symbol_manipulator.cc: a pre-base vowel sign (i, e, ai) moves behind the following consonant cluster
/// (pieces ending with hasant [+ZWNJ/ZWJ], the consonant and a ya-phala), before a candrabindu of the cluster.
private func joinBengali(_ input: [Bytes]) -> Bytes {
    var v = input.filter { !$0.isEmpty }
    let n = v.count
    let hasants = [b("\u{09CD}"), b("\u{09CD}\u{200C}"), b("\u{09CD}\u{200D}")]
    let yaPhalas = [b("\u{09CD}\u{09AF}"), b("\u{09CD}\u{200C}\u{09AF}"), b("\u{09CD}\u{200D}\u{09AF}")]
    let preBase = [b("\u{09BF}"), b("\u{09C7}"), b("\u{09C8}")]
    let candrabindu = b("\u{0981}")
    var i = 0
    while i < n {
        defer { i += 1 }
        if !preBase.contains(v[i]) || i + 1 >= n { continue }
        let saved = v[i]
        var src = i + 1, dst = i
        while src < n && hasants.contains(where: { endsWith(v[src], $0) }) {
            v[dst] = v[src]
            dst += 1
            src += 1
        }
        if src == n {
            v[dst] = saved
            break
        }
        v[dst] = v[src]
        var next = src
        if src + 1 < n && yaPhalas.contains(v[src + 1]) {
            v[src] = v[src + 1]
            next = src + 1
        }
        v[next] = saved
        if endsWith(v[next - 1], candrabindu) {
            v[next - 1].removeLast(3)
            v[next] += candrabindu
        }
        i = next
    }
    return concat(v)
}

// MARK: - SplittingSymbolAtomManipulator::JoinSymbols

private struct Manipulator {
    /// SplittingSymbolAtomManipulator::JoinAndReorderStrings
    var join: (([Bytes]) -> Bytes)?
    /// precomposed -> decomposed, in key order
    var normalization: [(composed: Bytes, decomposed: Bytes)] = []
    /// MappingSymbolAtomManipulator::TransformFromAtomString
    var mapping: ((Bytes) -> Bytes)?
}

/// ApplyNormalization(.., to_composed = true)
private func normalize(_ m: Manipulator, _ s: inout Bytes) {
    for (composed, decomposed) in m.normalization {
        var out = Bytes()
        var pos = 0
        while let f = find(s, decomposed, from: pos) {
            out += s[pos..<f]
            out += composed
            pos = f + decomposed.count
        }
        s = out + s[pos...]
    }
}

/// aksara::util::AlignTextToPieces: the text must be a permutation of the pieces' code points; alignment[k] is the
/// rank of piece k by the first text position its code points take.
private func alignTextToPieces(_ text: Bytes, _ pieces: [Piece], _ first: Int, _ last: Int) -> [Int]? {
    var positions: [UInt32: [Int]] = [:]  // code point -> remaining positions (ascending)
    for (i, c) in scalars(text).enumerated() { positions[c, default: []].append(i) }
    var order: [(piece: Int, pos: Int)] = []
    for k in first...last {
        var minPos = text.count + 1
        for c in scalars(pieces[k].text) {
            guard var list = positions[c] else { return nil }
            minPos = min(minPos, list.removeFirst())
            positions[c] = list.isEmpty ? nil : list
        }
        order.append((k - first, minPos))
    }
    if !positions.isEmpty { return nil }
    order.stableSort { $0.pos < $1.pos }
    var alignment = [Int](repeating: 0, count: order.count)
    for (r, o) in order.enumerated() { alignment[o.piece] = r }
    return alignment
}

/// MappingSymbolAtomManipulator::JoinSymbols: the line text is transformed code point for code point and handed back
/// to the symbols in order (MonotonicUpdate).
private func mapSymbols(_ m: Manipulator, _ symbols: inout [Piece]) -> Bool {
    let joined = concat(symbols.map(\.text))
    let output = m.mapping!(joined)
    let cps = scalars(output)
    guard cps.count == scalars(joined).count else { return false }  // CHECK in the original
    var pos = 0, byte = 0
    for i in symbols.indices where !symbols[i].text.isEmpty {
        var len = 0
        for _ in 0..<scalars(symbols[i].text).count {
            len += utf8Len(cps[pos])
            pos += 1
        }
        symbols[i].text = Array(output[byte..<(byte + len)])
        byte += len
    }
    return true
}

private func joinSymbols(_ m: Manipulator, _ symbols: inout [Piece]) -> Bool {
    if m.mapping != nil { return mapSymbols(m, &symbols) }
    let inputs = symbols.map(\.text)
    let output = m.join!(inputs)
    if output == concat(inputs) {
        var normalized = output
        normalize(m, &normalized)
        if normalized == output { return true }
    }
    var joined: [Piece] = []
    var offset = 0, pos = 0
    let n = symbols.count
    while offset < output.count {
        if pos >= n { return false }
        var j = pos, len = 0
        var alignment: [Int] = []
        while true {
            if j >= n { return false }
            len += inputs[j].count
            if offset + len > output.count { return false }  // CHECK in the original
            if let a = alignTextToPieces(Array(output[offset..<(offset + len)]), symbols, pos, j) {
                alignment = a
                // the group must not end inside a decomposed sequence of the normalization map
                let rest = Array(output[offset...])
                var straddles = false
                for kv in m.normalization {
                    if let f = find(rest, kv.decomposed), f < len && f + kv.decomposed.count > len {
                        straddles = true
                        break
                    }
                }
                if !straddles { break }
            }
            j += 1
        }
        if j == pos {
            var p = symbols[pos]
            if !m.normalization.isEmpty { normalize(m, &p.text) }
            joined.append(p)
        } else {
            var slots = [[Int]](repeating: [], count: j - pos + 1)
            for k in pos...j { slots[alignment[k - pos]] = symbols[k].atoms }
            var p = Piece(text: Array(output[offset..<(offset + len)]), atoms: slots.flatMap { $0 })
            if !m.normalization.isEmpty { normalize(m, &p.text) }
            joined.append(p)
        }
        offset += len
        pos = j + 1
    }
    symbols = joined
    return true
}

private let manipulators: [Manipulator] = [
    Manipulator(join: joinBengali,
                normalization: [(b("\u{09CB}"), b("\u{09C7}\u{09BE}")), (b("\u{09CC}"), b("\u{09C7}\u{09D7}"))]),
    Manipulator(join: joinDevanagari),
    Manipulator(join: joinGujarati),
    Manipulator(join: joinKannada),
    Manipulator(mapping: { b(mirrorRtlText(String(decoding: $0, as: UTF8.self))) }),  // MirroringSymbolManipulator
    Manipulator(join: joinTamil,
                normalization: [(b("\u{0B94}"), b("\u{0B92}\u{0BD7}")), (b("\u{0BCA}"), b("\u{0BC6}\u{0BBE}")),
                                (b("\u{0BCB}"), b("\u{0BC7}\u{0BBE}")), (b("\u{0BCC}"), b("\u{0BC6}\u{0BD7}"))]),
    Manipulator(join: joinTelugu),
]

/// Joins `symbols` (one per decoded label, in recognition order) in place. A joined symbol's box is the union of its
/// labels' boxes (CleanupSymbols) and its confidence the product of theirs
/// (CreateTextLineResultFromCTCDecoderOutput). If any manipulator can't align its output with the labels, the
/// symbols stay one per label.
func joinSymbolsLogical(_ symbols: inout [RecSymbol]) {
    var pieces = symbols.enumerated().map { Piece(text: b($0.element.text), atoms: [$0.offset]) }
    for m in manipulators.reversed() {
        if !joinSymbols(m, &pieces) { return }  // original: back to one symbol per atom
    }
    var changed = pieces.count != symbols.count
    var i = 0
    while !changed && i < pieces.count {
        changed = pieces[i].text != b(symbols[i].text)
        i += 1
    }
    if !changed { return }
    var out: [RecSymbol] = []
    for p in pieces {
        var s = RecSymbol(text: String(decoding: p.text, as: UTF8.self))
        // box: union of the atom boxes; confidence: product (double) of the label confidences in label order
        let labels = p.atoms.sorted()
        var x0 = Int(Int32.max), y0 = Int(Int32.max), x1 = Int(Int32.min), y1 = Int(Int32.min)
        var conf = 1.0
        for a in labels {
            let at = symbols[a]
            x0 = min(x0, at.box.left)
            y0 = min(y0, at.box.top)
            x1 = max(x1, at.box.left + at.box.width)
            y1 = max(y1, at.box.top + at.box.height)
            conf *= Double(at.confidence)
        }
        if labels.count == 1 {
            s.box = symbols[labels[0]].box
        } else if !labels.isEmpty {
            s.box = symbols[labels[0]].box
            s.box.left = x0
            s.box.top = y0
            s.box.width = x1 - x0
            s.box.height = y1 - y0
        }
        s.confidence = Float(conf)
        if labels.count == 1 {
            let atomText = b(symbols[labels[0]].text)
            let now = scalars(p.text), atom = scalars(atomText)
            s.mirrored = p.text != atomText && now.count == 1 && atom.count == 1 && bidiMirrorGlyph(now[0]) == atom[0]
        }
        out.append(s)
    }
    symbols = out
}
