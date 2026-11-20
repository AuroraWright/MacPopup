import Foundation

/// The encoder: encoder input frames to encoder output frames, carrying its state from call to call.
protocol FrameEncoder: AnyObject {
    func reset()
    func encode(_ frames: [[Float]]) throws -> [[Float]]
}

public struct SODAWord: Sendable, Equatable {
    /// With punctuation.
    public var text = ""
    /// As recognized.
    public var rawText = ""
    public var startMs = 0
    /// The word began at a bare word boundary piece: in packs punctuated by character, libsoda's final raw text puts
    /// no space before it.
    var joined = false
    /// Bytes at the start and end of rawText from marks of their own that joined it (a grammar's "(" or ","), which
    /// libsoda's punctuation model does not see.
    var marksBefore = 0, marksAfter = 0
}

public struct SODAResult: Sendable, Equatable {
    /// Punctuated, with spaces only where the script uses them.
    public var text = ""
    /// Unpunctuated, as `text`.
    public var rawText = ""
    public var startMs = 0
    public var endMs = 0
    public var words: [SODAWord] = []
}

/// A pack's casing stage: rewrites the recognized words one for one.
protocol WordStage {
    func apply(_ words: inout [String])
}

protocol Punctuating {
    /// Punctuates the words; `final`: after the last word too. `modelWords`: the words as the model sees them
    /// (without marks the grammars wrote).
    func punctuate(_ words: inout [String], final: Bool, modelWords: [String]?) throws
}

/// Recognizes a stretch of speech as opensoda's Recognizer does for Live Caption without a voice activity detector:
/// a final result at the end of the audio, and before it one wherever the model ends an utterance with </S> (which
/// the packs' Live Caption configs don't let it do).
final class SODARecognizer {
    private static let wordBoundary = "\u{2581}"

    let config: PipelineConfig
    private let mean: [Float], stddev: [Float]
    private let encoder: FrameEncoder
    private let search: BeamSearch
    private let decoder: PredictionNetwork
    /// en-US's second pass (cascaded encoder, its decoder and joint), which gives the finals.
    private let cascade: (encoder: FrameEncoder, search: BeamSearch, decoder: PredictionNetwork)?
    let symbols: [String]
    /// The punctuation settings segment text by whitespace (else by character, as in ja-JP), and their marks.
    private(set) var spacedWords = false
    private(set) var characterPartials = false
    private(set) var punctuationMarks: [String] = []
    var punctuator: Punctuating?
    /// Grammars before truecasing, the casing, and the grammars after it.
    var precaseDenormalizers: [TextNormalizer] = []
    var casing: WordStage?
    var denormalizers: [TextNormalizer] = []
    /// A ClassNormalizer rewrites class-tagged spans, so the class tags the model writes are kept as words.
    private var keepClassTags = false
    /// The first pass can end an utterance with </S>, which makes a final (and its search runs even with a second
    /// pass, which gives the finals).
    private var endsUtterances: Bool { config.decoder.eosID > 0 && config.decoder.eosPenalty > 0 }
    /// The ignored_resume_context_suffix's id.
    private let resumeSuffix: Int?

    /// `cascadeEncoder`: the second pass's encoder, for packs that have one. `punctuation`: run the pack's
    /// punctuation model.
    init(models: URL, config: PipelineConfig, symbols: [String], encoder: FrameEncoder, cascadeEncoder: FrameEncoder? = nil,
         punctuation: Bool = true) throws {
        self.config = config
        (mean, stddev) = try loadMeanStddev(models.appendingPathComponent(config.frontend.meanStddevFile))
        frontend = try Frontend(config.frontend, mean: mean, stddev: stddev)
        gain = GainControl(config.gainControl)
        self.encoder = encoder
        decoder = try PredictionNetwork(models.appendingPathComponent(config.decoder.decoderFile))
        let joint = try JointNetwork(models.appendingPathComponent(config.decoder.jointFile))
        search = BeamSearch(decoder: decoder, joint: joint, config: config.decoder)
        if let cascadeEncoder, !config.cascade.encoder.file.isEmpty {
            let c = config.cascade.decoder
            let decoder = try PredictionNetwork(models.appendingPathComponent(c.decoderFile))
            let joint = try JointNetwork(models.appendingPathComponent(c.jointFile))
            cascade = (cascadeEncoder, BeamSearch(decoder: decoder, joint: joint, config: c), decoder)
        } else {
            cascade = nil
        }
        self.symbols = symbols
        let suffix = config.decoder.ignoredResumeContextSuffix
        if suffix.isEmpty {
            resumeSuffix = nil
        } else {
            guard let id = symbols.firstIndex(of: suffix) else {
                throw SODAError("Unknown ignored_resume_context_suffix: '\(suffix)'")
            }
            resumeSuffix = id
        }
        // Words are written with spaces when the punctuation settings segment text by whitespace
        // (BasicTextSegmenterConfig field 3 = SIMPLE_WHITESPACE) rather than by character (ja-JP).
        if let settings = try? Data(contentsOf: models.appendingPathComponent("SODA_punctuation_config.pb")) {
            ProtoReader([UInt8](settings)).forEach { f in
                guard f.field == 7 else { return }
                ProtoReader(f.bytes).forEach { s in
                    if s.field == 1 { punctuationMarks.append(s.string) }
                    if s.field == 3 { spacedWords = s.int == 1 }
                }
            }
            // A pack without settings (th-TH) lists words.
            characterPartials = !spacedWords
        }
        // Like libsoda, a stage whose files are missing or unreadable is left out. Captions use no spoken punctuation
        // (none of the packs lists a pQRNN spoken punctuation normalizer for them).
        if punctuation { punctuator = try? Punctuator(models: models) }
        if !config.capitalizationTransducerFile.isEmpty && !config.capitalizationLMFile.isEmpty {
            casing = try? Truecaser(transducer: models.appendingPathComponent(config.capitalizationTransducerFile),
                                    lm: models.appendingPathComponent(config.capitalizationLMFile))
        } else if !config.capitalizationModelFile.isEmpty {
            casing = try? RoadrunnerCapitalizer(model: models.appendingPathComponent(config.capitalizationModelFile),
                                                window: config.capitalizationWindow, left: config.capitalizationLeft,
                                                right: config.capitalizationRight)
        }
        for d in config.denormalizers where d.spokenPunctuationSettings.isEmpty {
            guard let n = try? FstNormalizer(contentsOf: models.appendingPathComponent(d.file), classSpans: d.classNormalizer)
            else { continue }
            keepClassTags = keepClassTags || d.classNormalizer
            if d.beforeCapitalization { precaseDenormalizers.append(n) } else { denormalizers.append(n) }
        }
    }

    /// Receives each encoder output frame (pass 0: the encoder, 1: the cascaded encoder), for checks.
    var encoderTap: ((Int, [Float]) -> Void)?
    /// How recognize encodes a stretch: 0, as libsoda does audio arriving in 100 ms pieces (mostly 2 frames a call),
    /// with libsoda's results; more, the whole stretch's frames this many at a time. The int8 layers' activation scales
    /// then come from more frames, so results differ slightly (16: 105 of 1,000 Japanese clips by a few characters,
    /// as often better as worse, 13.51% vs 13.56% CER), but the encoder takes much less time (median 227 vs 340 ms).
    var wholeStretchBatch = 0

    // Streaming state (reset by `reset()`).
    private var frontend: Frontend
    private var gain: GainControl
    /// Encoder input frames not encoded yet, and their ends (in the front end's units).
    private var pending: [[Float]] = [], pendingEnds: [Int] = []
    private var takenEnds = 0
    private var firstBatch = true, backlog = 0
    /// Per first-pass encoder frame of the segment, its end; the last one; where the segment started.
    private var frameEnds: [Int] = []
    private var decodedEnd = 0, segmentStart = 0
    /// The stretch's finals so far.
    private(set) var finals: [SODAResult] = []
    /// The second pass: first-pass frames not encoded yet with their ends, outputs so far, their ends.
    private var cascadePending: [[Float]] = [], cascadeInputEnds: [Int] = [], lastFirstPassFrame: [Float] = []
    private var cascadeOutputs = 0
    private var cascadeEnds: [Int] = []

    /// Starts a new stretch of speech.
    func reset() {
        frontend = try! Frontend(config.frontend, mean: mean, stddev: stddev)
        gain = GainControl(config.gainControl)
        (pending, pendingEnds, takenEnds, firstBatch, backlog) = ([], [], 0, true, 0)
        (frameEnds, decodedEnd, segmentStart, finals) = ([], 0, 0, [])
        (cascadePending, cascadeInputEnds, lastFirstPassFrame, cascadeOutputs, cascadeEnds) = ([], [], [], 0, [])
        encoder.reset()
        search.reset()
        decoder.clearCache()
        if let cascade {
            cascade.encoder.reset()
            cascade.search.reset()
            cascade.decoder.clearCache()
        }
    }

    /// Takes 16 kHz samples on the 16-bit scale, encoding and decoding the frames that are ready.
    func accept(_ samples: [Float], encoding: Bool = true) throws {
        var audio = samples
        gain.process(&audio)
        var frames: [[Float]] = []
        frontend.accept(audio, into: &frames)
        enqueue(frames)
        if encoding { try runEncoder(flush: false) }
    }

    /// The stretch's result, once all its samples are in: its finals (`finals`) joined.
    func finish() throws -> SODAResult {
        var frames: [[Float]] = []
        frontend.flush(into: &frames)
        enqueue(frames)
        try runEncoder(flush: true)
        try emitFinal(endOfAudio: true)
        guard let last = finals.last else { return SODAResult() }
        let said = finals.filter { !$0.words.isEmpty }
        guard finals.count > 1, let first = said.first else { return last }
        let separator = spacedWords ? " " : ""
        return SODAResult(text: said.map(\.text).joined(separator: separator),
                          rawText: said.map(\.rawText).joined(separator: separator),
                          startMs: first.startMs, endMs: last.endMs, words: said.flatMap(\.words))
    }

    /// opensoda's EmitFinal: the segment's final result, then a new segment from where it ended. A final before the end
    /// of the audio is left out if it has no text.
    private func emitFinal(endOfAudio: Bool) throws {
        let best: Hypothesis, ends: [Int]
        if let cascade {
            // EncoderInsertRightContextStream: at a segment end, rightContext copies of the last frame (or zeros) let
            // the last frames through.
            try runCascade(flush: true)
            if !cascadeInputEnds.isEmpty {
                let pad = config.cascade.useLastFrame ? lastFirstPassFrame : [Float](repeating: 0, count: lastFirstPassFrame.count)
                cascadePending += repeatElement(pad, count: config.cascade.rightContext)
                try runCascade(flush: true)
            }
            (best, ends) = (cascade.search.best, cascadeEnds)
        } else {
            (best, ends) = (search.best, frameEnds)
        }
        var result = try describe(best, frameEnds: ends, frameMs: Int(config.frontend.encoderFrameMs))
        if endOfAudio || result.rawText.contains(where: { $0 != " " && $0 != "\n" }) {
            result.endMs = decodedEnd
            // Like libsoda, a result starts at its first word.
            result.startMs = max(segmentStart, result.words.first?.startMs ?? segmentStart)
            finals.append(result)
        }
        if config.decoder.resumeSearch && !endOfAudio { search.resume(ignoredSuffix: resumeSuffix) } else { search.reset() }
        if let cascade {
            cascade.encoder.reset()
            cascade.search.reset()
            (cascadePending, cascadeInputEnds, cascadeOutputs, cascadeEnds) = ([], [], 0, [])
        }
        segmentStart = decodedEnd
        frameEnds = []
    }

    /// 16 kHz samples on the 16-bit scale, fed in 100 ms chunks as opensoda's tests do.
    func recognize(_ samples: [Float]) throws -> SODAResult {
        reset()
        for start in stride(from: 0, to: samples.count, by: 1600) {
            try accept(Array(samples[start..<min(start + 1600, samples.count)]), encoding: wholeStretchBatch == 0)
        }
        return try finish()
    }

    private func enqueue(_ frames: [[Float]]) {
        pending += frames
        pendingEnds += frontend.ends[takenEnds..<(takenEnds + frames.count)]
        takenEnds += frames.count
    }

    /// libsoda's CausalEncoderStream batching: the smallest time batch size that the ready frames fill, or at the
    /// end, the largest flush size that fits (0: wait for more frames).
    private static func batchSize(_ e: PipelineConfig.Encoder, _ ready: Int, closed: Bool) -> Int {
        var n = e.timeBatchSizes.filter { $0 <= ready }.min() ?? 0
        if n == 0 && closed { n = e.flushBatchSizes.filter { $0 <= ready }.max() ?? 0 }
        return n
    }

    private func runEncoder(flush: Bool) throws {
        while !pending.isEmpty {
            let ready = pending.count
            var n = Self.batchSize(config.encoder, ready, closed: flush)
            if wholeStretchBatch > 0 && flush {
                n = wholeStretchBatch
            // Where the segmenter gates 10 ms frames (ko-KR, hi-IN, pt-BR, cmn-Hans-CN), libsoda's encoder encodes
            // the smallest batch first and then the largest batches that fit the backlog (opensoda's RunEncoder).
            } else if firstBatch && n > 0 && config.frontend.subsampleAfterGate {
                backlog = ready - n
            } else if backlog > 0 && n > 0 {
                for b in config.encoder.timeBatchSizes where b <= backlog { n = max(n, b) }
                backlog -= min(backlog, n)
            }
            n = min(n, ready)
            if n == 0 { break }
            firstBatch = false
            let chunk = Array(pending[..<n]), ends = Array(pendingEnds[..<n])
            pending.removeFirst(n)
            pendingEnds.removeFirst(n)
            let encoded = try encoder.encode(chunk)
            for (i, frame) in encoded.enumerated() {
                encoderTap?(0, frame)
                decodedEnd = Int(Float(ends[min(i, ends.count - 1)]) * frontend.stackedFrameMs)
                frameEnds.append(decodedEnd)
                // Finals come from the second pass, so unless it can end utterances, the first pass's search isn't
                // run.
                if cascade == nil || endsUtterances { try search.advance(frame) }
                if cascade != nil {
                    lastFirstPassFrame = frame
                    cascadePending.append(frame)
                    cascadeInputEnds.append(decodedEnd)
                    try runCascade(flush: false)
                }
                if endsUtterances, search.best.labels.last == config.decoder.eosID {
                    // The model ended the utterance with </S>.
                    try emitFinal(endOfAudio: false)
                }
            }
        }
    }

    /// libsoda's EncoderUnshiftStream: the cascaded encoder's output for a frame comes rightContext frames later and
    /// takes that frame's time.
    private func runCascade(flush: Bool) throws {
        guard let cascade else { return }
        let right = config.cascade.rightContext
        while !cascadePending.isEmpty {
            let n = Self.batchSize(config.cascade.encoder, cascadePending.count, closed: flush)
            if n == 0 { break }
            let chunk = Array(cascadePending[..<n])
            cascadePending.removeFirst(n)
            for frame in try cascade.encoder.encode(chunk) {
                encoderTap?(1, frame)
                let k = cascadeOutputs
                cascadeOutputs += 1
                if k < right { continue }
                try cascade.search.advance(frame)
                cascadeEnds.append(cascadeInputEnds[k - right])
            }
        }
    }

    private func isTag(_ s: String) -> Bool { s.count > 2 && s.hasPrefix("<") && s.hasSuffix(">") }

    func labelsToText(_ labels: [Int]) -> String {
        var text = ""
        for id in labels where id > 0 && id < symbols.count {
            let s = symbols[id]
            if isTag(s) { continue }
            if s.hasPrefix(Self.wordBoundary) {
                text += " " + s.dropFirst()
            } else {
                text += s
            }
        }
        return Self.glueSpacelessScripts(text)
    }

    /// Scripts written without spaces between words (CJK, kana, fullwidth forms).
    static func isSpaceless(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        return (0x2E80...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v) || (0xFF00...0xFFEF).contains(v)
            || (0x20000...0x2FFFF).contains(v)
    }

    /// Removes spaces next to characters of spaceless scripts, and at the ends.
    static func glueSpacelessScripts(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        for (k, c) in scalars.enumerated() {
            if c == " " {
                let previous = k > 0 && isSpaceless(scalars[k - 1])
                let next = k + 1 < scalars.count && isSpaceless(scalars[k + 1])
                if previous || next || out.isEmpty || k + 1 == scalars.count { continue }
            }
            out.append(c)
        }
        return String(out)
    }

    /// Whether two adjacent words are written without a space between them.
    static func glueWords(_ left: String, _ right: String) -> Bool {
        guard let l = left.unicodeScalars.last, let r = right.unicodeScalars.first else { return true }
        return isSpaceless(l) || isSpaceless(r)
    }

    /// The raw text of words: in packs punctuated by character, no space before a word that began at a bare word
    /// boundary; elsewhere the scripts decide.
    private func joinRaw(_ words: [SODAWord]) -> String {
        var text = ""
        for (i, w) in words.enumerated() {
            let glue = characterPartials && w.joined
            if i > 0 && !glue && !Self.glueWords(words[i - 1].rawText, w.rawText) { text += " " }
            text += w.rawText
        }
        return text
    }

    /// A final result's words and text from a hypothesis whose label frames end at `frameEnds`.
    private func describe(_ h: Hypothesis, frameEnds: [Int], frameMs: Int) throws -> SODAResult {
        var e = SODAResult(rawText: labelsToText(h.labels))
        // Words start at pieces carrying the boundary marker.
        var current: Int?
        for (i, id) in h.labels.enumerated() where id > 0 && id < symbols.count {
            let s = symbols[id]
            if isTag(s) {
                if keepClassTags && FstNormalizer.classTag(s.utf8) != nil {
                    // The next word's start.
                    e.words.append(SODAWord(rawText: s, startMs: -1))
                    current = nil
                }
                continue
            }
            let boundary = s.hasPrefix(Self.wordBoundary)
            if boundary || current == nil {
                e.words.append(SODAWord(startMs: -1, joined: s == Self.wordBoundary))
                current = e.words.count - 1
            }
            // libsoda starts a word at the start of the frame where the label before its first piece of text was
            // emitted (a bare word boundary is a label of its own), and the first label of a segment at its start.
            if e.words[current!].startMs < 0 && s != Self.wordBoundary {
                var start = segmentStart
                if i > 0 && !frameEnds.isEmpty {
                    start = max(segmentStart, frameEnds[min(h.labelFrames[i - 1], frameEnds.count - 1)] - frameMs)
                }
                e.words[current!].startMs = start
            }
            e.words[current!].rawText += boundary ? String(s.dropFirst()) : s
        }
        // A trailing bare boundary or class tag.
        for i in e.words.indices.reversed() where e.words[i].startMs < 0 {
            e.words[i].startMs = i + 1 < e.words.count ? e.words[i + 1].startMs : decodedEnd
        }
        if e.words.isEmpty { return e }
        if characterPartials { e.rawText = joinRaw(e.words) }
        // The config's denormalizer list fixes the order: grammars listed before the capitalization normalizer see the
        // words before truecasing.
        if !precaseDenormalizers.isEmpty {
            denormalize(precaseDenormalizers, &e.words)
            e.rawText = joinRaw(e.words)
        }
        if let casing, !e.words.isEmpty {
            var cased = e.words.map(\.rawText)
            casing.apply(&cased)
            for i in cased.indices where i < e.words.count { e.words[i].rawText = cased[i] }
            e.rawText = joinRaw(e.words)
        }
        if !denormalizers.isEmpty && !e.words.isEmpty {
            denormalize(denormalizers, &e.words)
            e.rawText = joinRaw(e.words)
        }

        var words = e.words.map(\.rawText)
        let modelWords = e.words.map { w -> String in
            let raw = Array(w.rawText.utf8), marks = w.marksBefore + w.marksAfter
            return marks < raw.count ? String(decoding: raw[w.marksBefore..<(raw.count - w.marksAfter)], as: UTF8.self) : w.rawText
        }
        try punctuator?.punctuate(&words, final: true, modelWords: modelWords)
        for (i, w) in words.enumerated() {
            e.words[i].text = w
            if i > 0 && !Self.glueWords(words[i - 1], w) { e.text += " " }
            e.text += w
        }
        return e
    }
}

extension SODARecognizer {
    /// Applies grammars to a final's words joined by spaces, and carries the words' starts over to the words of the
    /// output (opensoda's DenormalizeText).
    func denormalize(_ normalizers: [TextNormalizer], _ words: inout [SODAWord]) {
        guard !normalizers.isEmpty, !words.isEmpty else { return }
        var text = Array(words.map(\.rawText).joined(separator: " ").utf8)
        let before = text
        // As libsoda formats them, closing marks join the word before and opening brackets the word after.
        let closing = Array(",.?!;:%)]}".utf8), opening = Array("([{".utf8)
        func only(_ t: some Collection<UInt8>, _ set: [UInt8]) -> Bool { !t.isEmpty && t.allSatisfy(set.contains) }
        func isMark(_ t: some Collection<UInt8>) -> Bool { only(t, closing) || only(t, opening) }
        // The text before the grammars that only take out spaces (the last one joins dictated marks to their words,
        // "Hello ," to "Hello,"): libsoda keeps those marks apart from the words its punctuation model sees.
        func noSpaces(_ s: [UInt8]) -> [UInt8] { s.filter { $0 != 32 } }
        var split: [UInt8] = []
        for d in normalizers {
            let next = d.apply(text)
            if next != text {
                if noSpaces(next) != noSpaces(text) {
                    split = []
                } else if split.isEmpty {
                    split = text
                }
            }
            text = next
        }
        if text == before { return }
        // Which of the text's bytes are of a token of marks in `split`.
        var mark = [Bool](repeating: false, count: text.count)
        if !split.isEmpty {
            var s = 0
            for i in text.indices where text[i] != 32 {
                while s < split.count && split[s] == 32 { s += 1 }
                guard s < split.count else { break }
                let from = split[..<s].lastIndex(of: 32).map { $0 + 1 } ?? 0
                let to = split[s...].firstIndex(of: 32) ?? split.count
                mark[i] = isMark(split[from..<to])
                s += 1
            }
        }
        // libsoda drops a paragraph or line break ("{new-paragraph}" in dictation) and the spaces around it in a
        // final, joining the words, and capitalizes the next word.
        var at = text.firstIndex(of: 10)
        while let i = at {
            var a = i, b = i
            while a > 0 && (text[a - 1] == 32 || text[a - 1] == 10) { a -= 1 }
            while b < text.count && (text[b] == 32 || text[b] == 10) { b += 1 }
            if b < text.count && text[b] >= 97 && text[b] <= 122 { text[b] -= 32 }
            text.removeSubrange(a..<b)
            mark.removeSubrange(a..<b)
            at = text[a...].firstIndex(of: 10)
        }
        var tokens: [[UInt8]] = []
        var tokenMarks: [(start: Int, end: Int)] = []  // Mark bytes at each token's start and end.
        var i = 0
        while i <= text.count {
            let j = text[i...].firstIndex(of: 32) ?? text.count
            if j > i {
                tokens.append(Array(text[i..<j]))
                var f = i, l = j
                while f < j && mark[f] { f += 1 }
                while l > f && mark[l - 1] { l -= 1 }
                tokenMarks.append((f - i, j - l))
            }
            i = j + 1
        }
        // Word starts carry over through the longest common subsequence of the words. Between kept words, as many new
        // words as replaced ones take theirs one for one (hi-IN's transliteration of its romanized words); otherwise a
        // new word starts where the first word it replaced did.
        let raw = words.map { Array($0.rawText.utf8) }
        let n = words.count, m = tokens.count
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in (0..<n).reversed() {
            for j in (0..<m).reversed() {
                lcs[i][j] = raw[i] == tokens[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var starts = [Int](repeating: 0, count: m)
        var joined = [Bool](repeating: false, count: m)  // Only the first word replacing several stays joined.
        var gapWord = 0, gapToken = 0  // Where the current replaced stretch begins.
        func fillGap(_ wordEnd: Int, _ tokenEnd: Int) {
            let oneForOne = wordEnd - gapWord == tokenEnd - gapToken
            for j in gapToken..<max(gapToken, tokenEnd) {
                let w = words[min(oneForOne ? gapWord + (j - gapToken) : gapWord, n - 1)]
                starts[j] = w.startMs
                joined[j] = (oneForOne || j == gapToken) && w.joined
            }
        }
        var wi = 0, tj = 0
        while tj < m || wi < n {
            if wi < n && tj < m && raw[wi] == tokens[tj] {
                fillGap(wi, tj)
                joined[tj] = words[wi].joined
                starts[tj] = words[wi].startMs
                wi += 1
                tj += 1
                (gapWord, gapToken) = (wi, tj)
            } else if wi < n && (tj == m || lcs[wi + 1][tj] >= lcs[wi][tj + 1]) {
                wi += 1  // A replaced word.
            } else {
                tj += 1  // A new word.
            }
        }
        fillGap(n, m)
        var out: [(raw: [UInt8], word: SODAWord)] = []
        var prefix: [UInt8] = []
        for (j, t) in tokens.enumerated() {
            if only(t, opening) {
                prefix += t
                continue
            }
            if !out.isEmpty && only(t, closing) {
                out[out.count - 1].raw += prefix + t
                out[out.count - 1].word.marksAfter += prefix.count + t.count
            } else {
                var w = SODAWord(startMs: starts[j], joined: joined[j])
                w.marksBefore = prefix.count + tokenMarks[j].start
                w.marksAfter = tokenMarks[j].end
                out.append((prefix + t, w))
            }
            prefix = []
        }
        if !prefix.isEmpty {
            if out.isEmpty {
                out.append((prefix, SODAWord(text: String(decoding: prefix, as: UTF8.self), startMs: words[0].startMs)))
            } else {
                out[out.count - 1].raw += prefix
                out[out.count - 1].word.marksAfter += prefix.count
            }
        }
        words = out.map { o in
            var w = o.word
            w.rawText = String(decoding: o.raw, as: UTF8.self)
            return w
        }
    }
}

/// Encoder outputs computed elsewhere (opensoda's, for checking the rest of the port).
final class RecordedEncoder: FrameEncoder {
    private let frames: [[Float]]
    private var used = 0

    init(_ frames: [[Float]]) { self.frames = frames }

    func reset() { used = 0 }

    func encode(_ input: [[Float]]) throws -> [[Float]] {
        let n = min(input.count, frames.count - used)
        defer { used += n }
        return Array(frames[used..<used + n])
    }
}
