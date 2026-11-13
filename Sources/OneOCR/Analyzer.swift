import CoreML
import Foundation

// The text analyzer: AuxMltCls (script, handwritten, flipped) and LineLayout (CJK horizontal or vertical) per line,
// then oneocr's per-image decisions on each line's OCR mode, orientation and layout.

enum Script {
    static let unknown = 0, cjk = 2, latin = 3, cyrillic = 4, arabic = 5, devanagari = 6, greek = 7, thai = 8,
               hebrew = 9, tamil = 10, nonText = 11
    static let byName = ["Unknown": 0, "CJK": 2, "Latin": 3, "Cyrillic": 4, "Arabic": 5, "Devanagari": 6, "Greek": 7,
                         "Thai": 8, "Hebrew": 9, "Tamil": 10, "NonText": 11]
}

enum Category {
    static let mixed = 0, printed = 1, handwritten = 2
    static let byName = ["Mixed": 0, "Printed": 1, "Handwritten": 2]
}

enum OCRMode {
    static let auto = 1001
    static let byName = [
        "Auto": 1001, "LatinPrintedV2": 1106, "LatinMixedV2": 1107, "LatinPrintedV2Dummy": 1108, "LatinAutoV2": 1109,
        "CJKPrinted": 1401, "CJKMixed": 1402, "CJKAuto": 1403,
        "CyrillicAuto": 1500, "CyrillicPrinted": 1501, "CyrillicMixed": 1502, "CyrillicPrintedDummy": 1503,
        "CyrillicMixedDummy": 1504,
        "ArabicAuto": 1600, "ArabicPrinted": 1601, "ArabicMixed": 1602, "ArabicPrintedDummy": 1603,
        "ArabicMixedDummy": 1604,
        "DevanagariAuto": 1700, "DevanagariPrinted": 1701, "DevanagariMixed": 1702,
        "DevanagariPrintedDummy": 1703, "DevanagariMixedDummy": 1704,
        "GreekAuto": 1800, "GreekPrinted": 1801, "GreekMixed": 1802, "GreekPrintedDummy": 1803,
        "GreekMixedDummy": 1804,
        "ThaiAuto": 1900, "ThaiPrinted": 1901, "ThaiMixed": 1902, "ThaiPrintedDummy": 1903, "ThaiMixedDummy": 1904,
        "HebrewAuto": 2000, "HebrewPrinted": 2001, "HebrewMixed": 2002, "HebrewPrintedDummy": 2003,
        "TamilAuto": 2100, "TamilPrinted": 2101, "TamilMixed": 2102, "TamilPrintedDummy": 2103,
    ]
    static let name = Dictionary(uniqueKeysWithValues: byName.map { ($1, $0) })
    static let autoScript: Set = [1109, 1403, 1500, 1600, 1700, 1800, 1900, 2000, 2100]
    static let latinV2: Set = [1106, 1107, 1108]
    static let cjk: Set = [1401, 1402, 1403]
    static let lineLayoutRequest: Set = [1401, 1402, 1403, 1001]
}

/// std::map<double, V>::lower_bound(x)->second, the last value past the end.
private struct LowerBoundMap {
    let keys: [Double], vals: [Int]

    init(_ pairs: [(Double, Int)]) {
        let s = pairs.sorted { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1 < $1.1) }
        keys = s.map(\.0)
        vals = s.map(\.1)
    }

    func callAsFunction(_ x: Double) -> Int {
        var lo = 0, hi = keys.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if keys[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return vals[min(lo, vals.count - 1)]
    }
}

/// The same for the float-valued calibration map.
private struct CalibrationMap {
    let keys: [Double], vals: [Double]

    func callAsFunction(_ x: Double) -> Double {
        var lo = 0, hi = keys.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if keys[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return vals[min(lo, vals.count - 1)]
    }
}

/// numpy's pairwise float32 sum (n <= 128).
func numpySum(_ a: [Float]) -> Float {
    let n = a.count
    if n < 8 {
        var res: Float = 0
        for v in a { res += v }
        return res
    }
    var r = Array(a[0..<8])
    var i = 8
    while i < n - n % 8 {
        for j in 0..<8 { r[j] += a[i + j] }
        i += 8
    }
    var res = ((r[0] + r[1]) + (r[2] + r[3])) + ((r[4] + r[5]) + (r[6] + r[7]))
    while i < n {
        res += a[i]
        i += 1
    }
    return res
}

private func sigmoid(_ x: Double) -> Double { 1 / (1 + exp(-x)) }

private func maxRun(_ seq: [Int], _ value: Int) -> Int {
    var best = 0, cur = 0
    for s in seq {
        cur = s == value ? cur + 1 : 0
        best = max(best, cur)
    }
    return best
}

/// The classifier input: 60 rows (at least 16 wide), CHW RGB / 255.
func classifierInput(_ line: ImageU8) throws -> MLMultiArray {
    let img = line.width < 16 ? CV.resizeLinear(line, 16, 60) : line
    let w = img.width, h = img.height
    let k = Float(1.0 / 255.0)
    return try makeInput(h, w) { dst in
        for c in 0..<3 {
            for i in 0..<(w * h) { dst[c * w * h + i] = Float(img.data[i * 3 + 2 - c]) * k }
        }
    }
}

final class TextAnalyzer: @unchecked Sendable {
    private static let auxScriptMap = ["NonText", "CJK", "Latin", "Cyrillic", "Arabic", "Devanagari", "Greek", "Thai",
                                       "Hebrew", "Tamil"].map { Script.byName[$0]! }
    private static let perframeScripts = ["CJK", "Cyrillic", "Arabic", "Devanagari", "Greek", "Thai", "Hebrew",
                                          "Tamil"].map { Script.byName[$0]! }

    private let aux: CoreMLModel, lineLayout: CoreMLModel
    /// The models' results for lines of recent readings (see LineCache).
    private let auxCache = LineCache<Info>(), lineLayoutCache = LineCache<Float>()
    private let earlyRej: Bool
    private let scriptThr: Double, nontextThr: Double
    private let hwpcMap: LowerBoundMap, flipMap: LowerBoundMap, llMap: LowerBoundMap
    private let hwpcFramesThr: Int
    private let scriptFramesThr: [Int: Int]
    private let calib: CalibrationMap
    private let hwThreshold: Double
    private var scriptToMode: [Int: Int] = [:], scriptCatToMode: [Int: [Int: Int]] = [:]
    private var modeToCategory: [Int: Int] = [:], modeToScript: [Int: Int] = [:]
    private(set) var modeToCharModel: [Int: String] = [:], modeToConfRej: [Int: String] = [:]

    init(files: ModelFiles, config cfg: [String: Any]) throws {
        guard let a = (cfg["aux_mlt_cls_model"] as? [[String: Any]])?.first,
              let ll = (cfg["line_layout_cls_model"] as? [[String: Any]])?.first,
              let em = cfg["enums_map"] as? [String: [[String: Any]]] else { throw OneOCRError("config.json is invalid") }
        aux = try files.model("AuxMltCls", units: .cpuOnly)
        lineLayout = try files.model("LineLayout_\(ll["name"] as? String ?? "CJK")", units: .cpuOnly)
        func num(_ d: [String: Any], _ k: String) -> Double {
            if let n = d[k] as? NSNumber { return n.doubleValue }
            if let s = d[k] as? String, let v = Double(s) { return v }
            return 0
        }
        earlyRej = ((cfg["rejection_option"] as? [String: Any])?["enable_early_rej"] as? Bool) ?? false
        scriptThr = num(a, "script_threshold")
        nontextThr = num(a, "non_text_script_threshold")
        let hmin = num(a, "hwpc_ambiguous_min"), hmax = num(a, "hwpc_ambiguous_max")
        hwpcMap = LowerBoundMap([(hmin, Category.printed), (hmax, Category.mixed), (.infinity, Category.handwritten)])
        flipMap = LowerBoundMap([(num(a, "flip_ambiguous_min"), Orientation.flipped),
                                 (num(a, "flip_ambiguous_max"), Orientation.unknown), (.infinity, Orientation.normal)])
        hwpcFramesThr = Int(num(a, "hwpc_consecutive_frames_threshold"))
        var sft: [Int: Int] = [:]
        for (k, v) in a["script_consecutive_frames_threshold"] as? [String: Any] ?? [:] {
            if let s = Script.byName[k] { sft[s] = Int((v as? String).flatMap(Double.init) ?? (v as? NSNumber)?.doubleValue ?? 0) }
        }
        scriptFramesThr = sft
        var ck: [(Double, Double)] = []
        if let path = a["hwpc_handwritten_calib_map_path"] as? String,
           let text = try? String(contentsOf: files.url(path), encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let p = line.split(whereSeparator: \.isWhitespace)
                if p.count == 2, let x = Double(p[0]), let y = Double(p[1]) { ck.append((x, y)) }
            }
        }
        guard !ck.isEmpty else { throw OneOCRError("The handwriting calibration map is missing") }
        ck.sort { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1 < $1.1) }
        calib = CalibrationMap(keys: ck.map(\.0), vals: ck.map(\.1))
        hwThreshold = calib(sigmoid((hmin + hmax) * 0.5))
        llMap = LowerBoundMap([(num(ll, "ambiguous_min"), LineLayout.vertical), (num(ll, "ambiguous_max"), LineLayout.unknown),
                               (.infinity, LineLayout.horizontal)])
        let sc = { (d: [String: Any]) in Script.byName[d["script"] as? String ?? "Unknown"] ?? 0 }
        let ca = { (d: [String: Any]) in Category.byName[d["category"] as? String ?? "Mixed"] ?? 0 }
        let mo = { (d: [String: Any]) in OCRMode.byName[d["mode"] as? String ?? "Auto"] ?? OCRMode.auto }
        for d in em["text_script_to_ocr_mode"] ?? [] { scriptToMode[sc(d)] = mo(d) }
        for d in em["text_script_category_to_ocr_mode"] ?? [] { scriptCatToMode[sc(d), default: [:]][ca(d)] = mo(d) }
        for d in em["ocr_mode_to_text_category"] ?? [] { modeToCategory[mo(d)] = ca(d) }
        for d in em["ocr_mode_to_text_script"] ?? [] { modeToScript[mo(d)] = sc(d) }
        for d in em["ocr_mode_to_char_model_path"] ?? [] { modeToCharModel[mo(d)] = d["path"] as? String }
        for d in em["ocr_mode_to_conf_rej_path"] ?? [] { modeToConfRej[mo(d)] = d["path"] as? String }
        guard scriptToMode[Script.unknown] != nil else { throw OneOCRError("config.json is invalid") }
    }

    private struct Info {
        var script: Int
        var probs: [Float]
        var category: Int
        var handwrittenProb: Double
        var isHandwritten: Bool
        var orientation: Int
        var flipProb: Double
    }

    private func scriptFromScores(_ s: ArraySlice<Float>) -> Int {
        var i = s.startIndex
        for j in s.indices where s[j] > s[i] { i = j }
        let sc = Self.auxScriptMap[i - s.startIndex]
        if !(earlyRej || sc != Script.nonText) { return sc }
        let thr = sc == Script.nonText ? nontextThr : scriptThr
        for j in s.indices where j != i && Self.auxScriptMap[j - s.startIndex] != sc {
            if Double(s[i]) - Double(s[j]) < thr { return Script.unknown }
        }
        return sc
    }

    private func runAux(_ img: ImageU8) throws -> Info {
        let o = try aux.predict(["data": classifierInput(img)])
        func get(_ k: String) throws -> (shape: [Int], data: [Float]) {
            guard let a = o[k] else { throw OneOCRError("AuxMltCls output \(k) missing") }
            return floats(a)
        }
        let sid = try get("script_id_score").data
        var script = scriptFromScores(sid[...])
        if script == Script.unknown {
            let f = try get("script_id_perframe_predict")
            let c = f.shape.last!, t = f.data.count / c
            let fs = (0..<t).map { scriptFromScores(f.data[($0 * c)..<($0 * c + c)]) }
            var best = Script.unknown, bestMargin = 0
            for sc in Self.perframeScripts {
                guard let thr = scriptFramesThr[sc] else { continue }
                let run = maxRun(fs, sc)
                if run > thr && run - thr > bestMargin {
                    best = sc
                    bestMargin = run - thr
                }
            }
            script = best
        }
        let mx = sid.dropFirst().reduce(sid[0]) { $1 > $0 ? $1 : $0 }
        let e = sid.map { expf($0 - mx) }
        let sum = numpySum(e)
        let probs = e.map { $0 / sum }
        let hw = Double(try get("hwpc_score").data[0])
        var cat = hwpcMap(hw)
        if cat == Category.printed {
            let f = try get("hwpc_perframe_predict")
            let c = f.shape.last!, t = f.data.count / c
            let seq = (0..<t).map { hwpcMap(Double(f.data[$0 * c] - f.data[$0 * c + 1])) }
            if maxRun(seq, Category.handwritten) > hwpcFramesThr { cat = Category.mixed }
        }
        let calibrated = calib(sigmoid(hw))
        let flip = Double(try get("flip_score").data[0])
        return Info(script: script, probs: probs, category: cat, handwrittenProb: calibrated,
                    isHandwritten: calibrated > hwThreshold, orientation: flipMap(flip), flipProb: sigmoid(flip))
    }

    private func voteUnknown(_ info: Info, _ hist: [Int: Int]) -> Int {
        var probs = info.probs
        var counts = hist
        probs[Self.auxScriptMap.firstIndex(of: Script.nonText)!] = 0
        counts[Script.nonText] = 0
        let total = counts.values.reduce(0, +) - (counts[Script.unknown] ?? 0)
        let denom = Double(max(total, 1))
        for (i, sc) in Self.auxScriptMap.enumerated() {
            probs[i] = probs[i] + Float(2.0 * Double(counts[sc] ?? 0) / denom)
        }
        var best = 0
        for i in probs.indices where probs[i] > probs[best] { best = i }
        return Self.auxScriptMap[best]
    }

    /// Analyzes all lines of one image.
    /// A reading is done (see LineCache).
    func endReading() {
        auxCache.endReading()
        lineLayoutCache.endReading()
    }

    func analyze(_ lines: [TextLine], mode: Int = OCRMode.auto) throws {
        let infos = try concurrentMap(lines.count) { i in
            let image = lines[i].lineImage
            return try auxCache.value(image.cacheKey()) { try runAux(image) }
        }
        var hist: [Int: Int] = [:]
        var nh = 0, fh = 0, nv = 0, fv = 0
        for (l, inf) in zip(lines, infos) {
            if mode == OCRMode.auto || inf.script == Script.nonText { l.script = inf.script }
            if mode == OCRMode.auto { hist[inf.script, default: 0] += 1 }
            l.orientation = inf.orientation
            if l.script != Script.nonText {
                if l.orientation == Orientation.normal {
                    if l.isHorizontal { nh += 1 } else { nv += 1 }
                } else if l.orientation == Orientation.flipped {
                    if l.isHorizontal { fh += 1 } else { fv += 1 }
                }
            }
        }
        for (l, inf) in zip(lines, infos) where l.script != Script.nonText {
            if mode != OCRMode.auto {
                l.ocrMode = mode
                l.script = modeToScript[mode] ?? Script.unknown
            } else {
                l.scriptUnknown = l.script == Script.unknown
                if l.scriptUnknown { l.script = voteUnknown(inf, hist) }
                l.ocrMode = scriptToMode[l.script] ?? scriptToMode[Script.unknown]!
            }
            if OCRMode.autoScript.contains(l.ocrMode) {
                l.category = inf.category
                l.handwrittenProb = inf.handwrittenProb
                l.ocrMode = scriptCatToMode[l.script]?[l.category] ?? l.ocrMode
            } else if OCRMode.latinV2.contains(l.ocrMode) {
                l.category = inf.category
                l.handwrittenProb = inf.handwrittenProb
            } else {
                l.category = modeToCategory[l.ocrMode] ?? Category.mixed
            }
            l.isHandwritten = inf.isHandwritten
            l.orientationAmbiguous = l.orientation == Orientation.unknown
            if l.orientationAmbiguous {
                let (n, f) = l.isHorizontal ? (nh, fh) : (nv, fv)
                let mx = Double(max(n, f))
                let bias = mx <= 3 ? 0.4 : (Double(n) - Double(f)) / mx
                l.orientation = bias + (inf.flipProb - 0.5) >= 0 ? Orientation.normal : Orientation.flipped
            }
        }
        for l in lines where l.script != Script.nonText && l.orientation == Orientation.flipped {
            l.lineImage = l.lineImage.rotated180()
        }
        if OCRMode.lineLayoutRequest.contains(mode) {
            let cjk = lines.filter { $0.script != Script.nonText && OCRMode.cjk.contains($0.ocrMode) }
            let scores = try concurrentMap(cjk.count) { i -> Float in
                let image = cjk[i].lineImage
                return try lineLayoutCache.value(image.cacheKey()) {
                    let o = try lineLayout.predict(["data": classifierInput(image)])
                    guard let s = o["line_layout_score"] else { throw OneOCRError("LineLayout output missing") }
                    return floats(s).data[0]
                }
            }
            var layoutScores = [ObjectIdentifier: Float]()
            for (l, s) in zip(cjk, scores) { layoutScores[ObjectIdentifier(l)] = s }
            var n1 = 0, n2 = 0
            for l in lines where l.script != Script.nonText {
                if let s = layoutScores[ObjectIdentifier(l)] {
                    l.layout = llMap(Double(s))
                    if l.layout == LineLayout.horizontal { n1 += 1 }
                    if l.layout == LineLayout.vertical { n2 += 1 }
                } else {
                    l.layout = LineLayout.horizontal
                }
                l.layoutAmbiguous = l.layout == LineLayout.unknown
            }
            for l in lines where l.layoutAmbiguous { l.layout = n1 > n2 ? LineLayout.horizontal : LineLayout.vertical }
        }
    }

    func charModelName(_ mode: Int) -> String? { modeToCharModel[mode] }
}
