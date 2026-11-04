import Foundation

/// With "Highlight recognized text boxes (debug)" on, the page writes each OCR reading and WebSocket line here, one JSON object per
/// line (see logOcrDebug in web/src/overlay.js): Application Support/MacPopup/ocr-debug.jsonl, or the folder in
/// MACPOPUP_DEBUG_OCR_DIR. Over 20 MB, it's moved to ocr-debug.old.jsonl and a new one is started.
enum OCRDebugLog {
    private static let queue = DispatchQueue(label: "OCRDebugLog")
    private static let maxSize = 20_000_000

    static var url: URL {
        let folder = ProcessInfo.processInfo.environment["MACPOPUP_DEBUG_OCR_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacPopup")
        return folder.appendingPathComponent("ocr-debug.jsonl")
    }

    static func append(_ json: String) {
        guard let data = (json + "\n").data(using: .utf8) else { return }
        let url = url
        queue.async {
            let files = FileManager.default
            try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? files.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxSize {
                let old = url.deletingLastPathComponent().appendingPathComponent("ocr-debug.old.jsonl")
                try? files.removeItem(at: old)
                try? files.moveItem(at: url, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
