import AVFoundation
import CoreAudio
import Darwin
import PauseHelperInterface

/// Records what some processes play, with a Core Audio process tap: an app with its helper
/// processes, or every process but some. Apps often play their sound from another process (WebKit's GPU
/// process for web views, a browser's helpers, Parallels' VM process), which ScreenCaptureKit's
/// recording of an app leaves out. A Windows app in Parallels' Coherence mode has a window of its own
/// helper app, which can't be told from the VM's process: the sound of every Parallels VM is recorded.
///
/// A tap keeps recording the processes it was made with: Core Audio doesn't follow changes to them while
/// it runs. So when the processes to record change (a process is added to the ones Core Audio knows
/// when it first plays sound), or the default output device does, the tap is made again, which leaves a
/// gap of a few milliseconds. Its buffers keep the first tap's format: another output device can have
/// another sample rate (or, for a tap of the device, other channels), and then they're converted.
///
/// A tap only records while its processes play sound. So that the recording keeps time (as for how long
/// to wait for a voice), silence stands in for the time they don't.
///
/// The first recording asks for permission to record other apps' audio. Without it, the tap only
/// records silence.
final class AudioTap {
    /// Which processes are recorded, by process ID.
    enum Processes: Equatable {
        /// The app with this process and its helpers (see `belongs`).
        case app(pid_t)
        /// Every process but this app and its helpers.
        case allBut(pid_t)
    }

    /// A tap of some processes, and the private device that records it.
    private final class Recorder {
        let exclusive: Bool
        let objects: [AudioObjectID]
        let outputDevice: String
        /// The format of the buffers it gives.
        let format: AVAudioFormat
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var ioProcID: AudioDeviceIOProcID?
        /// Cleared by `destroy`, so buffers still on their way to the queue are dropped. Only used on the queue.
        private var isLive = true
        /// Core Audio waits for its IO block, holding a lock that AudioDeviceStop takes, so the block runs here and not
        /// on the queue, where the recorder is destroyed (stopping it there would wait for itself).
        private let ioQueue = DispatchQueue(label: "com.aury.macpopup.audio-tap.io")

        /// Records `objects` (Core Audio process objects), or with `exclusive`, everything other processes play on the
        /// default output device. Buffers are `bufferFrames` long, or the device's own size.
        init(exclusive: Bool, objects: [AudioObjectID], bufferFrames: UInt32?, queue: DispatchQueue,
             onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
            self.exclusive = exclusive
            self.objects = objects
            outputDevice = AudioTap.defaultOutputDevice()
            // A global tap (stereoGlobalTapButExcludeProcesses) records the processes it should leave out
            // too, so the one that leaves some out is a tap of the output device.
            let description = exclusive
                ? CATapDescription(excludingProcesses: objects, deviceUID: outputDevice, stream: 0)
                : CATapDescription(stereoMixdownOfProcesses: objects)
            description.uuid = UUID()
            description.name = "MacPopup sentence audio"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            var tapID = AudioObjectID(kAudioObjectUnknown)
            try AudioTap.check(AudioHardwareCreateProcessTap(description, &tapID), "create the audio tap")
            var streamDescription = AudioStreamBasicDescription()
            guard AudioTap.get(tapID, kAudioTapPropertyFormat, &streamDescription) == noErr,
                  let tapFormat = AVAudioFormat(streamDescription: &streamDescription),
                  let format = AVAudioFormat(standardFormatWithSampleRate: tapFormat.sampleRate, channels: tapFormat.channelCount) else {
                AudioHardwareDestroyProcessTap(tapID)
                throw AppError("Couldn’t read the audio tap’s format")
            }
            self.tapID = tapID
            self.format = format
            do {
                let aggregate: [String: Any] = [
                    kAudioAggregateDeviceNameKey: "MacPopup sentence audio",
                    kAudioAggregateDeviceUIDKey: UUID().uuidString,
                    kAudioAggregateDeviceIsPrivateKey: true,
                    kAudioAggregateDeviceIsStackedKey: false,
                    kAudioAggregateDeviceTapAutoStartKey: true,
                    kAudioAggregateDeviceTapListKey: [[
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                        kAudioSubTapDriftCompensationKey: true,
                    ]],
                ]
                try AudioTap.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create the recording device")
                if var frames = bufferFrames {
                    var address = AudioTap.address(kAudioDevicePropertyBufferFrameSize)
                    AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
                }
                try AudioTap.check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { [weak self] _, input, _, _, _ in
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: input, deallocator: nil),
                          let copy = AudioTap.deinterleaved(buffer, as: format) else { return }
                    queue.async {
                        guard self?.isLive == true else { return }
                        onBuffer(copy)
                    }
                }, "start recording")
                try AudioTap.check(AudioDeviceStart(aggregateID, ioProcID), "start recording")
            } catch {
                destroy()
                throw error
            }
        }

        func destroy() {
            isLive = false
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                self.ioProcID = nil
            }
            if aggregateID != kAudioObjectUnknown {
                AudioHardwareDestroyAggregateDevice(aggregateID)
                aggregateID = AudioObjectID(kAudioObjectUnknown)
            }
            if tapID != kAudioObjectUnknown {
                AudioHardwareDestroyProcessTap(tapID)
                tapID = AudioObjectID(kAudioObjectUnknown)
            }
        }
    }

    private let processes: Processes
    private let bundle: String?
    /// A Windows app's helper in Parallels' Coherence mode, whose sound the VM's process plays.
    private let isParallelsApp: Bool
    private let queue: DispatchQueue
    private let onBuffer: (AVAudioPCMBuffer) -> Void
    private let bufferFrames: UInt32?
    private var recorder: Recorder?
    /// The format of the buffers given (the first recorder's), and the recorder's converter to it if it records
    /// another one.
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var listener: AudioObjectPropertyListenerBlock?
    /// Whether processesChanged is due: changes come in bursts (each sound that starts or ends is one), so they're
    /// checked at most every quarter second rather than each time.
    private var checkDue = false
    private var silenceTimer: DispatchSourceTimer?
    private var startTime = DispatchTime.now()
    private var lastBufferTime = DispatchTime.now()
    /// Seconds given to `onBuffer`.
    private var duration = 0.0

    /// `onBuffer` is called on `queue` with each new buffer, as Float32 with one buffer per channel. `bufferFrames`
    /// sets the buffer size: larger buffers wake MacPopup less often, for recordings that don't need the audio right
    /// away.
    init(processes: Processes, bufferFrames: UInt32? = nil, queue: DispatchQueue, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.processes = processes
        bundle = switch processes {
        case let .app(pid), let .allBut(pid): Self.bundlePath(of: pid)
        }
        // Parallels runs the VM as root, so it isn't the helper's child, and the helper is in a folder of
        // the user's, not in Parallels' app.
        isParallelsApp = PauseHelper.isParallelsWinApp(bundleID: bundle.flatMap { Bundle(path: $0)?.bundleIdentifier })
        self.queue = queue
        self.onBuffer = onBuffer
        self.bufferFrames = bufferFrames
    }

    deinit {
        stop()
    }

    func start() throws {
        try queue.sync {
            let (exclusive, objects, summary) = target()
            sentenceAudioLog(summary)
            recorder = try makeRecorder(exclusive: exclusive, objects: objects)
            startTime = .now()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
            timer.setEventHandler { [weak self] in self?.addSilence() }
            timer.resume()
            silenceTimer = timer
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.checkProcesses() }
            self.listener = listener
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
    }

    /// Called on the queue (or once nothing else uses it).
    func stop() {
        if let listener {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            self.listener = nil
        }
        silenceTimer?.cancel()
        silenceTimer = nil
        recorder?.destroy()
        recorder = nil
    }

    private func makeRecorder(exclusive: Bool, objects: [AudioObjectID]) throws -> Recorder {
        let recorder = try Recorder(exclusive: exclusive, objects: objects, bufferFrames: bufferFrames, queue: queue) { [weak self] buffer in
            // Buffers come on the queue, after makeRecorder has set the converter.
            guard let self, let buffer = converted(buffer) else { return }
            lastBufferTime = .now()
            duration += Double(buffer.frameLength) / buffer.format.sampleRate
            onBuffer(buffer)
        }
        let format = format ?? recorder.format
        self.format = format
        converter = nil
        if recorder.format != format {
            sentenceAudioLog(String(format: "recording %.0f Hz, %d channels, converted to the first recording's %.0f Hz, %d channels",
                                    recorder.format.sampleRate, recorder.format.channelCount, format.sampleRate, format.channelCount))
            converter = AVAudioConverter(from: recorder.format, to: format)
            converter?.downmix = recorder.format.channelCount > format.channelCount
        }
        return recorder
    }

    /// The buffer in `format`, if it's in another one (or nil if it can't be converted).
    private func converted(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, buffer.format == converter.inputFormat else { return buffer.format == format ? buffer : nil }
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                            frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024) else { return nil }
        var given = false
        var error: NSError?
        // No more for now (rather than the end of the stream): the converter keeps what it needs of this buffer.
        converter.convert(to: output, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }

    /// Fills the time since the tap last gave sound with silence, once it has stopped.
    private func addSilence() {
        let now = DispatchTime.now()
        let gap = Double(now.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1e9 - duration
        guard Double(now.uptimeNanoseconds - lastBufferTime.uptimeNanoseconds) / 1e9 > 0.25, gap > 0.05,
              let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(gap * format.sampleRate)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(format.channelCount) {
            channels[channel].update(repeating: 0, count: Int(buffer.frameLength))
        }
        duration += Double(buffer.frameLength) / format.sampleRate
        onBuffer(buffer)
    }

    /// The processes to tap: the app's (none until it has played sound, by leaving every process out), or
    /// every one but the app's.
    private func target() -> (exclusive: Bool, objects: [AudioObjectID], summary: String) {
        let all = Self.audioProcesses(withBundleIDs: isParallelsApp)
        let app = switch processes {
        case let .app(pid), let .allBut(pid): pid
        }
        let matching = all.filter {
            Self.belongs($0.pid, to: app, bundle: bundle) || (isParallelsApp && $0.bundleID == "com.parallels.vm")
        }
        let pids = matching.map { "\($0.pid)" }.joined(separator: ", ")
        switch processes {
        case .app where matching.isEmpty:
            return (true, all.map(\.object), "the app hasn't played sound yet")
        case .app:
            return (false, matching.map(\.object), "recording processes \(pids)")
        case .allBut:
            return (true, matching.map(\.object), matching.isEmpty ? "recording every process" : "recording every process but \(pids)")
        }
    }

    private func checkProcesses() {
        guard !checkDue else { return }
        checkDue = true
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.checkDue = false
            self?.processesChanged()
        }
    }

    /// Makes the tap again when the processes to record, or the output device it records, changed.
    private func processesChanged() {
        guard let current = recorder else { return }
        let (exclusive, objects, summary) = target()
        guard exclusive != current.exclusive || Set(objects) != Set(current.objects)
            || current.outputDevice != Self.defaultOutputDevice() else { return }
        sentenceAudioLog(summary)
        current.destroy()
        do {
            recorder = try makeRecorder(exclusive: exclusive, objects: objects)
        } catch {
            recorder = nil
            sentenceAudioLog("couldn't record the processes again: \(error.localizedDescription)")
        }
    }

    // MARK: Processes

    /// Core Audio's objects for the processes that have played or recorded sound, with their process IDs
    /// and, `withBundleIDs`, bundle IDs (each one more call to coreaudiod; else empty).
    private static func audioProcesses(withBundleIDs: Bool) -> [(object: AudioObjectID, pid: pid_t, bundleID: String)] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.compactMap { object in
            var pid: pid_t = -1
            var bundleID = "" as CFString
            if withBundleIDs { _ = get(object, kAudioProcessPropertyBundleID, &bundleID) }
            return get(object, kAudioProcessPropertyPID, &pid) == noErr ? (object, pid, bundleID as String) : nil
        }
    }

    /// Whether the process is the app's, or one of its helpers: one macOS holds the app responsible for
    /// (as WebKit's processes), a child of it (as with Wine), or one from inside its .app bundle (as a
    /// browser's helpers, or Parallels' VM).
    static func belongs(_ pid: pid_t, to app: pid_t, bundle: String?) -> Bool {
        if pid == app || responsiblePID(pid) == app { return true }
        var parent = parentPID(pid)
        for _ in 0..<64 where parent > 1 {
            if parent == app { return true }
            parent = parentPID(parent)
        }
        if let bundle, let path = PauseHelper.executablePath(pid), path.hasPrefix(bundle + "/") { return true }
        return false
    }

    /// The outermost .app bundle the process's executable is in.
    static func bundlePath(of pid: pid_t) -> String? {
        guard let path = PauseHelper.executablePath(pid), let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    private static func parentPID(_ pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return -1 }
        return pid_t(info.pbi_ppid)
    }

    /// The process macOS holds responsible for `pid` (for privacy permissions), which for an app's helpers
    /// is the app. Not in the SDK, so it's looked up, and -1 without it.
    private static let responsiblePID: (pid_t) -> pid_t = {
        typealias Function = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return { _ in -1 }
        }
        let function = unsafeBitCast(symbol, to: Function.self)
        return { function($0) }
    }()

    // MARK: Core Audio

    private static func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else { throw AppError("Couldn’t \(action) (\(status))") }
    }

    /// The UID of the default output device.
    private static func defaultOutputDevice() -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var uid = "" as CFString
        _ = get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &device)
        _ = get(device, kAudioDevicePropertyDeviceUID, &uid)
        return uid as String
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> OSStatus {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
    }

    /// A copy of `buffer` (which Core Audio reuses) with a buffer for each channel.
    private static func deinterleaved(_ buffer: AVAudioPCMBuffer, as format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let source = buffer.floatChannelData, let target = copy.floatChannelData else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(format.channelCount)
        if buffer.format.isInterleaved {
            for frame in 0..<frames {
                for channel in 0..<channels {
                    target[channel][frame] = source[0][frame * channels + channel]
                }
            }
        } else {
            for channel in 0..<channels {
                target[channel].update(from: source[channel], count: frames)
            }
        }
        return copy
    }
}
