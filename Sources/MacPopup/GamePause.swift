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
        shortcut.set(combination) { [weak self] taken in
            self?.onToast?("The pause and scan shortcut \(taken.displayName) is used by another app or shortcut")
        }
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
        DebugLog.note("switched to \(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "another app") while the game was paused")
        onSwitchAway?()
    }

    /// Asked by the overlay, as popups open and close. Returns once the game is frozen, so that what's read of its
    /// window then stays.
    func setPaused(_ paused: Bool) async {
        requested = paused
        apply()
        if paused { await freezing?.value }
    }

    private func apply() {
        let freeze = requested && settings["gamePause"] as? Bool == true
        guard freeze != frozen else { return }
        if freeze {
            guard Self.service.status == .enabled else {
                DebugLog.note("game not paused: the pause helper isn't allowed")
                if !toldAboutHelper {
                    toldAboutHelper = true
                    onToast?("Pausing the game needs MacPopup’s helper: allow it in Settings → Permissions")
                }
                return
            }
            guard let (app, pids) = Self.gameProcesses(), !pids.isEmpty else {
                DebugLog.note("game not paused: no game found")
                return
            }
            DebugLog.note("game paused: \(NSRunningApplication(processIdentifier: app)?.localizedName ?? "pid \(app)"), \(pids.count) process\(pids.count == 1 ? "" : "es")")
            frozen = true
            frozenPIDs = pids + [app]
            GameClock.freeze()
            freezing = stop(pids)
        } else {
            frozen = false
            GameClock.thaw()
            helper()?.resume {}
            onResume?()
        }
    }

    /// Has the helper stop the game. The request is sent right away, so that a resume asked for after it (a popup
    /// closed at once) reaches the helper after it too; the task ends once the helper did it (or didn't answer).
    private func stop(_ pids: [pid_t]) -> Task<Void, Never> {
        let (replied, reply) = AsyncStream<Void>.makeStream()
        if let helper = helper(onError: { reply.finish() }) {
            helper.freeze(pids.map { NSNumber(value: $0) }) { stopped in
                if stopped.count < pids.count {
                    NSLog("MacPopup: the pause helper stopped \(stopped.count) of \(pids.count) processes")
                    Task { @MainActor in DebugLog.note("the pause helper stopped \(stopped.count) of \(pids.count) processes") }
                }
                reply.finish()
            }
        } else {
            reply.finish()
        }
        return Task { for await _ in replied {} }
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
            Task { @MainActor in DebugLog.note("the pause helper didn't answer: \(error.localizedDescription)") }
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

    // MARK: The game

    /// The game's app and the processes to stop: the captured window's app (or else the app in front) and its helpers,
    /// or for a Windows app in Parallels' Coherence mode, Parallels' VM (the whole VM pauses).
    private static func gameProcesses() -> (app: pid_t, pids: [pid_t])? {
        let own = ProcessInfo.processInfo.processIdentifier
        guard let app = OCRController.savedWindow()?.ownerPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier, app != own
        else { return nil }
        let all = allPIDs()
        let bundleID = NSRunningApplication(processIdentifier: app)?.bundleIdentifier ?? ""
        if PauseHelper.isParallelsWinApp(bundleID: bundleID) {
            return (app, all.filter(PauseHelper.isParallelsVM))
        }
        let bundle = AudioTap.bundlePath(of: app)
        return (app, all.filter { $0 != own && AudioTap.belongs($0, to: app, bundle: bundle) })
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(0, found)))).filter { $0 > 1 }
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
