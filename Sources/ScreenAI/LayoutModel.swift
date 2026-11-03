import Accelerate
import Foundation

// The layout analysis' graph network (gocr/layout/cluster_sort/model_v2.tflite): per text line, whether its
// paragraph reads in columns. Its shapes depend on the number of lines and edges, which Core ML can't run
// efficiently, and it's small, so it runs here: scripts/convert-screenai.py exports its operators and constants to
// layout/, and this evaluates them in order with TensorFlow Lite's reference semantics in 32-bit floats.

private enum Values {
    case float([Float]), int32([Int32]), int64([Int64]), bool([Bool])

    var count: Int {
        switch self {
        case .float(let v): v.count
        case .int32(let v): v.count
        case .int64(let v): v.count
        case .bool(let v): v.count
        }
    }

    /// Integer values (indices, shapes, axes).
    var ints: [Int] {
        switch self {
        case .int32(let v): v.map { Int($0) }
        case .int64(let v): v.map { Int($0) }
        case .float(let v): v.map { Int($0) }
        case .bool(let v): v.map { $0 ? 1 : 0 }
        }
    }

    /// The values at `indices`, in that order.
    func gathered(_ indices: [Int]) -> Values {
        switch self {
        case .float(let v): .float(indices.map { v[$0] })
        case .int32(let v): .int32(indices.map { v[$0] })
        case .int64(let v): .int64(indices.map { v[$0] })
        case .bool(let v): .bool(indices.map { v[$0] })
        }
    }

    /// The `width` values from `row * width` for each of `rows`, in that order.
    func rows(_ rows: [Int], _ width: Int) -> Values {
        func copy<T>(_ v: [T]) -> [T] {
            var out: [T] = []
            out.reserveCapacity(rows.count * width)
            for r in rows { out += v[r * width..<(r + 1) * width] }
            return out
        }
        switch self {
        case .float(let v): return .float(copy(v))
        case .int32(let v): return .int32(copy(v))
        case .int64(let v): return .int64(copy(v))
        case .bool(let v): return .bool(copy(v))
        }
    }

    /// `count` values of this type, all `fill` (the first value of a tensor of the same type).
    static func filled(_ fill: Values, _ count: Int) -> Values {
        switch fill {
        case .float(let v): .float([Float](repeating: v[0], count: count))
        case .int32(let v): .int32([Int32](repeating: v[0], count: count))
        case .int64(let v): .int64([Int64](repeating: v[0], count: count))
        case .bool(let v): .bool([Bool](repeating: v[0], count: count))
        }
    }
}

private struct Tensor {
    var shape: [Int]
    var values: Values

    var count: Int { shape.reduce(1, *) }
}

private struct Operator {
    var op: String
    var inputs: [Int], outputs: [Int]
    var options: [String: Int]
    /// FULLY_CONNECTED with constant weights: them transposed ([inputs][units]).
    var transposedWeights: [Float]? = nil
}

/// Row-major strides.
private func strides(_ shape: [Int]) -> [Int] {
    var s = [Int](repeating: 1, count: shape.count)
    var k = shape.count - 2
    while k >= 0 {
        s[k] = s[k + 1] * shape[k + 1]
        k -= 1
    }
    return s
}

/// Where an input of a broadcast reads its value for each output element.
private enum IndexMap {
    /// The input has the output's shape.
    case same
    /// A single value.
    case scalar
    /// Repeats along the leading dimensions: element k reads k % n.
    case modulo(Int)
    /// Repeats along the trailing dimensions: element k reads k / n.
    case divide(Int)
    case table([Int])

    @inline(__always) func callAsFunction(_ k: Int) -> Int {
        switch self {
        case .same: k
        case .scalar: 0
        case .modulo(let n): k % n
        case .divide(let n): k / n
        case .table(let t): t[k]
        }
    }
}

/// NumPy-style broadcasting: the output shape, and per input where it reads each output element.
private func broadcast(_ shapes: [[Int]]) throws -> (shape: [Int], maps: [IndexMap]) {
    if shapes.allSatisfy({ $0 == shapes[0] }) { return (shapes[0], [IndexMap](repeating: .same, count: shapes.count)) }
    let rank = shapes.map(\.count).max() ?? 0
    let padded = shapes.map { [Int](repeating: 1, count: rank - $0.count) + $0 }
    var out = [Int](repeating: 1, count: rank)
    for d in 0..<rank {
        for s in padded where s[d] != 1 {
            if out[d] != 1 && out[d] != s[d] { throw ScreenAIError("Layout model: shapes don't broadcast") }
            out[d] = s[d]
        }
        if padded.contains(where: { $0[d] == 0 }) { out[d] = 0 }
    }
    let total = out.reduce(1, *)
    let maps: [IndexMap] = padded.map { s in
        if s == out || total == 0 { return .same }
        let count = s.reduce(1, *)
        if count == 1 { return .scalar }
        // Ones then the output's dimensions, or the output's dimensions then ones.
        if let first = s.firstIndex(where: { $0 != 1 }), s[first...] == out[first...] { return .modulo(count) }
        if let last = s.lastIndex(where: { $0 != 1 }), s[...last] == out[...last] { return .divide(total / count) }
        let st = strides(s)
        var map = [Int](repeating: 0, count: total)
        var index = [Int](repeating: 0, count: rank)
        for k in 0..<total {
            var flat = 0
            for d in 0..<rank where s[d] != 1 { flat += index[d] * st[d] }
            map[k] = flat
            var d = rank - 1
            while d >= 0 {
                index[d] += 1
                if index[d] < out[d] { break }
                index[d] = 0
                d -= 1
            }
        }
        return .table(map)
    }
    return (out, maps)
}

final class LayoutModel {
    private let tensorTypes: [String]
    private let constants: [Tensor?]
    private let operators: [Operator]
    private let inputs: [Int], outputs: [Int]
    /// Per operator, the tensors it reads last (freed after it, so later results reuse warm memory).
    private let lastReads: [[Int]]

    init(resources: Resources) throws {
        guard let manifestBytes = resources.read("layout/layout.json"), let blob = resources.read("layout/layout.bin"),
              let manifest = try? JSONSerialization.jsonObject(with: Data(manifestBytes)) as? [String: Any],
              let tensorSpecs = manifest["tensors"] as? [[String: Any]],
              let operatorSpecs = manifest["operators"] as? [[String: Any]],
              let inputs = manifest["inputs"] as? [Int], let outputs = manifest["outputs"] as? [Int],
              inputs.count == 3, outputs.count >= 2
        else { throw ScreenAIError("The layout model is missing (convert the models again)") }
        var types: [String] = []
        var constants: [Tensor?] = []
        for spec in tensorSpecs {
            guard let type = spec["type"] as? String, let shape = spec["shape"] as? [Int] else {
                throw ScreenAIError("Bad layout model manifest")
            }
            types.append(type)
            guard let offset = spec["offset"] as? Int else {
                constants.append(nil)
                continue
            }
            let n = shape.reduce(1, *)
            let size = type == "bool" ? 1 : type == "int64" ? 8 : 4
            guard offset >= 0, offset + n * size <= blob.count else { throw ScreenAIError("Bad layout model weights") }
            let values: Values = blob[offset..<offset + n * size].withUnsafeBytes { raw in
                switch type {
                case "float32": .float((0..<n).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4 * $0, as: UInt32.self))) })
                case "int32": .int32((0..<n).map { Int32(littleEndian: raw.loadUnaligned(fromByteOffset: 4 * $0, as: Int32.self)) })
                case "int64": .int64((0..<n).map { Int64(littleEndian: raw.loadUnaligned(fromByteOffset: 8 * $0, as: Int64.self)) })
                default: .bool((0..<n).map { raw[$0] != 0 })
                }
            }
            constants.append(Tensor(shape: shape, values: values))
        }
        tensorTypes = types
        self.constants = constants
        var operators = try operatorSpecs.map { spec in
            guard let op = spec["op"] as? String, let ins = spec["inputs"] as? [Int], let outs = spec["outputs"] as? [Int],
                  (ins + outs).allSatisfy({ $0 < types.count })
            else { throw ScreenAIError("Bad layout model manifest") }
            // A native copy of the name: the bridged one compares slowly in every switch.
            return Operator(op: String(decoding: Array(op.utf8), as: UTF8.self), inputs: ins, outputs: outs,
                            options: spec["options"] as? [String: Int] ?? [:])
        }
        for k in operators.indices where operators[k].op == "FULLY_CONNECTED" && operators[k].inputs.count > 1 {
            let w = operators[k].inputs[1]
            guard w >= 0, let t = constants[w], t.shape.count == 2, case .float(let v) = t.values else { continue }
            let units = t.shape[0], n = t.shape[1]
            var transposed = [Float](repeating: 0, count: v.count)
            for u in 0..<units {
                for j in 0..<n { transposed[j * units + u] = v[u * n + j] }
            }
            operators[k].transposedWeights = transposed
        }
        self.operators = operators
        self.inputs = inputs
        self.outputs = outputs
        var lastReader = [Int](repeating: -1, count: types.count)
        for (k, op) in operators.enumerated() {
            for i in op.inputs where i >= 0 { lastReader[i] = k }
        }
        var lastReads = [[Int]](repeating: [], count: operators.count)
        for (i, k) in lastReader.enumerated() where k >= 0 && !outputs.contains(i) { lastReads[k].append(i) }
        self.lastReads = lastReads
    }

    /// The node outputs (one logit per line) for the graph's edges (`senders[k]` - `receivers[k]`) and line
    /// features ([lines][30]).
    func nodeLogits(senders: [Int], receivers: [Int], features: [Float], lines: Int) throws -> [Float] {
        var tensors = constants
        tensors[inputs[0]] = Tensor(shape: [senders.count], values: .int64(senders.map { Int64($0) }))
        tensors[inputs[1]] = Tensor(shape: [receivers.count], values: .int64(receivers.map { Int64($0) }))
        tensors[inputs[2]] = Tensor(shape: [lines, features.count / max(lines, 1)], values: .float(features))
        for (k, op) in operators.enumerated() {
            let ins = try op.inputs.map { i -> Tensor? in
                if i < 0 { return nil }
                guard let t = tensors[i] else { throw ScreenAIError("Layout model: \(op.op) input not computed") }
                return t
            }
            for i in lastReads[k] { tensors[i] = nil }
            let out = try run(op, ins, outputType: tensorTypes[op.outputs[0]])
            tensors[op.outputs[0]] = out
        }
        guard let out = tensors[outputs[1]], case .float(let logits) = out.values, logits.count >= lines else {
            throw ScreenAIError("Layout model: no node outputs")
        }
        return Array(logits.prefix(lines))
    }

    // MARK: Operators

    private func run(_ op: Operator, _ ins: [Tensor?], outputType: String) throws -> Tensor {
        func input(_ k: Int) throws -> Tensor {
            guard k < ins.count, let t = ins[k] else { throw ScreenAIError("Layout model: \(op.op) is missing an input") }
            return t
        }
        switch op.op {
        case "ADD", "SUB", "MUL", "DIV", "MAXIMUM", "MINIMUM":
            return try arithmetic(op.op, try input(0), try input(1))
        case "LESS", "LESS_EQUAL", "GREATER_EQUAL":
            return try comparison(op.op, try input(0), try input(1))
        case "LOGICAL_AND":
            let a = try input(0), b = try input(1)
            guard case .bool(let x) = a.values, case .bool(let y) = b.values else { throw unsupported(op) }
            let (shape, maps) = try broadcast([a.shape, b.shape])
            return Tensor(shape: shape, values: .bool(elementwise(And.self, x, y, maps, shape)))
        case "SELECT":
            let c = try input(0), a = try input(1), b = try input(2)
            guard case .bool(let cond) = c.values else { throw unsupported(op) }
            let (shape, maps) = try broadcast([c.shape, a.shape, b.shape])
            let n = shape.reduce(1, *)
            func select<T>(_ x: [T], _ y: [T]) -> [T] {
                [T](unsafeUninitializedCapacity: n) { out, count in
                    guard let out = out.baseAddress else { return }
                    if case .same = maps[0], case .same = maps[1], case .same = maps[2] {
                        cond.withUnsafeBufferPointer { c in
                            x.withUnsafeBufferPointer { x in
                                y.withUnsafeBufferPointer { y in
                                    for k in 0..<n { (out + k).initialize(to: c[k] ? x[k] : y[k]) }
                                }
                            }
                        }
                    } else {
                        for k in 0..<n { (out + k).initialize(to: cond[maps[0](k)] ? x[maps[1](k)] : y[maps[2](k)]) }
                    }
                    count = n
                }
            }
            switch (a.values, b.values) {
            case (.float(let x), .float(let y)): return Tensor(shape: shape, values: .float(select(x, y)))
            case (.int32(let x), .int32(let y)): return Tensor(shape: shape, values: .int32(select(x, y)))
            default: throw unsupported(op)
            }
        case "EXP", "RSQRT":
            let a = try input(0)
            guard case .float(let x) = a.values else { throw unsupported(op) }
            return Tensor(shape: a.shape, values: .float(op.op == "EXP" ? x.map { expf($0) } : x.map { 1 / sqrtf($0) }))
        case "CAST":
            let a = try input(0)
            return Tensor(shape: a.shape, values: try cast(a.values, to: outputType))
        case "SHAPE":
            let a = try input(0)
            let dims = [Int64](a.shape.map { Int64($0) })
            return Tensor(shape: [a.shape.count],
                          values: outputType == "int64" ? .int64(dims) : .int32(dims.map { Int32($0) }))
        case "FILL":
            let dims = try input(0).values.ints, value = try input(1)
            return Tensor(shape: dims, values: .filled(value.values, dims.reduce(1, *)))
        case "RESHAPE":
            let a = try input(0)
            var shape = try input(1).values.ints
            if let k = shape.firstIndex(of: -1) {
                let known = shape.enumerated().filter { $0.offset != k }.map(\.element).reduce(1, *)
                shape[k] = known == 0 ? 0 : a.count / known
            }
            guard shape.reduce(1, *) == a.count else { throw ScreenAIError("Layout model: bad reshape") }
            return Tensor(shape: shape, values: a.values)
        case "EXPAND_DIMS":
            let a = try input(0)
            var axis = try input(1).values.ints[0]
            if axis < 0 { axis += a.shape.count + 1 }
            var shape = a.shape
            shape.insert(1, at: axis)
            return Tensor(shape: shape, values: a.values)
        case "TRANSPOSE":
            let a = try input(0)
            let perm = try input(1).values.ints
            let shape = perm.map { a.shape[$0] }
            // Moving only dimensions of size 1 keeps the order of the values.
            let moved = perm.filter { a.shape[$0] != 1 }
            if moved == moved.sorted() { return Tensor(shape: shape, values: a.values) }
            let inStrides = strides(a.shape)
            var map: [Int] = []
            map.reserveCapacity(a.count)
            forEachIndex(shape) { index in
                var flat = 0
                for d in 0..<perm.count { flat += index[d] * inStrides[perm[d]] }
                map.append(flat)
            }
            return Tensor(shape: shape, values: a.values.gathered(map))
        case "BROADCAST_TO":
            let a = try input(0)
            let target = try input(1).values.ints
            let (shape, maps) = try broadcast([a.shape, target])
            guard shape == target else { throw ScreenAIError("Layout model: bad broadcast") }
            if case .same = maps[0] { return Tensor(shape: shape, values: a.values) }
            return Tensor(shape: shape, values: a.values.gathered((0..<shape.reduce(1, *)).map { maps[0]($0) }))
        case "SLICE":
            let a = try input(0)
            let begin = try input(1).values.ints
            let size = try input(2).values.ints
            let ends = a.shape.indices.map { size[$0] < 0 ? a.shape[$0] : begin[$0] + size[$0] }
            return try slice(a, begin, ends, [Int](repeating: 1, count: a.shape.count), shrink: 0)
        case "STRIDED_SLICE":
            let a = try input(0)
            var begin = try input(1).values.ints
            var end = try input(2).values.ints
            let step = try input(3).values.ints
            let o = op.options
            guard step.allSatisfy({ $0 == 1 }), o["ellipsis_mask"] ?? 0 == 0, o["new_axis_mask"] ?? 0 == 0,
                  o["offset"] ?? 0 == 0
            else { throw unsupported(op) }
            for d in a.shape.indices {
                let dim = a.shape[d]
                if (o["begin_mask"] ?? 0) >> d & 1 == 1 { begin[d] = 0 }
                if (o["end_mask"] ?? 0) >> d & 1 == 1 { end[d] = dim }
                if begin[d] < 0 { begin[d] += dim }
                if end[d] < 0 { end[d] += dim }
                if (o["shrink_axis_mask"] ?? 0) >> d & 1 == 1 { end[d] = begin[d] + 1 }
                begin[d] = min(max(begin[d], 0), dim)
                end[d] = min(max(end[d], 0), dim)
            }
            return try slice(a, begin, end, step, shrink: o["shrink_axis_mask"] ?? 0)
        case "GATHER":
            let params = try input(0), indices = try input(1)
            guard op.options["axis"] ?? 0 == 0, op.options["batch_dims"] ?? 0 == 0 else { throw unsupported(op) }
            let inner = params.shape.dropFirst().reduce(1, *)
            let rows = indices.values.ints
            guard rows.allSatisfy({ $0 >= 0 && $0 < params.shape[0] }) else {
                throw ScreenAIError("Layout model: gather index out of range")
            }
            return Tensor(shape: indices.shape + params.shape.dropFirst(), values: params.values.rows(rows, inner))
        case "GATHER_ND":
            let params = try input(0), indices = try input(1)
            let k = indices.shape.last ?? 0
            let inner = params.shape.dropFirst(k).reduce(1, *)
            let st = strides(params.shape)
            let idx = indices.values.ints
            var rows: [Int] = []
            rows.reserveCapacity(k == 0 ? 0 : idx.count / k)
            for row in 0..<(k == 0 ? 0 : idx.count / k) {
                var flat = 0
                for d in 0..<k {
                    let i = idx[row * k + d]
                    guard i >= 0 && i < params.shape[d] else { throw ScreenAIError("Layout model: gather index out of range") }
                    flat += i * st[d]
                }
                rows.append(flat / max(inner, 1))
            }
            return Tensor(shape: indices.shape.dropLast() + params.shape.dropFirst(k), values: params.values.rows(rows, inner))
        case "SCATTER_ND":
            let indices = try input(0), updates = try input(1)
            let shape = try input(2).values.ints
            guard case .float(let u) = updates.values else { throw unsupported(op) }
            let k = indices.shape.last ?? 0
            let inner = shape.dropFirst(k).reduce(1, *)
            let st = strides(shape)
            let idx = indices.values.ints
            var out = [Float](repeating: 0, count: shape.reduce(1, *))
            let rows = k == 0 ? 0 : idx.count / k
            guard u.count >= rows * inner else { throw ScreenAIError("Layout model: bad scatter") }
            try out.withUnsafeMutableBufferPointer { out in
                try u.withUnsafeBufferPointer { u in
                    for row in 0..<rows {
                        var flat = 0
                        for d in 0..<k {
                            let i = idx[row * k + d]
                            guard i >= 0 && i < shape[d] else { throw ScreenAIError("Layout model: scatter index out of range") }
                            flat += i * st[d]
                        }
                        for j in 0..<inner { out[flat + j] += u[row * inner + j] }
                    }
                }
            }
            return Tensor(shape: shape, values: .float(out))
        case "UNSORTED_SEGMENT_PROD":
            let data = try input(0), idsTensor = try input(1)
            let ids = idsTensor.values.ints, segments = try input(2).values.ints[0]
            guard case .int32(let v) = data.values else { throw unsupported(op) }
            let inner = data.count / max(ids.count, 1)
            var out = [Int32](repeating: 1, count: segments * inner)
            for (row, id) in ids.enumerated() where id >= 0 && id < segments {
                for j in 0..<inner { out[id * inner + j] &*= v[row * inner + j] }
            }
            return Tensor(shape: [segments] + data.shape.dropFirst(idsTensor.shape.count), values: .int32(out))
        case "SUM", "REDUCE_ALL":
            let a = try input(0)
            let axes = Set(try input(1).values.ints.map { $0 < 0 ? $0 + a.shape.count : $0 })
            let keep = op.options["keep_dims"] ?? 0 != 0
            if op.op == "SUM", axes == [a.shape.count - 1], case .float(let x) = a.values {
                // Each row's sum, in order.
                let inner = a.shape.last ?? 1, rows = inner == 0 ? 0 : x.count / inner
                var out = [Float](repeating: 0, count: rows)
                for r in 0..<rows {
                    var acc: Float = 0
                    for j in 0..<inner { acc += x[r * inner + j] }
                    out[r] = acc
                }
                return Tensor(shape: keep ? a.shape.dropLast() + [1] : Array(a.shape.dropLast()), values: .float(out))
            }
            let kept = a.shape.indices.map { axes.contains($0) ? 1 : a.shape[$0] }
            let outStrides = strides(kept)
            var targets: [Int] = []
            targets.reserveCapacity(a.count)
            forEachIndex(a.shape) { index in
                var flat = 0
                for d in index.indices where !axes.contains(d) { flat += index[d] * outStrides[d] }
                targets.append(flat)
            }
            let shape = keep ? kept : a.shape.indices.filter { !axes.contains($0) }.map { a.shape[$0] }
            let n = kept.reduce(1, *)
            switch a.values {
            case .float(let x) where op.op == "SUM":
                var out = [Float](repeating: 0, count: n)
                for (k, t) in targets.enumerated() { out[t] += x[k] }
                return Tensor(shape: shape, values: .float(out))
            case .bool(let x) where op.op == "REDUCE_ALL":
                var out = [Bool](repeating: true, count: n)
                for (k, t) in targets.enumerated() { out[t] = out[t] && x[k] }
                return Tensor(shape: shape, values: .bool(out))
            default:
                throw unsupported(op)
            }
        case "CONCATENATION":
            let parts = try (0..<ins.count).map { try input($0) }
            var axis = op.options["axis"] ?? 0
            let rank = parts[0].shape.count
            if axis < 0 { axis += rank }
            var shape = parts[0].shape
            shape[axis] = parts.map { $0.shape[axis] }.reduce(0, +)
            let outer = shape.prefix(axis).reduce(1, *)
            let blocks = parts.map { $0.shape.dropFirst(axis).reduce(1, *) }
            func concatenated<T>(_ v: [[T]]) -> [T] {
                var out: [T] = []
                out.reserveCapacity(shape.reduce(1, *))
                for o in 0..<outer {
                    for (p, block) in blocks.enumerated() { out += v[p][o * block..<(o + 1) * block] }
                }
                return out
            }
            switch parts[0].values {
            case .float:
                return Tensor(shape: shape, values: .float(concatenated(parts.map { if case .float(let x) = $0.values { x } else { [] } })))
            case .int32:
                return Tensor(shape: shape, values: .int32(concatenated(parts.map { if case .int32(let x) = $0.values { x } else { [] } })))
            default:
                throw unsupported(op)
            }
        case "FULLY_CONNECTED":
            let a = try input(0), w = try input(1)
            guard case .float(let x) = a.values, case .float(let weights) = w.values, w.shape.count == 2 else {
                throw unsupported(op)
            }
            let k = w.shape[1], units = w.shape[0]
            let rows = k == 0 ? 0 : x.count / k
            var transposed = op.transposedWeights ?? []
            if op.transposedWeights == nil {
                transposed = [Float](repeating: 0, count: weights.count)
                for u in 0..<units {
                    for j in 0..<k { transposed[j * units + u] = weights[u * k + j] }
                }
            }
            // x * weightsᵀ + bias (summed in another order than TensorFlow Lite's, as its XNNPACK one is).
            var out = [Float](repeating: 0, count: rows * units)
            if rows > 0 && units > 0 && k > 0 {
                vDSP_mmul(x, 1, transposed, 1, &out, 1, vDSP_Length(rows), vDSP_Length(units), vDSP_Length(k))
            }
            if ins.count > 2, let b = ins[2], case .float(let bias) = b.values, bias.count == units {
                out.withUnsafeMutableBufferPointer { out in
                    for r in 0..<rows {
                        let row = out.baseAddress! + r * units
                        vDSP_vadd(row, 1, bias, 1, row, 1, vDSP_Length(units))
                    }
                }
            }
            return Tensor(shape: a.shape.dropLast() + [units], values: .float(out))
        default:
            throw unsupported(op)
        }
    }

    private func unsupported(_ op: Operator) -> ScreenAIError {
        ScreenAIError("Layout model: unsupported \(op.op)")
    }

    private func arithmetic(_ op: String, _ a: Tensor, _ b: Tensor) throws -> Tensor {
        let (shape, maps) = try broadcast([a.shape, b.shape])
        switch (a.values, b.values) {
        case (.float(let x), .float(let y)):
            let v: [Float]
            switch op {
            case "ADD": v = elementwise(Add.self, x, y, maps, shape)
            case "SUB": v = elementwise(Subtract.self, x, y, maps, shape)
            case "MUL": v = elementwise(Multiply.self, x, y, maps, shape)
            case "DIV": v = elementwise(Divide.self, x, y, maps, shape)
            case "MAXIMUM": v = elementwise(Maximum.self, x, y, maps, shape)
            default: v = elementwise(Minimum.self, x, y, maps, shape)
            }
            return Tensor(shape: shape, values: .float(v))
        case (.int32(let x), .int32(let y)):
            let v: [Int32]
            switch op {
            case "ADD": v = elementwise(WrappingAdd.self, x, y, maps, shape)
            case "SUB": v = elementwise(WrappingSubtract.self, x, y, maps, shape)
            case "MUL": v = elementwise(WrappingMultiply.self, x, y, maps, shape)
            case "MAXIMUM": v = elementwise(Maximum.self, x, y, maps, shape)
            case "MINIMUM": v = elementwise(Minimum.self, x, y, maps, shape)
            default: throw ScreenAIError("Layout model: unsupported integer \(op)")
            }
            return Tensor(shape: shape, values: .int32(v))
        default:
            throw ScreenAIError("Layout model: unsupported \(op) types")
        }
    }

    private func comparison(_ op: String, _ a: Tensor, _ b: Tensor) throws -> Tensor {
        let (shape, maps) = try broadcast([a.shape, b.shape])
        func compare<T: Comparable>(_ x: [T], _ y: [T]) -> [Bool] {
            switch op {
            case "LESS": elementwise(Less.self, x, y, maps, shape)
            case "LESS_EQUAL": elementwise(LessOrEqual.self, x, y, maps, shape)
            default: elementwise(GreaterOrEqual.self, x, y, maps, shape)
            }
        }
        switch (a.values, b.values) {
        case (.float(let x), .float(let y)): return Tensor(shape: shape, values: .bool(compare(x, y)))
        case (.int32(let x), .int32(let y)): return Tensor(shape: shape, values: .bool(compare(x, y)))
        case (.int64(let x), .int64(let y)): return Tensor(shape: shape, values: .bool(compare(x, y)))
        default: throw ScreenAIError("Layout model: unsupported \(op) types")
        }
    }

    private func cast(_ v: Values, to type: String) throws -> Values {
        switch (v, type) {
        case (.int64(let x), "int32"): return .int32(x.map { Int32(truncatingIfNeeded: $0) })
        case (.int32(let x), "int64"): return .int64(x.map { Int64($0) })
        case (.int32(let x), "float32"): return .float(x.map { Float($0) })
        case (.int64(let x), "float32"): return .float(x.map { Float($0) })
        case (.float(let x), "int32"): return .int32(x.map { Int32($0) })
        case (.bool(let x), "float32"): return .float(x.map { $0 ? 1 : 0 })
        default:
            if case .float = v, type == "float32" { return v }
            if case .int32 = v, type == "int32" { return v }
            throw ScreenAIError("Layout model: unsupported cast to \(type)")
        }
    }

    private func slice(_ a: Tensor, _ begin: [Int], _ end: [Int], _ step: [Int], shrink: Int) throws -> Tensor {
        let st = strides(a.shape)
        let shape = a.shape.indices.map { max(0, (end[$0] - begin[$0] + step[$0] - 1) / step[$0]) }
        var map: [Int] = []
        forEachIndex(shape) { index in
            var flat = 0
            for d in index.indices { flat += (begin[d] + index[d] * step[d]) * st[d] }
            map.append(flat)
        }
        let outShape = shape.indices.filter { shrink >> $0 & 1 == 0 }.map { shape[$0] }
        return Tensor(shape: outShape, values: a.values.gathered(map))
    }
}

/// A binary operator, as a type so that the loops below get it inlined (closures stay calls).
private protocol Kernel {
    associatedtype T
    associatedtype R
    static func apply(_ a: T, _ b: T) -> R
}

private enum Add: Kernel { static func apply(_ a: Float, _ b: Float) -> Float { a + b } }
private enum Subtract: Kernel { static func apply(_ a: Float, _ b: Float) -> Float { a - b } }
private enum Multiply: Kernel { static func apply(_ a: Float, _ b: Float) -> Float { a * b } }
private enum Divide: Kernel { static func apply(_ a: Float, _ b: Float) -> Float { a / b } }
private enum WrappingAdd: Kernel { static func apply(_ a: Int32, _ b: Int32) -> Int32 { a &+ b } }
private enum WrappingSubtract: Kernel { static func apply(_ a: Int32, _ b: Int32) -> Int32 { a &- b } }
private enum WrappingMultiply: Kernel { static func apply(_ a: Int32, _ b: Int32) -> Int32 { a &* b } }
private enum Maximum<T: Comparable>: Kernel { static func apply(_ a: T, _ b: T) -> T { a > b ? a : b } }
private enum Minimum<T: Comparable>: Kernel { static func apply(_ a: T, _ b: T) -> T { a < b ? a : b } }
private enum Less<T: Comparable>: Kernel { static func apply(_ a: T, _ b: T) -> Bool { a < b } }
private enum LessOrEqual<T: Comparable>: Kernel { static func apply(_ a: T, _ b: T) -> Bool { a <= b } }
private enum GreaterOrEqual<T: Comparable>: Kernel { static func apply(_ a: T, _ b: T) -> Bool { a >= b } }
private enum And: Kernel { static func apply(_ a: Bool, _ b: Bool) -> Bool { a && b } }

/// `K` over two broadcast inputs (see `broadcast`).
private func elementwise<K: Kernel>(_: K.Type, _ x: [K.T], _ y: [K.T], _ maps: [IndexMap], _ shape: [Int]) -> [K.R] {
    let n = shape.reduce(1, *)
    return [K.R](unsafeUninitializedCapacity: n) { buffer, count in
        guard let out = buffer.baseAddress else { return }
        x.withUnsafeBufferPointer { x in
            y.withUnsafeBufferPointer { y in
                guard let x = x.baseAddress, let y = y.baseAddress else { return }
                switch (maps[0], maps[1]) {
                case (.same, .same): for k in 0..<n { (out + k).initialize(to: K.apply(x[k], y[k])) }
                case (.same, .scalar):
                    let v = y[0]
                    for k in 0..<n { (out + k).initialize(to: K.apply(x[k], v)) }
                case (.scalar, .same):
                    let v = x[0]
                    for k in 0..<n { (out + k).initialize(to: K.apply(v, y[k])) }
                case (.same, .modulo(let m)):
                    for r in 0..<n / m {
                        let o = out + r * m, a = x + r * m
                        for j in 0..<m { (o + j).initialize(to: K.apply(a[j], y[j])) }
                    }
                case (.modulo(let m), .same):
                    for r in 0..<n / m {
                        let o = out + r * m, b = y + r * m
                        for j in 0..<m { (o + j).initialize(to: K.apply(x[j], b[j])) }
                    }
                case (.same, .divide(let m)):
                    for r in 0..<n / m {
                        let o = out + r * m, a = x + r * m, v = y[r]
                        for j in 0..<m { (o + j).initialize(to: K.apply(a[j], v)) }
                    }
                case (.divide(let m), .same):
                    for r in 0..<n / m {
                        let o = out + r * m, b = y + r * m, v = x[r]
                        for j in 0..<m { (o + j).initialize(to: K.apply(v, b[j])) }
                    }
                case (let mx, let my): for k in 0..<n { (out + k).initialize(to: K.apply(x[mx(k)], y[my(k)])) }
                }
            }
        }
        count = n
    }
}

/// Calls `body` with every index of `shape`, in row-major order.
private func forEachIndex(_ shape: [Int], _ body: ([Int]) -> Void) {
    let total = shape.reduce(1, *)
    if total == 0 { return }
    var index = [Int](repeating: 0, count: shape.count)
    for _ in 0..<total {
        body(index)
        var d = shape.count - 1
        while d >= 0 {
            index[d] += 1
            if index[d] < shape[d] { break }
            index[d] = 0
            d -= 1
        }
    }
}
