import Foundation

/// A pack's streaming encoder run by the Swift TFLite interpreter, as opensoda's StreamingEncoder: T frames per call,
/// with the recurrent state carried from call to call.
final class TFLiteEncoder: FrameEncoder {
    private let interpreter: Interpreter
    private let inputDim: Int, outputDim: Int
    /// Per state input: the output it feeds back from, and its value.
    private var states: [(input: Int, output: Int, value: Tensor, zero: Tensor)] = []
    /// The recognition domain's slot among the inputs, for encoders that take one.
    private var domainSlot = -1
    var domainID = 0

    init(contentsOf url: URL) throws {
        interpreter = try Interpreter(contentsOf: url)
        let graph = interpreter.model.subgraphs[0]
        guard graph.inputs.count >= 2, graph.outputs.count >= 2 else { throw SODAError("unexpected encoder signature") }
        inputDim = graph.tensors[graph.inputs[0]].shape[2]
        outputDim = graph.tensors[graph.outputs[0]].shape[2]
        // ".../previous_state.NN" feeds back from ".../next_state.NN" (else outputs pair with inputs in order). Some
        // encoders also take the recognition domain as an int32 "domain_id".
        func stateIndex(_ name: String) -> String? {
            guard name.contains("previous_state") || name.contains("next_state"), let dot = name.lastIndex(of: ".") else {
                return nil
            }
            return String(name[name.index(after: dot)...])
        }
        var nextStates: [String: Int] = [:]
        for (slot, i) in graph.outputs.enumerated().dropFirst() {
            if let k = stateIndex(graph.tensors[i].name) { nextStates[k] = slot }
        }
        let byName = nextStates.count == graph.outputs.count - 1
        for (slot, i) in graph.inputs.enumerated().dropFirst() {
            let tensor = graph.tensors[i]
            if tensor.name == "domain_id" {
                domainSlot = slot
                continue
            }
            let output = byName ? stateIndex(tensor.name).flatMap { nextStates[$0] } : (slot < graph.outputs.count ? slot : nil)
            guard let output else { throw SODAError("encoder input \(tensor.name) has no state output") }
            let n = tensor.shape.reduce(1, *)
            let data: TensorData = switch tensor.type {
            case .bool: .bool([Bool](repeating: false, count: n))
            case .int32: .int32([Int32](repeating: 0, count: n))
            case .int64: .int64([Int64](repeating: 0, count: n))
            default: .float([Float](repeating: 0, count: n))
            }
            let zero = Tensor(shape: tensor.shape, data: data)
            states.append((slot, output, zero, zero))
        }
    }

    func reset() {
        for k in states.indices { states[k].value = states[k].zero }
    }

    func encode(_ frames: [[Float]]) throws -> [[Float]] {
        guard !frames.isEmpty else { return [] }
        let graph = interpreter.model.subgraphs[0]
        var inputs = [Tensor](repeating: Tensor([Float]()), count: graph.inputs.count)
        inputs[0] = Tensor(frames.flatMap { $0 }, shape: [1, frames.count, inputDim])
        for s in states { inputs[s.input] = s.value }
        if domainSlot >= 0 { inputs[domainSlot] = Tensor([Int32(domainID)]) }
        let outputs = try interpreter.run(inputs)
        for k in states.indices { states[k].value = outputs[states[k].output] }
        let out = outputs[0].floats
        return (0..<out.count / outputDim).map { Array(out[($0 * outputDim)..<(($0 + 1) * outputDim)]) }
    }
}
