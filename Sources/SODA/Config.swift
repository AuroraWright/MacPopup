import Foundation

/// A pack's recognizer, as its config (configs/*.config, a binary greco.PipelineDef) describes it: streams such as
/// Framer, FilterBank, FrameStacker, CausalEncoderStream and the decoder, and resources naming the model files. Only
/// what captions use is read (no voice activity detection, language identification, biasing or dictation stages);
/// defaults are the protos'.
struct PipelineConfig {
    struct FrameStack {
        var inputSize = 0
        var leftContext = 0
        var rightContext = 0
        var zeroPadding = false
        /// From the SubsampleStream after the stacker.
        var subsample = 1
        var span: Int { leftContext + 1 + rightContext }
    }

    struct Frontend {
        var frameSizeMs: Float = 25
        var frameStepMs: Float = 10
        var preemphasis: Float = 0.97
        /// greco.WindowParams.WindowType; 1 = HANNING.
        var windowType = 1
        var noiseScale: Float = 0
        var windowSizeMs: Float = 25
        var fftInputLengthMs = 25
        var minFftSize = 512
        var fftOverdrive = false
        var channelCount = 80
        var upperBandLimit: Float = 7500
        var lowerBandLimit: Float = 125
        var fbankOutputFloor: Float = 1
        /// Stacking before normalization, and the stacking layer after it.
        var stack1 = FrameStack(inputSize: 80, leftContext: 2, rightContext: 0, zeroPadding: false, subsample: 3)
        var stack2 = FrameStack(inputSize: 241, leftContext: 0, rightContext: 1, zeroPadding: true, subsample: 2)
        /// The AppendClusterIdStream's id on the encoder path (-1: none).
        /// The first SubsampleStream comes after the segmenter (ko-KR, hi-IN, pt-BR, cmn-Hans-CN): libsoda then
        /// subsamples the frames it passes, dating each by the last 10 ms frame it stands for, and the flush by the
        /// last frame.
        var subsampleAfterGate = false
        var clusterID = -1
        var meanStddevFile = ""

        /// Milliseconds of audio an encoder frame stands for.
        var encoderFrameMs: Float { frameStepMs * Float(stack1.subsample * stack2.subsample) }
    }

    struct Decoder {
        var sosID = 1
        var eosID = 2
        /// Multiplies P(</S>); CONTINUOUS configs set 0, never ending on </S>.
        var eosPenalty: Float = 1
        /// FstDecoderParams.enable_resume_search: after a final mid-stretch, the search goes on from the last labels
        /// (CONTINUOUS sets it) instead of from <S>.
        var resumeSearch = false
        /// FstDecoderParams.ignored_resume_context_suffix: a symbol a resumed search drops from the end of its context
        /// (the en-US SHORT configs name </S> but leave resume off).
        var ignoredResumeContextSuffix = ""
        var smoothingTemperature: Float = 1
        var decoderInitialValue = 1
        // FstSearchParams.
        var maxArcs = 3
        var minArcs = 0
        var localBeam: Float = 5
        var histogramScale: Float = 5
        var histogramBuckets = 100
        var wordPenalty: Float = 0
        // DualSearchParams: labels costlier than maxModelCost are not expanded (0: no limit); a frame expands labels at
        // most maxExpansions - 1 times.
        var maxModelCost: Float = 0
        var maxExpansions = 100
        var pruneOnMinCost = false
        var decoderFile = ""
        var jointFile = ""
    }

    struct Encoder {
        var file = ""
        /// CausalEncoderStream batches (the time_batch_sizes, and on flush).
        var timeBatchSizes = [2, 4, 8]
        var flushBatchSizes = [1]
        /// Encoders with a domain_id input: the recognition domain's id, else the default (-1: no such input).
        var domainIDs: [String: Int] = [:]
        var defaultDomainID = -1
    }

    /// en-US's second, non-causal pass over the first encoder's outputs, which gives the final results.
    struct Cascade {
        var encoder = Encoder()
        /// Frames of lookahead; at the end the last frame is repeated (or zeros).
        var rightContext = 0
        var useLastFrame = false
        var decoder = Decoder()
    }

    /// greco.AutoGainControlParams (the SAMPLE_LEVEL_TARGET_RANGE estimator).
    struct GainControl {
        var activated = false
        var estimator = 3
        var delayMs = 8
        var attackWindowMs = 0
        var halfLifeSeconds: Float = 2
        var floor: Float = 0.004
        var curvature: Float = 0.03
        var levelTarget: Float = 0.6
        var lowerLevelTarget: Float = 0.075
        var gainScale: Float = 1.2
        var lowerTargetTransition: Float = 20
    }

    /// One of the denormalizer list's byte-level grammars (an FstNormalizer or ClassNormalizer .mfar).
    struct Denormalizer {
        var file: String
        /// Listed before the capitalization normalizer, so it sees the words before truecasing.
        var beforeCapitalization: Bool
        /// A ClassNormalizer: rewrites class-tagged spans only.
        var classNormalizer: Bool
        /// A PortablePqrnnSpokenPunctuationNormalizer's SpokenPunctuationInferenceSettings (`file` is its model).
        var spokenPunctuationSettings: [UInt8] = []
    }

    var gainControl = GainControl()
    var frontend = Frontend()
    var decoder = Decoder()
    var encoder = Encoder()
    /// encoder.file is empty without a second pass.
    var cascade = Cascade()
    var symbolsFile = ""
    /// The encoder path's AppendClusterIdStream.domain_name_to_internal_id.
    var clusterIDByDomain: [String: Int] = [:]
    /// GeneralCapitalizationNormalizer: case variants per word and an n-gram LM choosing among them.
    var capitalizationTransducerFile = ""
    var capitalizationLMFile = ""
    /// RuntimeRoadrunnerCapitalizationNormalizer: a TFLite model casing words in windows.
    var capitalizationModelFile = ""
    var capitalizationWindow = 5
    var capitalizationLeft = 1
    var capitalizationRight = 1
    /// The denormalizers captions apply (untyped ones), in order.
    var denormalizers: [Denormalizer] = []
    /// The denormalizer list's PunctuationNormalizer type (spoken punctuation; 3 for dictation only).
    var spokenPunctuationType: Int?

    // Extension field numbers of greco.Params (and nested extension points), from libsoda's descriptors.
    private enum Extension {
        static let framer = 18_905_525, window = 18_905_515, fft = 18_905_514, filterBank = 18_905_716
        static let frameStacker = 19_077_915, subsample = 3_328_023, appendClusterID = 247_260_833
        static let frameNormalize = 332_044_632, encoderStream = 320_100_746, rightContext = 39_816_938
        static let domainIDMapping = 98179, tfLiteSession = 307_419_518, proto = 23_431_063
        static let sessionRuntime = 399_795_227, dualSearch = 171_805_764, capitalization = 331_244_104
        static let fstNormalizer = 27_845_124, denormalizerList = 329_822_714, symbolTable = 98173
        static let pqrnnSpokenPunctuation = 387_838_176
        static let autoGainControl = 27_582_545, decoder = 19_583_231, fstDecoder = 41_039_125
        static let pieRnnFstDecoder = 194_955_910, tfliteTransducer = 213_412_442
    }

    private struct Def {
        var name = "", classname = ""
        var params: ProtoReader?
        var paramsRefs: [String] = []
    }

    /// Reads configs/<name>.config; nil if it isn't a pipeline with an end-to-end transducer.
    init(contentsOf url: URL) throws {
        let data = [UInt8](try Data(contentsOf: url))
        var streams: [Def] = []
        var resources: [String: Def] = [:]
        var reader = ProtoReader(data)
        while reader.next() {
            guard reader.field == 1 || reader.field == 3 || reader.field == 5 else { continue }
            var def = Def()
            reader.message.forEach { f in
                switch f.field {
                case 1: def.name = f.string
                case 2: def.classname = f.string
                case 3: def.params = f.message
                case 4: def.paramsRefs.append(f.string)
                default: break
                }
            }
            if reader.field == 1 { streams.append(def) } else { resources[def.name] = def }
        }
        guard reader.ok, !streams.isEmpty else { throw SODAError("malformed pipeline config \(url.lastPathComponent)") }

        var refs: [String: String] = [:], cascadeRefs: [String: String] = [:]
        var encoderRef = "", cascadeEncoderRef = "", meanStddevRef = ""
        var encoderDomainsRef = "", cascadeDomainsRef = ""
        var stackersSeen = 0, encodersSeen = 0, decodersSeen = 0
        var afterNormalize = false, segmenterSeen = false
        for s in streams {
            // The voice activity branch shares the classes but isn't on the encoder path.
            if s.name.hasPrefix("vad.") { continue }
            if s.classname == "AutoGainControl" {
                Self.parseGainControl(s.params.find(Extension.autoGainControl), &gainControl)
                continue
            }
            // Parameters may sit in the stream itself or in referenced Params resources.
            for p in [s.params] + s.paramsRefs.map({ resources[$0]?.params }) {
                switch s.classname {
                case "Framer": Self.parseFramer(p.find(Extension.framer), &frontend)
                case "Window": Self.parseWindow(p.find(Extension.window), &frontend)
                case "Fft": Self.parseFft(p.find(Extension.fft), &frontend)
                case "FilterBank":
                    Self.parseFilterBank(p.find(Extension.filterBank), &frontend)
                    Self.parseFft(p.find(Extension.fft), &frontend)
                default: break
                }
            }
            switch s.classname {
            case "SegmenterStream":
                segmenterSeen = true
            case "FrameStacker":
                var stack = FrameStack(inputSize: 13, leftContext: 4)
                s.params.find(Extension.frameStacker).forEach { f in
                    switch f.field {
                    case 2: stack.inputSize = f.int
                    case 3: stack.leftContext = f.int
                    case 4: stack.rightContext = f.int
                    case 7: stack.zeroPadding = f.bool
                    default: break
                    }
                }
                if stackersSeen == 0 { frontend.stack1 = stack } else { frontend.stack2 = stack }
                stackersSeen += 1
            case "SubsampleStream":
                var stride = 1
                s.params.find(Extension.subsample).forEach { f in if f.field == 1 { stride = f.int } }
                if stackersSeen <= 1 { frontend.stack1.subsample = stride } else { frontend.stack2.subsample = stride }
                if stackersSeen <= 1 && segmenterSeen { frontend.subsampleAfterGate = true }
            case "FrameNormalizeStream":
                meanStddevRef = s.params.find(Extension.frameNormalize).firstString(1)
                afterNormalize = true
            case "AppendClusterIdStream" where afterNormalize:
                s.params.find(Extension.appendClusterID).forEach { f in
                    if f.field == 1 { frontend.clusterID = f.int }
                    if f.field == 4, let (key, value) = Self.entry(f.message) { clusterIDByDomain[key] = value }
                }
            case "CausalEncoderStream":
                let p = s.params.find(Extension.encoderStream)
                if encodersSeen == 0 {
                    Self.parseEncoder(p, &encoder, &encoderRef, &encoderDomainsRef)
                } else {
                    Self.parseEncoder(p, &cascade.encoder, &cascadeEncoderRef, &cascadeDomainsRef)
                }
                encodersSeen += 1
            case "EncoderInsertRightContextStream":
                s.params.find(Extension.rightContext).forEach { f in
                    if f.field == 1 { cascade.rightContext = f.int }
                    if f.field == 2 { cascade.useLastFrame = f.bool }
                }
            case "DecoderEndpointerStream", "DecoderStream":
                let p = s.params.find(Extension.decoder)
                if decodersSeen == 0 {
                    Self.parseDecoder(p, &decoder, &refs)
                    let symbols = p.firstString(3)
                    if !symbols.isEmpty { refs["symbols"] = symbols }
                } else {
                    Self.parseDecoder(p, &cascade.decoder, &cascadeRefs)
                }
                decodersSeen += 1
            default: break
            }
        }

        func filename(_ ref: String?, _ ext: Int) -> String {
            guard let ref, let params = resources[ref]?.params else { return "" }
            let p = params.find(ext)
            var name = p.firstString(1)
            if name.isEmpty, ext == Extension.tfLiteSession {
                // Newer configs name the file in a SessionResourceRuntimeParams resource
                // (TfLiteSessionParams.session_resource_runtime_params_ref = 14).
                name = resources[p.firstString(14)]?.params.find(Extension.sessionRuntime).firstString(1) ?? ""
            }
            return name
        }
        func domainIDs(_ ref: String, _ e: inout Encoder) {
            guard let params = resources[ref]?.params else { return }
            e.defaultDomainID = 0
            params.find(Extension.domainIDMapping).forEach { f in
                if f.field == 2 { e.defaultDomainID = f.int }
                if f.field == 1, let (key, value) = Self.entry(f.message) { e.domainIDs[key] = value }
            }
        }
        func searchParams(_ ref: String?, _ d: inout Decoder) {
            // FstSearchParams is the only extension in that Params message.
            guard let ref, let params = resources[ref]?.params else { return }
            params.forEach { f in if f.wireType == .lengthDelimited { Self.parseSearch(f.message, &d) } }
        }
        encoder.file = filename(encoderRef, Extension.tfLiteSession)
        domainIDs(encoderDomainsRef, &encoder)
        decoder.decoderFile = filename(refs["decoder"], Extension.tfLiteSession)
        decoder.jointFile = filename(refs["joint"], Extension.tfLiteSession)
        symbolsFile = filename(refs["symbols"], Extension.symbolTable)
        frontend.meanStddevFile = filename(meanStddevRef, Extension.proto)
        searchParams(refs["search"], &decoder)
        if !cascadeEncoderRef.isEmpty, decodersSeen > 1 {
            cascade.encoder.file = filename(cascadeEncoderRef, Extension.tfLiteSession)
            domainIDs(cascadeDomainsRef, &cascade.encoder)
            cascade.decoder.decoderFile = filename(cascadeRefs["decoder"], Extension.tfLiteSession)
            cascade.decoder.jointFile = filename(cascadeRefs["joint"], Extension.tfLiteSession)
            searchParams(cascadeRefs["search"], &cascade.decoder)
            if cascade.decoder.decoderFile.isEmpty || cascade.decoder.jointFile.isEmpty { cascade.encoder.file = "" }
        }

        let isCapitalization = { (classname: String) in
            classname == "GeneralCapitalizationNormalizer" || classname == "RuntimeRoadrunnerCapitalizationNormalizer"
        }
        for def in resources.values where isCapitalization(def.classname) {
            // Both classes keep their fields in one params message: 1 and 2 for the general normalizer, 12 and up for
            // the Roadrunner model.
            def.params.find(Extension.capitalization).forEach { f in
                switch f.field {
                case 1: capitalizationTransducerFile = f.string
                case 2: capitalizationLMFile = f.string
                case 12: capitalizationModelFile = f.string
                case 14: capitalizationWindow = f.int
                case 15: capitalizationLeft = f.int
                case 16: capitalizationRight = f.int
                default: break
                }
            }
        }
        // The resources holding a DenormalizerResourceList {1: {1: resource_name, 2: denormalizer_type}}. Captions
        // apply its untyped FstNormalizer and ClassNormalizer grammars; spoken punctuation and emoji (types 3 and 4)
        // are for dictation, and the offensive-word masker (1) is off.
        for name in resources.keys.sorted() {
            guard let list = resources[name]?.params.find(Extension.denormalizerList) else { continue }
            var listed: [(resource: String, type: Int)] = []
            list.forEach { f in
                guard f.field == 1 else { return }
                var entry = (resource: "", type: 0)
                f.message.forEach { e in
                    if e.field == 1 { entry.resource = e.string }
                    if e.field == 2 { entry.type = e.int }
                }
                listed.append(entry)
            }
            var capitalizationAhead = listed.contains { resources[$0.resource].map { isCapitalization($0.classname) } ?? false }
            for (resource, type) in listed {
                guard let def = resources[resource] else { continue }
                if isCapitalization(def.classname) { capitalizationAhead = false }
                if def.classname == "PunctuationNormalizer" { spokenPunctuationType = type }
                if def.classname == "PortablePqrnnSpokenPunctuationNormalizer" {
                    // {1: model_file, 2: inference_settings}; as the grammars, for captions only untyped.
                    let p = def.params.find(Extension.pqrnnSpokenPunctuation)
                    var settings: [UInt8] = []
                    p.forEach { if $0.field == 2 && settings.isEmpty { settings = $0.bytes } }
                    let file = p.firstString(1)
                    if type == 0 && !file.isEmpty {
                        denormalizers.append(Denormalizer(file: file, beforeCapitalization: capitalizationAhead,
                                                          classNormalizer: false, spokenPunctuationSettings: settings))
                    }
                    continue
                }
                let file = def.params.find(Extension.fstNormalizer).firstString(1)
                guard type == 0, !file.isEmpty, def.classname == "FstNormalizer" || def.classname == "ClassNormalizer",
                      !denormalizers.contains(where: { $0.file == file })
                else { continue }
                denormalizers.append(Denormalizer(file: file, beforeCapitalization: capitalizationAhead,
                                                  classNormalizer: def.classname == "ClassNormalizer"))
            }
        }

        guard !encoder.file.isEmpty, !decoder.decoderFile.isEmpty, !decoder.jointFile.isEmpty, !symbolsFile.isEmpty else {
            throw SODAError("\(url.lastPathComponent) has no end-to-end transducer model")
        }
    }

    /// A map entry {1: key, 2: value}.
    private static func entry(_ m: ProtoReader) -> (String, Int)? {
        var key = "", value = 0
        m.forEach { e in
            if e.field == 1 { key = e.string }
            if e.field == 2 { value = e.int }
        }
        return key.isEmpty ? nil : (key, value)
    }

    private static func parseFramer(_ m: ProtoReader?, _ c: inout Frontend) {
        m.forEach { f in
            if f.field == 1 { c.frameSizeMs = f.float }
            if f.field == 2 { c.frameStepMs = f.float }
        }
    }

    private static func parseWindow(_ m: ProtoReader?, _ c: inout Frontend) {
        m.forEach { f in
            switch f.field {
            case 1: c.preemphasis = f.float
            case 3: c.windowType = f.int
            case 6: c.noiseScale = f.float
            case 8: c.windowSizeMs = f.float
            default: break
            }
        }
    }

    private static func parseFft(_ m: ProtoReader?, _ c: inout Frontend) {
        m.forEach { f in
            switch f.field {
            case 1: c.fftInputLengthMs = f.int
            case 2: c.minFftSize = f.int
            case 5: c.fftOverdrive = f.bool
            default: break
            }
        }
    }

    private static func parseFilterBank(_ m: ProtoReader?, _ c: inout Frontend) {
        m.forEach { f in
            switch f.field {
            case 1: c.channelCount = f.int
            case 2: c.upperBandLimit = f.float
            case 3: c.lowerBandLimit = f.float
            case 7: c.fbankOutputFloor = f.float
            default: break
            }
        }
    }

    private static func parseGainControl(_ m: ProtoReader?, _ a: inout GainControl) {
        a.activated = true
        m.forEach { f in
            switch f.field {
            case 1: a.delayMs = f.int
            case 2: a.halfLifeSeconds = f.float
            case 4: a.floor = f.float
            case 5: a.curvature = f.float
            case 6: a.attackWindowMs = f.int
            case 7: a.estimator = f.int
            case 8: a.levelTarget = f.float
            case 9: a.lowerLevelTarget = f.float
            case 10: a.activated = f.bool
            case 11: a.gainScale = f.float
            case 13: a.lowerTargetTransition = f.float
            default: break
            }
        }
    }

    private static func parseEncoder(_ m: ProtoReader?, _ e: inout Encoder, _ sessionRef: inout String, _ domainsRef: inout String) {
        var batches: [Int] = [], flush: [Int] = []
        m.forEach { f in
            switch f.field {
            case 1: sessionRef = f.string
            case 8: batches += f.ints
            case 16: flush += f.ints
            case 17: domainsRef = f.string
            default: break
            }
        }
        if !batches.isEmpty { e.timeBatchSizes = batches }
        if !flush.isEmpty { e.flushBatchSizes = flush }
    }

    private static func parseDecoder(_ m: ProtoReader?, _ d: inout Decoder, _ refs: inout [String: String]) {
        if let fst = m.find(Extension.fstDecoder) {
            refs["search"] = fst.firstString(11)
            fst.forEach { f in
                if f.field == 24 { d.resumeSearch = f.bool }
                if f.field == 38 { d.ignoredResumeContextSuffix = f.string }
            }
        }
        guard let pie = m.find(Extension.pieRnnFstDecoder) else { return }
        pie.forEach { f in
            switch f.field {
            case 2: d.sosID = f.int
            case 11: d.eosID = f.int
            case 4: d.smoothingTemperature = f.float
            case 13: d.eosPenalty = f.float
            default: break
            }
        }
        pie.find(Extension.tfliteTransducer).forEach { f in
            switch f.field {
            case 5: refs["decoder"] = f.string
            case 6: refs["joint"] = f.string
            case 12 where f.wireType == .varint: d.decoderInitialValue = f.int
            default: break
            }
        }
    }

    private static func parseSearch(_ m: ProtoReader, _ d: inout Decoder) {
        m.forEach { f in
            switch f.field {
            case 1: d.maxArcs = f.int
            case 2: d.localBeam = f.float
            case 3: d.histogramBuckets = f.int
            case 7: d.wordPenalty = f.float
            case 20: d.histogramScale = f.float
            case 23: d.minArcs = f.int
            default: break
            }
        }
        // DualSearchParams: {1: max_model_cost, 9: max_expansions, 33: use_min_of_original_and_influenced_cost_for_pruning}.
        m.find(Extension.dualSearch).forEach { f in
            if f.field == 1 { d.maxModelCost = f.float }
            if f.field == 9 { d.maxExpansions = f.int }
            if f.field == 33 { d.pruneOnMinCost = f.bool }
        }
    }

    /// The cluster id and encoder domain id for a recognition domain ("CAPTION"): each looks the domain up in its own
    /// map, else takes the domain's enum value (as libsoda does).
    mutating func select(domain: String) {
        let domains = ["FARFIELD": 1, "IME": 2, "TELEPHONY": 3, "CAPTION": 4, "VOICE_SEARCH": 7, "HOTQUERY": 10]
        if frontend.clusterID >= 0, let id = clusterIDByDomain[domain] ?? domains[domain] { frontend.clusterID = id }
    }
}

/// Reads an lstm.MeanStdDev proto (repeated float mean = 1, std_dev = 2).
func loadMeanStddev(_ url: URL) throws -> (mean: [Float], stddev: [Float]) {
    var mean: [Float] = [], stddev: [Float] = []
    ProtoReader([UInt8](try Data(contentsOf: url))).forEach { f in
        if f.field == 1 { mean += f.floats }
        if f.field == 2 { stddev += f.floats }
    }
    return (mean, stddev)
}

/// Something about the models or the pack isn't as expected.
public struct SODAError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}
