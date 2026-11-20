import Accelerate
import SODAKernels
import Foundation

/// TFLite's builtin operator codes (schema.fbs) that the packs' small models use.
enum Op {
    static let add = 0, averagePool2D = 1, concatenation = 2, conv2D = 3, dequantize = 6, embeddingLookup = 7
    static let fullyConnected = 9, logistic = 14, maxPool2D = 17, mul = 18, reshape = 22, softmax = 25, tanh = 28
    static let custom = 32, pad = 34, gather = 36, transpose = 39, mean = 40, sub = 41, div = 42, squeeze = 43
    static let stridedSlice = 45, exp = 47, split = 49, logSoftmax = 50, cast = 53, maximum = 55, minimum = 57
    static let less = 58, neg = 59, greater = 61, greaterEqual = 62, lessEqual = 63, select = 64, slice = 65
    static let sin = 66, tile = 69, expandDims = 70, equal = 71, notEqual = 72, log = 73, sum = 74, sqrt = 75
    static let rsqrt = 76, shape = 77, reduceProd = 81, reduceMax = 82, pack = 83, logicalOr = 84, oneHot = 85
    static let logicalAnd = 86, logicalNot = 87, floorDiv = 90, zerosLike = 93, fill = 94, range = 96
    static let squaredDifference = 99, splitV = 102, gatherND = 107, cos = 108, `if` = 118, `while` = 119
    static let selectV2 = 123, segmentSum = 125, hashtable = 136, hashtableFind = 137, hashtableImport = 138
    static let topK = 48, reduceAny = 91, floorMod = 95, reverseSequence = 112, dynamicUpdateSlice = 151
    static let depthwiseConv2D = 4, batchMatMul = 126, cumsum = 128
}

extension Context {
    mutating func run(_ op: TFLiteModel.Operator) throws {
        switch op.code {
        case Op.add, Op.sub, Op.mul, Op.div, Op.maximum, Op.minimum, Op.squaredDifference, Op.floorDiv, Op.floorMod:
            try arithmetic(op)
        case Op.less, Op.greater, Op.greaterEqual, Op.lessEqual, Op.equal, Op.notEqual, Op.logicalAnd, Op.logicalOr:
            comparison(op)
        case Op.neg, Op.exp, Op.log, Op.rsqrt, Op.sqrt, Op.sin, Op.cos, Op.tanh, Op.logistic:
            try unary(op)
        case Op.logicalNot:
            let a = input(op, 0)
            set(op, 0, Tensor(shape: a.shape, data: .bool(a.bools.map { !$0 })))
        case Op.reshape:
            let a = input(op, 0)
            var shape = hasInput(op, 1) ? input(op, 1).ints : op.options?.scalars(0, as: Int32.self).map(Int.init) ?? []
            if let unknown = shape.firstIndex(of: -1) {
                shape[unknown] = a.count / max(1, shape.enumerated().filter { $0.offset != unknown }.map(\.element).reduce(1, *))
            }
            set(op, 0, a.reshaped(shape))
        case Op.expandDims:
            let a = input(op, 0)
            var axis = input(op, 1).ints[0]
            if axis < 0 { axis += a.shape.count + 1 }
            var shape = a.shape
            shape.insert(1, at: axis)
            set(op, 0, a.reshaped(shape))
        case Op.squeeze:
            let a = input(op, 0)
            let axes = (op.options?.scalars(0, as: Int32.self) ?? []).map { Int($0) < 0 ? Int($0) + a.shape.count : Int($0) }
            set(op, 0, a.reshaped(a.shape.enumerated().filter { axes.isEmpty ? $0.element != 1 : !axes.contains($0.offset) }.map(\.element)))
        case Op.shape:
            set(op, 0, Tensor(input(op, 0).shape.map { Int32($0) }))
        case Op.cast:
            cast(op)
        case Op.concatenation:
            try concatenation(op)
        case Op.pack:
            pack(op)
        case Op.split, Op.splitV:
            split(op)
        case Op.stridedSlice:
            stridedSlice(op)
        case Op.slice:
            let a = input(op, 0)
            let begin = input(op, 1).ints
            let size = zip(input(op, 2).ints, zip(a.shape, begin)).map { $0 < 0 ? $1.0 - $1.1 : $0 }
            set(op, 0, slice(a, begin: begin, size: size, strides: begin.map { _ in 1 }))
        case Op.gather:
            gather(op)
        case Op.gatherND:
            gatherND(op)
        case Op.transpose:
            let a = input(op, 0)
            set(op, 0, transpose(a, input(op, 1).ints))
        case Op.tile:
            tile(op)
        case Op.pad:
            pad(op)
        case Op.fill:
            let shape = input(op, 0).ints
            let value = input(op, 1)
            set(op, 0, value.gathered([Int](repeating: 0, count: shape.reduce(1, *)), shape: shape))
        case Op.zerosLike:
            let a = input(op, 0)
            set(op, 0, Tensor([Float](repeating: 0, count: a.count), shape: a.shape))
        case Op.range:
            range(op)
        case Op.depthwiseConv2D:
            try depthwiseConv2D(op)
        case Op.averagePool2D, Op.maxPool2D:
            try pool2D(op)
        case Op.batchMatMul:
            try batchMatMul(op)
        case Op.cumsum:
            try cumsum(op)
        case Op.topK:
            topK(op)
        case Op.reverseSequence:
            reverseSequence(op)
        case Op.dynamicUpdateSlice:
            dynamicUpdateSlice(op)
        case Op.mean, Op.sum, Op.reduceMax, Op.reduceProd, Op.reduceAny:
            reduce(op)
        case Op.softmax:
            try softmax(op)
        case Op.logSoftmax:
            logSoftmax(op)
        case Op.embeddingLookup:
            let ids = input(op, 0).ints, table = input(op, 1)
            let row = table.count / table.shape[0]
            let shape = [ids.count] + table.shape.dropFirst()
            if let values = graph.tensors[op.inputs[1]].weights {
                // An int8 table left in the file: the rows copied from there.
                let rows = [Int8](unsafeUninitializedCapacity: ids.count * row) { out, count in
                    for (k, id) in ids.enumerated() {
                        precondition(id >= 0 && id < table.shape[0], "EMBEDDING_LOOKUP id out of range")
                        UnsafeMutableRawBufferPointer(rebasing: UnsafeMutableRawBufferPointer(out)[(k * row)..<(k + 1) * row])
                            .copyMemory(from: UnsafeRawBufferPointer(rebasing: values[(id * row)..<(id + 1) * row]))
                    }
                    count = ids.count * row
                }
                set(op, 0, Tensor(shape: shape, data: .int8(rows), quantization: table.quantization))
            } else {
                set(op, 0, table.gathered(ids.flatMap { id in (id * row)..<(id + 1) * row }, shape: shape))
            }
        case Op.dequantize:
            let a = input(op, 0)
            let scale = a.quantization.scale, zero = Int(a.quantization.zeroPoint)
            set(op, 0, Tensor(a.ints.map { Float($0 - zero) * scale }, shape: a.shape))
        case Op.fullyConnected:
            try fullyConnected(op)
        case Op.select, Op.selectV2:
            select(op)
        case Op.segmentSum:
            segmentSum(op)
        case Op.oneHot:
            oneHot(op)
        case Op.while:
            try whileLoop(op)
        case Op.if:
            try ifThenElse(op)
        case Op.hashtable, Op.hashtableFind, Op.hashtableImport:
            try hashTable(op)
        case Op.conv2D:
            try conv2D(op)
        case Op.custom:
            try custom(op)
        default:
            throw SODAError("unsupported TFLite op \(op.code)")
        }
    }

    // MARK: Elementwise

    /// numpy broadcasting: the output shape and, per output element, the elements of `a` and `b` it reads.
    static func broadcast(_ a: [Int], _ b: [Int]) -> (shape: [Int], a: [Int], b: [Int]) {
        if a == b { return (a, Array(0..<a.reduce(1, *)), Array(0..<a.reduce(1, *))) }
        let rank = max(a.count, b.count)
        let pa = [Int](repeating: 1, count: rank - a.count) + a, pb = [Int](repeating: 1, count: rank - b.count) + b
        // A dimension of 1 takes the other's size, 0 included.
        let shape = zip(pa, pb).map { $0 == 1 ? $1 : $1 == 1 ? $0 : max($0, $1) }
        func strides(_ s: [Int]) -> [Int] {
            var st = [Int](repeating: 0, count: rank), m = 1
            for i in stride(from: rank - 1, through: 0, by: -1) {
                st[i] = s[i] == 1 ? 0 : m
                m *= s[i]
            }
            return st
        }
        let sa = strides(pa), sb = strides(pb)
        let total = shape.reduce(1, *)
        var ia = [Int](repeating: 0, count: total), ib = ia
        var index = [Int](repeating: 0, count: rank)
        for i in 0..<total {
            var x = 0, y = 0
            for d in 0..<rank {
                x += index[d] * sa[d]
                y += index[d] * sb[d]
            }
            (ia[i], ib[i]) = (x, y)
            var d = rank - 1
            while d >= 0 {
                index[d] += 1
                if index[d] < shape[d] { break }
                index[d] = 0
                d -= 1
            }
        }
        return (shape, ia, ib)
    }

    /// f of the two tensors' values, broadcast, with direct loops for equal shapes, and for a single value, a trailing
    /// block or a value per row on either side.
    @inline(__always)
    static func elementwise<A, B, R>(_ x: [A], _ xShape: [Int], _ y: [B], _ yShape: [Int],
                                     _ f: (A, B) -> R) -> ([R], [Int]) {
        /// `count` values, written by `body` into uninitialized memory.
        @inline(__always)
        func make(_ count: Int, _ body: (UnsafeMutablePointer<R>, UnsafePointer<A>, UnsafePointer<B>) -> Void) -> [R] {
            guard count > 0, !x.isEmpty, !y.isEmpty else { return [] }
            return x.withUnsafeBufferPointer { xs in
                y.withUnsafeBufferPointer { ys in
                    [R](unsafeUninitializedCapacity: count) { o, n in
                        body(o.baseAddress!, xs.baseAddress!, ys.baseAddress!)
                        n = count
                    }
                }
            }
        }
        func trailing(_ small: [Int], of large: [Int]) -> Bool {
            let s = Array(small.drop(while: { $0 == 1 }))
            return s.count <= large.count && Array(large.suffix(s.count)) == s
        }
        if xShape == yShape {
            return (make(x.count) { o, xp, yp in for i in 0..<x.count { (o + i).initialize(to: f(xp[i], yp[i])) } }, xShape)
        }
        if xShape.count >= yShape.count, !y.isEmpty, trailing(yShape, of: xShape) {
            let n = y.count
            return (make(x.count) { o, xp, yp in
                for start in stride(from: 0, to: x.count, by: n) {
                    for j in 0..<n { (o + start + j).initialize(to: f(xp[start + j], yp[j])) }
                }
            }, xShape)
        }
        if yShape.count >= xShape.count, !x.isEmpty, trailing(xShape, of: yShape) {
            let n = x.count
            return (make(y.count) { o, xp, yp in
                for start in stride(from: 0, to: y.count, by: n) {
                    for j in 0..<n { (o + start + j).initialize(to: f(xp[j], yp[start + j])) }
                }
            }, yShape)
        }
        // One value per row: the same leading dimensions, then 1s.
        func leading(_ small: [Int], of large: [Int]) -> Bool {
            small.count == large.count && zip(small, large).drop(while: { $0 == $1 }).allSatisfy { $0.0 == 1 }
        }
        if !y.isEmpty, leading(yShape, of: xShape) {
            let inner = x.count / y.count
            return (make(x.count) { o, xp, yp in
                for r in 0..<y.count {
                    let v = yp[r], base = r * inner
                    for j in 0..<inner { (o + base + j).initialize(to: f(xp[base + j], v)) }
                }
            }, xShape)
        }
        if !x.isEmpty, leading(xShape, of: yShape) {
            let inner = y.count / x.count
            return (make(y.count) { o, xp, yp in
                for r in 0..<x.count {
                    let v = xp[r], base = r * inner
                    for j in 0..<inner { (o + base + j).initialize(to: f(v, yp[base + j])) }
                }
            }, yShape)
        }
        let (shape, ia, ib) = broadcast(xShape, yShape)
        return (make(ia.count) { o, xp, yp in for i in 0..<ia.count { (o + i).initialize(to: f(xp[ia[i]], yp[ib[i]])) } }, shape)
    }

    /// The cases `elementwise` loops over directly, as rows for soda_binary: `outer` rows of `inner` values, each side
    /// stepping by its outer stride per row and by its inner stride (0 or 1) within one.
    static func rows(_ xShape: [Int], _ xCount: Int, _ yShape: [Int], _ yCount: Int)
        -> (shape: [Int], outer: Int, inner: Int, xOuter: Int, xInner: Int32, yOuter: Int, yInner: Int32)? {
        guard xCount > 0, yCount > 0 else { return nil }
        func trailing(_ small: [Int], of large: [Int]) -> Bool {
            let s = Array(small.drop(while: { $0 == 1 }))
            return s.count <= large.count && Array(large.suffix(s.count)) == s
        }
        if xShape == yShape { return (xShape, 1, xCount, 0, 1, 0, 1) }
        if xShape.count >= yShape.count, trailing(yShape, of: xShape) {
            return yCount == 1 ? (xShape, 1, xCount, 0, 1, 0, 0) : (xShape, xCount / yCount, yCount, yCount, 1, 0, 1)
        }
        if yShape.count >= xShape.count, trailing(xShape, of: yShape) {
            return xCount == 1 ? (yShape, 1, yCount, 0, 0, 0, 1) : (yShape, yCount / xCount, xCount, 0, 1, xCount, 1)
        }
        func leading(_ small: [Int], of large: [Int]) -> Bool {
            small.count == large.count && zip(small, large).drop(while: { $0 == $1 }).allSatisfy { $0.0 == 1 }
        }
        if leading(yShape, of: xShape) { return (xShape, yCount, xCount / yCount, xCount / yCount, 1, 1, 0) }
        if leading(xShape, of: yShape) { return (yShape, xCount, yCount / xCount, 1, 0, yCount / xCount, 1) }
        return nil
    }

    static func activate(_ v: inout [Float], _ activation: Int8) {
        switch activation {
        case 1: for i in v.indices { v[i] = max(v[i], 0) }
        case 2: for i in v.indices { v[i] = min(max(v[i], -1), 1) }
        case 3: for i in v.indices { v[i] = min(max(v[i], 0), 6) }
        case 4: for i in v.indices { v[i] = Darwin.tanh(v[i]) }
        default: break
        }
    }

    private mutating func arithmetic(_ op: TFLiteModel.Operator) throws {
        let a = input(op, 0), b = input(op, 1)
        if case .uint8 = a.data { return try quantizedArithmetic(op) }
        switch (a.data, b.data) {
        case (.float(let x), .float(let y)):
            if let r = Self.rows(a.shape, x.count, b.shape, y.count) {
                var out = [Float](unsafeUninitializedCapacity: r.outer * r.inner) { o, n in
                    let done = soda_binary(Int32(op.code), x, r.xOuter, r.xInner, y, r.yOuter, r.yInner, o.baseAddress!,
                                           r.outer, r.inner)
                    precondition(done != 0, "soda_binary has no op \(op.code)")
                    n = r.outer * r.inner
                }
                Self.activate(&out, op.options?.scalar(0, Int8(0)) ?? 0)
                set(op, 0, Tensor(out, shape: r.shape))
                return
            }
            var (out, shape) = switch op.code {
            case Op.add: Self.elementwise(x, a.shape, y, b.shape, +)
            case Op.sub: Self.elementwise(x, a.shape, y, b.shape, -)
            case Op.mul: Self.elementwise(x, a.shape, y, b.shape, *)
            case Op.div: Self.elementwise(x, a.shape, y, b.shape, /)
            case Op.maximum: Self.elementwise(x, a.shape, y, b.shape) { Swift.max($0, $1) }
            case Op.minimum: Self.elementwise(x, a.shape, y, b.shape) { Swift.min($0, $1) }
            case Op.squaredDifference: Self.elementwise(x, a.shape, y, b.shape) { ($0 - $1) * ($0 - $1) }
            case Op.floorMod: Self.elementwise(x, a.shape, y, b.shape) { x, y in
                let t = fmodf(x, y)
                return t != 0 && (y < 0) != (t < 0) ? t + y : t
            }
            default: Self.elementwise(x, a.shape, y, b.shape) { ($0 / $1).rounded(.down) }
            }
            Self.activate(&out, op.options?.scalar(0, Int8(0)) ?? 0)
            set(op, 0, Tensor(out, shape: shape))
        default:
            let x = a.ints, y = b.ints
            let f: (Int, Int) -> Int = switch op.code {
            case Op.add: (+)
            case Op.sub: (-)
            case Op.mul: (*)
            case Op.div: (/)
            case Op.maximum: { Swift.max($0, $1) }
            case Op.minimum: { Swift.min($0, $1) }
            case Op.squaredDifference: { ($0 - $1) * ($0 - $1) }
            case Op.floorMod: { x, y in
                let t = x % y
                return t != 0 && (y < 0) != (t < 0) ? t + y : t
            }
            default: { Int((Double($0) / Double($1)).rounded(.down)) }
            }
            let (out, shape) = Self.elementwise(x, a.shape, y, b.shape, f)
            if case .int64 = a.data {
                set(op, 0, Tensor(shape: shape, data: .int64(out.map(Int64.init))))
            } else {
                set(op, 0, Tensor(out.map { Int32(truncatingIfNeeded: $0) }, shape: shape))
            }
        }
    }

    private mutating func comparison(_ op: TFLiteModel.Operator) {
        let a = input(op, 0), b = input(op, 1)
        let out: [Bool], shape: [Int]
        switch (a.data, b.data) {
        case (.float(let x), .float(let y)):
            let f: (Float, Float) -> Bool = switch op.code {
            case Op.less: (<)
            case Op.greater: (>)
            case Op.greaterEqual: (>=)
            case Op.lessEqual: (<=)
            case Op.equal: (==)
            default: (!=)
            }
            (out, shape) = Self.elementwise(x, a.shape, y, b.shape, f)
        case (.string(let x), .string(let y)):
            let equal = op.code == Op.equal
            (out, shape) = Self.elementwise(x, a.shape, y, b.shape) { ($0 == $1) == equal }
        default:
            let x = a.ints, y = b.ints
            let f: (Int, Int) -> Bool = switch op.code {
            case Op.less: (<)
            case Op.greater: (>)
            case Op.greaterEqual: (>=)
            case Op.lessEqual: (<=)
            case Op.equal: (==)
            case Op.notEqual: (!=)
            case Op.logicalAnd: { $0 != 0 && $1 != 0 }
            default: { $0 != 0 || $1 != 0 }
            }
            (out, shape) = Self.elementwise(x, a.shape, y, b.shape, f)
        }
        set(op, 0, Tensor(shape: shape, data: .bool(out)))
    }

    private mutating func unary(_ op: TFLiteModel.Operator) throws {
        let a = input(op, 0)
        if case .uint8 = a.data { return try quantizedActivation(op) }
        let x = a.floats
        var out = [Float](repeating: 0, count: x.count)
        switch op.code {
        case Op.neg: for i in x.indices { out[i] = -x[i] }
        case Op.exp: for i in x.indices { out[i] = Darwin.exp(x[i]) }
        case Op.log: for i in x.indices { out[i] = Darwin.log(x[i]) }
        case Op.rsqrt: for i in x.indices { out[i] = 1 / x[i].squareRoot() }
        case Op.sqrt: for i in x.indices { out[i] = x[i].squareRoot() }
        case Op.sin: for i in x.indices { out[i] = Darwin.sin(x[i]) }
        case Op.cos: for i in x.indices { out[i] = Darwin.cos(x[i]) }
        case Op.tanh: soda_tanh(x, &out, x.count)
        default: soda_logistic(x, &out, x.count)
        }
        set(op, 0, Tensor(out, shape: a.shape))
    }

    private mutating func cast(_ op: TFLiteModel.Operator) {
        let a = input(op, 0)
        let type = graph.tensors[op.outputs[0]].type
        let values: [Double] = switch a.data {
        case .float(let v): v.map(Double.init)
        default: a.ints.map(Double.init)
        }
        let data: TensorData = switch type {
        case .float32: .float(values.map { Float($0) })
        case .int64: .int64(values.map { Int64($0) })
        case .bool: .bool(values.map { $0 != 0 })
        case .uint8: .uint8(values.map { UInt8(truncatingIfNeeded: Int($0)) })
        case .int8: .int8(values.map { Int8(truncatingIfNeeded: Int($0)) })
        default: .int32(values.map { Int32(truncatingIfNeeded: Int64($0)) })
        }
        set(op, 0, Tensor(shape: a.shape, data: data))
    }

    private mutating func select(_ op: TFLiteModel.Operator) {
        let c = input(op, 0), x = input(op, 1), y = input(op, 2)
        // SELECT takes a condition of the inputs' shape or of their first dimension.
        let condition = c.shape.count == 1 && x.shape.count > 1 && c.shape[0] == x.shape[0] && op.code == Op.select
            ? c.reshaped([c.shape[0]] + [Int](repeating: 1, count: x.shape.count - 1)) : c
        let bools = condition.bools
        if case .float(let u) = x.data, case .float(let v) = y.data {
            // The condition picks from x where true, then y fills the rest, each broadcast.
            let (picked, s1) = Self.elementwise(bools, condition.shape, u, x.shape) { c, a -> Float? in c ? a : nil }
            let (out, shape) = Self.elementwise(picked, s1, v, y.shape) { p, b in p ?? b }
            return set(op, 0, Tensor(out, shape: shape))
        }
        let (s1, ic, ix) = Self.broadcast(condition.shape, x.shape)
        let (shape, i1, iy) = Self.broadcast(s1, y.shape)
        let pick = i1.map { bools[ic[$0]] }
        let a = x.gathered(i1.map { ix[$0] }, shape: shape), b = y.gathered(iy, shape: shape)
        switch (a.data, b.data) {
        case (.float(let u), .float(let v)):
            set(op, 0, Tensor(pick.indices.map { pick[$0] ? u[$0] : v[$0] }, shape: shape))
        case (.bool(let u), .bool(let v)):
            set(op, 0, Tensor(shape: shape, data: .bool(pick.indices.map { pick[$0] ? u[$0] : v[$0] })))
        default:
            let u = a.ints, v = b.ints
            set(op, 0, Tensor(pick.indices.map { Int32(pick[$0] ? u[$0] : v[$0]) }, shape: shape))
        }
    }

    // MARK: Shapes

    private mutating func concatenation(_ op: TFLiteModel.Operator) throws {
        let parts = op.inputs.indices.map { input(op, $0) }
        if case .uint8 = parts[0].data, !parts.allSatisfy({ $0.quantization.scale == outputQuantization(op).scale
            && $0.quantization.zeroPoint == outputQuantization(op).zeroPoint }) {
            return try quantizedConcatenation(op, parts)
        }
        var axis = Int(op.options?.scalar(0, Int32(0)) ?? 0)
        if axis < 0 { axis += parts[0].shape.count }
        set(op, 0, concatenate(parts, axis: axis))
    }

    func concatenate(_ parts: [Tensor], axis: Int) -> Tensor {
        let outer = parts[0].shape[..<axis].reduce(1, *)
        var shape = parts[0].shape
        shape[axis] = parts.map { $0.shape[axis] }.reduce(0, +)
        // For each outer index, each part's inner block.
        let inners = parts.map { $0.shape[axis...].reduce(1, *) }
        let runs = runs([0, outer] + inners) {
            var runs = CopyRuns()
            for o in 0..<outer {
                for (p, inner) in inners.enumerated() { runs.append(p, o * inner, inner) }
            }
            return runs
        }
        return Tensor.copying(parts, runs, shape: shape)
    }

    private mutating func pack(_ op: TFLiteModel.Operator) {
        let parts = op.inputs.indices.map { input(op, $0) }
        var axis = Int(op.options?.scalar(1, Int32(0)) ?? 0)
        if axis < 0 { axis += parts[0].shape.count + 1 }
        let expanded = parts.map { p -> Tensor in
            var s = p.shape
            s.insert(1, at: axis)
            return p.reshaped(s)
        }
        set(op, 0, concatenate(expanded, axis: axis))
    }

    private mutating func split(_ op: TFLiteModel.Operator) {
        let a: Tensor, axisValue: Int, sizes: [Int]
        if op.code == Op.split {
            a = input(op, 1)
            axisValue = input(op, 0).ints[0]
            let n = op.outputs.count
            let axis = axisValue < 0 ? axisValue + a.shape.count : axisValue
            sizes = [Int](repeating: a.shape[axis] / n, count: n)
        } else {
            a = input(op, 0)
            axisValue = input(op, 2).ints[0]
            let axis = axisValue < 0 ? axisValue + a.shape.count : axisValue
            var s = input(op, 1).ints
            if let unknown = s.firstIndex(of: -1) { s[unknown] = a.shape[axis] - s.filter { $0 >= 0 }.reduce(0, +) }
            sizes = s
        }
        let axis = axisValue < 0 ? axisValue + a.shape.count : axisValue
        var start = 0
        for (i, size) in sizes.enumerated() {
            var begin = [Int](repeating: 0, count: a.shape.count), extent = a.shape
            begin[axis] = start
            extent[axis] = size
            set(op, i, slice(a, begin: begin, size: extent, strides: begin.map { _ in 1 }))
            start += size
        }
    }

    /// Elements begin[d] + k * strides[d] for k < size[d] in each dimension.
    func slice(_ a: Tensor, begin: [Int], size: [Int], strides: [Int]) -> Tensor {
        let rank = a.shape.count
        guard rank > 0 else { return a }
        let runs = runs([1] + a.shape + begin + size + strides) {
            var aStrides = [Int](repeating: 1, count: rank)
            for d in stride(from: rank - 2, through: 0, by: -1) { aStrides[d] = aStrides[d + 1] * a.shape[d + 1] }
            var runs = CopyRuns()
            func walk(_ d: Int, _ base: Int) {
                if d == rank - 1 {
                    if strides[d] == 1 { return runs.append(0, base + begin[d], size[d]) }
                    for k in 0..<size[d] { runs.append(0, base + begin[d] + k * strides[d], 1) }
                    return
                }
                for k in 0..<size[d] { walk(d + 1, base + (begin[d] + k * strides[d]) * aStrides[d]) }
            }
            if size.allSatisfy({ $0 > 0 }) { walk(0, 0) }
            return runs
        }
        return Tensor.copying([a], runs, shape: size)
    }

    private mutating func stridedSlice(_ op: TFLiteModel.Operator) {
        let a = input(op, 0)
        let rank = a.shape.count
        var begin = input(op, 1).ints, end = input(op, 2).ints, strides = input(op, 3).ints
        let o = op.options
        let beginMask = Int(o?.scalar(0, Int32(0)) ?? 0), endMask = Int(o?.scalar(1, Int32(0)) ?? 0)
        let shrinkMask = Int(o?.scalar(4, Int32(0)) ?? 0)
        // Fewer entries than dimensions: the rest are whole.
        while begin.count < rank {
            begin.append(0)
            end.append(0)
            strides.append(1)
        }
        var starts: [Int] = [], sizes: [Int] = [], shape: [Int] = []
        for d in 0..<rank {
            let n = a.shape[d], s = strides[d]
            var b = begin[d], e = end[d]
            let whole = d >= input(op, 1).count
            if b < 0 { b += n }
            if e < 0 { e += n }
            if beginMask & (1 << d) != 0 || whole { b = s > 0 ? 0 : n - 1 }
            if endMask & (1 << d) != 0 || whole { e = s > 0 ? n : -1 }
            if shrinkMask & (1 << d) != 0 {
                b = begin[d] < 0 ? begin[d] + n : begin[d]
                e = b + 1
            }
            b = s > 0 ? min(max(b, 0), n) : min(max(b, -1), n - 1)
            e = s > 0 ? min(max(e, 0), n) : min(max(e, -1), n - 1)
            let count = s > 0 ? max(0, (e - b + s - 1) / s) : max(0, (b - e - s - 1) / -s)
            starts.append(b)
            sizes.append(count)
            if shrinkMask & (1 << d) == 0 { shape.append(count) }
        }
        set(op, 0, slice(a, begin: starts, size: sizes, strides: strides).reshaped(shape))
    }

    private mutating func gather(_ op: TFLiteModel.Operator) {
        let a = input(op, 0), positions = input(op, 1)
        var axis = Int(op.options?.scalar(0, Int32(0)) ?? 0)
        if axis < 0 { axis += a.shape.count }
        let batchDims = Int(op.options?.scalar(1, Int32(0)) ?? 0)
        precondition(batchDims == 0, "GATHER with batch_dims")
        let outer = a.shape[..<axis].reduce(1, *), inner = a.shape[(axis + 1)...].reduce(1, *), n = a.shape[axis]
        let ids = positions.ints
        var indices: [Int] = []
        indices.reserveCapacity(outer * ids.count * inner)
        for o in 0..<outer {
            for id in ids {
                let base = (o * n + id) * inner
                indices.append(contentsOf: base..<base + inner)
            }
        }
        set(op, 0, a.gathered(indices, shape: Array(a.shape[..<axis]) + positions.shape + Array(a.shape[(axis + 1)...])))
    }

    private mutating func gatherND(_ op: TFLiteModel.Operator) {
        let a = input(op, 0), positions = input(op, 1)
        let depth = positions.shape.last!
        let ids = positions.ints
        let inner = a.shape[depth...].reduce(1, *)
        var aStrides = [Int](repeating: inner, count: depth)
        for d in stride(from: depth - 2, through: 0, by: -1) { aStrides[d] = aStrides[d + 1] * a.shape[d + 1] }
        var indices: [Int] = []
        for i in stride(from: 0, to: ids.count, by: depth) {
            let base = (0..<depth).reduce(0) { $0 + ids[i + $1] * aStrides[$1] }
            indices.append(contentsOf: base..<base + inner)
        }
        set(op, 0, a.gathered(indices, shape: Array(positions.shape.dropLast()) + Array(a.shape[depth...])))
    }

    func transpose(_ a: Tensor, _ permutation: [Int]) -> Tensor {
        let rank = a.shape.count
        guard rank > 0, a.count > 0 else { return a.reshaped(permutation.map { a.shape[$0] }) }
        var strides = [Int](repeating: 1, count: rank)
        for d in stride(from: rank - 2, through: 0, by: -1) { strides[d] = strides[d + 1] * a.shape[d + 1] }
        let shape = permutation.map { a.shape[$0] }
        let moved = permutation.map { strides[$0] }
        if moved[rank - 1] == 1 {
            // The last dimension stays: whole rows.
            let runs = runs([2] + shape + moved) {
                var runs = CopyRuns()
                func walk(_ d: Int, _ base: Int) {
                    if d == rank - 1 { return runs.append(0, base, shape[d]) }
                    for k in 0..<shape[d] { walk(d + 1, base + k * moved[d]) }
                }
                walk(0, 0)
                return runs
            }
            return Tensor.copying([a], runs, shape: shape)
        }
        // Element by element, the output's index counting up: a run along the last dimension at a time.
        let inner = shape[rank - 1], step = moved[rank - 1], total = a.count
        func permuted<T>(_ v: [T]) -> [T] {
            v.withUnsafeBufferPointer { v in
                [T](unsafeUninitializedCapacity: total) { out, count in
                    var index = [Int](repeating: 0, count: rank), at = 0, i = 0
                    while i < total {
                        var p = at
                        for _ in 0..<inner {
                            (out.baseAddress! + i).initialize(to: v[p])
                            p += step
                            i += 1
                        }
                        var d = rank - 2
                        while d >= 0 {
                            index[d] += 1
                            at += moved[d]
                            if index[d] < shape[d] { break }
                            at -= moved[d] * shape[d]
                            index[d] = 0
                            d -= 1
                        }
                    }
                    count = total
                }
            }
        }
        let data: TensorData = switch a.data {
        case .float(let v): .float(permuted(v))
        case .int32(let v): .int32(permuted(v))
        case .int64(let v): .int64(permuted(v))
        case .uint8(let v): .uint8(permuted(v))
        case .int8(let v): .int8(permuted(v))
        case .int16(let v): .int16(permuted(v))
        case .bool(let v): .bool(permuted(v))
        case .string(let v): .string(permuted(v))
        case .resource: a.data
        }
        return Tensor(shape: shape, data: data, quantization: a.quantization)
    }

    private mutating func tile(_ op: TFLiteModel.Operator) {
        let a = input(op, 0), multiples = input(op, 1).ints
        let shape = zip(a.shape, multiples).map(*)
        let rank = a.shape.count
        var strides = [Int](repeating: 1, count: rank)
        for d in stride(from: rank - 2, through: 0, by: -1) { strides[d] = strides[d + 1] * a.shape[d + 1] }
        var indices: [Int] = []
        func walk(_ d: Int, _ base: Int) {
            if d == rank { return indices.append(base) }
            for k in 0..<shape[d] { walk(d + 1, base + (k % a.shape[d]) * strides[d]) }
        }
        walk(0, 0)
        set(op, 0, a.gathered(indices, shape: shape))
    }

    private mutating func pad(_ op: TFLiteModel.Operator) {
        let a = input(op, 0), paddings = input(op, 1).ints
        let rank = a.shape.count
        let shape = (0..<rank).map { (d: Int) -> Int in a.shape[d] + paddings[2 * d] + paddings[2 * d + 1] }
        var strides = [Int](repeating: 1, count: rank)
        for d in stride(from: rank - 2, through: 0, by: -1) { strides[d] = strides[d + 1] * a.shape[d + 1] }
        var indices: [Int] = []
        func walk(_ d: Int, _ base: Int?) {
            if d == rank { return indices.append(base ?? -1) }
            for k in 0..<shape[d] {
                let i = k - paddings[2 * d]
                walk(d + 1, base.flatMap { i >= 0 && i < a.shape[d] ? $0 + i * strides[d] : nil })
            }
        }
        walk(0, 0)
        // Padding is zero (the zero point for quantized tensors).
        switch a.data {
        case .float(let v): set(op, 0, Tensor(indices.map { $0 < 0 ? 0 : v[$0] }, shape: shape))
        case .uint8(let v):
            let zero = UInt8(a.quantization.zeroPoint)
            set(op, 0, Tensor(shape: shape, data: .uint8(indices.map { $0 < 0 ? zero : v[$0] }), quantization: a.quantization))
        default:
            let v = a.ints
            set(op, 0, Tensor(indices.map { Int32($0 < 0 ? 0 : v[$0]) }, shape: shape))
        }
    }

    private mutating func range(_ op: TFLiteModel.Operator) {
        let start = input(op, 0), limit = input(op, 1), delta = input(op, 2)
        if case .float(let s) = start.data {
            let l = limit.floats[0], d = delta.floats[0]
            let n = Int(((l - s[0]) / d).rounded(.up))
            set(op, 0, Tensor((0..<max(n, 0)).map { s[0] + Float($0) * d }))
        } else {
            let s = start.ints[0], l = limit.ints[0], d = delta.ints[0]
            set(op, 0, Tensor(Swift.stride(from: s, to: l, by: d).map { Int32($0) }))
        }
    }

    private mutating func reduce(_ op: TFLiteModel.Operator) {
        let a = input(op, 0)
        let rank = a.shape.count
        let axes = Set(input(op, 1).ints.map { $0 < 0 ? $0 + rank : $0 })
        let keep = op.options?.bool(0) ?? false
        let outShape = (0..<rank).compactMap { axes.contains($0) ? (keep ? 1 : nil) : a.shape[$0] }
        let groupShape = (0..<rank).map { axes.contains($0) ? 1 : a.shape[$0] }
        let groups = groupShape.reduce(1, *)
        let n = a.count / max(groups, 1)
        // A float mean over the last dimensions (once size-1 dimensions are dropped), with some left, is Eigen's
        // column sum in TFLite; other reductions go in order.
        let kept = (0..<rank).filter { a.shape[$0] != 1 }
        if op.code == Op.mean, case .float(let v) = a.data, let last = kept.last, axes.contains(last),
           !axes.contains(kept[0]), kept.drop(while: { !axes.contains($0) }).allSatisfy(axes.contains) {
            let out = (0..<groups).map { EigenMath.sum(v[($0 * n)..<($0 * n + n)]) / Float(n) }
            set(op, 0, Tensor(out, shape: outShape))
            return
        }
        // Reduced dimensions next to each other (once size-1 dimensions are dropped): each output combines a strided
        // run in order, as the general loop below does.
        let reduced = kept.filter(axes.contains)
        if case .float(let v) = a.data, op.code != Op.reduceAny, let first = reduced.first,
           let at = kept.firstIndex(of: first), Array(kept[at..<min(kept.count, at + reduced.count)]) == reduced {
            let inner = kept[(at + reduced.count)...].reduce(1) { $0 * a.shape[$1] }, outer = groups / inner
            var out = [Float](repeating: op.code == Op.reduceMax ? -.infinity : (op.code == Op.reduceProd ? 1 : 0), count: groups)
            v.withUnsafeBufferPointer { v in
                out.withUnsafeMutableBufferPointer { out in
                    for o in 0..<outer {
                        let to = out.baseAddress! + o * inner
                        for r in 0..<n {
                            let from = v.baseAddress! + (o * n + r) * inner
                            switch op.code {
                            case Op.reduceMax: for j in 0..<inner { to[j] = max(to[j], from[j]) }
                            case Op.reduceProd: for j in 0..<inner { to[j] *= from[j] }
                            default: for j in 0..<inner { to[j] += from[j] }
                            }
                        }
                    }
                }
            }
            if op.code == Op.mean { for g in out.indices { out[g] /= Float(n) } }
            set(op, 0, Tensor(out, shape: outShape))
            return
        }
        let (_, _, target) = Self.broadcast(a.shape, groupShape)
        if op.code == Op.reduceAny {
            var out = [Bool](repeating: false, count: groups)
            for (i, v) in a.bools.enumerated() where v { out[target[i]] = true }
            set(op, 0, Tensor(shape: outShape, data: .bool(out)))
            return
        }
        if case .float(let v) = a.data {
            var out = [Float](repeating: op.code == Op.reduceMax ? -.infinity : (op.code == Op.reduceProd ? 1 : 0), count: groups)
            for i in v.indices {
                switch op.code {
                case Op.reduceMax: out[target[i]] = max(out[target[i]], v[i])
                case Op.reduceProd: out[target[i]] *= v[i]
                default: out[target[i]] += v[i]
                }
            }
            if op.code == Op.mean { for g in out.indices { out[g] /= Float(n) } }
            set(op, 0, Tensor(out, shape: outShape))
        } else {
            let v = a.ints
            var out = [Int](repeating: op.code == Op.reduceMax ? Int.min : (op.code == Op.reduceProd ? 1 : 0), count: groups)
            for i in v.indices {
                switch op.code {
                case Op.reduceMax: out[target[i]] = max(out[target[i]], v[i])
                case Op.reduceProd: out[target[i]] *= v[i]
                default: out[target[i]] += v[i]
                }
            }
            if op.code == Op.mean { for g in out.indices { out[g] /= n } }
            set(op, 0, Tensor(out.map { Int32(truncatingIfNeeded: $0) }, shape: outShape))
        }
    }

    /// TOPK_V2: the k largest values of each row, in decreasing order (ties: the earlier first), and their indices.
    private mutating func topK(_ op: TFLiteModel.Operator) {
        let a = input(op, 0), k = input(op, 1).ints[0]
        let row = a.shape.last ?? 1, rows = a.count / max(row, 1)
        let v = a.floats
        var picked: [Int] = [], indices: [Int32] = []
        for r in 0..<rows {
            let values = v[(r * row)..<(r * row + row)]
            let top = (0..<row).sorted { (i: Int, j: Int) -> Bool in
                let x = values[r * row + i], y = values[r * row + j]
                return x != y ? x > y : i < j
            }
            for i in top.prefix(k) {
                picked.append(r * row + i)
                indices.append(Int32(i))
            }
        }
        let shape = Array(a.shape.dropLast()) + [k]
        set(op, 0, a.gathered(picked, shape: shape))
        set(op, 1, Tensor(indices, shape: shape))
    }

    /// REVERSE_SEQUENCE: per batch entry, the first seq_lengths elements along seq_dim reversed.
    private mutating func reverseSequence(_ op: TFLiteModel.Operator) {
        let a = input(op, 0), lengths = input(op, 1).ints
        let rank = a.shape.count
        let seqDim = Int(op.options?.scalar(0, Int32(0)) ?? 0), batchDim = Int(op.options?.scalar(1, Int32(0)) ?? 0)
        var strides = [Int](repeating: 1, count: rank)
        for d in stride(from: rank - 2, through: 0, by: -1) { strides[d] = strides[d + 1] * a.shape[d + 1] }
        let indices = (0..<a.count).map { i -> Int in
            let s = i / strides[seqDim] % a.shape[seqDim], b = i / strides[batchDim] % a.shape[batchDim]
            let n = lengths[b]
            return s < n ? i + (n - 1 - 2 * s) * strides[seqDim] : i
        }
        set(op, 0, a.gathered(indices, shape: a.shape))
    }

    /// DYNAMIC_UPDATE_SLICE: the operand with `update` written at the start indices (clamped so it fits).
    private mutating func dynamicUpdateSlice(_ op: TFLiteModel.Operator) {
        let a = input(op, 0), update = input(op, 1), starts = input(op, 2).ints
        let rank = a.shape.count
        let start = (0..<rank).map { Swift.min(Swift.max(0, starts[$0]), a.shape[$0] - update.shape[$0]) }
        var strides = [Int](repeating: 1, count: rank)
        for d in stride(from: rank - 2, through: 0, by: -1) { strides[d] = strides[d + 1] * a.shape[d + 1] }
        // Per operand position, the update's index there (else -1), then runs of either.
        var source = [Int](repeating: -1, count: a.count)
        for u in 0..<update.count {
            var rest = u, at = 0
            for d in (0..<rank).reversed() {
                at += (rest % update.shape[d] + start[d]) * strides[d]
                rest /= update.shape[d]
            }
            source[at] = u
        }
        var runs = CopyRuns()
        for (i, u) in source.enumerated() { u < 0 ? runs.append(0, i, 1) : runs.append(1, u, 1) }
        set(op, 0, Tensor.copying([a, update], runs, shape: a.shape))
    }

    private mutating func segmentSum(_ op: TFLiteModel.Operator) {
        let a = input(op, 0), ids = input(op, 1).ints
        let inner = a.count / max(a.shape[0], 1)
        let segments = (ids.max() ?? -1) + 1
        var out = [Float](repeating: 0, count: segments * inner)
        let v = a.floats
        for (row, id) in ids.enumerated() {
            for j in 0..<inner { out[id * inner + j] += v[row * inner + j] }
        }
        set(op, 0, Tensor(out, shape: [segments] + a.shape.dropFirst()))
    }

    private mutating func oneHot(_ op: TFLiteModel.Operator) {
        let ids = input(op, 0).ints, depth = input(op, 1).ints[0]
        let on = input(op, 2).floats[0], off = input(op, 3).floats[0]
        var out = [Float](repeating: off, count: ids.count * depth)
        for (i, id) in ids.enumerated() where id >= 0 && id < depth { out[i * depth + id] = on }
        set(op, 0, Tensor(out, shape: input(op, 0).shape + [depth]))
    }

    // MARK: Softmax

    // As TFLite's optimized kernels compute them with Eigen: exponentials by packets of 4 (the last few scalar), sums
    // in Eigen's order.
    private mutating func softmax(_ op: TFLiteModel.Operator) throws {
        let a = input(op, 0)
        if case .uint8 = a.data { return try quantizedSoftmax(op) }
        let beta = op.options?.float(0, 1) ?? 1
        let x = a.floats
        let depth = a.shape.last ?? 1
        var out = [Float](repeating: 0, count: x.count)
        for start in stride(from: 0, to: x.count, by: depth) {
            let m = x[start..<start + depth].max() ?? 0
            for i in start..<start + depth { out[i] = (x[i] - m) * beta }
        }
        // The exponentials over the whole tensor at once.
        EigenMath.exp(&out)
        for start in stride(from: 0, to: x.count, by: depth) {
            let inverse = 1 / EigenMath.sum(out[start..<start + depth])
            for i in start..<start + depth { out[i] *= inverse }
        }
        set(op, 0, Tensor(out, shape: a.shape))
    }

    private mutating func logSoftmax(_ op: TFLiteModel.Operator) {
        let a = input(op, 0)
        let x = a.floats
        let depth = a.shape.last ?? 1
        var out = [Float](repeating: 0, count: x.count)
        for start in stride(from: 0, to: x.count, by: depth) {
            let m = x[start..<start + depth].max() ?? 0
            var e = x[start..<start + depth].map { $0 - m }
            EigenMath.exp(&e)
            let logSum = Darwin.log(EigenMath.sum(e[...]))
            for i in start..<start + depth { out[i] = x[i] - m - logSum }
        }
        set(op, 0, Tensor(out, shape: a.shape))
    }

    // MARK: Fully connected

    private mutating func fullyConnected(_ op: TFLiteModel.Operator) throws {
        let x = input(op, 0), w = input(op, 1)
        if case .uint8 = x.data { return try quantizedFullyConnected(op) }
        let options = op.options
        let activation = options?.scalar(0, Int8(0)) ?? 0
        let keepDims = options?.bool(2) ?? false
        let asymmetric = options?.bool(3) ?? false
        let columns = w.shape[1], units = w.shape[0]
        let batch = x.count / columns
        let bias = hasInput(op, 2) ? input(op, 2).floats : nil
        let inputs = x.floats
        var out = [Float](repeating: 0, count: batch * units)
        if case .float(let weights) = w.data {
            // A float layer: out = bias + x Wᵀ.
            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(batch), Int32(units), Int32(columns), 1, inputs,
                        Int32(columns), weights, Int32(columns), 0, &out, Int32(units))
            if let bias { for b in 0..<batch { for u in 0..<units { out[b * units + u] = bias[u] + out[b * units + u] } } }
        } else if graph.tensors[op.inputs[1]].type == .int4, TFLiteModel.packed4Bit(w.shape) {
            out = Self.hybrid4Bit(inputs, batch: batch, weights: interpreter.weights(op.inputs[1], of: subgraph, w),
                                  units: units, columns: columns, quantization: w.quantization, bias: bias)
        } else {
            out = Self.hybrid(inputs, batch: batch, weights: interpreter.weights(op.inputs[1], of: subgraph, w),
                              units: units, columns: columns, quantization: w.quantization, bias: bias, asymmetric: asymmetric,
                              sums: &interpreter.sums)
        }
        Self.activate(&out, activation)
        let shape = keepDims ? Array(x.shape.dropLast()) + [units] : [batch, units]
        set(op, 0, Tensor(out, shape: shape))
    }

    /// TFLite's hybrid fully connected layer (float input, int8 weights): each input row is quantized to int8 (per
    /// row, symmetric or asymmetric), multiplied with the weights in integers, and scaled back. Block-sparse weights
    /// take TFLite's sparse kernel (its sdot version), which takes the zero point's share off the bias first and then
    /// adds each row's products.
    /// `sums`: room for the integer sums, grown as needed.
    static func hybrid(_ x: [Float], batch: Int, weights: HybridWeights, units: Int, columns: Int,
                       quantization: Quantization, bias: [Float]?, asymmetric: Bool, sums: inout [Int32]) -> [Float] {
        // The bias in each row (or zeros).
        var out = [Float](unsafeUninitializedCapacity: batch * units) { o, count in
            if let bias {
                bias.withUnsafeBufferPointer { bias in
                    for b in 0..<batch { (o.baseAddress! + b * units).initialize(from: bias.baseAddress!, count: units) }
                }
            } else {
                o.initialize(repeating: 0)
            }
            count = batch * units
        }
        // An all-zero input leaves the bias.
        if soda_all_zero(x, x.count) != 0 { return out }
        // Each row quantized on its own (every byte written).
        var factors = [Float](repeating: 1, count: batch), offsets = [Int32](repeating: 0, count: batch)
        let quantized = [Int8](unsafeUninitializedCapacity: x.count) { q, count in
            x.withUnsafeBufferPointer { x in
                for b in 0..<batch {
                    let at = b * columns
                    if asymmetric {
                        soda_quantize_asymmetric(x.baseAddress! + at, Int32(columns), q.baseAddress! + at, &factors[b], &offsets[b])
                    } else {
                        factors[b] = soda_quantize_symmetric(x.baseAddress! + at, Int32(columns), q.baseAddress! + at)
                    }
                }
            }
            count = x.count
        }
        let perChannel = quantization.scales.count > 1
        let scales = quantization.scales
        if !perChannel { for b in 0..<batch { factors[b] *= quantization.scale } }
        if sums.count < batch * units { sums = [Int32](repeating: 0, count: batch * units) }
        /// Each row's sums scaled back into `out`.
        func rescale(sparse: Bool) {
            out.withUnsafeMutableBufferPointer { out in
                sums.withUnsafeBufferPointer { dots in
                    weights.rowSums.withUnsafeBufferPointer { rowSums in
                        scales.withUnsafeBufferPointer { scales in
                            for b in 0..<batch {
                                soda_rescale(out.baseAddress! + b * units, dots.baseAddress! + b * units, rowSums.baseAddress,
                                             perChannel ? scales.baseAddress : nil, factors[b], offsets[b], Int32(units),
                                             sparse ? 1 : 0, asymmetric ? 1 : 0)
                            }
                        }
                    }
                }
            }
        }
        if let sparsity = weights.sparsity {
            // The kernel's scratch space after the sums.
            let scratch = 4 * (sparsity.blocks / 2 + 2)
            if sums.count < batch * units + scratch { sums = [Int32](repeating: 0, count: batch * units + scratch) }
            weights.withValues { w in
                sums.withUnsafeMutableBufferPointer {
                    soda_sparse_dot_s8(quantized, Int32(batch), w, sparsity.segments, sparsity.indices.baseAddress,
                                       Int32(sparsity.indexSize), Int32(units), Int32(columns), $0.baseAddress!,
                                       $0.baseAddress! + batch * units)
                }
            }
            rescale(sparse: true)
            return out
        }
        weights.withValues { soda_dot_s8(quantized, Int32(batch), $0, Int32(units), Int32(columns), &sums) }
        rescale(sparse: false)
        return out
    }

    /// TFLite's 4-bit hybrid layer (optimized_4bit, which int4 weights take): each input row is scaled to ±127 by its
    /// largest magnitude (the factors divided in double), the weights are held as w + 7, and their sum's offset goes
    /// into the bias first (fused), then each product sum is added as (sum · input scale) · weight scale.
    static func hybrid4Bit(_ x: [Float], batch: Int, weights: HybridWeights, units: Int, columns: Int,
                           quantization: Quantization, bias: [Float]?) -> [Float] {
        let scales = quantization.scales.count > 1 ? quantization.scales
            : [Float](repeating: quantization.scale, count: units)
        var quantized = [Int8](repeating: 0, count: x.count)
        var factors = [Float](repeating: 1, count: batch), offsets = [Int32](repeating: 0, count: batch)
        for b in 0..<batch {
            let row = b * columns..<(b + 1) * columns
            var largest = x[row].reduce(Float(0)) { max($0, abs($1)) }
            if largest == 0 { largest = 127 }
            let inverse = Float(127.0 / Double(largest))
            factors[b] = Float(Double(largest) / 127.0)
            var sum: Int32 = 0
            for i in row {
                let q = Int8(clamping: Int32(clamping: Int64((x[i] * inverse).rounded(.toNearestOrAwayFromZero))))
                quantized[i] = q
                sum += Int32(q)
            }
            offsets[b] = sum
        }
        var dots = [Int32](repeating: 0, count: batch * units)
        weights.withValues { w in
            if weights.packed4Bit {
                w.withMemoryRebound(to: UInt8.self, capacity: units * columns / 2) {
                    soda_dot_s4(quantized, Int32(batch), $0, Int32(units), Int32(columns), &dots)
                }
            } else {
                soda_dot_s8(quantized, Int32(batch), w, Int32(units), Int32(columns), &dots)
            }
        }
        var out = [Float](repeating: 0, count: batch * units)
        let fused = units & ~3
        for b in 0..<batch {
            let share = Float(offsets[b] &* -7) * factors[b]
            for u in 0..<units {
                if let bias {
                    out[b * units + u] = u < fused ? bias[u].addingProduct(scales[u], share) : share * scales[u] + bias[u]
                } else {
                    out[b * units + u] = scales[u] * share
                }
            }
            for u in 0..<units {
                let held = dots[b * units + u] &+ 7 &* offsets[b]
                out[b * units + u] = (Float(held) * factors[b]) * scales[u] + out[b * units + u]
            }
        }
        return out
    }

    /// TFLite's NeonSymmetricQuantizeFloats: the row scaled to ±127 by its largest magnitude.
    static func quantizeSymmetric(_ x: [Float], _ row: Range<Int>, into q: inout [Int8]) -> Float {
        x.withUnsafeBufferPointer { x in
            q.withUnsafeMutableBufferPointer { q in
                soda_quantize_symmetric(x.baseAddress! + row.lowerBound, Int32(row.count), q.baseAddress! + row.lowerBound)
            }
        }
    }

    /// TFLite's NeonAsymmetricQuantizeFloats: the row's range mapped to -128...127 with a zero point.
    static func quantizeAsymmetric(_ x: [Float], _ row: Range<Int>, into q: inout [Int8]) -> (Float, Int32) {
        var scale: Float = 1, zero: Int32 = 0
        x.withUnsafeBufferPointer { x in
            q.withUnsafeMutableBufferPointer { q in
                soda_quantize_asymmetric(x.baseAddress! + row.lowerBound, Int32(row.count), q.baseAddress! + row.lowerBound,
                                         &scale, &zero)
            }
        }
        return (scale, zero)
    }
}

/// Eigen's float approximations, as TFLite's optimized kernels compute TANH, LOGISTIC and softmaxes (Eigen as
/// libsoda's TFLite has it, with fused multiply-adds on Arm).
enum EigenMath {
    /// Eigen's pexp_float: exp(r) by a degree-6 polynomial, times 2^m (soda_packet_exp does the same).
    static func packetExp(_ input: Float) -> Float {
        if input < -104 { return 0 }
        let x = min(input, 88.723)
        let m = Float(0.5).addingProduct(x, 1.44269504088896341).rounded(.down)
        var r = x.addingProduct(m, -0.693359375)
        r = r.addingProduct(m, 2.12194440e-4)
        let r2 = r * r
        var even = Float(4.166965186595916748046875e-2).addingProduct(r2, 1.37449637986719608306884765625e-3)
        let odd = Float(0.16666518151760101318359375).addingProduct(r2, 8.36894474923610687255859375e-3)
        even = Float(0.49999988079071044921875).addingProduct(r2, even)
        let low = r + 1
        var y = even.addingProduct(r, odd)
        y = low.addingProduct(r2, y)
        return max(ldexp(y, m), input)
    }

    /// Eigen's pldexp_generic: y * 2^m in four factors.
    private static func ldexp(_ a: Float, _ exponent: Float) -> Float {
        let e = Int32(min(max(exponent, -278), 278))
        var b = e >> 2
        var c = Float(bitPattern: UInt32(bitPattern: (b + 127) << 23))
        var out = a * c * c * c
        b = e - 3 * b
        c = Float(bitPattern: UInt32(bitPattern: (b + 127) << 23))
        out = out * c
        return out
    }

    /// exp of each value as an Eigen array expression evaluates it: by packets of 4 from the start, the rest with
    /// the scalar exp.
    static func exp(_ values: inout [Float]) {
        let packets = values.count / 4 * 4
        values.withUnsafeMutableBufferPointer { v in
            if packets > 0 { soda_packet_exp(v.baseAddress!, v.baseAddress!, packets) }
        }
        for i in packets..<values.count { values[i] = Darwin.exp(values[i]) }
    }

    /// Eigen's vectorized sum (redux_impl, LinearVectorizedTraversal) of a slice of a tensor whose buffer is 16-byte
    /// aligned: packets from the first aligned index into two accumulators, a pairwise horizontal sum, then the
    /// unaligned head and the tail one by one.
    static func sum(_ v: ArraySlice<Float>) -> Float {
        let base = v.startIndex, n = v.count
        let start = min((4 - base % 4) % 4, n)
        let size = (n - start) / 4 * 4, size2 = (n - start) / 8 * 8
        guard size > 0 else { return v.dropFirst().reduce(v.first ?? 0, +) }
        func packet(_ i: Int) -> SIMD4<Float> { SIMD4<Float>(v[base + i..<base + i + 4]) }
        var r0 = packet(start)
        if size > 4 {
            var r1 = packet(start + 4)
            for i in stride(from: start + 8, to: start + size2, by: 8) {
                r0 = r0 + packet(i)
                r1 = r1 + packet(i + 4)
            }
            r0 = r0 + r1
            if size > size2 { r0 = r0 + packet(start + size2) }
        }
        var result = (r0[0] + r0[1]) + (r0[2] + r0[3])
        for i in 0..<start { result += v[base + i] }
        for i in (start + size)..<n { result += v[base + i] }
        return result
    }

    /// Eigen's ptanh_float (late 2025): a [9,8] rational approximation on [-8.0177, 8.0177] (soda_tanh does the same).
    static func tanh(_ a: Float) -> Float {
        let x = min(max(a, -8.01773357391357422), 8.01773357391357422)
        let x2 = x * x, x3 = x2 * x
        var p: Float = 1.394553628e-8
        for c: Float in [2.102733560e-5, 3.520756727e-3, 1.340216100e-1] { p = c.addingProduct(p, x2) }
        var q: Float = 8.015776984e-7
        for c: Float in [3.326951409e-4, 2.597254514e-2, 4.673548340e-1, 1.0] { q = c.addingProduct(q, x2) }
        p = x.addingProduct(x3, p)
        return p / q
    }

    /// Eigen's scalar_logistic_op<float> packet path: exp(x/2) by a degree-5 polynomial, squared, then e / (1 + e)
    /// (soda_logistic does the same).
    static func logistic(_ input: Float) -> Float {
        if input < -104 { return 0 }
        var x = min(input, 16.6355324)
        x *= 0.5
        let m = (0.5 as Float).addingProduct(x, 1.44269504088896341).rounded(.down)
        var r = x.addingProduct(m, -0.693359375)
        r = r.addingProduct(m, 2.12194440e-4)
        let r2 = r * r
        let even = Float(0.49999141693115234375).addingProduct(r2, 4.1898667812347412109375e-2)
        let odd = Float(0.16666877269744873046875).addingProduct(r2, 8.33471305668354034423828125e-3)
        let low = r + 1
        var p = even.addingProduct(r, odd)
        p = low.addingProduct(r2, p)
        let exponent = Int32(min(max(m + 127, 0), 255))
        var e = p * Float(bitPattern: UInt32(exponent) << 23)
        e = e * e
        return e / (1 + e)
    }
}
