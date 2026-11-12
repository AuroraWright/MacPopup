import AVFoundation
import AVKit
import CoreImage
import OCREngines
import ReplayKit
import SwiftUI

/// Continuous mode: reads the frames the broadcast extension (Broadcast/) hands over, in the user's areas (or the whole
/// screen), into the live readings Safari's /live page shows as they come. A silent audio session keeps the app
/// running in the background meanwhile. What it does goes to the App Group's continuous.log.
/// Continuous reading's settings (iOS only; the ones the extension uses are in SharedFrame).
enum ContinuousKey {
    /// An engine for continuous reading, or none for Settings' (see Continuous.engine).
    static let engine = "continuousEngine"
    /// Seconds the text must read the same before it's saved.
    static let settleTime = "continuousSettleTime"
    /// Seconds after which text that keeps changing is saved anyway.
    static let maxWait = "continuousMaxWait"
    /// Live readings kept for the page.
    static let kept = "continuousKept"
    /// Picture in Picture leaves out lines it showed lately.
    static let newLinesOnly = "continuousNewLinesOnly"

    static let defaults: [String: Any] = [engine: "", settleTime: 0.5, maxWait: 4.0, kept: 300, newLinesOnly: true]
}

@MainActor
final class Continuous: ObservableObject {
    static let shared = Continuous()

    /// Continuous reading is on: the app keeps running and reads the frames. It's on while the screen broadcast is (and
    /// while Picture in Picture shows, which needs the audio session).
    @Published private(set) var isOn = false
    @Published private(set) var isBroadcasting = false
    @Published private(set) var latest: Reading?
    /// The latest frames read, newest first, to draw areas on.
    @Published private(set) var recentFrames: [Picture] = []
    @Published var areas = SharedFrame.areas {
        didSet { SharedFrame.areas = areas }
    }

    /// Made once reading starts: setting up its output with the session's default category, at launch, stops other
    /// apps' sound (e.g. a YouTube video playing in the background).
    private var audio: AVAudioEngine?
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    private var heartbeat: Timer?
    private var started = Date()
    private var isReading = false
    /// A frame arrived while one was being read.
    private var isPending = false
    /// Frames announced, and those dropped since another was being read, since the last heartbeat.
    private var counts = (arrived: 0, dropped: 0)
    /// The text last saved for each area (nil: the whole screen), to skip readings that didn't change.
    private var lastTexts: [UUID?: String] = [:]
    /// Each area's new text waiting to settle: saved once it has read the same for `settleTime`, or once no frame came
    /// for that long (the extension only sends frames that changed, so the picture stayed the same).
    private var pending: [UUID?: Pending] = [:]
    private var settling: Task<Void, Never>?
    /// The lines of the latest readings, so that Picture in Picture leaves out text that stays on screen (names, menus,
    /// labels) and shows only what's new.
    private var seenLines: [String] = []
    /// When the live page last said it's in front (see pageIsVisible).
    private var pageSeen = Date.distantPast
    private static let seenLineCount = 200
    private let defaults = UserDefaults.standard
    /// As MacPopup's OCR mode (Settings → OCR Mode: settle time, and how long to wait for text that keeps changing).
    private var settleTime: TimeInterval { defaults.double(forKey: ContinuousKey.settleTime) }
    private var maxWait: TimeInterval { defaults.double(forKey: ContinuousKey.maxWait) }

    private struct Pending {
        var text: String
        var page: [String: Any]
        var picture: Picture
        /// When the text was first read like this, and when the area started changing.
        var since: Date
        var started: Date
    }
    /// CIContext renders on the GPU by default, which apps can't use in the background.
    nonisolated private static let context = CIContext(options: [.useSoftwareRenderer: true])
    private init() {
        UserDefaults.standard.register(defaults: ContinuousKey.defaults)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center, nil, { _, _, _, _, _ in Task { @MainActor in Continuous.shared.frameArrived() } },
            SharedFrame.notification as CFString, nil, .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center, nil, { _, _, _, _, _ in Task { @MainActor in Continuous.shared.broadcastChanged(true) } },
            SharedFrame.startedNotification as CFString, nil, .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center, nil, { _, _, _, _, _ in Task { @MainActor in Continuous.shared.broadcastChanged(false) } },
            SharedFrame.finishedNotification as CFString, nil, .deliverImmediately
        )
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { notification in
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            Task { @MainActor in Continuous.shared.interrupted(type == .ended) }
        }
        latest = ReadingStore.live.readings.first
    }

    /// The engine in Settings, but meikiocr instead of one that can't read continuously (Engine.readsContinuously):
    /// Google Lens and Bing would make a request for each change.
    var engine: Engine {
        if let chosen = Engine(rawValue: defaults.string(forKey: ContinuousKey.engine) ?? ""), chosen.isAvailable, chosen.readsContinuously {
            return chosen
        }
        let engine = AppModel.shared.engine
        return engine.readsContinuously ? engine : .meikiocr
    }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        if on {
            do {
                try startAudio()
                PageServer.shared.start()
                useCPU(true)
                isOn = true
                started = Date()
                lastTexts = [:]
                heartbeat = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                    MainActor.assumeIsolated { Continuous.shared.beat() }
                }
                record("Continuous reading on with \(engine.name)")
            } catch {
                record("Continuous reading couldn’t start: \(error.localizedDescription)")
                AppModel.shared.error = "Continuous reading couldn’t start: \(error.localizedDescription)"
            }
        } else {
            isOn = false
            PiPCompanion.shared.stop()
            player.stop()
            audio?.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            heartbeat?.invalidate()
            heartbeat = nil
            useCPU(false)
            record("Continuous reading off")
        }
    }

    /// Reloads the engine's models on the CPU, or back where they run best.
    private func useCPU(_ cpu: Bool) {
        OCRCompute.cpuOnly = cpu
        Task {
            await AppModel.shared.unloadEngine()
            if cpu { await AppModel.shared.prepareEngine(engine) }
        }
    }

    /// Plays silence, mixed with other apps' sound.
    private func startAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, options: .mixWithOthers)
        try session.setActive(true)
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
        silence.frameLength = 44100
        for channel in 0..<Int(format.channelCount) {
            silence.floatChannelData![channel].update(repeating: 0, count: Int(silence.frameLength))
        }
        let audio = self.audio ?? {
            let audio = AVAudioEngine()
            audio.attach(player)
            audio.connect(player, to: audio.mainMixerNode, format: format)
            self.audio = audio
            return audio
        }()
        try audio.start()
        player.scheduleBuffer(silence, at: nil, options: .loops)
        player.play()
    }

    private func interrupted(_ ended: Bool) {
        record(ended ? "Audio interruption ended" : "Audio interrupted")
        guard ended, isOn else { return }
        do {
            try startAudio()
        } catch {
            record("Restarting the audio failed: \(error.localizedDescription)")
        }
    }

    /// Continuous reading follows the broadcast: it stops with it, so the app no longer runs in the background.
    private func broadcastChanged(_ broadcasting: Bool) {
        isBroadcasting = broadcasting
        record(broadcasting ? "Broadcast started" : "Broadcast finished")
        setOn(broadcasting)
    }

    /// When the app comes to the front: a broadcast started from Control Center while the app wasn't running starts
    /// reading now, and one that finished meanwhile stops it.
    func appBecameActive() {
        let broadcasting = SharedFrame.isBroadcasting
        guard broadcasting != isBroadcasting else { return }
        broadcastChanged(broadcasting)
    }

    private func beat() {
        record(String(
            format: "Running for %.0f min, battery %.0f%%, %d frames arrived, %d dropped while reading",
            Date().timeIntervalSince(started) / 60, UIDevice.current.batteryLevel * 100, counts.arrived, counts.dropped
        ))
        counts = (0, 0)
    }

    func clear() {
        ReadingStore.live.delete(Set(ReadingStore.live.readings.map(\.id)))
        latest = nil
        lastTexts = [:]
        pending = [:]
        seenLines = []
        PiPCompanion.shared.show("")
    }

    func addArea(_ part: CGRect, on frame: Picture) {
        areas.append(ScreenArea(rect: part, landscape: frame.image.width > frame.image.height))
    }

    /// The live page is in front: the broadcast would read the page itself. It says so every second while it is, so
    /// reading starts again a moment after Safari goes to the background. Text not settled yet is dropped: it may be
    /// the page's, seen while switching to it.
    func pageIsVisible() {
        if !isPaused {
            record("Paused: the live page is in front")
            pending = [:]
            settling?.cancel()
        }
        pageSeen = Date()
    }

    private var isPaused: Bool {
        Date().timeIntervalSince(pageSeen) < 2.5
    }

    private func frameArrived() {
        // Frames of MacPopup itself or of the live page, or with continuous reading off, aren't read.
        guard isOn, UIApplication.shared.applicationState != .active, !isPaused else { return }
        counts.arrived += 1
        guard !isReading else {
            if isPending { counts.dropped += 1 }
            isPending = true
            return
        }
        isReading = true
        Task {
            await readFrame()
            isReading = false
            if isPending {
                isPending = false
                frameArrived()
            }
        }
    }

    private func readFrame() async {
        let start = Date()
        guard let (image, number) = await Task.detached(priority: .userInitiated, operation: { Self.frame() }).value else {
            return record("Couldn’t read the frame")
        }
        let saved = await read(Picture(image: image), number: number)
        record(String(
            format: "Frame %d: %d saved, %.0f ms with %@", number, saved, Date().timeIntervalSince(start) * 1000, engine.name
        ))
    }

    /// Reads a frame's areas; text that has settled goes into the live readings. Returns how many areas were saved.
    @discardableResult
    func read(_ frame: Picture, number: UInt64 = 0) async -> Int {
        let image = frame.image
        recentFrames = Array(([frame] + recentFrames).prefix(6))
        let matching = ScreenArea.matching(areas, width: image.width, height: image.height)
        // The whole screen when no area applies.
        let parts: [(id: UUID?, rect: CGRect)] = matching.isEmpty ? [(nil, CGRect(x: 0, y: 0, width: 1, height: 1))] : matching.map { ($0.id, $0.rect) }
        settling?.cancel()
        var saved = 0
        for part in parts {
            let picture = frame.cropped(to: part.rect)
            do {
                let page = try await AppModel.shared.page(picture, engine: engine)
                // The live page came to the front meanwhile.
                guard !isPaused else { return saved }
                let text = ReadingStore.text(page)
                let now = Date()
                guard !text.isEmpty, text != lastTexts[part.id] else {
                    // An empty area lets the same text count as new when it comes back.
                    if text.isEmpty { lastTexts[part.id] = "" }
                    pending[part.id] = nil
                    continue
                }
                if var waiting = pending[part.id] {
                    if waiting.text != text {
                        waiting = Pending(text: text, page: page, picture: picture, since: now, started: waiting.started)
                    }
                    pending[part.id] = waiting
                    if now.timeIntervalSince(waiting.since) >= settleTime || now.timeIntervalSince(waiting.started) >= maxWait {
                        if save(part.id) { saved += 1 }
                    }
                } else {
                    pending[part.id] = Pending(text: text, page: page, picture: picture, since: now, started: now)
                }
            } catch {
                record("Frame \(number): reading failed: \(error.localizedDescription)")
            }
        }
        if !pending.isEmpty {
            settling = Task {
                try? await Task.sleep(for: .seconds(settleTime))
                guard !Task.isCancelled, !isReading, !isPending else { return }
                for id in Array(pending.keys) { save(id) }
            }
        }
        return saved
    }

    /// Saves an area's pending text into the live readings and shows it.
    @discardableResult
    private func save(_ id: UUID?) -> Bool {
        guard let waiting = pending.removeValue(forKey: id) else { return false }
        lastTexts[id] = waiting.text
        do {
            let reading = try ReadingStore.live.save(waiting.picture, reading: waiting.page)
            ReadingStore.live.keepNewest(defaults.integer(forKey: ContinuousKey.kept))
            latest = reading
            PageServer.shared.announce(reading)
            let lines = ReadingStore.lines(waiting.page)
            let new = defaults.bool(forKey: ContinuousKey.newLinesOnly)
                ? lines.filter { line in !seenLines.contains { Self.similar($0, line) } }
                : lines
            seenLines = Array((seenLines + lines).suffix(Self.seenLineCount))
            if !new.isEmpty { PiPCompanion.shared.show(new.joined(separator: "\n")) }
            record("Saved: \(String(waiting.text.prefix(40)))")
            return true
        } catch {
            record("Saving the reading failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Whether two lines read the same, allowing a character in ten to differ (the same text read again can come out
    /// slightly differently, e.g. over a moving background).
    private static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let a = Array(a), b = Array(b)
        let allowed = max(a.count, b.count) / 10
        guard abs(a.count - b.count) <= allowed, allowed > 0 else { return false }
        // Edit distance, one row at a time.
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1] + [Int](repeating: 0, count: b.count)
            for (j, y) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1))
            }
            if current.min()! > allowed { return false }
            previous = current
        }
        return previous[b.count] <= allowed
    }

    /// The frame in the App Group, turned the way the screen shows it.
    nonisolated private static func frame() -> (CGImage, UInt64)? {
        guard let url = SharedFrame.url, let data = try? Data(contentsOf: url), let header = SharedFrame.Header(data) else { return nil }
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, header.width, header.height, header.pixelFormat, attributes, &created) == kCVReturnSuccess,
              let buffer = created
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        let planar = CVPixelBufferGetPlaneCount(buffer) > 0
        data.withUnsafeBytes { bytes in
            var offset = SharedFrame.headerSize
            for (index, plane) in header.planes.enumerated() {
                guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, index) : CVPixelBufferGetBaseAddress(buffer) else { continue }
                let bytesPerRow = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, index) : CVPixelBufferGetBytesPerRow(buffer)
                let rows = min(plane.height, planar ? CVPixelBufferGetHeightOfPlane(buffer, index) : CVPixelBufferGetHeight(buffer))
                for row in 0..<rows {
                    memcpy(base + row * bytesPerRow, bytes.baseAddress! + offset + row * plane.bytesPerRow, min(bytesPerRow, plane.bytesPerRow))
                }
                offset += plane.bytesPerRow * plane.height
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let image = CIImage(cvPixelBuffer: buffer).oriented(CGImagePropertyOrientation(rawValue: header.orientation) ?? .up)
        return context.createCGImage(image, from: image.extent).map { ($0, header.number) }
    }

    /// Adds to continuous.log, with the app's state.
    func record(_ message: String) {
        let state = switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        default: "background"
        }
        let thermal = ["nominal", "fair", "serious", "critical"][ProcessInfo.processInfo.thermalState.rawValue]
        let memory = Memory.footprint().current
        IntentLog.append("\(message) [\(state), memory \(Memory.megabytes(memory)) of \(Memory.megabytes(memory + Memory.available())), \(thermal)]", to: "continuous.log")
    }
}

/// A Picture in Picture window over every app with the latest text, drawn by the app into an
/// AVSampleBufferDisplayLayer. It can't be tapped (taps show the PiP controls), so it's only to read along.
@MainActor
final class PiPCompanion: NSObject, ObservableObject {
    static let shared = PiPCompanion()

    @Published private(set) var isActive = false
    /// The view the window starts from; it has to be on screen. It shows what the window shows.
    let sourceView = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 120))

    private static let size = CGSize(width: 800, height: 300)
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var possible: NSKeyValueObservation?
    private var text = ""

    override private init() {
        super.init()
        sourceView.backgroundColor = .black
        displayLayer.frame = sourceView.bounds
        displayLayer.videoGravity = .resizeAspect
        sourceView.layer.addSublayer(displayLayer)
        text = Continuous.shared.latest?.text ?? ""
        enqueue()
    }

    func start() {
        Continuous.shared.setOn(true)
        guard controller == nil else { return }
        let controller = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self))
        controller.delegate = self
        self.controller = controller
        enqueue()
        possible = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { controller, _ in
            guard controller.isPictureInPicturePossible else { return }
            DispatchQueue.main.async {
                if !controller.isPictureInPictureActive { controller.startPictureInPicture() }
            }
        }
    }

    func stop() {
        controller?.stopPictureInPicture()
        controller = nil
        possible = nil
        isActive = false
        if !Continuous.shared.isBroadcasting { Continuous.shared.setOn(false) }
    }

    func show(_ text: String) {
        self.text = text
        enqueue()
    }

    /// The text as large as fits, in white on black.
    private func enqueue() {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(nil, Int(Self.size.width), Int(Self.size.height), kCVPixelFormatType_32BGRA, attributes, &created) == kCVReturnSuccess,
              let buffer = created
        else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: Int(Self.size.width), height: Int(Self.size.height), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) {
            context.setFillColor(UIColor.black.cgColor)
            context.fill(CGRect(origin: .zero, size: Self.size))
            context.translateBy(x: 0, y: Self.size.height)
            context.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(context)
            let bounds = CGRect(origin: .zero, size: Self.size).insetBy(dx: 24, dy: 20)
            let shown = text.isEmpty ? "MacPopup" : text
            var size: CGFloat = 64
            var attributes: [NSAttributedString.Key: Any] = [:]
            var height = CGFloat.infinity
            while size >= 18 {
                attributes = [.font: UIFont.systemFont(ofSize: size), .foregroundColor: text.isEmpty ? UIColor.gray : UIColor.white]
                height = (shown as NSString).boundingRect(
                    with: CGSize(width: bounds.width, height: .infinity), options: .usesLineFragmentOrigin, attributes: attributes, context: nil
                ).height
                if height <= bounds.height { break }
                size -= 4
            }
            let top = bounds.minY + max(0, (bounds.height - height) / 2)
            (shown as NSString).draw(
                with: CGRect(x: bounds.minX, y: top, width: bounds.width, height: bounds.maxY - top),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes, context: nil
            )
            UIGraphicsPopContext()
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard let format, CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }
}

extension PiPCompanion: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in PiPCompanion.shared.isActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in PiPCompanion.shared.stop() }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            PiPCompanion.shared.stop()
            Continuous.shared.record("Picture in Picture failed to start: \(message)")
            AppModel.shared.error = "Picture in Picture couldn’t start: \(message)"
        }
    }
}

extension PiPCompanion: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { false }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping @Sendable () -> Void
    ) {
        completionHandler()
    }
}

struct ContinuousView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var continuous = Continuous.shared
    @ObservedObject private var pip = PiPCompanion.shared
    @AppStorage(SharedFrame.intervalKey, store: SharedFrame.defaults) private var interval = 0.5
    @AppStorage(SharedFrame.changeThresholdKey, store: SharedFrame.defaults) private var changeThreshold = 0.3
    @AppStorage(ContinuousKey.engine) private var engine = ""
    @AppStorage(ContinuousKey.settleTime) private var settleTime = 0.5
    @AppStorage(ContinuousKey.maxWait) private var maxWait = 4.0
    @AppStorage(ContinuousKey.kept) private var kept = 300
    @AppStorage(ContinuousKey.newLinesOnly) private var newLinesOnly = true
    @State private var addsArea = false

    var body: some View {
        Form {
            Section {
                Button {
                    BroadcastButton.showPicker()
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(continuous.isBroadcasting ? "Stop Reading the Screen" : "Start Reading the Screen")
                            Text(continuous.isBroadcasting ? "Reading" : "A screen broadcast, also in Control Center")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: continuous.isBroadcasting ? "stop.circle.fill" : "record.circle")
                            .font(.title2)
                            .foregroundStyle(.red)
                    }
                    .contentShape(Rectangle())
                }
                // A plain button: a list tints a default one's whole label.
                .buttonStyle(.plain)
                .background(BroadcastButton().frame(width: 1, height: 1).opacity(0.01))
                Button("Open the Live Page") { model.open(PageServer.live) }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("While the broadcast runs, MacPopup reads the screen each time its text changes and then stays the same, and adds it to the live page in Safari, where your dictionary extension looks it up. It uses more battery.")
                    if engine.isEmpty && model.engine.isCloud {
                        Text("\(model.engine.name) would be asked to read each change of the screen, so continuous reading uses meikiocr instead.")
                    }
                }
            }
            Section {
                Toggle("Show the Latest Text", isOn: Binding(get: { pip.isActive }, set: { $0 ? pip.start() : pip.stop() }))
                Toggle("Only New Lines", isOn: $newLinesOnly)
                PiPSourceView()
                    .frame(width: 320, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } header: {
                Text("Picture in Picture")
            } footer: {
                Text(newLinesOnly
                    ? "A window over other apps with the latest new lines: text that stays on screen, like names and menus, is shown only the first time. Move the window out of your areas, or it’s read too."
                    : "A window over other apps with the latest text read. Move it out of your areas, or it’s read too.")
            }
            Section {
                ForEach(Array(continuous.areas.enumerated()), id: \.element.id) { index, area in
                    LabeledContent("Area \(index + 1)", value: area.landscape ? "Landscape" : "Portrait")
                }
                .onDelete { continuous.areas.remove(atOffsets: $0) }
                Button("Add Area…") { addsArea = true }
                    .disabled(continuous.recentFrames.isEmpty)
            } header: {
                Text("Areas")
            } footer: {
                Text(continuous.recentFrames.isEmpty
                    ? "Without areas, the whole screen is read. To draw one, read the game’s screen once first: start reading the screen, then switch to the game and back."
                    : "Only the areas are watched and read (those drawn with the screen turned the same way). Without areas, the whole screen is.")
            }
            Section {
                Picker("Engine", selection: $engine) {
                    Text("As in Settings (\(continuous.engine.name))").tag("")
                    ForEach(Engine.allCases.filter { $0.readsContinuously && $0.isAvailable }) { engine in
                        Text(engine.name).tag(engine.rawValue)
                    }
                }
                Stepper(value: $interval, in: 0.25...2, step: 0.25) {
                    LabeledContent("Check the Screen Every", value: "\(interval.formatted()) s")
                }
                Stepper(value: $changeThreshold, in: 0.1...3, step: 0.1) {
                    LabeledContent("Change Needed", value: "\(changeThreshold.formatted(.number.precision(.fractionLength(1))))%")
                }
                Stepper(value: $settleTime, in: 0.25...3, step: 0.25) {
                    LabeledContent("Text Settles After", value: "\(settleTime.formatted()) s")
                }
                Stepper(value: $maxWait, in: 1...15, step: 1) {
                    LabeledContent("Changing Text Saved After", value: "\(maxWait.formatted()) s")
                }
                Stepper(value: $kept, in: 50...1000, step: 50) {
                    LabeledContent("Live Page Keeps", value: "\(kept) readings")
                }
            } header: {
                Text("Reading")
            } footer: {
                Text("Checking more often and needing less change finds new text sooner, with more battery. Change needed is the share of an area’s pixels that must change clearly for it to be read again. Text is saved once it reads the same for the settle time, or once the screen stops changing; text that keeps changing (e.g. over video) is saved after the longer time anyway.")
            }
            Section("Latest") {
                Text(continuous.latest?.text ?? "Nothing read yet.")
                    .foregroundStyle(continuous.latest == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                Button("Clear the Live Page", role: .destructive) { continuous.clear() }
                    .disabled(continuous.latest == nil)
            }
        }
        .navigationTitle("Continuous Reading")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $addsArea) {
            AreaFramePicker(frames: continuous.recentFrames) { part, frame in
                continuous.addArea(part, on: frame)
                addsArea = false
            }
        }
    }
}

/// Chooses one of the latest frames read, then draws the area on it.
private struct AreaFramePicker: View {
    let frames: [Picture]
    let add: (CGRect, Picture) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(frames.indices, id: \.self) { index in
                        NavigationLink {
                            CropView(picture: frames[index], title: "Area", action: "Add") { add($0, frames[index]) }
                        } label: {
                            Image(uiImage: UIImage(cgImage: frames[index].image))
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Choose a Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// The system's button that starts and stops a broadcast, with MacPopup's extension chosen. It's hidden behind the
/// app's own button, which taps it (showPicker): only the system's button may show the broadcast sheet.
private struct BroadcastButton: UIViewRepresentable {
    @MainActor private static weak var picker: RPSystemBroadcastPickerView?

    @MainActor static func showPicker() {
        picker?.subviews.compactMap { $0 as? UIButton }.first?.sendActions(for: .touchUpInside)
    }

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = "com.aury.macpopup.ios.broadcast"
        picker.showsMicrophoneButton = false
        Self.picker = picker
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

private struct PiPSourceView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { PiPCompanion.shared.sourceView }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
