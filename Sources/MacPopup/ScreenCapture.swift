import AppKit
import ScreenCaptureKit
import VideoToolbox

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
    fileprivate static func limited<T>(seconds: Double = 5, _ operation: @escaping () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            let timer = Task {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                once.resume(with: .failure(AppError("Screen capture didn't respond within \(Int(seconds)) seconds")))
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
            throw AppError("Display not found")
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
        guard let data else { throw AppError("Failed to encode screenshot") }
        return data
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}

/// One ScreenCaptureKit stream, for a picture that's captured often (screen OCR mode's checks for changes). A screenshot
/// each time makes the system check the permission and update its recording indicator for every capture (tccd,
/// ControlCenter, systemstatusd and replayd took about half a core between them at 10 a second); a stream does that once,
/// and only sends a picture when it changed.
final class CaptureStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// What it captures: another stream is started when that changes.
    let key: String
    private var stream: SCStream!
    private let queue = DispatchQueue(label: "com.aury.macpopup.capture-stream")
    private let lock = NSLock()
    private var pixels: CVPixelBuffer?
    /// `pixels` as an image, made when it's asked for.
    private var image: CGImage?
    private var stopped = false

    init(filter: SCContentFilter, configuration: SCStreamConfiguration, key: String) throws {
        self.key = key
        super.init()
        stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    func start() async throws {
        try await ScreenCapture.limited { [stream] in try await stream!.startCapture() }
    }

    func stop() {
        lock.withLock { stopped = true }
        Task { [stream] in try? await stream!.stopCapture() }
    }

    /// The latest picture: nil until the first one came.
    var latest: CGImage? {
        lock.withLock {
            if image == nil, let pixels { VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image) }
            return image
        }
    }

    /// Whether it stopped, by itself (e.g. the window closed) or with `stop()`.
    var hasStopped: Bool { lock.withLock { stopped } }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Only complete frames have a picture: the others say it hasn't changed (idle) or can't be seen (blank, suspended).
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]]
        let status = attachments?.first?[SCStreamFrameInfo.status.rawValue as CFString] as? Int
        guard type == .screen, status == SCFrameStatus.complete.rawValue, let frame = CMSampleBufferGetImageBuffer(buffer) else { return }
        lock.withLock {
            pixels = frame
            image = nil
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { stopped = true }
    }
}
