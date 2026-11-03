import AppKit
import ScreenCaptureKit

/// Screenshots for the `{screenshot}` Anki marker, and ScreenCaptureKit's calls with a time limit.
enum ScreenCapture {
    /// SCShareableContent with a time limit (see `limited`).
    static func shareableContent(onScreenWindowsOnly: Bool) async throws -> SCShareableContent {
        try await limited { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: onScreenWindowsOnly) }
    }

    /// SCScreenshotManager.captureImage with a time limit (see `limited`).
    static func image(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        try await limited { try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) }
    }

    /// ScreenCaptureKit's calls can, rarely, never return (once in OCR mode, which then stopped reading for good, since
    /// it waits for each capture). This gives up on `operation` after `seconds` with an error. It's left running, as it may
    /// not stop when cancelled, and what it returns then is dropped.
    private static func limited<T>(seconds: Double = 5, _ operation: @escaping () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            let timer = Task {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                once.resume(with: .failure(BridgeError("Screen capture didn't respond within \(Int(seconds)) seconds")))
            }
            Task {
                let result: Result<T, Error>
                do { result = .success(try await operation()) } catch { result = .failure(error) }
                timer.cancel()
                once.resume(with: result)
            }
        }
    }

    /// A continuation resumed by whichever finishes first.
    private final class Once<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func resume(with result: Result<T, Error>) {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }

    /// Captures the display behind the overlay, excluding this app's own windows.
    /// - Parameter fullResolution: At the display's scale, or else at 1x.
    static func capture(displayID: CGDirectDisplayID, fullResolution: Bool, format: String, quality: Double) async throws -> Data {
        let content = try await shareableContent(onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw BridgeError("Display not found")
        }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let scale = fullResolution ? NSScreen.screens.first(where: { $0.displayID == displayID })?.backingScaleFactor ?? 2 : 1
        let configuration = SCStreamConfiguration()
        configuration.width = Int(Double(display.width) * scale)
        configuration.height = Int(Double(display.height) * scale)
        configuration.showsCursor = false

        let screenshot = try await image(filter: filter, configuration: configuration)
        return try encode(screenshot, format: format, quality: quality)
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
