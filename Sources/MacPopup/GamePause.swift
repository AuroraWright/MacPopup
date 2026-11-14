import AppKit
import PauseHelperInterface
import ServiceManagement
import Synchronization

/// Settings → Scanning → Pause the game while a popup is open: the game is frozen while a popup is open (or while the controller has
/// focus), so it can't move on meanwhile, and continues when it closes. MacPopup's pause helper (Sources/PauseHelper)
/// stops and continues it: it runs as root, for Windows games in Parallels, and continues the game if MacPopup quits or
/// crashes. It's approved once in System Settings (Settings → Permissions → Pause Helper). Its pause and scan shortcut
/// pauses the game until it's pressed again or you switch to another app, to look up whatever's on screen (see
/// togglePausedScan in web/src/overlay.js).
@MainActor
final class GamePause {
    static let shared = GamePause()

    private var connection: NSXPCConnection?
    /// Whether the overlay asked for the game to be paused.
    private var requested = false
    /// How many asked for the game to go on meanwhile (Anki Audio, waiting for a voice to end).
    private var runRequests = 0
    /// Whether the game is (being) frozen.
    private var frozen = false
    /// The game's processes while it's frozen, with its app's (for a Windows game in Parallels, the app's process isn't
    /// one of the VM's that are frozen).
    private var frozenPIDs: [pid_t] = []
    /// The latest freeze, until the helper answers.
    private var freezing: Task<Void, Never>?
    /// Whether it was said that pausing needs the helper.
    private var toldAboutHelper = false

    private var settings: [String: Any] { SettingsStore.shared.dictionary }

    private let shortcut = HotkeyController(signature: 0x4D50_5053) // "MPPS"
    /// The shortcut last found taken (see applyShortcut).
    private var reportedShortcut: KeyCombination?

    private init() {
        shortcut.onPress = { [weak self] _ in self?.onShortcut?() }
        SettingsStore.shared.observe { [weak self] _ in
            self?.connectEarly()
            self?.applyShortcut()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { GamePause.shared.appActivated(pid) }
        }
        connectEarly()
    }

    /// Settings → Scanning → Pause and scan shortcut, registered while pausing is on.
    private func applyShortcut() {
        let combination = settings["gamePause"] as? Bool == true ? KeyCombination(setting: settings["gamePauseShortcut"]) : nil
        let registered = shortcut.set(combination.map { [$0] } ?? [])
        // Told once for each shortcut (this runs at every settings change).
        let failed = registered.first == false ? combination : nil
        if let failed, failed != reportedShortcut {
            onToast?("The pause and scan shortcut \(failed.displayName) is used by another app or shortcut")
        }
        reportedShortcut = failed
    }

    /// With pausing on, the helper is connected to (and so started by launchd) beforehand: the first freeze would
    /// otherwise wait for it to start.
    private func connectEarly() {
        guard settings["gamePause"] as? Bool == true, connection == nil, Self.service.status == .enabled else { return }
        helper()?.resume {}
    }

    nonisolated static var service: SMAppService { SMAppService.daemon(plistName: PauseHelper.plistName) }
    /// Shows a message on the overlay.
    var onToast: ((String) -> Void)?
    /// The game goes on after it was frozen (e.g. to watch its window for the rest of a line it was drawing).
    var onResume: (() -> Void)?
    /// The pause and scan shortcut was pressed. It's registered once this is set (after onToast, which says if it can't
    /// be).
    var onShortcut: (() -> Void)? {
        didSet { applyShortcut() }
    }
    /// You switched to another app (not the game, nor MacPopup) while the game was frozen: as the controller is let go
    /// then (see GamepadController.onSwitchAway), the pause and scan shortcut's pause ends.
    var onSwitchAway: (() -> Void)?

    private func appActivated(_ pid: pid_t?) {
        guard frozen, let pid, pid != ProcessInfo.processInfo.processIdentifier, !frozenPIDs.contains(pid) else { return }
        OCRDebugLog.note("switched to \(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "another app") while the game was paused")
        onSwitchAway?()
    }

    /// Asked by the overlay, as popups open and close. Returns once the game is frozen, so that what's read of its
    /// window then stays.
    func setPaused(_ paused: Bool) async {
        requested = paused
        apply()
        if paused { await freezing?.value }
    }

    /// While `run` is on, the game goes on even with a popup open (for Anki Audio, which waits for the voice to end).
    func letRun(_ run: Bool) {
        runRequests += run ? 1 : -1
        apply()
    }

    private func apply() {
        let freeze = requested && runRequests <= 0 && settings["gamePause"] as? Bool == true
        guard freeze != frozen else { return }
        if freeze {
            guard Self.service.status == .enabled else {
                OCRDebugLog.note("game not paused: the pause helper isn't allowed")
                if !toldAboutHelper {
                    toldAboutHelper = true
                    onToast?("Pausing the game needs MacPopup’s helper: allow it in Settings → Permissions")
                }
                return
            }
            guard let (app, pids) = Self.gameProcesses(), !pids.isEmpty else {
                OCRDebugLog.note("game not paused: no game found")
                return
            }
            OCRDebugLog.note("game paused: \(NSRunningApplication(processIdentifier: app)?.localizedName ?? "pid \(app)"), \(pids.count) process\(pids.count == 1 ? "" : "es")")
            frozen = true
            frozenPIDs = pids + [app]
            GameClock.freeze()
            freezing = Task { await stop(pids) }
        } else {
            frozen = false
            GameClock.thaw()
            helper()?.resume {}
            onResume?()
        }
    }

    /// Has the helper stop the game, and returns once it did (or didn't answer).
    private func stop(_ pids: [pid_t]) async {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            guard let helper = helper(onError: once.resume) else { return once.resume() }
            helper.freeze(pids.map { NSNumber(value: $0) }) { stopped in
                if stopped.count < pids.count {
                    NSLog("MacPopup: the pause helper stopped \(stopped.count) of \(pids.count) processes")
                    Task { @MainActor in OCRDebugLog.note("the pause helper stopped \(stopped.count) of \(pids.count) processes") }
                }
                once.resume()
            }
        }
    }

    /// The connection to the helper, kept while MacPopup runs: when it's gone (MacPopup quit or crashed), the helper
    /// continues the game.
    /// - Parameter onError: Called when the helper doesn't answer (instead of the reply).
    private func helper(onError: (@Sendable () -> Void)? = nil) -> PauseHelperProtocol? {
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: PauseHelper.label, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: PauseHelperProtocol.self)
            connection.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.connectionLost() }
            }
            connection.interruptionHandler = { [weak self] in
                Task { @MainActor in self?.connectionLost() }
            }
            connection.resume()
            self.connection = connection
        }
        return connection?.remoteObjectProxyWithErrorHandler { error in
            NSLog("MacPopup: the pause helper didn't answer: \(error.localizedDescription)")
            Task { @MainActor in OCRDebugLog.note("the pause helper didn't answer: \(error.localizedDescription)") }
            onError?()
        } as? PauseHelperProtocol
    }

    /// The helper went away, continuing what it stopped.
    private func connectionLost() {
        connection?.invalidate()
        connection = nil
        if frozen {
            frozen = false
            GameClock.thaw()
            onResume?()
        }
    }

    /// For test scripts: has the helper stop `pids` (replying with the ones it stopped), or continue what it stopped.
    func debugHelper(freeze pids: [pid_t]?) async -> [Int] {
        guard let helper = helper() else { return [] }
        guard let pids else {
            await withCheckedContinuation { continuation in helper.resume { continuation.resume() } }
            return []
        }
        return await withCheckedContinuation { continuation in
            helper.freeze(pids.map { NSNumber(value: $0) }) { continuation.resume(returning: $0.map(\.intValue)) }
        }
    }

    // MARK: The game

    /// The game's processes: the captured window's app (or else the app in front) and its helpers, or for a Windows app
    /// in Parallels' Coherence mode, Parallels' VM (the whole VM pauses).
    /// The game's app, and the processes to stop.
    private static func gameProcesses() -> (app: pid_t, pids: [pid_t])? {
        let own = ProcessInfo.processInfo.processIdentifier
        guard let app = capturedWindowPID() ?? NSWorkspace.shared.frontmostApplication?.processIdentifier, app != own else { return nil }
        let all = allPIDs()
        let bundleID = NSRunningApplication(processIdentifier: app)?.bundleIdentifier ?? ""
        if bundleID.hasPrefix("com.parallels.winapp.") {
            return (app, all.filter { AudioTap.executablePath($0)?.hasSuffix("/Parallels VM.app/Contents/MacOS/prl_vm_app") == true })
        }
        let bundle = AudioTap.bundlePath(of: app)
        return (app, all.filter { $0 != own && AudioTap.belongs($0, to: app, bundle: bundle) })
    }

    private static func capturedWindowPID() -> pid_t? {
        guard let saved = SettingsStore.shared.dictionary["ocrWindow"] as? [String: Any], let owner = saved["ownerName"] as? String
        else { return nil }
        let title = saved["title"] as? String ?? ""
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = list.compactMap(OCRController.windowInfo).filter { $0.ownerName == owner && $0.layer == 0 }
        return (windows.first { $0.title == title } ?? windows.first)?.ownerPID
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(0, found)))).filter { $0 > 1 }
    }
}

/// Resumes a continuation once, from whichever of the helper's reply and its error handler comes first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.withLock {
            continuation?.resume()
            continuation = nil
        }
    }
}

/// The system uptime without the time the game was frozen (see GamePause): Anki Audio's clock, so that the game's audio
/// and its lines are timed as the game ran, and a freeze isn't kept as silence in the middle of a line's voice.
enum GameClock {
    private struct State {
        var frozenFor = 0.0
        var frozenSince: Double?
    }

    private static let state = Mutex(State())

    static var now: Double {
        state.withLock { state in
            let uptime = ProcessInfo.processInfo.systemUptime
            return uptime - state.frozenFor - (state.frozenSince.map { uptime - $0 } ?? 0)
        }
    }

    static var isFrozen: Bool { state.withLock { $0.frozenSince != nil } }

    static func freeze() {
        state.withLock { $0.frozenSince = $0.frozenSince ?? ProcessInfo.processInfo.systemUptime }
    }

    static func thaw() {
        state.withLock { state in
            guard let since = state.frozenSince else { return }
            state.frozenFor += ProcessInfo.processInfo.systemUptime - since
            state.frozenSince = nil
        }
    }
}
