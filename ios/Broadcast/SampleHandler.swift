import CoreMedia
import ReplayKit

/// Continuous mode's capture: a system-wide broadcast (Control Center, or the app's broadcast button). It compares the
/// user's areas of the screen (or all of it) every few tenths of a second, and when they differ from the last frame it
/// handed to the app (SharedFrame), hands this one over. The app reads them until the text settles (see
/// Continuous.readFrame): with video or an animated background behind the text, the picture never does. The engines
/// need more memory than an extension has.
final class SampleHandler: RPBroadcastSampleHandler {
    private var lastCompared: CFAbsoluteTime = 0
    private var lastLogged: CFAbsoluteTime = 0
    /// Thumbnails of the areas in the last frame handed over.
    private var sent: [[UInt8]]?
    private var number: UInt64 = 0
    private var counts = (frames: 0, compared: 0, sent: 0)
    /// Time spent comparing frames and writing those sent.
    private var seconds = (comparing: 0.0, writing: 0.0)

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        log("Broadcast started, every \(SharedFrame.interval) s")
        SharedFrame.defaults.set(Date().timeIntervalSince1970, forKey: SharedFrame.broadcastAliveKey)
        SharedFrame.announce(SharedFrame.startedNotification)
    }

    override func broadcastPaused() { log("Broadcast paused") }
    override func broadcastResumed() { log("Broadcast resumed") }
    override func broadcastFinished() {
        log("Broadcast finished")
        SharedFrame.defaults.removeObject(forKey: SharedFrame.broadcastAliveKey)
        SharedFrame.announce(SharedFrame.finishedNotification)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        counts.frames += 1
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastLogged >= 10 {
            lastLogged = now
            SharedFrame.defaults.set(Date().timeIntervalSince1970, forKey: SharedFrame.broadcastAliveKey)
            log(String(
                format: "%d frames, %d compared, %d sent; comparing %.0f ms, writing %.0f ms on average",
                counts.frames, counts.compared, counts.sent,
                seconds.comparing / Double(max(counts.compared, 1)) * 1000, seconds.writing / Double(max(counts.sent, 1)) * 1000
            ))
        }
        guard now - lastCompared >= SharedFrame.interval, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastCompared = now
        counts.compared += 1

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        // ReplayKit's left and right are the other way around from CGImagePropertyOrientation's (applied as they are,
        // landscape frames came out upside down).
        let attached = (CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber)?.uint32Value ?? 1
        let orientation: UInt32 = attached == 6 ? 8 : attached == 8 ? 6 : attached
        guard let thumbnails = Self.thumbnails(pixelBuffer, orientation: orientation) else { return }
        let differs = sent.map { Self.differs(thumbnails, $0) } ?? true
        seconds.comparing += CFAbsoluteTimeGetCurrent() - now
        guard differs else { return }
        sent = thumbnails

        let start = CFAbsoluteTimeGetCurrent()
        do {
            try write(pixelBuffer, orientation: orientation)
            seconds.writing += CFAbsoluteTimeGetCurrent() - start
            counts.sent += 1
            SharedFrame.announce()
        } catch {
            log("Writing the frame failed: \(error.localizedDescription)")
        }
    }

    private func write(_ pixelBuffer: CVPixelBuffer, orientation: UInt32) throws {
        guard let url = SharedFrame.url else { throw AppError("The App Group isn’t available.") }
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        let planes: [(bytesPerRow: Int, height: Int, base: UnsafeMutableRawPointer?)] = planeCount == 0
            ? [(CVPixelBufferGetBytesPerRow(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), CVPixelBufferGetBaseAddress(pixelBuffer))]
            : (0..<planeCount).map {
                (CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, $0), CVPixelBufferGetHeightOfPlane(pixelBuffer, $0), CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, $0))
            }
        number += 1
        let header = SharedFrame.Header(
            pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer),
            width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer),
            orientation: orientation, planes: planes.map { ($0.bytesPerRow, $0.height) }, number: number
        )
        var data = header.data
        data.reserveCapacity(SharedFrame.headerSize + planes.reduce(0) { $0 + $1.bytesPerRow * $1.height })
        for plane in planes {
            guard let base = plane.base else { throw AppError("The frame has no pixels.") }
            data.append(base.assumingMemoryBound(to: UInt8.self), count: plane.bytesPerRow * plane.height)
        }
        try data.write(to: url, options: .atomic)
    }

    /// Thumbnails of the user's areas that apply to the frame (or of the whole screen), at most about 256 pixels a side:
    /// the luma plane's, or a BGRA frame's green.
    private static func thumbnails(_ pixelBuffer: CVPixelBuffer, orientation: UInt32) -> [[UInt8]]? {
        let planar = CVPixelBufferGetPlaneCount(pixelBuffer) > 0
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) : CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = planar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : CVPixelBufferGetWidth(pixelBuffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) : CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let step = planar ? 1 : 4, offset = planar ? 0 : 1
        let turned = orientation == 6 || orientation == 8
        let areas = ScreenArea.matching(SharedFrame.areas, width: turned ? height : width, height: turned ? width : height)
        let rects = areas.isEmpty
            ? [CGRect(x: 0, y: 0, width: width, height: height)]
            : areas.map { $0.pixels(inFrameOf: width, height: height, orientation: orientation) }
        return rects.map { rect in
            guard rect.width >= 1, rect.height >= 1 else { return [] }
            let stride = max(1, Int(max(rect.width, rect.height)) / 256)
            var thumbnail: [UInt8] = []
            thumbnail.reserveCapacity((Int(rect.width) / stride + 1) * (Int(rect.height) / stride + 1))
            for y in Swift.stride(from: Int(rect.minY), to: Int(rect.maxY), by: stride) {
                let row = pixels + y * bytesPerRow + offset
                for x in Swift.stride(from: Int(rect.minX), to: Int(rect.maxX), by: stride) {
                    thumbnail.append(row[x * step])
                }
            }
            return thumbnail
        }
    }

    /// Whether any area changed clearly (or the areas did).
    private static func differs(_ a: [[UInt8]], _ b: [[UInt8]]) -> Bool {
        guard a.count == b.count else { return true }
        // As MacPopup's OCR mode (OCRController.differs): more than the threshold's share of an area's pixels changed
        // clearly (by more than 40 of 255), so a blinking cursor or slight animation doesn't count.
        let threshold = SharedFrame.changeThreshold / 100
        return zip(a, b).contains { x, y in
            guard x.count == y.count, !x.isEmpty else { return x.count != y.count }
            var changed = 0
            for index in x.indices where abs(Int(x[index]) - Int(y[index])) > 40 { changed += 1 }
            return Double(changed) / Double(x.count) > threshold
        }
    }

    private func log(_ message: String) {
        let memory = Memory.footprint()
        let available = Memory.available()
        IntentLog.append(
            "\(message) [memory \(Memory.megabytes(memory.current)), peak \(Memory.megabytes(memory.peak)), limit about \(Memory.megabytes(memory.current + available))]",
            to: "continuous.log"
        )
    }
}
