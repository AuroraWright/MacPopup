import AppKit
import os
import ScreenCaptureKit
import VideoToolbox

/// Screenshots for the `{screenshot}` Anki marker, and ScreenCaptureKit's calls with a time limit.
enum ScreenCapture {
    /// SCShareableContent with a time limit (see `limited`).
    static func shareableContent(onScreenWindowsOnly: Bool) async throws -> SCShareableContent {
        try await limited { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: onScreenWindowsOnly) }
    }

    /// SCScreenshotManager.captureImage with a time limit (see `limited`). Now and then a screenshot that usually takes
    /// a few hundredths of a second takes a whole second (the same with no other capture going on), while another
    /// asked for meanwhile comes right away: one is asked for again after 0.3 s, and whichever comes first is taken. Not
    /// for a while after one took seconds even so, as then the second one takes as long (e.g. a minimized window's take
    /// many seconds each), and would only make more wait.
    static func image(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        let started = Date(), retry = noRetryUntil.withLock { started >= $0 }
        defer {
            if Date().timeIntervalSince(started) > 2 { noRetryUntil.withLock { $0 = Date().addingTimeInterval(30) } }
        }
        return try await limited(retryAfter: retry ? 0.3 : nil) {
            try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }
    }

    private static let noRetryUntil = OSAllocatedUnfairLock(initialState: Date.distantPast)

    /// ScreenCaptureKit's calls can, rarely, never return (once while reading with OCR, which then stopped for good, since
    /// it waits for each capture). This gives up on `operation` after `seconds` with an error. It's left running, as it may
    /// not stop when cancelled, and what it returns then is dropped.
    /// - Parameter retryAfter: If it hasn't returned by then, `operation` is started once more, and whichever returns
    ///   first is taken.
    fileprivate static func limited<T>(seconds: Double = 5, retryAfter: Double? = nil, _ operation: @escaping () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            let timer = Task {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                once.resume(with: .failure(AppError("Screen capture timed out after \(Int(seconds)) seconds")))
            }
            let run = { @Sendable in
                let result: Result<T, Error>
                do { result = .success(try await operation()) } catch { result = .failure(error) }
                timer.cancel()
                once.resume(with: result)
            }
            Task { await run() }
            if let retryAfter {
                Task {
                    try? await Task.sleep(for: .seconds(retryAfter))
                    guard !once.isDone else { return }
                    await run()
                }
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

        var isDone: Bool { lock.withLock { continuation == nil } }

        func resume(with result: Result<T, Error>) {
            let continuation = lock.withLock {
                defer { self.continuation = nil }
                return self.continuation
            }
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
        guard let data else { throw AppError("Couldn’t encode the screenshot") }
        return data
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}

/// One ScreenCaptureKit stream, for a picture that's captured often (OCR's checks for changes, and its readings). A screenshot
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
    /// When `pixels` was on screen (mach absolute time), to compare with another stream's.
    private var displayTime: UInt64 = 0
    private var frames = 0
    /// `pixels` as an image, made when it's asked for.
    private var image: CGImage?
    private var stopped = false
    private var error: Error?
    /// The latest frame said what's captured can't be seen (e.g. a Parallels window hidden with ⌘H): its pictures stop
    /// while screenshots of it may still be up to date.
    private var unseen = false

    init(filter: SCContentFilter, configuration: SCStreamConfiguration, key: String) throws {
        self.key = key
        super.init()
        stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    func start() async throws {
        do {
            try await ScreenCapture.limited { [self] in
                try await stream!.startCapture()
                // Given up on meanwhile (see below): it's stopped once it started.
                if hasStopped { try? await stream!.stopCapture() }
            }
        } catch {
            // E.g. it didn't start in time: nothing else would stop it if it starts later.
            stop()
            throw error
        }
    }

    func stop() {
        lock.withLock { stopped = true }
        // The stream keeps its output: removing it lets both go.
        Task { [stream, self] in
            try? await stream!.stopCapture()
            try? stream!.removeStreamOutput(self, type: .screen)
        }
    }

    /// The latest picture: nil until the first one came, and while what's captured can't be seen.
    var latest: CGImage? {
        lock.withLock {
            guard !unseen else { return nil }
            if image == nil, let pixels { VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image) }
            return image
        }
    }

    /// The latest picture copied out of the stream's buffer, for a picture that's kept a while: an image made from the
    /// buffer keeps it, and the stream only has a few to send pictures in.
    var latestCopy: CGImage? {
        guard let image = latest, let space = image.colorSpace, let data = image.dataProvider?.data,
              let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: image.width, height: image.height, bitsPerComponent: image.bitsPerComponent, bitsPerPixel: image.bitsPerPixel,
            bytesPerRow: image.bytesPerRow, space: space, bitmapInfo: image.bitmapInfo, provider: provider, decode: nil,
            shouldInterpolate: false, intent: image.renderingIntent
        )
    }

    /// How many pictures it sent (for the debug log).
    var frameCount: Int { lock.withLock { frames } }

    /// When the latest picture was on screen (mach absolute time): 0 until the first one came.
    var latestTime: UInt64 { lock.withLock { displayTime } }

    /// Whether it stopped, by itself (e.g. the window closed) or with `stop()`.
    var hasStopped: Bool { lock.withLock { stopped } }

    /// Why it stopped by itself (e.g. the system stops every stream when the disk is nearly full).
    var stopError: Error? { lock.withLock { error } }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Only complete frames have a picture: the others say it hasn't changed (idle) or can't be seen (blank, suspended).
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]]
        let status = (attachments?.first?[SCStreamFrameInfo.status.rawValue as CFString] as? Int).flatMap(SCFrameStatus.init)
        guard type == .screen else { return }
        if status == .blank || status == .suspended { lock.withLock { unseen = true } }
        guard status == .complete, let frame = CMSampleBufferGetImageBuffer(buffer) else { return }
        let time = attachments?.first?[SCStreamFrameInfo.displayTime.rawValue as CFString] as? UInt64 ?? 0
        lock.withLock {
            pixels = frame
            displayTime = time
            unseen = false
            frames += 1
            image = nil
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock {
            stopped = true
            self.error = error
        }
    }
}
