import Foundation

/// The files of an unpacked models archive (made by scripts/convert-screenai.py): the original's config, label map
/// and language model files under their original paths (e.g. "gocr/gocr_models/..."), the compiled Core ML models
/// under "coreml/", the language identifier's weights under "langid/" and the layout analysis' graph network under
/// "layout/".
struct Resources {
    let root: URL

    func url(_ relativePath: String) -> URL { root.appendingPathComponent(relativePath) }

    /// Nil when the file is missing or empty.
    func read(_ relativePath: String) -> [UInt8]? {
        guard let data = try? Data(contentsOf: url(relativePath)), !data.isEmpty else { return nil }
        return [UInt8](data)
    }
}

struct ScreenAIError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
