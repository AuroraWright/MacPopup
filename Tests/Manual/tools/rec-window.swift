// rec-window <pid> <seconds> <out.mov>: records only the process's largest on-screen window (ScreenCaptureKit, a
// desktop-independent window filter: nothing of other windows, covered or not) at 60 fps, without the pointer.
import AppKit
import ScreenCaptureKit

let args = CommandLine.arguments
let pid = pid_t(args[1])!, seconds = Double(args[2])!, out = URL(fileURLWithPath: args[3])

// ScreenCaptureKit needs a connection to the window server.
_ = NSApplication.shared

final class Delegate: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) { print("recording") }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) { print("failed: \(error)"); exit(1) }
    func stream(_ stream: SCStream, didStopWithError error: Error) { print("stopped: \(error)"); exit(1) }
}

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.filter({ $0.owningApplication?.processID == pid })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            print("no window"); exit(1)
        }
        print("window \(window.windowID) \(window.frame)")
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false
        let delegate = Delegate()
        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = out
        recording.outputFileType = .mov
        recording.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: recording, delegate: delegate)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()
        try await Task.sleep(for: .seconds(seconds))
        try await stream.stopCapture()
        try await Task.sleep(for: .milliseconds(500))
        withExtendedLifetime(delegate) { print("saved") }
        exit(0)
    } catch {
        print("error: \(error)"); exit(1)
    }
}
RunLoop.main.run()
