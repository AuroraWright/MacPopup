import AppKit
import AVFoundation

/// The macOS privacy permissions MacPopup uses, shown in Settings → Permissions.
enum Permission {
    case screenRecording
    case microphone
    case accessibility

    enum Status {
        case granted
        /// Never asked: asking shows macOS's prompt.
        case notDetermined
        /// Turned off, or asked before (macOS doesn't tell which for some permissions): it's then turned
        /// on in System Settings.
        case notGranted
    }

    var status: Status {
        switch self {
        case .screenRecording:
            CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .granted
            case .notDetermined: .notDetermined
            default: .notGranted
            }
        case .accessibility:
            AXIsProcessTrusted() ? .granted : .notGranted
        }
    }

    /// Shows macOS's prompt, when it still shows one.
    func request() async {
        switch self {
        case .screenRecording:
            CGRequestScreenCaptureAccess()
        case .microphone:
            await AVCaptureDevice.requestAccess(for: .audio)
        case .accessibility:
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
    }

    /// The permission's page in System Settings → Privacy & Security.
    func openSystemSettings() {
        let anchor = switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
