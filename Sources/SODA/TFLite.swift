import Accelerate
import SODAKernels
import Foundation

/// A tensor's values. Quantized tensors keep their raw integers, with `Tensor.quantization`.
enum TensorData {
    case float([Float])
    case int32([Int32])
    case int64([Int64])
    case uint8([UInt8])
    case int8([Int8])
    case int16([Int16])
    case bool([Bool])
    case string([[UInt8]])
    /// A resource handle (hash tables).
    case resource(Int)
}

struct Quantization {
    var scales: [Float] = []
    var zeroPoints: [Int64] = []
    var dimension = 0

    var scale: Float { scales.first ?? 0 }
    var zeroPoint: Int32 { Int32(zeroPoints.first ?? 0) }
}

struct Tensor {
    var shape: [Int]
    var data: TensorData
    var quantization = Quantization()

    var count: Int { shape.reduce(1, *) }

    init(shape: [Int], data: TensorData, quantization: Quantization = Quantization()) {
        (self.shape, self.data, self.quantization) = (shape, data, quantization)
    }

    init(_ values: [Float], shape: [Int]? = nil) { self.init(shape: shape ?? [values.count], data: .float(values)) }
    init(_ values: [Int32], shape: [Int]? = nil) { self.init(shape: shape ?? [values.count], data: .int32(values)) }

    var floats: [Float] {
        if case .float(let v) = data { return v }
        fatalError("not a float tensor")
    }

    var int32s: [Int32] {
        if case .int32(let v) = data { return v }
        fatalError("not an int32 tensor")
    }

    var uint8s: [UInt8] {
        if case .uint8(let v) = data { return v }
        fatalError("not a uint8 tensor")
    }

    var bools: [Bool] {
        if case .bool(let v) = data { return v }
        fatalError("not a bool tensor")
    }

    var strings: [[UInt8]] {
        if case .string(let v) = data { return v }
        fatalError("not a string tensor")
    }

    /// Integer values (int32, int64, int8, int16, uint8 or bool) as Ints.
    var ints: [Int] {
        switch data {
        case .int32(let v): v.map(Int.init)
        case .int64(let v): v.map(Int.init)
        case .int8(let v): v.map(Int.init)
        case .int16(let v): v.map(Int.init)
        case .uint8(let v): v.map(Int.init)
        case .bool(let v): v.map { $0 ? 1 : 0 }
        default: fatalError("not an integer tensor")
        }
    }

    /// The same values in another shape (RESHAPE, EXPAND_DIMS, SQUEEZE).
    func reshaped(_ shape: [Int]) -> Tensor {
        var t = self
        t.shape = shape
        return t
    }

    /// Picks elements by flat index (gathers, slices, transposes): the same type and quantization.
    func gathered(_ indices: [Int], shape: [Int]) -> Tensor {
        func pick<T>(_ v: [T]) -> [T] {
            guard !indices.isEmpty else { return [] }
            return v.withUnsafeBufferPointer { v in
                indices.withUnsafeBufferPointer { indices in
                    [T](unsafeUninitializedCapacity: indices.count) { out, count in
                        for (i, j) in indices.enumerated() {
                            precondition(j >= 0 && j < v.count)
                            (out.baseAddress! + i).initialize(to: v[j])
                        }
                        count = indices.count
                    }
                }
            }
        }
        let data: TensorData = switch self.data {
        case .float(let v): .float(pick(v))
        case .int32(let v): .int32(pick(v))
        case .int64(let v): .int64(pick(v))
        case .uint8(let v): .uint8(pick(v))
        case .int8(let v): .int8(pick(v))
        case .int16(let v): .int16(pick(v))
        case .bool(let v): .bool(pick(v))
        case .string(let v): .string(pick(v))
        case .resource: self.data
        }
        return Tensor(shape: shape, data: data, quantization: quantization)
    }

    /// The runs' values in order, from tensors of one type (with the first's quantization).
    static func copying(_ sources: [Tensor], _ runs: CopyRuns, shape: [Int]) -> Tensor {
        func pick<T>(_ values: (TensorData) -> [T]?) -> [T] {
            let arrays = sources.map { values($0.data)! }
            return [T](unsafeUninitializedCapacity: runs.total) { out, count in
                var at = out.baseAddress!
                for r in runs.runs {
                    arrays[r.source].withUnsafeBufferPointer {
                        precondition(r.start >= 0 && r.start + r.count <= $0.count)
                        at.initialize(from: $0.baseAddress! + r.start, count: r.count)
                    }
                    at += r.count
                }
                count = runs.total
            }
        }
        let data: TensorData = switch sources[0].data {
        case .float: .float(pick { if case .float(let v) = $0 { v } else { nil } })
        case .int32: .int32(pick { if case .int32(let v) = $0 { v } else { nil } })
        case .int64: .int64(pick { if case .int64(let v) = $0 { v } else { nil } })
        case .uint8: .uint8(pick { if case .uint8(let v) = $0 { v } else { nil } })
        case .int8: .int8(pick { if case .int8(let v) = $0 { v } else { nil } })
        case .int16: .int16(pick { if case .int16(let v) = $0 { v } else { nil } })
        case .bool: .bool(pick { if case .bool(let v) = $0 { v } else { nil } })
        case .string: .string(pick { if case .string(let v) = $0 { v } else { nil } })
        case .resource: sources[0].data
        }
        return Tensor(shape: shape, data: data, quantization: sources[0].quantization)
    }
}

/// A TFLite model (a .tflite FlatBuffer), run by `Interpreter`.
final class TFLiteModel: @unchecked Sendable {
    enum ElementType: Int8 {
        case float32 = 0, float16 = 1, int32 = 2, uint8 = 3, int64 = 4, string = 5, bool = 6, int16 = 7, int8 = 9
        case resource = 13, int4 = 17
    }

    struct TensorInfo {
        let name: String
        let shape: [Int]
        let type: ElementType
        let quantization: Quantization
        /// The value of a constant tensor.
        let constant: Tensor?
        /// A block-sparse weight matrix's layout (its constant holds only the blocks' values).
        let sparsity: BlockSparsity?
        /// An int8 weight matrix or table that only FULLY_CONNECTED or EMBEDDING_LOOKUP take, or a 4-bit matrix
        /// that only the 4-bit layer takes: its values in the file, not copied (its constant holds only its shape
        /// and quantization).
        let weights: UnsafeRawBufferPointer?
    }

    /// TFLite's 1×16 block sparsity of a weight matrix: row u holds the 16-column blocks
    /// indices[segments[u] ..< segments[u + 1]], their values in that order. The indices are the file's (1, 2 or 4
    /// bytes each, unsigned), in place.
    struct BlockSparsity {
        let segments: [Int32]
        let indices: UnsafeRawBufferPointer
        let indexSize: Int
        var blocks: Int { indices.count / indexSize }
    }

    struct Operator {
        let code: Int
        /// The name of a custom op.
        let custom: String
        let inputs: [Int]
        let outputs: [Int]
        let options: FlatTable?
        /// A custom op's options (a FlexBuffer).
        let customOptions: [UInt8]
    }

    struct Subgraph {
        let tensors: [TensorInfo]
        let inputs: [Int]
        let outputs: [Int]
        let operators: [Operator]
        /// Per op, the tensors no later op takes (nor the subgraph gives): Interpreter.run drops them after it.
        let releases: [[Int]]

        init(tensors: [TensorInfo], inputs: [Int], outputs: [Int], operators: [Operator]) {
            (self.tensors, self.inputs, self.outputs, self.operators) = (tensors, inputs, outputs, operators)
            var last: [Int: Int] = [:]
            for (k, op) in operators.enumerated() {
                for i in op.inputs + op.outputs where i >= 0 { last[i] = k }
            }
            for i in outputs { last[i] = nil }
            var releases = [[Int]](repeating: [], count: operators.count)
            for (i, k) in last { releases[k].append(i) }
            self.releases = releases
        }
    }

    private(set) var subgraphs: [Subgraph] = []
    /// The file's bytes (mapped, or a copy of the data the model was made from), which options tables and the
    /// FULLY_CONNECTED weights read from.
    private let storage: UnsafeRawBufferPointer
    private let mapped: Bool

    /// Maps the file: the weights stay in it, outside the process's own memory.
    convenience init(contentsOf url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw SODAError("can’t open \(url.lastPathComponent)") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0,
              let base = mmap(nil, Int(info.st_size), PROT_READ, MAP_PRIVATE, fd, 0), base != MAP_FAILED else {
            throw SODAError("can’t read \(url.lastPathComponent)")
        }
        try self.init(storage: UnsafeRawBufferPointer(start: base, count: Int(info.st_size)), mapped: true,
                      name: url.lastPathComponent)
    }

    convenience init(data: Data, name: String) throws {
        let copy = UnsafeMutableRawBufferPointer.allocate(byteCount: data.count, alignment: 16)
        data.copyBytes(to: copy)
        try self.init(storage: UnsafeRawBufferPointer(copy), mapped: false, name: name)
    }

    private init(storage: UnsafeRawBufferPointer, mapped: Bool, name: String) throws {
        (self.storage, self.mapped) = (storage, mapped)
        let bytes = storage
        guard bytes.count > 8, bytes[4] == 0x54, bytes[5] == 0x46, bytes[6] == 0x4C, bytes[7] == 0x33 else {
            throw SODAError("\(name) isn’t a TFLite model")
        }
        let model = FlatTable(root: bytes)
        let codes = model.tables(1).map { c -> (Int, String) in
            let deprecated = Int(c.scalar(0, Int8(0)))
            return (max(deprecated, Int(c.scalar(3, Int32(0)))), c.string(1) ?? "")
        }
        let buffers = model.tables(4)
        for g in model.tables(2) {
            let operators = g.tables(3).map { o -> Operator in
                let (code, custom) = codes[Int(o.scalar(0, UInt32(0)))]
                return Operator(code: code, custom: custom, inputs: o.scalars(1, as: Int32.self).map(Int.init),
                                outputs: o.scalars(2, as: Int32.self).map(Int.init), options: o.table(4),
                                customOptions: o.data(5))
            }
            let outputs = g.scalars(2, as: Int32.self).map(Int.init)
            // The tensors FULLY_CONNECTED or EMBEDDING_LOOKUP take as weights, and those anything else takes.
            var weightInputs = Set<Int>(), lookups = Set<Int>(), other = Set(outputs)
            for op in operators {
                for (slot, i) in op.inputs.enumerated() {
                    if op.code == Op.fullyConnected && slot == 1 {
                        weightInputs.insert(i)
                    } else if op.code == Op.embeddingLookup && slot == 1 {
                        lookups.insert(i)
                    } else {
                        other.insert(i)
                    }
                }
            }
            let tensors = try g.tables(0).enumerated().map { index, t -> TensorInfo in
                let shape = t.scalars(0, as: Int32.self).map(Int.init)
                let raw = t.scalar(1, Int8(0))
                let type = ElementType(rawValue: raw) ?? .float32
                var quantization = Quantization()
                if let q = t.table(4) {
                    quantization = Quantization(scales: q.floats(2), zeroPoints: q.scalars(3, as: Int64.self),
                                                dimension: Int(q.scalar(6, Int32(0))))
                }
                let buffer = Int(t.scalar(2, UInt32(0)))
                let bytes = buffer < buffers.count ? buffers[buffer].dataBytes(0) : nil
                let weights: UnsafeRawBufferPointer? = if other.contains(index) {
                    nil
                } else if lookups.contains(index) {
                    type == .int8 ? bytes : nil
                } else if weightInputs.contains(index) {
                    type == .int8 || type == .int4 && !lookups.contains(index) && Self.packed4Bit(shape) ? bytes : nil
                } else {
                    nil
                }
                let constant = bytes.flatMap { bytes -> Tensor? in
                    if bytes.isEmpty { return nil }
                    if weights != nil { return Tensor(shape: shape, data: .int8([]), quantization: quantization) }
                    return Self.tensor(bytes, type: type, shape: shape, quantization: quantization)
                }
                let name = t.string(3) ?? ""
                let sparsity = try t.table(6).map { try Self.blockSparsity($0, name: name) }
                return TensorInfo(name: name, shape: shape, type: type, quantization: quantization, constant: constant,
                                  sparsity: sparsity, weights: weights)
            }
            subgraphs.append(Subgraph(tensors: tensors, inputs: g.scalars(1, as: Int32.self).map(Int.init),
                                      outputs: outputs, operators: operators))
        }
    }

    deinit {
        if mapped {
            munmap(UnsafeMutableRawPointer(mutating: storage.baseAddress), storage.count)
        } else {
            storage.deallocate()
        }
    }

    /// Whether FULLY_CONNECTED takes 4-bit weights of this shape packed (TFLite's optimized_4bit layer); else
    /// they're unpacked to int8.
    static func packed4Bit(_ shape: [Int]) -> Bool {
        shape.count == 2 && shape[1] % 2 == 0 && shape[0] >= 4 && shape[1] >= 32
    }

    private static func tensor(_ bytes: UnsafeRawBufferPointer, type: ElementType, shape: [Int],
                               quantization: Quantization) -> Tensor {
        func values<T>(_: T.Type) -> [T] {
            let count = bytes.count / MemoryLayout<T>.stride
            return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
                UnsafeMutableRawBufferPointer(buffer).copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[..<(count * MemoryLayout<T>.stride)]))
                initialized = count
            }
        }
        let data: TensorData = switch type {
        case .float32: .float(values(Float.self))
        case .float16: .float(values(UInt16.self).map { Float(Float16(bitPattern: $0)) })
        case .int32: .int32(values(Int32.self))
        case .int64: .int64(values(Int64.self))
        case .uint8: .uint8(Array(bytes))
        case .int8: .int8(values(Int8.self))
        // Two 4-bit values a byte, the first in the low nibble.
        case .int4: .int8([Int8](unsafeUninitializedCapacity: bytes.count * 2) { out, initialized in
            for (i, b) in bytes.enumerated() {
                out[2 * i] = Int8(bitPattern: b << 4) >> 4
                out[2 * i + 1] = Int8(bitPattern: b) >> 4
            }
            initialized = bytes.count * 2
        })
        case .int16: .int16(values(Int16.self))
        case .bool: .bool(bytes.map { $0 != 0 })
        case .string: .string(Self.strings(Array(bytes)))
        case .resource: .resource(0)
        }
        return Tensor(shape: shape, data: data, quantization: quantization)
    }

    /// A tensor's SparsityParameters, of the one kind the packs use: rows dense, columns in CSR blocks of 16.
    private static func blockSparsity(_ p: FlatTable, name: String) throws -> BlockSparsity {
        // SparsityParameters: traversal_order, block_map, dim_metadata. DimensionMetadata: format (0 dense, 1 CSR),
        // dense_size, then the segments' and the indices' vectors (unions of Int32Vector, Uint16Vector, Uint8Vector).
        let dims = p.tables(2)
        /// A vector's bytes and element size.
        func vector(_ d: FlatTable, _ index: Int) -> (bytes: UnsafeRawBufferPointer, size: Int)? {
            guard let v = d.table(index + 1) else { return nil }
            let size = switch d.scalar(index, UInt8(0)) {
            case 1: 4
            case 2: 2
            case 3: 1
            default: 0
            }
            return size == 0 ? nil : v.dataBytes(0, elementSize: size).map { ($0, size) }
        }
        guard p.scalars(0, as: Int32.self) == [0, 1, 2], p.scalars(1, as: Int32.self) == [1], dims.count == 3,
              dims[0].scalar(0, Int8(0)) == 0, dims[1].scalar(0, Int8(0)) == 1,
              dims[2].scalar(0, Int8(0)) == 0, dims[2].scalar(1, Int32(0)) == 16,
              let segments = vector(dims[1], 2), let indices = vector(dims[1], 4) else {
            throw SODAError("\(name) has a sparsity other than 1×16 blocks")
        }
        let s = segments.bytes
        let starts: [Int32] = (0..<s.count / segments.size).map { i in
            switch segments.size {
            case 1: Int32(s[i])
            case 2: Int32(s.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self))
            default: s.loadUnaligned(fromByteOffset: 4 * i, as: Int32.self)
            }
        }
        return BlockSparsity(segments: starts, indices: indices.bytes, indexSize: indices.size)
    }

    /// A TFLite string tensor's strings: int32 count, count + 1 offsets, then the bytes.
    static func strings(_ bytes: [UInt8]) -> [[UInt8]] {
        guard bytes.count >= 4 else { return [] }
        func int(_ at: Int) -> Int {
            Int(UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24)
        }
        let count = int(0)
        return (0..<count).map { i in Array(bytes[int(4 + 4 * i)..<int(8 + 4 * i)]) }
    }
}

/// Runs a TFLite model's ops on the CPU, as TFLite's kernels compute them where the results matter (the hybrid int8
/// layers' quantization of their inputs, uint8 arithmetic), so that results match libsoda's.
final class Interpreter: @unchecked Sendable {
    let model: TFLiteModel
    /// Per subgraph and tensor: an int8 weight matrix and its rows' sums (for the hybrid layers).
    private var weightCache: [Int: HybridWeights] = [:]
    private let cacheLock = NSLock()
    /// Resource tensors' hash tables (keyed by table id).
    var hashTables: [Int: HashTable] = [:]
    /// The hybrid layers' integer sums, kept from call to call (an interpreter runs one op at a time).
    var sums: [Int32] = []
    /// Concatenations', slices' and transposes' copy runs, by their shapes (the same from frame to frame).
    var copyRuns: [[Int]: CopyRuns] = [:]

    init(_ model: TFLiteModel) {
        self.model = model
    }

    convenience init(contentsOf url: URL) throws {
        try self.init(TFLiteModel(contentsOf: url))
    }

    var inputs: [TFLiteModel.TensorInfo] { model.subgraphs[0].inputs.map { model.subgraphs[0].tensors[$0] } }
    var outputs: [TFLiteModel.TensorInfo] { model.subgraphs[0].outputs.map { model.subgraphs[0].tensors[$0] } }

    /// Runs subgraph `index` on `inputs`, giving its outputs.
    func run(_ inputs: [Tensor], subgraph index: Int = 0) throws -> [Tensor] {
        let graph = model.subgraphs[index]
        let values = try runAll(inputs, subgraph: index, keepingAll: false)
        return try graph.outputs.map { i in
            guard let t = values[i] else { throw SODAError("model output \(graph.tensors[i].name) wasn't computed") }
            return t
        }
    }

    /// Runs subgraph `index`, giving the values of all its tensors (only its outputs' unless `keepingAll`).
    func runAll(_ inputs: [Tensor], subgraph index: Int = 0, keepingAll: Bool = true) throws -> [Tensor?] {
        // TFLite runs with denormals flushed to zero (ruy::ScopedSuppressDenormals sets FPCR.FZ and FZ16).
        var saved = fenv_t()
        fegetenv(&saved)
        var env = saved
        env.__fpcr |= 0x108_0000
        fesetenv(&env)
        defer { fesetenv(&saved) }
        let graph = model.subgraphs[index]
        var values = [Tensor?](repeating: nil, count: graph.tensors.count)
        for (i, t) in graph.tensors.enumerated() where t.constant != nil { values[i] = t.constant }
        for (slot, tensor) in zip(graph.inputs, inputs) {
            var t = tensor
            if t.quantization.scales.isEmpty { t.quantization = graph.tensors[slot].quantization }
            values[slot] = t
        }
        var context = Context(interpreter: self, subgraph: index, graph: graph, values: values)
        for (k, op) in graph.operators.enumerated() {
            try context.run(op)
            if !keepingAll { for i in graph.releases[k] { context.values[i] = nil } }
        }
        return context.values
    }

    /// An int8 (or int4) weight matrix with its rows' sums, computed once.
    func weights(_ tensor: Int, of subgraph: Int, _ values: Tensor) -> HybridWeights {
        let key = subgraph << 32 | tensor
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = weightCache[key] { return cached }
        let info = model.subgraphs[subgraph].tensors[tensor]
        var weights: HybridWeights
        if let mapped = info.weights, info.type == .int4 {
            // The 4-bit layer doesn't use the rows' sums.
            weights = HybridWeights(mapped: mapped.bindMemory(to: Int8.self), sparsity: nil, packed4Bit: true)
            weightCache[key] = weights
            return weights
        } else if let mapped = info.weights {
            weights = HybridWeights(mapped: mapped.bindMemory(to: Int8.self), sparsity: info.sparsity)
        } else {
            guard case .int8(let w) = values.data else { fatalError("weights aren't int8") }
            weights = HybridWeights(values: w, sparsity: info.sparsity)
        }
        weights.sumRows(columns: values.shape.last ?? 1)
        weightCache[key] = weights
        return weights
    }
}

/// A hybrid layer's int8 weight matrix ([units, columns], or its blocks when block-sparse) and its rows' sums. The
/// values are an array, or the model file's own.
struct HybridWeights {
    private let array: [Int8]
    private let mapped: UnsafeBufferPointer<Int8>?
    private(set) var rowSums: [Int32]
    var sparsity: TFLiteModel.BlockSparsity? = nil
    /// 4-bit values, two a byte (the first in the low nibble).
    private(set) var packed4Bit = false

    init(values: [Int8], rowSums: [Int32] = [], sparsity: TFLiteModel.BlockSparsity? = nil) {
        (array, mapped, self.rowSums, self.sparsity) = (values, nil, rowSums, sparsity)
    }

    /// Values in a model file, which must outlive these weights.
    init(mapped: UnsafeBufferPointer<Int8>, sparsity: TFLiteModel.BlockSparsity?, packed4Bit: Bool = false) {
        (array, self.mapped, rowSums, self.sparsity, self.packed4Bit) = ([], mapped, [], sparsity, packed4Bit)
    }

    func withValues<R>(_ body: (UnsafePointer<Int8>) throws -> R) rethrows -> R {
        if let mapped { return try body(mapped.baseAddress!) }
        return try array.withUnsafeBufferPointer { try body($0.baseAddress!) }
    }

    /// Sums each row (each unit's blocks, when block-sparse) of `columns` columns.
    mutating func sumRows(columns: Int) {
        let count = mapped?.count ?? array.count
        let sparsity = sparsity
        rowSums = withValues { w in
            if let sparsity {
                return (0..<sparsity.segments.count - 1).map { u in
                    (Int(sparsity.segments[u]) * 16..<Int(sparsity.segments[u + 1]) * 16).reduce(Int32(0)) { $0 + Int32(w[$1]) }
                }
            }
            let rows = count / columns
            return [Int32](unsafeUninitializedCapacity: rows) { out, initialized in
                soda_row_sums_s8(w, rows, Int32(columns), out.baseAddress!)
                initialized = rows
            }
        }
    }
}

/// One run of a subgraph: its tensors' values.
struct Context {
    let interpreter: Interpreter
    let subgraph: Int
    let graph: TFLiteModel.Subgraph
    var values: [Tensor?]

    func input(_ op: TFLiteModel.Operator, _ i: Int) -> Tensor {
        let index = op.inputs[i]
        guard index >= 0, let t = values[index] else { fatalError("missing input \(i) of op \(op.code)") }
        return t
    }

    func hasInput(_ op: TFLiteModel.Operator, _ i: Int) -> Bool {
        i < op.inputs.count && op.inputs[i] >= 0
    }

    /// The quantization the model gives an op's output.
    func outputQuantization(_ op: TFLiteModel.Operator, _ i: Int = 0) -> Quantization {
        graph.tensors[op.outputs[i]].quantization
    }

    mutating func set(_ op: TFLiteModel.Operator, _ i: Int = 0, _ t: Tensor) {
        var t = t
        let q = graph.tensors[op.outputs[i]].quantization
        if !q.scales.isEmpty { t.quantization = q }
        values[op.outputs[i]] = t
    }

    /// The copy runs `key` stands for, made by `make` the first time.
    func runs(_ key: [Int], _ make: () -> CopyRuns) -> CopyRuns {
        if let runs = interpreter.copyRuns[key] { return runs }
        let runs = make()
        interpreter.copyRuns[key] = runs
        return runs
    }
}

/// Runs of consecutive values of source tensors, for `Tensor.copying`: adjacent runs are merged.
struct CopyRuns {
    private(set) var runs: [(source: Int, start: Int, count: Int)] = []
    private(set) var total = 0

    mutating func append(_ source: Int, _ start: Int, _ count: Int) {
        guard count > 0 else { return }
        total += count
        if let last = runs.last, last.source == source, last.start + last.count == start {
            runs[runs.count - 1].count += count
        } else {
            runs.append((source, start, count))
        }
    }
}

/// A HASHTABLE resource (TFLite's StaticHashtable): filled by its first import only.
final class HashTable {
    var map: [TensorElement: TensorElement] = [:]
    var initialized = false
}

/// A hash table key or value.
enum TensorElement: Hashable {
    case int(Int)
    case string([UInt8])
}
