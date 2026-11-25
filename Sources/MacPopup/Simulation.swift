import Accelerate
import AppKit
import AVFoundation
import CryptoKit
import OCREngines
import VideoToolbox
import WebKit

/// The time OCR goes by (OCRController, and the debug log's records): the system's, or a simulated run's (see
/// Simulation).
enum OCRClock {
    static var now: Date { Simulation.shared?.now ?? Date() }

    @MainActor static func sleep(for duration: Duration) async {
        if let simulation = Simulation.shared {
            await simulation.sleep(for: duration)
        } else {
            try? await Task.sleep(for: duration)
        }
    }
}

/// Development hook: OCR reads a recording instead of the screen, on a simulated clock, for testing OCR's logic (when
/// it reads, line tracking, the page's handling of readings) fast and the same way each time. Set with
/// MACPOPUP_SIM_MOVIE=<movie> (a recording of the window at 2 pixels per point), MACPOPUP_SIM_FROM and MACPOPUP_SIM_TO
/// (seconds of it), MACPOPUP_SIM_CACHE=<file> (the readings of pictures read before) and MACPOPUP_SIM_LOG=<file> (as
/// replay's log: "start <epoch s> <movie s>", for the time the recording starts at). OCR's window is still a real one
/// (a stand-in of the recording's size), whose captures are replaced by the recording's picture at the simulated time.
///
/// The clock moves only when OCR waits (OCRClock.sleep; until the first capture, which starts the recording, it also
/// waits that long), as long as a capture is modeled to take (MACPOPUP_SIM_CAPTURE_MS, for the checks for changes, and
/// MACPOPUP_SIM_READING_CAPTURE_MS; a capture is the picture as a stream last sent it, at MACPOPUP_SIM_FPS), and as
/// long as each reading took the first time (the engine reads each picture once: its readings are kept in the cache).
/// Nothing else happens on the system's clock that OCR goes by (e.g. input isn't watched: see
/// OCRController.checkInput). Before each wait the page handles what it was sent (with the page's clock at the time it
/// was sent: see evals/sim/sim-page.js). The app quits 4 seconds after the end.
final class Simulation: @unchecked Sendable {
    static let shared = Simulation(DevelopmentEnvironment.all)

    private let lock = NSLock()
    /// The simulated time, in whole nanoseconds since `base` (a whole second), and when the recording started (on a
    /// whole second): so that it's rounded the same way in each run when it's turned into seconds (see `now`).
    private static let base = Date().timeIntervalSince1970.rounded(.down)
    private var nanoseconds: Int64 = 0
    private var movieStart: Int64?
    private let movie: URL, from: Double, to: Double, logURL: URL, cacheURL: URL
    private let captureTime: Double, readingCaptureTime: Double, framesPerSecond: Double
    private var frames: Frames?
    private var movieSize = CGSize.zero
    private var current: Frames.Frame?
    /// Readings by engine and picture (see recognize), with how long they took (ms).
    private var cache: [String: (lines: [RecognizedLine], ms: Double)] = [:]
    /// The page, waited for before each wait (see sleep).
    @MainActor weak var page: WKWebView?
    @MainActor private var sentToPage = false

    private init?(_ environment: [String: String]) {
        guard let movie = environment["MACPOPUP_SIM_MOVIE"], let from = environment["MACPOPUP_SIM_FROM"].flatMap(Double.init),
              let to = environment["MACPOPUP_SIM_TO"].flatMap(Double.init), let cache = environment["MACPOPUP_SIM_CACHE"],
              let log = environment["MACPOPUP_SIM_LOG"] else { return nil }
        self.movie = URL(fileURLWithPath: movie)
        self.from = from
        self.to = to
        cacheURL = URL(fileURLWithPath: cache)
        logURL = URL(fileURLWithPath: log)
        captureTime = environment["MACPOPUP_SIM_CAPTURE_MS"].flatMap(Double.init).map { $0 / 1000 } ?? 0.003
        readingCaptureTime = environment["MACPOPUP_SIM_READING_CAPTURE_MS"].flatMap(Double.init).map { $0 / 1000 } ?? 0.015
        framesPerSecond = environment["MACPOPUP_SIM_FPS"].flatMap(Double.init) ?? 20
        loadCache()
    }

    var now: Date {
        let time = lock.withLock { nanoseconds }
        return Date(timeIntervalSince1970: Self.base + Double(time / 1_000_000_000) + Double(time % 1_000_000_000) / 1e9)
    }

    @MainActor func sleep(for duration: Duration) async {
        if sentToPage, let page {
            sentToPage = false
            _ = try? await page.callAsyncJavaScript("return await window.__simIdle?.()", contentWorld: .page)
        }
        let (seconds, attoseconds) = duration.components
        let movieTime = lock.withLock {
            nanoseconds += seconds * 1_000_000_000 + attoseconds / 1_000_000_000
            return movieStart.map { Double(nanoseconds - $0) / 1e9 + from }
        }
        guard let movieTime else {
            // Before the recording (e.g. while the engine loads).
            try? await Task.sleep(for: duration)
            return
        }
        if movieTime > to + 4 { finish() }
        // A moment for the rest of the app (e.g. the page's replies).
        try? await Task.sleep(for: .microseconds(100))
    }

    /// For a message to the page: sets the page's clock to the time it's sent.
    @MainActor func pageMessage(_ js: String) -> String {
        sentToPage = true
        return "window.__simNow = \(Int64(Self.base) * 1000 + lock.withLock { nanoseconds } / 1_000_000); " + js
    }

    /// The recording's picture now, as a capture of `rect` (in window points, of a window of `windowSize`) at
    /// `width` × `height` pixels. The first starts the recording.
    @MainActor func capture(_ rect: CGRect, windowSize: CGSize, width: Int, height: Int, forReading: Bool) async -> CGImage? {
        if lock.withLock({ movieStart }) == nil { start() }
        // As a stream's latest picture, sent at most `framesPerSecond` times a second.
        let movieTime = lock.withLock { Double((nanoseconds - movieStart!) * Int64(framesPerSecond) / 1_000_000_000) / framesPerSecond + from }
        guard let frame = frame(at: movieTime), let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // The movie's pixels per window point, and the capture's per movie pixel; drawn flipped (CG's origin is at the
        // bottom).
        let perPoint = movieSize.width / windowSize.width
        let crop = CGRect(x: rect.minX * perPoint, y: rect.minY * perPoint, width: rect.width * perPoint, height: rect.height * perPoint)
        let scaleX = CGFloat(width) / crop.width, scaleY = CGFloat(height) / crop.height
        context.interpolationQuality = .medium
        context.draw(frame, in: CGRect(
            x: -crop.minX * scaleX, y: CGFloat(height) - (movieSize.height - crop.minY) * scaleY,
            width: movieSize.width * scaleX, height: movieSize.height * scaleY
        ))
        let image = context.makeImage()
        await sleep(for: .seconds(forReading ? readingCaptureTime : captureTime))
        return image
    }

    /// The engine's reading of `image`, from the cache if it was read before (the clock moves as long as that took).
    @MainActor func recognize(_ image: CGImage, engine: String, _ read: () async throws -> [RecognizedLine]) async throws -> [RecognizedLine] {
        let key = engine + " " + Self.hash(image)
        if let cached = cache[key] {
            await sleep(for: .milliseconds(cached.ms))
            return cached.lines
        }
        let started = Date()
        let lines = try await read()
        let ms = (Date().timeIntervalSince(started) * 1000).rounded()
        cache[key] = (lines, ms)
        save(key, lines, ms)
        await sleep(for: .milliseconds(ms))
        return lines
    }

    private func start() {
        let asset = AVURLAsset(url: movie)
        guard let reader = try? AVAssetReader(asset: asset), let (track, size) = Self.videoTrack(of: asset) else {
            FileHandle.standardError.write("simulation: can't read \(movie.path)\n".data(using: .utf8)!)
            exit(1)
        }
        movieSize = size
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), end: CMTime(seconds: to + 5, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        frames = Frames(reader: reader, output: output, from: from, framesPerSecond: framesPerSecond)
        let started = lock.withLock {
            nanoseconds = (nanoseconds / 1_000_000_000 + 1) * 1_000_000_000
            movieStart = nanoseconds
            return Self.base + Double(nanoseconds / 1_000_000_000)
        }
        try? String(format: "start %.3f %.3f\n", started, from).write(to: logURL, atomically: true, encoding: .utf8)
    }

    /// The movie's video track and its size, which AVFoundation now only loads asynchronously. Waited for, so that
    /// nothing else moves the simulated clock before the recording starts (it starts at the same time in each run).
    private static func videoTrack(of asset: AVURLAsset) -> (AVAssetTrack, CGSize)? {
        let loaded = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (AVAssetTrack, CGSize)?
        Task.detached {
            if let track = try? await asset.loadTracks(withMediaType: .video).first, let size = try? await track.load(.naturalSize) {
                result = (track, size)
            }
            loaded.signal()
        }
        loaded.wait()
        return result
    }

    /// The movie's frame on screen at `movieTime`: the last one by then (the first before that).
    private func frame(at movieTime: Double) -> CGImage? {
        while let next = frames?.next(), next.time <= movieTime || current == nil {
            current = next
            frames?.removeNext()
        }
        return current?.image
    }

    @MainActor private func finish() {
        try? "end\n".write(to: logURL.appendingPathExtension("end"), atomically: true, encoding: .utf8)
        DebugLog.flush()
        exit(0)
    }

    /// The image's pixels in one format (RGBA, premultiplied, device RGB; whatever it was made from), hashed. vImage
    /// gives the same bytes as drawing it into that format, faster.
    private static func hash(_ image: CGImage) -> String {
        let format = vImage_CGImageFormat(
            bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )!
        guard let buffer = try? vImage_Buffer(cgImage: image, format: format) else { return "\(image.width)x\(image.height) ?" }
        defer { buffer.free() }
        var hasher = SHA256()
        for row in 0..<image.height {
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer.data + row * buffer.rowBytes, count: image.width * 4))
        }
        return "\(image.width)x\(image.height) " + hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// What's cached: 2 has the lines' corners (2026-11-25). Records of another version are read again.
    private static let cacheVersion = 2

    private func loadCache() {
        guard let text = try? String(contentsOf: cacheURL, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  record["version"] as? Int == Self.cacheVersion,
                  let key = record["key"] as? String, let ms = record["ms"] as? Double,
                  let lines = record["lines"] as? [[String: Any]] else { continue }
            cache[key] = (lines.map { line in
                let box = Self.rect(line["box"])
                let words = (line["words"] as? [[Any]] ?? []).map { word in (word.first as? String ?? "", Self.rect(Array(word.dropFirst()))) }
                return RecognizedLine(text: line["text"] as? String ?? "", box: box, words: words, corners: RecognizedLine.corners(saved: line["corners"]))
            }, ms)
        }
    }

    private func save(_ key: String, _ lines: [RecognizedLine], _ ms: Double) {
        let numbers = { (rect: CGRect) -> [Any] in [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)] }
        let record: [String: Any] = ["version": Self.cacheVersion, "key": key, "ms": ms, "lines": lines.map { line in
            var item: [String: Any] = ["text": line.text, "box": numbers(line.box), "words": line.words.map { [$0.text as Any] + numbers($0.box) }]
            item["corners"] = line.savedCorners
            return item
        }]
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        if let handle = try? FileHandle(forWritingTo: cacheURL) {
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: cacheURL)
        }
    }

    private static func rect(_ value: Any?) -> CGRect {
        let numbers = (value as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue ?? 0 }
        guard numbers.count == 4 else { return .zero }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }
}

/// A simulation's movie frames, decoded ahead on a thread of their own and turned into the captures' color space (device
/// RGB) with vImage once each, rather than by each capture drawing them (the same pixels). Only the frames a capture can
/// show are kept: the first, and the last one before each of the stream's times (every 1/framesPerSecond seconds from
/// `from`; see Simulation.capture). At most `ahead` wait at a time.
private final class Frames: @unchecked Sendable {
    struct Frame {
        let time: Double
        let image: CGImage
    }

    private static let ahead = 6
    private let condition = NSCondition()
    private var ready: [Frame] = []
    private var finished = false

    init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, from: Double, framesPerSecond: Double) {
        nonisolated(unsafe) let (reader, output) = (reader, output)
        Thread.detachNewThread { [self] in
            decode(output, from: from, framesPerSecond: framesPerSecond)
            withExtendedLifetime(reader) {}
        }
    }

    /// The next frame, once it's ready; nil after the last.
    func next() -> Frame? {
        condition.lock()
        defer { condition.unlock() }
        while ready.isEmpty && !finished { condition.wait() }
        return ready.first
    }

    func removeNext() {
        condition.lock()
        ready.removeFirst()
        condition.broadcast()
        condition.unlock()
    }

    private func decode(_ output: AVAssetReaderTrackOutput, from: Double, framesPerSecond: Double) {
        var converter: (vImageConverter, vImage_CGImageFormat, vImage_CGImageFormat)?
        var previous: (time: Double, pixels: CVPixelBuffer)?
        var isFirst = true
        // The next of the stream's times, from + stream / framesPerSecond (as Simulation.capture works it out).
        var stream = 0
        func keep(_ time: Double, _ pixels: CVPixelBuffer) {
            var made: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &made)
            guard let frame = made else { return }
            if converter == nil, let source = vImage_CGImageFormat(cgImage: frame), let target = vImage_CGImageFormat(
                bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            ), let made = try? vImageConverter.make(sourceFormat: source, destinationFormat: target) {
                converter = (made, source, target)
            }
            guard let (converter, source, target) = converter, let input = try? vImage_Buffer(cgImage: frame, format: source),
                  var converted = try? vImage_Buffer(width: frame.width, height: frame.height, bitsPerPixel: 32) else { return }
            defer { input.free(); converted.free() }
            guard (try? converter.convert(source: input, destination: &converted)) != nil,
                  let image = try? converted.createCGImage(format: target) else { return }
            condition.lock()
            while ready.count >= Self.ahead { condition.wait() }
            ready.append(Frame(time: time, image: image))
            condition.broadcast()
            condition.unlock()
        }
        while let buffer = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            if let (previousTime, previousPixels) = previous {
                while Double(stream) / framesPerSecond + from < previousTime { stream += 1 }
                if isFirst || Double(stream) / framesPerSecond + from < time { keep(previousTime, previousPixels) }
                isFirst = false
            }
            previous = (time, pixels)
        }
        if let (time, pixels) = previous { keep(time, pixels) }
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }
}
