import AppIntents
import CoreImage
import Foundation
import UIKit
import VisualIntelligence

/// Visual Intelligence (iOS 26: the camera from the Action button, Control Center or Camera Control, or a screenshot's
/// Visual Intelligence button): MacPopup is one of its sources. It offers the picture at once (Visual Intelligence
/// doesn't wait for a reading, which takes seconds); opening it reads the picture, saves the reading and opens it in
/// Safari, as the share sheet does.
@available(iOS 26.0, *)
struct ReadingSearch: IntentValueQuery {
    func values(for input: SemanticContentDescriptor) async throws -> [PictureResult] {
        guard let buffer = input.pixelBuffer, let image = Self.image(buffer),
              let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.9)
        else {
            IntentLog.append("Visual Intelligence: no picture (labels: \(input.labels.joined(separator: ", ")))")
            return []
        }
        let result = PictureResult(id: UUID().uuidString, thumbnail: Self.thumbnail(image))
        try PictureResult.keep(data, id: result.id)
        IntentLog.append("Visual Intelligence: \(image.width)×\(image.height), labels \(input.labels.joined(separator: ", "))")
        return [result]
    }

    /// CIContext renders on the GPU by default, which an app in the background can't use.
    private static let context = CIContext(options: [.useSoftwareRenderer: true])

    private static func image(_ buffer: CVReadOnlyPixelBuffer) -> CGImage? {
        buffer.withUnsafeBuffer { pixelBuffer in
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            return context.createCGImage(image, from: image.extent)
        }
    }

    private static func thumbnail(_ image: CGImage) -> Data? {
        let scale = min(1, 240 / CGFloat(max(image.width, image.height)))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size)) }
            .jpegData(compressionQuality: 0.8)
    }
}

/// A picture Visual Intelligence gave, kept in Caches/search until the user opens it (iOS may quit the app meanwhile).
@available(iOS 26.0, *)
struct PictureResult: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Picture"
    static let defaultQuery = Query()

    static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("search", isDirectory: true)

    let id: String
    let thumbnail: Data?

    var file: URL { Self.folder.appendingPathComponent("\(id).jpg") }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "Read with MacPopup",
            subtitle: "Opens the text in Safari to look it up",
            image: thumbnail.map { .init(data: $0) }
        )
    }

    /// Keeps the picture, and only the newest few.
    static func keep(_ data: Data, id: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("\(id).jpg"))
        let kept = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let old = kept.sorted {
            let dates = [$0, $1].map { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
            return dates[0] > dates[1]
        }.dropFirst(5)
        for file in old { try? FileManager.default.removeItem(at: file) }
    }

    struct Query: EntityQuery {
        func entities(for identifiers: [String]) async throws -> [PictureResult] {
            let found = identifiers.map { PictureResult(id: $0, thumbnail: nil) }.filter {
                FileManager.default.fileExists(atPath: $0.file.path)
            }
            IntentLog.append("Visual Intelligence: looked up \(identifiers.count), found \(found.count)")
            return found
        }
    }
}

/// Opening a Visual Intelligence result: reads the picture, saves the reading and opens it in Safari.
@available(iOS 26.0, *)
struct OpenPictureResultIntent: OpenIntent {
    static let title: LocalizedStringResource = "Read Picture"

    @Parameter(title: "Picture")
    var target: PictureResult

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        let start = Date()
        guard let data = try? Data(contentsOf: target.file), let picture = Picture(data: data) else {
            IntentLog.append("Visual Intelligence: \(target.id) is gone")
            throw AppError("This picture is gone. Search with Visual Intelligence again.")
        }
        let reading = try await AppModel.shared.reading(picture)
        try? FileManager.default.removeItem(at: target.file)
        AppModel.shared.serve()
        IntentLog.append(String(
            format: "Visual Intelligence: read in %.0f ms, app state %d, opening %@", Date().timeIntervalSince(start) * 1000,
            UIApplication.shared.applicationState.rawValue, reading.id
        ))
        return .result(opensIntent: OpenURLIntent(PageServer.url(reading)))
    }
}
