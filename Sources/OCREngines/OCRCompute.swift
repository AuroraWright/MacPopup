import CoreML

/// Where the engines run their models. They run on the CPU once an engine has crashed MacPopup while loading, and
/// in the iOS app's continuous mode, which reads while the app is in the background: there iOS doesn't let apps use the
/// GPU, and the Neural Engine stalled or failed while a game was in front. Models loaded before a change keep their
/// units until they're unloaded.
public enum OCRCompute {
    nonisolated(unsafe) public static var cpuOnly = false

    static func units(_ preferred: MLComputeUnits) -> MLComputeUnits {
        cpuOnly ? .cpuOnly : preferred
    }
}
