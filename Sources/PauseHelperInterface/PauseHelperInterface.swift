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
}
