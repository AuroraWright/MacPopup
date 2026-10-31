import AppKit
import ScreenCaptureKit

/// Screenshots for the `{screenshot}` Anki marker.
enum ScreenCapture {
    /// Captures the display behind the overlay, excluding this app's own windows.
    static func capture(displayID: CGDirectDisplayID, format: String, quality: Double) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw BridgeError("Display not found")
        }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let scale = NSScreen.screens.first(where: { $0.displayID == displayID })?.backingScaleFactor ?? 2
        let configuration = SCStreamConfiguration()
        configuration.width = Int(Double(display.width) * scale)
        configuration.height = Int(Double(display.height) * scale)
        configuration.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return try encode(image, format: format, quality: quality)
    }

    /// PNG, or JPEG at `quality` percent.
    static func encode(_ image: CGImage, format: String, quality: Double) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        let data: Data?
        if format == "png" {
            data = rep.representation(using: .png, properties: [:])
        } else {
            data = rep.representation(using: .jpeg, properties: [.compressionFactor: max(0, min(1, quality / 100))])
        }
        guard let data else { throw BridgeError("Failed to encode screenshot") }
        return data
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
