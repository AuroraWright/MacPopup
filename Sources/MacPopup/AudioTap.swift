import AVFoundation
import CoreAudio
import Darwin

/// Records what some processes play, with a Core Audio process tap (macOS 14.2): an app with its helper
/// processes, or every process but some. Apps often play their sound from another process (WebKit's GPU
/// process for web views, a browser's helpers, Parallels' VM process), which ScreenCaptureKit's
/// recording of an app leaves out.
///
/// A tap keeps recording the processes it was made with: Core Audio doesn't follow changes to them while
/// it runs. So when the processes to record change (a process is added to the ones Core Audio knows
/// when it first plays sound), or the default output device does, the tap is made again, which leaves a
/// gap of a few milliseconds.
///
/// A tap only records while its processes play sound. So that the recording keeps time (as for how long
/// to wait for a voice), silence stands in for the time they don't.
///
/// The first recording asks for permission to record other apps' audio. Without it, the tap only
/// records silence.
@available(macOS 14.2, *)
final class AudioTap {
    /// Which processes are recorded, by process ID.
    enum Processes {
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

        /// Records `objects` (Core Audio's process objects), or, when `exclusive`, every process but those
        /// that plays on the default output device.
        init(exclusive: Bool, objects: [AudioObjectID], queue: DispatchQueue, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
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
                throw SentenceAudioError("Couldn’t read the audio tap’s format")
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
                try AudioTap.check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, _, _ in
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: input, deallocator: nil),
                          let copy = AudioTap.deinterleaved(buffer, as: format) else { return }
                    onBuffer(copy)
                }, "start recording")
                try AudioTap.check(AudioDeviceStart(aggregateID, ioProcID), "start recording")
            } catch {
                destroy()
                throw error
            }
        }

        func destroy() {
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
    private let queue: DispatchQueue
    private let onBuffer: (AVAudioPCMBuffer) -> Void
    private var recorder: Recorder?
    private var listener: AudioObjectPropertyListenerBlock?
    private var silenceTimer: DispatchSourceTimer?
    private var startTime = DispatchTime.now()
    private var lastBufferTime = DispatchTime.now()
    /// Seconds given to `onBuffer`.
    private var duration = 0.0

    /// `onBuffer` is called on `queue` with each part of the recording, in a format of its own (Float32,
    /// one buffer for each channel).
    init(processes: Processes, queue: DispatchQueue, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.processes = processes
        bundle = switch processes {
        case let .app(pid), let .allBut(pid): Self.bundlePath(of: pid)
        }
        self.queue = queue
        self.onBuffer = onBuffer
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
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.processesChanged() }
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
        try Recorder(exclusive: exclusive, objects: objects, queue: queue) { [weak self] buffer in
            guard let self else { return }
            lastBufferTime = .now()
            duration += Double(buffer.frameLength) / buffer.format.sampleRate
            onBuffer(buffer)
        }
    }

    /// Fills the time since the tap last gave sound with silence, once it has stopped.
    private func addSilence() {
        let now = DispatchTime.now()
        let gap = Double(now.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1e9 - duration
        guard Double(now.uptimeNanoseconds - lastBufferTime.uptimeNanoseconds) / 1e9 > 0.25, gap > 0.05,
              let format = recorder?.format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(gap * format.sampleRate)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(format.channelCount) {
            channels[channel].update(repeating: 0, count: Int(buffer.frameLength))
        }
        duration += Double(buffer.frameLength) / format.sampleRate
        onBuffer(buffer)
    }

    /// The processes to tap: the app's (until it has played sound, none, by leaving them all out), or
    /// every one but the app's.
    private func target() -> (exclusive: Bool, objects: [AudioObjectID], summary: String) {
        let all = Self.audioProcesses()
        let app = switch processes {
        case let .app(pid), let .allBut(pid): pid
        }
        let matching = all.filter { Self.belongs($0.pid, to: app, bundle: bundle) }
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

    /// Core Audio's objects for the processes that have played or recorded sound, with their process IDs.
    private static func audioProcesses() -> [(object: AudioObjectID, pid: pid_t)] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.compactMap { object in
            var pid: pid_t = -1
            return get(object, kAudioProcessPropertyPID, &pid) == noErr ? (object, pid) : nil
        }
    }

    /// Whether the process is the app's, or one of its helpers: one macOS holds the app responsible for
    /// (as WebKit's processes), a child of it (as with Wine), or one from inside its .app bundle (as a
    /// browser's helpers, or Parallels' VM).
    private static func belongs(_ pid: pid_t, to app: pid_t, bundle: String?) -> Bool {
        if pid == app || responsiblePID(pid) == app { return true }
        var parent = parentPID(pid)
        for _ in 0..<64 where parent > 1 {
            if parent == app { return true }
            parent = parentPID(parent)
        }
        if let bundle, let path = executablePath(pid), path.hasPrefix(bundle + "/") { return true }
        return false
    }

    /// The outermost .app bundle the process's executable is in.
    private static func bundlePath(of pid: pid_t) -> String? {
        guard let path = executablePath(pid), let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
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
        guard status == noErr else { throw SentenceAudioError("Couldn’t \(action) (\(status))") }
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
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
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
