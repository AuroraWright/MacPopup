import Combine
import Foundation

/// Whether the Yomitan API answers, shown on the menu bar icon and in its menu. Each request is on its
/// own, so this checks every 30 seconds, when the menu opens and when its URL changes, and again when
/// the web side's requests stop or start working (see `reportRequest`).
@MainActor
final class YomitanAPIStatus: ObservableObject {
    static let shared = YomitanAPIStatus()

    enum State: Equatable {
        case unknown
        case reachable(version: String)
        case unreachable
    }

    @Published private(set) var state = State.unknown {
        didSet { if state != oldValue { onChange?() } }
    }
    /// Whether it gives the Yomitan profile's display options and dictionaries (AnkiConnect.yomitanGivesProfile), which
    /// Settings shows instead of MacPopup's.
    @Published private(set) var givesProfile = false
    /// The URL and version that givesProfile was asked of.
    private var profileAskedFor: String?

    var onChange: (() -> Void)?
    private var timer: Timer?
    private var checking = false
    /// Asked for while a check was running, e.g. after the URL changed.
    private var checkAgain = false
    private var url: String?

    private init() {
        url = SettingsStore.shared.string("yomitanApiUrl")
        SettingsStore.shared.observe { [weak self] _ in
            Task { @MainActor in self?.settingsChanged() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        check()
    }

    func check() {
        guard !checking else {
            checkAgain = true
            return
        }
        checking = true
        Task {
            let settings = SettingsStore.shared.dictionary
            let version = try? await AnkiConnect.yomitanVersion(settings: settings)
            // Asked again only when it's back, at another URL or another version, so an older Yomitan isn't asked
            // every time.
            let profileKey = version.map { "\(settings["yomitanApiUrl"] ?? "") \($0)" }
            if profileKey != profileAskedFor {
                // Only a definite answer is kept: after a failed request it's asked again at the next check.
                let givesProfile = profileKey != nil ? await AnkiConnect.yomitanGivesProfile(settings: settings) : false
                if let givesProfile {
                    profileAskedFor = profileKey
                    if givesProfile != self.givesProfile { self.givesProfile = givesProfile }
                }
            }
            state = version.map { .reachable(version: $0) } ?? .unreachable
            checking = false
            if checkAgain {
                checkAgain = false
                check()
            }
        }
    }

    /// A request of the web side worked or failed. When that's not what the last check found, this checks
    /// again: a failed request can also be one the API turned down.
    func reportRequest(succeeded: Bool) {
        switch state {
        case .reachable where succeeded, .unreachable where !succeeded:
            return
        default:
            check()
        }
    }

    private func settingsChanged() {
        let newURL = SettingsStore.shared.string("yomitanApiUrl")
        guard newURL != url else { return }
        url = newURL
        check()
    }
}
