import AppKit
import ServiceManagement

/// The macOS privacy permissions MacPopup uses, shown in Settings → Permissions.
enum Permission {
    case screenRecording
    /// Recording other apps' audio, for Anki Audio and transcription. System Settings lists it with Screen Recording.
    case audioCapture
    case accessibility
    /// MacPopup's pause helper (see GamePause), approved in System Settings → General → Login Items.
    case pauseHelper

    enum Status {
        case granted
        /// Turned off, or never asked (macOS doesn't tell which): asking shows macOS's prompt when it
        /// still shows one, or else it's turned on in System Settings.
        case notGranted
    }

    var status: Status {
        switch self {
        case .screenRecording:
            CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        case .audioCapture:
            TCC.preflight?(TCC.audioCapture, nil) == 0 ? .granted : .notGranted
        case .accessibility:
            AXIsProcessTrusted() ? .granted : .notGranted
        case .pauseHelper:
            GamePause.service.status == .enabled ? .granted : .notGranted
        }
    }

    /// Shows macOS's prompt, when it still shows one.
    func request() async {
        switch self {
        case .screenRecording:
            CGRequestScreenCaptureAccess()
        case .audioCapture:
            guard let request = TCC.request else { return }
            await withCheckedContinuation { continuation in
                request(TCC.audioCapture, nil) { _ in continuation.resume() }
            }
        case .accessibility:
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        case .pauseHelper:
            // Registering it lists it in System Settings, where it's then allowed.
            do {
                try GamePause.service.register()
            } catch {
                NSLog("MacPopup: couldn't register the pause helper: \(error.localizedDescription)")
            }
            if GamePause.service.status != .enabled { SMAppService.openSystemSettingsLoginItems() }
        }
    }

    /// The permission's page in System Settings → Privacy & Security.
    func openSystemSettings() {
        let anchor = switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .audioCapture: "Privacy_AudioCapture"
        case .accessibility: "Privacy_Accessibility"
        case .pauseHelper: nil as String?
        }
        guard let anchor else {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// macOS has no public way to check or ask for permission to record other apps' audio, so this uses the
/// private TCC framework's (as Apple's apps do), when it's there.
private enum TCC {
    typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    static let audioCapture = "kTCCServiceAudioCapture" as CFString
    private static let framework = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    /// 0 when granted (1 when turned off, 2 when never asked).
    static let preflight = dlsym(framework, "TCCAccessPreflight").map { unsafeBitCast($0, to: Preflight.self) }
    /// Shows macOS's prompt when it was never asked, and calls back with whether it's granted.
    static let request = dlsym(framework, "TCCAccessRequest").map { unsafeBitCast($0, to: Request.self) }
}
