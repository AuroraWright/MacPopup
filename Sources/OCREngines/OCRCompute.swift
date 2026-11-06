import CoreML

/// Where the engines run their models. The iOS app's continuous mode reads while the app is in the background, where iOS
/// doesn't let apps use the GPU, and where the Neural Engine stalled or failed while a game was in front: there the
/// models run on the CPU. Models loaded before a change keep their units until they're unloaded.
public enum OCRCompute {
    nonisolated(unsafe) public static var cpuOnly = false

    static func units(_ preferred: MLComputeUnits) -> MLComputeUnits {
        cpuOnly ? .cpuOnly : preferred
    }
}
