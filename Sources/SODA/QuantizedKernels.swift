import Accelerate
import Foundation

/// TFLite's fixed-point arithmetic (quantization_util.cc, gemmlowp), without TFLITE_SINGLE_ROUNDING as libsoda's
/// TFLite is built.
enum FixedPoint {
    /// A real multiplier as a 31-bit fixed-point multiplier and a power-of-two shift.
    static func quantizeMultiplier(_ value: Double) -> (multiplier: Int32, shift: Int) {
        guard value != 0 else { return (0, 0) }
        let (fraction, exponent) = (frexp(value).0, frexp(value).1)
        var q = Int64((fraction * Double(Int64(1) << 31)).rounded(.toNearestOrAwayFromZero))
        var shift = exponent
        if q == Int64(1) << 31 {
            q /= 2
            shift += 1
        }
        if shift < -31 {
            shift = 0
            q = 0
        }
        if shift > 30 {
            shift = 30
            q = (Int64(1) << 31) - 1
        }
        return (Int32(q), shift)
    }

    static func saturatingRoundingDoublingHighMul(_ a: Int32, _ b: Int32) -> Int32 {
        if a == b && a == .min { return .max }
        let ab = Int64(a) * Int64(b)
        let nudge: Int64 = ab >= 0 ? 1 << 30 : 1 - (1 << 30)
        // Division truncating toward zero, as C++'s.
        return Int32((ab + nudge) / (Int64(1) << 31))
    }

    static func roundingDivideByPOT(_ x: Int32, _ exponent: Int) -> Int32 {
        let mask = Int32((Int64(1) << exponent) - 1)
        let remainder = x & mask
        let threshold = (mask >> 1) + (x < 0 ? 1 : 0)
        return (x >> Int32(exponent)) + (remainder > threshold ? 1 : 0)
    }

    static func multiply(_ x: Int32, _ multiplier: Int32, _ shift: Int) -> Int32 {
        let left = max(shift, 0), right = max(-shift, 0)
        return roundingDivideByPOT(saturatingRoundingDoublingHighMul(x &* Int32(1 << left), multiplier), right)
    }

    /// ruy's MultiplyByQuantizedMultiplier, as the layers TFLite runs through ruy (uint8 FULLY_CONNECTED, CONV_2D)
    /// apply their multipliers: one rounding, half up.
    static func ruyMultiply(_ x: Int32, _ multiplier: Int32, _ shift: Int) -> Int32 {
        let total = 31 - shift
        return Int32((Int64(x) * Int64(multiplier) + (Int64(1) << (total - 1))) >> Int64(total))
    }

    /// MultiplyByQuantizedMultiplierSmallerThanOneExp.
    static func multiplySmallerThanOne(_ x: Int32, _ multiplier: Int32, _ leftShift: Int) -> Int32 {
        roundingDivideByPOT(saturatingRoundingDoublingHighMul(x, multiplier), -leftShift)
    }
}

extension Context {
    /// The quantized range a fused activation leaves (CalculateActivationRangeQuantized), for uint8.
    func activationRange(_ activation: Int8, _ q: Quantization) -> (Int32, Int32) {
        func quantize(_ v: Float) -> Int32 { q.zeroPoint + Int32((v / q.scale).rounded(.toNearestOrAwayFromZero)) }
        switch activation {
        case 1: return (max(0, quantize(0)), 255)
        case 2: return (max(0, quantize(-1)), min(255, quantize(1)))
        case 3: return (max(0, quantize(0)), min(255, quantize(6)))
        default: return (0, 255)
        }
    }

    /// Σ_k a[i][k] b[j][k] for integer-valued rows, exactly: sgemm over blocks of columns small enough that no partial
    /// sum reaches 2²⁴.
    static func integerProducts(_ a: [Float], rows m: Int, _ b: [Float], rows n: Int, columns k: Int,
                                maxProduct: Float) -> [Int32] {
        let block = max(1, Int(Float(1 << 24) / max(maxProduct, 1)))
        var out = [Int32](repeating: 0, count: m * n)
        var partial = [Float](repeating: 0, count: m * n)
        var start = 0
        while start < k {
            let width = min(block, k - start)
            a.withUnsafeBufferPointer { a in
                b.withUnsafeBufferPointer { b in
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(m), Int32(n), Int32(width), 1,
                                a.baseAddress! + start, Int32(k), b.baseAddress! + start, Int32(k), 0, &partial, Int32(n))
                }
            }
            for i in out.indices { out[i] &+= Int32(partial[i]) }
            start += width
        }
        return out
    }

    // MARK: uint8 ops

    mutating func quantizedFullyConnected(_ op: TFLiteModel.Operator) throws {
        let x = input(op, 0), w = input(op, 1)
        let q = outputQuantization(op)
        let units = w.shape[0], columns = w.shape[1]
        let batch = x.count / columns
        let xz = Float(x.quantization.zeroPoint), wz = Float(w.quantization.zeroPoint)
        let inputs = x.uint8s.map { Float($0) - xz }
        let weights = w.uint8s.map { Float($0) - wz }
        var acc = Self.integerProducts(inputs, rows: batch, weights, rows: units, columns: columns, maxProduct: 65025)
        if hasInput(op, 2) {
            let bias = input(op, 2).int32s
            for b in 0..<batch { for u in 0..<units { acc[b * units + u] &+= bias[u] } }
        }
        let real = Double(x.quantization.scale) * Double(w.quantization.scale) / Double(q.scale)
        let (multiplier, shift) = FixedPoint.quantizeMultiplier(real)
        let (low, high) = activationRange(op.options?.scalar(0, Int8(0)) ?? 0, q)
        let out = acc.map { UInt8(min(high, max(low, FixedPoint.ruyMultiply($0, multiplier, shift) + q.zeroPoint))) }
        let keepDims = op.options?.bool(2) ?? false
        set(op, 0, Tensor(shape: keepDims ? Array(x.shape.dropLast()) + [units] : [batch, units], data: .uint8(out)))
    }

    /// CONV_2D (NHWC input, OHWI filter), uint8 or float, through im2col.
    mutating func conv2D(_ op: TFLiteModel.Operator) throws {
        let x = input(op, 0), f = input(op, 1)
        let o = op.options
        let same = (o?.scalar(0, Int8(0)) ?? 0) == 0
        let strideW = Int(o?.scalar(1, Int32(1)) ?? 1), strideH = Int(o?.scalar(2, Int32(1)) ?? 1)
        let activation = o?.scalar(3, Int8(0)) ?? 0
        let dilationW = Int(o?.scalar(4, Int32(1)) ?? 1), dilationH = Int(o?.scalar(5, Int32(1)) ?? 1)
        let (n, h, w, c) = (x.shape[0], x.shape[1], x.shape[2], x.shape[3])
        let (outC, kh, kw) = (f.shape[0], f.shape[1], f.shape[2])
        func extent(_ size: Int, _ k: Int, _ stride: Int, _ dilation: Int) -> (out: Int, pad: Int) {
            let effective = (k - 1) * dilation + 1
            let out = same ? (size + stride - 1) / stride : (size - effective + stride) / stride
            let total = max((out - 1) * stride + effective - size, 0)
            return (out, same ? total / 2 : 0)
        }
        let (oh, padH) = extent(h, kh, strideH, dilationH), (ow, padW) = extent(w, kw, strideW, dilationW)
        let patch = kh * kw * c
        let quantized: Bool
        let values: [Float]
        if case .uint8(let v) = x.data {
            quantized = true
            let zero = Float(x.quantization.zeroPoint)
            values = v.map { Float($0) - zero }
        } else {
            quantized = false
            values = x.floats
        }
        // Patches of input (0 outside it: the zero point for quantized inputs).
        var columns = [Float](repeating: 0, count: n * oh * ow * patch)
        for b in 0..<n {
            for y in 0..<oh {
                for xo in 0..<ow {
                    let row = ((b * oh + y) * ow + xo) * patch
                    for i in 0..<kh {
                        let iy = y * strideH - padH + i * dilationH
                        guard iy >= 0 && iy < h else { continue }
                        for j in 0..<kw {
                            let ix = xo * strideW - padW + j * dilationW
                            guard ix >= 0 && ix < w else { continue }
                            let from = ((b * h + iy) * w + ix) * c, to = row + (i * kw + j) * c
                            for k in 0..<c { columns[to + k] = values[from + k] }
                        }
                    }
                }
            }
        }
        let rows = n * oh * ow
        let shape = [n, oh, ow, outC]
        if quantized {
            let q = outputQuantization(op)
            let fz = Float(f.quantization.zeroPoint)
            let filters = f.uint8s.map { Float($0) - fz }
            var acc = Self.integerProducts(columns, rows: rows, filters, rows: outC, columns: patch, maxProduct: 65025)
            if hasInput(op, 2) {
                let bias = input(op, 2).int32s
                for r in 0..<rows { for u in 0..<outC { acc[r * outC + u] &+= bias[u] } }
            }
            let real = Double(x.quantization.scale) * Double(f.quantization.scale) / Double(q.scale)
            let (multiplier, shift) = FixedPoint.quantizeMultiplier(real)
            let (low, high) = activationRange(activation, q)
            let out = acc.map { UInt8(min(high, max(low, FixedPoint.ruyMultiply($0, multiplier, shift) + q.zeroPoint))) }
            set(op, 0, Tensor(shape: shape, data: .uint8(out)))
        } else {
            let filters = f.floats
            var out = [Float](repeating: 0, count: rows * outC)
            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(outC), Int32(patch), 1, columns,
                        Int32(patch), filters, Int32(patch), 0, &out, Int32(outC))
            if hasInput(op, 2) {
                let bias = input(op, 2).floats
                for r in 0..<rows { for u in 0..<outC { out[r * outC + u] += bias[u] } }
            }
            switch activation {
            case 1: for i in out.indices { out[i] = max(out[i], 0) }
            case 3: for i in out.indices { out[i] = min(max(out[i], 0), 6) }
            default: break
            }
            set(op, 0, Tensor(out, shape: shape))
        }
    }

    /// TANH and LOGISTIC on uint8: TFLite's lookup table of the float function.
    mutating func quantizedActivation(_ op: TFLiteModel.Operator) throws {
        let x = input(op, 0)
        let q = outputQuantization(op)
        let inverse = 1 / q.scale
        let table: [UInt8] = (0...255).map { v in
            let real = x.quantization.scale * Float(v - Int(x.quantization.zeroPoint))
            let y: Float = op.code == Op.tanh ? Darwin.tanh(real) : 1 / (1 + Darwin.exp(-real))
            let quantized = Int32((y * inverse).rounded(.toNearestOrAwayFromZero) + Float(q.zeroPoint))
            return UInt8(min(255, max(0, quantized)))
        }
        set(op, 0, Tensor(shape: x.shape, data: .uint8(x.uint8s.map { table[Int($0)] })))
    }

    /// ADD, SUB and MUL on uint8, as TFLite's reference kernels (with broadcasting).
    mutating func quantizedArithmetic(_ op: TFLiteModel.Operator) throws {
        let a = input(op, 0), b = input(op, 1)
        let q = outputQuantization(op)
        let (shape, ia, ib) = Self.broadcast(a.shape, b.shape)
        let x = a.uint8s, y = b.uint8s
        let (low, high) = activationRange(op.options?.scalar(0, Int8(0)) ?? 0, q)
        let za = -a.quantization.zeroPoint, zb = -b.quantization.zeroPoint
        var out = [UInt8](repeating: 0, count: ia.count)
        switch op.code {
        case Op.mul:
            let real = Double(a.quantization.scale) * Double(b.quantization.scale) / Double(q.scale)
            let (multiplier, shift) = FixedPoint.quantizeMultiplier(real)
            for i in out.indices {
                let product = (za + Int32(x[ia[i]])) * (zb + Int32(y[ib[i]]))
                out[i] = UInt8(min(high, max(low, q.zeroPoint + FixedPoint.multiply(product, multiplier, shift))))
            }
        case Op.add, Op.sub:
            let leftShift = 20
            let twiceMax = Double(2 * max(a.quantization.scale, b.quantization.scale))
            let m1 = FixedPoint.quantizeMultiplier(Double(a.quantization.scale) / twiceMax)
            let m2 = FixedPoint.quantizeMultiplier(Double(b.quantization.scale) / twiceMax)
            let mo = FixedPoint.quantizeMultiplier(twiceMax / Double(Float(1 << leftShift) * q.scale))
            for i in out.indices {
                let s1 = FixedPoint.multiplySmallerThanOne((za + Int32(x[ia[i]])) * (1 << leftShift), m1.multiplier, m1.shift)
                let s2 = FixedPoint.multiplySmallerThanOne((zb + Int32(y[ib[i]])) * (1 << leftShift), m2.multiplier, m2.shift)
                let raw = op.code == Op.add ? s1 + s2 : s1 - s2
                let result = (mo.shift > 0 ? FixedPoint.multiply(raw, mo.multiplier, mo.shift)
                    : FixedPoint.multiplySmallerThanOne(raw, mo.multiplier, mo.shift)) + q.zeroPoint
                out[i] = UInt8(min(high, max(low, result)))
            }
        default:
            throw SODAError("unsupported uint8 op \(op.code)")
        }
        set(op, 0, Tensor(shape: shape, data: .uint8(out)))
    }

    /// CONCATENATION of uint8 tensors of other quantizations than the output's: each requantized
    /// (ConcatenationWithScaling).
    mutating func quantizedConcatenation(_ op: TFLiteModel.Operator, _ parts: [Tensor]) throws {
        let q = outputQuantization(op)
        let inverse = 1 / q.scale
        let rescaled = parts.map { p -> Tensor in
            if p.quantization.scale == q.scale && p.quantization.zeroPoint == q.zeroPoint { return p }
            let scale = p.quantization.scale * inverse
            let bias = -Float(p.quantization.zeroPoint) * scale
            let v = p.uint8s.map { UInt8(max(min(255, (Float($0) * scale + bias).rounded(.toNearestOrAwayFromZero)
                + Float(q.zeroPoint)), 0)) }
            return Tensor(shape: p.shape, data: .uint8(v), quantization: q)
        }
        var axis = Int(op.options?.scalar(0, Int32(0)) ?? 0)
        if axis < 0 { axis += parts[0].shape.count }
        set(op, 0, concatenate(rescaled, axis: axis))
    }

    /// SOFTMAX on uint8: TFLite's 16-bit lookup table of exponentials (TFLITE_SOFTMAX_USE_UINT16_LUT).
    mutating func quantizedSoftmax(_ op: TFLiteModel.Operator) throws {
        let x = input(op, 0)
        let q = outputQuantization(op)
        let beta = op.options?.float(0, 1) ?? 1
        let scale = x.quantization.scale * beta
        let table: [Int32] = (0...255).map { v in
            let e = Double(expf(scale * Float(v - 255)) * 65535) + 0.5
            return min(65535, Int32(e))
        }
        let v = x.uint8s
        let depth = x.shape.last ?? 1
        var out = [UInt8](repeating: 0, count: v.count)
        for start in stride(from: 0, to: v.count, by: depth) {
            let row = v[start..<start + depth]
            let offset = 255 - Int(row.max() ?? 0)
            let sum = row.reduce(Int32(0)) { $0 + table[Int($1) + offset] }
            let inverse = 1 / (Float(sum) * q.scale)
            let (multiplier, shift) = FixedPoint.quantizeMultiplier(Double(inverse))
            for i in start..<start + depth {
                let value = FixedPoint.multiply(table[Int(v[i]) + offset], multiplier, shift) + q.zeroPoint
                out[i] = UInt8(min(255, max(0, value)))
            }
        }
        set(op, 0, Tensor(shape: x.shape, data: .uint8(out)))
    }

    // MARK: Custom ops

    mutating func custom(_ op: TFLiteModel.Operator) throws {
        let options = FlexValue(root: op.customOptions)
        switch op.custom {
        case "SEQUENCE_STRING_PROJECTION": try SequenceProjection.run(op, options, &self)
        case "pooling_op", "PoolingOp": pooling(op)
        case "CharNGramFeatures": try CharNGrams.run(op, options, &self)
        default: if try !textnorm(op, options) { throw SODAError("custom op \(op.custom)") }
        }
    }

    /// seq_flow_lite's QRNN pooling: state = state * multiplier + constant over time, forward or backward.
    private mutating func pooling(_ op: TFLiteModel.Operator) {
        let multiplier = input(op, 0), constant = input(op, 1)
        let forward = input(op, 2).uint8s[0] == 255
        let steps = multiplier.shape[1], size = multiplier.shape[2]
        let m = multiplier.uint8s, c = constant.uint8s
        func dequantize(_ t: Tensor, _ v: UInt8) -> Float { Float(Int32(v) - t.quantization.zeroPoint) * t.quantization.scale }
        func quantize(_ v: Float, _ q: Quantization) -> UInt8 {
            let x = v * (1 / q.scale)
            return UInt8(min(255, max(0, Int32(x + (x >= 0 ? 0.5 : -0.5)) + q.zeroPoint)))
        }
        let q = outputQuantization(op)
        var state = [Float](repeating: 0, count: size)
        var out = [UInt8](repeating: 0, count: m.count)
        for i in 0..<steps {
            let t = forward ? i : steps - 1 - i
            for j in 0..<size {
                let k = t * size + j
                state[j] = state[j] * dequantize(multiplier, m[k]) + dequantize(constant, c[k])
                out[k] = quantize(state[j], q)
            }
        }
        set(op, 0, Tensor(shape: multiplier.shape, data: .uint8(out)))
        if op.outputs.count == 2 {
            let fq = outputQuantization(op, 1)
            set(op, 1, Tensor(shape: [1, size], data: .uint8(state.map { quantize($0, fq) })))
        }
    }

    // MARK: Control flow

    mutating func whileLoop(_ op: TFLiteModel.Operator) throws {
        let condition = Int(op.options?.scalar(0, Int32(0)) ?? 0), body = Int(op.options?.scalar(1, Int32(0)) ?? 0)
        var state = op.inputs.indices.map { input(op, $0) }
        while try interpreter.run(state, subgraph: condition)[0].bools[0] {
            state = try interpreter.run(state, subgraph: body)
        }
        for (i, t) in state.enumerated() { set(op, i, t) }
    }

    mutating func ifThenElse(_ op: TFLiteModel.Operator) throws {
        let branch = input(op, 0).bools[0] ? Int(op.options?.scalar(0, Int32(0)) ?? 0) : Int(op.options?.scalar(1, Int32(0)) ?? 0)
        let outputs = try interpreter.run((1..<op.inputs.count).map { input(op, $0) }, subgraph: branch)
        for (i, t) in outputs.enumerated() { set(op, i, t) }
    }

    // MARK: Hash tables

    /// HASHTABLE gives a handle to the interpreter's table `table_id` (HashtableOptions field 0), HASHTABLE_IMPORT
    /// (handle, keys, values) fills it the first time, HASHTABLE_FIND (handle, keys, default) looks keys up.
    mutating func hashTable(_ op: TFLiteModel.Operator) throws {
        func elements(_ t: Tensor) -> [TensorElement] {
            if case .string(let v) = t.data { return v.map { .string($0) } }
            return t.ints.map { .int($0) }
        }
        switch op.code {
        case Op.hashtable:
            let id = Int(op.options?.scalar(0, Int32(0)) ?? 0)
            if interpreter.hashTables[id] == nil { interpreter.hashTables[id] = HashTable() }
            set(op, 0, Tensor(shape: [], data: .resource(id)))
        case Op.hashtableImport:
            guard case .resource(let id) = input(op, 0).data, let table = interpreter.hashTables[id] else {
                throw SODAError("no hash table")
            }
            if !table.initialized {
                for (k, v) in zip(elements(input(op, 1)), elements(input(op, 2))) where table.map[k] == nil { table.map[k] = v }
                table.initialized = true
            }
        default:
            guard case .resource(let id) = input(op, 0).data, let table = interpreter.hashTables[id], table.initialized else {
                throw SODAError("hash table used before its import")
            }
            let keys = input(op, 1), fallback = input(op, 2)
            let missing = elements(fallback)[0]
            let found = elements(keys).map { table.map[$0] ?? missing }
            let data: TensorData
            switch fallback.data {
            case .string: data = .string(found.map { if case .string(let s) = $0 { s } else { [] } })
            case .int64: data = .int64(found.map { if case .int(let v) = $0 { Int64(v) } else { 0 } })
            default: data = .int32(found.map { if case .int(let v) = $0 { Int32(v) } else { 0 } })
            }
            set(op, 0, Tensor(shape: keys.shape, data: data))
        }
    }
}

/// seq_flow_lite's SEQUENCE_STRING_PROJECTION: per space-separated word, ternary features from its murmur hash.
enum SequenceProjection {
    private static let mul: UInt64 = 0xc6a4_a793_5bd1_e995, mul2: UInt64 = 0x9e37_79b9_7f4a_7835

    private static func shiftMix(_ v: UInt64) -> UInt64 { v ^ (v >> 47) }

    /// The bytes as the reference loads them: ORing in signed chars.
    private static func load(_ p: ArraySlice<UInt8>) -> UInt64 {
        var v: UInt64 = 0
        for b in p.reversed() { v = (v << 8) | UInt64(bitPattern: Int64(Int8(bitPattern: b))) }
        return v
    }

    private static func murmur128(_ s: [UInt8]) -> (UInt64, UInt64) {
        var h1 = UInt64(s.count) &* mul, h2: UInt64 = 0
        let aligned = s.count & ~7
        for i in stride(from: 0, to: aligned, by: 8) {
            h1 ^= shiftMix(load(s[i..<i + 8]) &* mul) &* mul
            h1 = h1 &* mul
            h2 ^= h1
        }
        if s.count & 7 != 0 {
            h1 ^= load(s[aligned...])
            h1 = h1 &* mul
            h2 ^= h1
        }
        h1 = shiftMix(h1) &* mul
        h2 ^= h1
        h1 = shiftMix(h1)
        h2 = shiftMix(h2 &* mul2) &* mul2
        return (h1, h2)
    }

    private static func hashCodes(_ word: [UInt8], _ featureSize: Int) -> [UInt64] {
        var codes: [UInt64] = []
        var (low, high): (UInt64, UInt64) = (0, 0)
        for i in stride(from: 0, to: featureSize, by: 64) {
            if i == 0 {
                (low, high) = murmur128(word)
            } else {
                let h = shiftMix(low) &* mul
                let h2 = high ^ h
                high = shiftMix(h)
                low = shiftMix(h2 &* mul2) &* mul2
            }
            codes += [low, high]
        }
        return codes
    }

    /// Lowercases ASCII, Latin-1 and fullwidth Latin letters (the cases u_tolower changes in text the models see).
    static func lowercased(_ s: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < s.count {
            let c = s[i]
            if c < 0x80 {
                out.append(c >= 65 && c <= 90 ? c + 32 : c)
                i += 1
            } else if c == 0xC3 && i + 1 < s.count && s[i + 1] >= 0x80 && s[i + 1] <= 0x9E && s[i + 1] != 0x97 {
                out += [c, s[i + 1] + 0x20]
                i += 2
            } else if c == 0xEF && i + 2 < s.count && s[i + 1] == 0xBC && s[i + 2] >= 0xA1 && s[i + 2] <= 0xBA {
                let lower = 0xFF41 + Int(s[i + 2] - 0xA1)
                out += [0xEF, 0xBD, UInt8(0x80 | (lower & 0x3F))]
                i += 3
            } else {
                let n = c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4
                out += s[i..<min(s.count, i + n)]
                i += n
            }
        }
        return out
    }

    static func run(_ op: TFLiteModel.Operator, _ options: FlexValue?, _ context: inout Context) throws {
        guard let options else { throw SODAError("SEQUENCE_STRING_PROJECTION without options") }
        let featureSize = options["feature_size"].asInt
        let bos = !options["add_bos_tag"].isNull && options["add_bos_tag"].asBool
        let eos = options["add_eos_tag"].isNull || options["add_eos_tag"].asBool
        let hash = options["hashtype"].isNull ? "murmur" : options["hashtype"].asString
        guard featureSize > 0, hash == "murmur", options["split_on_space"].asBool,
              options["vocabulary"].asBytes.isEmpty, options["word_novelty_bits"].asInt == 0,
              options["doc_size_levels"].asInt == 0, options["add_first_cap_feature"].asFloat == 0,
              options["add_all_caps_feature"].asFloat == 0, !options["normalize_repetition"].asBool else {
            throw SODAError("unsupported SEQUENCE_STRING_PROJECTION options")
        }
        let text = context.input(op, 0).strings[0]
        var words = text.split(separator: 32).map { Array($0) }
        if bos { words.insert(Array("<BOS>".utf8), at: 0) }
        if eos { words.append(Array("<EOS>".utf8)) }
        guard !words.isEmpty else { throw SODAError("no words to project") }
        let quantized = context.graph.tensors[op.outputs[0]].type == .uint8
        let quantizedValues: [UInt8] = [127, 255, 0, 127], floatValues: [Float] = [0, 1, -1, 0]
        var bytes = [UInt8](repeating: 0, count: words.count * featureSize)
        var floats = [Float](repeating: 0, count: quantized ? 0 : words.count * featureSize)
        for (w, word) in words.enumerated() {
            let special = (bos && w == 0) || (eos && w + 1 == words.count)
            var k = 0
            for code in hashCodes(special ? word : lowercased(word), featureSize) {
                var hash = code
                let end = min(k + 32, featureSize)
                while k < end {
                    let at = w * featureSize + k
                    if quantized { bytes[at] = quantizedValues[Int(hash & 3)] } else { floats[at] = floatValues[Int(hash & 3)] }
                    hash >>= 2
                    k += 1
                }
            }
        }
        let shape = [1, words.count, featureSize]
        context.set(op, 0, quantized ? Tensor(shape: shape, data: .uint8(bytes)) : Tensor(floats, shape: shape))
    }
}

/// speech/textnorm's CharNGramFeatures: hashed character n-grams of each string.
enum CharNGrams {
    private static let mul: UInt64 = 0xC6A4_A793_5BD1_E995

    private static func murmur64A(_ p: ArraySlice<UInt8>, seed: UInt64) -> UInt64 {
        let len = p.count, start = p.startIndex
        var h = seed ^ (UInt64(len) &* mul)
        var i = 0
        while i + 8 <= len {
            var k: UInt64 = 0
            for j in 0..<8 { k |= UInt64(p[start + i + j]) << (8 * j) }
            k = k &* mul
            k ^= k >> 47
            k = k &* mul
            h ^= k
            h = h &* mul
            i += 8
        }
        if i < len {
            var tail: UInt64 = 0
            for j in 0..<(len - i) { tail |= UInt64(p[start + i + j]) << (8 * j) }
            h ^= tail
            h = h &* mul
        }
        h ^= h >> 47
        h = h &* mul
        return h ^ (h >> 47)
    }

    /// libsoda's default n-gram hash ("Fingerprint2011"), for inputs of at most 32 bytes.
    private static func fingerprint(_ p: ArraySlice<UInt8>) -> UInt64 {
        func word(_ at: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(p[at + $1]) << (8 * $1) } }
        let len = p.count
        let first: UInt64 = len >= 8 ? word(p.startIndex) : 0xA5B8_5C5E_198E_D849
        let last: UInt64 = len > 8 ? word(p.endIndex - 8) : 0xA5B8_5C5E_198E_D849
        var x = murmur64A(p, seed: 0xEC9B_9EE6_8CF8_F8DD) &+ last
        let y = (x ^ first) &* mul
        x = (x ^ (y >> 47) ^ y) &* mul
        x = (x ^ (x >> 47)) &* mul
        return x > 1 ? x : x | ~UInt64(1)
    }

    static func run(_ op: TFLiteModel.Operator, _ options: FlexValue?, _ context: inout Context) throws {
        guard let options else { throw SODAError("CharNGramFeatures without options") }
        var n = 0, vocabulary = 0
        var startMarker = Array("^".utf8), endMarker = Array("$".utf8)
        // A serialized speech.textnorm.CharNGramFeaturesConfig: 1 start_marker, 2 end_marker, 3 n, 4 vocab_size,
        // 5 hash_function.
        ProtoReader(options["config"].asBytes).forEach { f in
            switch f.field {
            case 1: startMarker = f.bytes
            case 2: endMarker = f.bytes
            case 3: n = f.int
            case 4: vocabulary = f.int
            case 5: if !f.bytes.isEmpty && f.string != "Fingerprint2011ExternalUsage" { n = -1 }
            default: break
            }
        }
        guard n > 0 else { throw SODAError("unsupported CharNGramFeatures options") }
        let textIndex = options["output_text_index"].asBool
        var ids: [Int32] = [], indices: [Int32] = [], positions: [Int32] = []
        var most: Int32 = 0
        for (t, string) in context.input(op, 0).strings.enumerated() {
            let s = startMarker + string + endMarker
            var starts = [0]
            var i = 0
            while i < s.count {
                let c = s[i]
                i += min(s.count - i, c < 0xC2 || c > 0xF4 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4)
                starts.append(i)
            }
            let before = ids.count
            for i in 0..<(starts.count - 1) {
                var j = i + 1
                while j < starts.count && j <= i + n {
                    var id = UInt32(truncatingIfNeeded: fingerprint(s[starts[i]..<starts[j]])) & 0x7FFF_FFFF
                    if vocabulary > 0 { id %= UInt32(vocabulary) }
                    positions.append(Int32(ids.count - before))
                    ids.append(Int32(id))
                    indices.append(Int32(t))
                    j += 1
                }
            }
            most = max(most, Int32(ids.count - before))
        }
        if !textIndex {
            for i in indices.indices { indices[i] = indices[i] * most + positions[i] }
        }
        context.set(op, 0, Tensor(ids))
        context.set(op, 1, Tensor(indices))
        context.set(op, 2, Tensor([most], shape: []))
    }
}
