import Foundation

/// What MacPopup asks of its pause helper (Sources/PauseHelper), over XPC: freezing the game while a popup is open
/// (Settings → Scanning → Pause the game).
@objc public protocol PauseHelperProtocol {
    /// Stops the processes (SIGSTOP), and replies with the ones it stopped: processes of the caller's user, or Parallels'
    /// VM (which runs as root).
    func freeze(_ pids: [NSNumber], reply: @escaping ([NSNumber]) -> Void)
    /// Continues (SIGCONT) the processes this connection stopped.
    func resume(reply: @escaping () -> Void)
}

public enum PauseHelper {
    /// Its launchd label and XPC service name.
    public static let label = "com.aury.macpopup.pause-helper"
    /// Its launchd property list, in MacPopup.app/Contents/Library/LaunchDaemons (see scripts/build.sh).
    public static let plistName = "\(label).plist"

    /// Whether the process runs Parallels' VM, which plays a Windows app's sound and is stopped to pause it.
    public static func isParallelsVM(_ pid: pid_t) -> Bool {
        executablePath(pid)?.hasSuffix("/Parallels VM.app/Contents/MacOS/prl_vm_app") == true
    }

    /// Whether the app is a Windows app's helper in Parallels' Coherence mode, which plays no sound of its own.
    public static func isParallelsWinApp(bundleID: String?) -> Bool {
        bundleID?.hasPrefix("com.parallels.winapp.") == true
    }

    public static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
