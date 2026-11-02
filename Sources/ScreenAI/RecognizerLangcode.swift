import Foundation

// aksara::script_util::MostLikelyScript: the script a BCP 47 language tag is most likely written in, as
// LanguageBasedLineRecognizerConfigSelector::Select uses it to pick a recognizer. The tag is parsed and validated
// like i18n_identifiers::LanguageCodeConverter does; tags that don't parse give "Latn".

private func pairs(_ flat: [String]) -> [String: String] {
    var d: [String: String] = [:]
    for i in stride(from: 0, to: flat.count - 1, by: 2) where d[flat[i]] == nil { d[flat[i]] = flat[i + 1] }
    return d
}

private let likelyScripts = pairs(kLikelyScripts)
private let regionScripts = pairs(kRegionScripts)
private let grandfathered = pairs(kGrandfathered)
private let regions = Set(kRegions)
private let scriptCodes = Set(kScriptCodes)
private let variants = Set(kVariants)
private let extlangs = Set(kExtlangs)

private func isAlpha(_ c: UInt8) -> Bool { (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) }
private func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
private func upper(_ c: UInt8) -> UInt8 { c >= 0x61 && c <= 0x7A ? c - 32 : c }
private func lower(_ c: UInt8) -> UInt8 { c >= 0x41 && c <= 0x5A ? c + 32 : c }

private func validLanguage(_ l: [UInt8]) -> Bool {
    guard (l.count == 2 || l.count == 3) && l.allSatisfy(isAlpha) else { return false }
    var i = 0
    for c in l { i = i * 26 + Int(lower(c) - 0x61) }
    let bits = l.count == 2 ? kValidLang2 : kValidLang3
    return (bits[i / 64] >> UInt64(i % 64)) & 1 != 0
}

func mostLikelyScript(_ tag: String) -> String {
    if tag.isEmpty { return "Zzzz" }
    let lowered = tag.utf8.map { $0 == 0x5F ? 0x2D : lower($0) }
    let str = { (b: [UInt8]) in String(decoding: b, as: UTF8.self) }
    if let g = grandfathered[str(lowered)] { return g }
    let parts = lowered.split(separator: 0x2D, omittingEmptySubsequences: false).map(Array.init)
    for p in parts where p.isEmpty || p.count > 8 { return "Latn" }
    var i = 0
    guard validLanguage(parts[i]) else { return "Latn" }
    var language = str(parts[i])
    i += 1
    if i < parts.count && parts[i].count == 3 && parts[i].allSatisfy(isAlpha) {  // extlang (zh-yue -> yue)
        guard extlangs.contains(language + "-" + str(parts[i])) else { return "Latn" }
        language = str(parts[i])
        i += 1
    }
    var script = "", region = ""
    if i < parts.count && parts[i].count == 4 && parts[i].allSatisfy(isAlpha) {
        var s = parts[i]
        i += 1
        s[0] = upper(s[0])
        script = str(s)
        if !scriptCodes.contains(script) {
            guard script == "Zzzz" else { return "Latn" }
            script = ""  // "unknown" is no script
        }
    }
    if i < parts.count
        && ((parts[i].count == 2 && parts[i].allSatisfy(isAlpha)) || (parts[i].count == 3 && parts[i].allSatisfy(isDigit)))
    {
        region = str(parts[i].map(upper))
        i += 1
        guard regions.contains(region) else { return "Latn" }
    }
    // Variants: registered ones only, in any order and with any prefix (ru-PETR1708, zh-Hant-1994).
    while i < parts.count && (parts[i].count >= 5 || (parts[i].count == 4 && isDigit(parts[i][0]))) {
        guard variants.contains(str(parts[i])) else { return "Latn" }
        i += 1
    }
    // Extensions: -t- (transformed content), -u- (locale) and -x- (private use) parse; nothing is read from them.
    if i < parts.count {
        let p = parts[i]
        if p.count != 1 || (p[0] != 0x74 && p[0] != 0x75 && p[0] != 0x78) || i + 1 == parts.count { return "Latn" }
    }
    if !script.isEmpty { return script }
    if !region.isEmpty, let s = regionScripts[language + "-" + region] { return s }
    return likelyScripts[language] ?? "Latn"
}
