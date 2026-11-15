import Darwin
import Foundation
import PauseHelperInterface
import Security

// MacPopup's pause helper: a launchd daemon (registered with SMAppService, approved once in System Settings) that
// freezes the game while a popup is open, and continues it when MacPopup asks, quits or crashes. It runs as root for
// Windows games in Parallels, whose VM runs as root; anything else it stops belongs to the user who runs MacPopup, which
// MacPopup could stop itself.
//
// It only answers MacPopup (its identifier, signed by the same team as the helper), and only stops processes of that
// user or Parallels' VM. The processes it stopped are kept in a file, so that if the helper itself crashes, launchd
// starts it again and it continues them.

/// The processes stopped, kept for a helper started again after a crash. (/var/run is emptied when the Mac starts.)
let stateFile = URL(fileURLWithPath: "/private/var/run/\(PauseHelper.label).json")

func owner(_ pid: pid_t) -> uid_t? {
    var info = proc_bsdinfo()
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
    return info.pbi_uid
}

/// Whether `user` may have the process stopped: it's theirs (never root's, launchd's or the helper's), or Parallels' VM.
/// Only root can start a root process from Parallels' VM's path, so the path is enough to tell it.
func mayStop(_ pid: pid_t, for user: uid_t) -> Bool {
    guard pid > 1, pid != getpid(), let processOwner = owner(pid) else { return false }
    if user != 0, processOwner == user { return true }
    return processOwner == 0 && PauseHelper.isParallelsVM(pid)
}

/// The team that signed the helper, which MacPopup must be signed by too (nil when it's signed ad-hoc).
func ownTeam() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
    else { return nil }
    return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
}

final class Helper: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: PauseHelper.label)
    // On the queue:
    /// The processes each connection stopped.
    private var stopped: [ObjectIdentifier: Set<pid_t>] = [:]
    /// The connections open now (each may be both interrupted and invalidated, so it's counted once).
    private var connections = Set<ObjectIdentifier>()
    private let requirement: String?

    override init() {
        requirement = ownTeam().map { "identifier \"com.aury.macpopup\" and anchor apple generic and certificate leaf[subject.OU] = \"\($0)\"" }
        super.init()
        // Processes left stopped by a helper that crashed.
        if let data = try? Data(contentsOf: stateFile), let pids = try? JSONDecoder().decode([pid_t].self, from: data) {
            for pid in pids { kill(pid, SIGCONT) }
        }
        try? FileManager.default.removeItem(at: stateFile)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement else { return false }
        connection.setCodeSigningRequirement(requirement)
        let id = ObjectIdentifier(connection), user = connection.effectiveUserIdentifier
        connection.exportedInterface = NSXPCInterface(with: PauseHelperProtocol.self)
        connection.exportedObject = Session(helper: self, id: id, user: user)
        connection.invalidationHandler = { [weak self] in self?.disconnected(id) }
        connection.interruptionHandler = { [weak self] in self?.disconnected(id) }
        queue.sync { _ = connections.insert(id) }
        connection.resume()
        return true
    }

    var isIdle: Bool { queue.sync { connections.isEmpty } }

    func freeze(_ pids: [pid_t], id: ObjectIdentifier, user: uid_t) -> [pid_t] {
        queue.sync {
            let allowed = pids.filter { mayStop($0, for: user) && kill($0, SIGSTOP) == 0 }
            stopped[id, default: []].formUnion(allowed)
            save()
            return allowed
        }
    }

    func resume(id: ObjectIdentifier) {
        queue.sync {
            for pid in stopped.removeValue(forKey: id) ?? [] { kill(pid, SIGCONT) }
            save()
        }
    }

    /// MacPopup quit or crashed: what it stopped continues, and the helper quits once no MacPopup is connected (launchd
    /// starts it again for the next one).
    private func disconnected(_ id: ObjectIdentifier) {
        resume(id: id)
        let last = queue.sync {
            connections.remove(id)
            return connections.isEmpty
        }
        if last { exit(0) }
    }

    private func save() {
        let pids = stopped.values.flatMap { $0 }
        if pids.isEmpty {
            try? FileManager.default.removeItem(at: stateFile)
        } else if let data = try? JSONEncoder().encode(pids) {
            try? data.write(to: stateFile, options: .atomic)
        }
    }
}

/// One MacPopup's connection.
final class Session: NSObject, PauseHelperProtocol {
    private weak var helper: Helper?
    private let id: ObjectIdentifier
    private let user: uid_t

    init(helper: Helper, id: ObjectIdentifier, user: uid_t) {
        self.helper = helper
        self.id = id
        self.user = user
    }

    func freeze(_ pids: [NSNumber], reply: @escaping ([NSNumber]) -> Void) {
        reply(helper?.freeze(pids.map(\.int32Value), id: id, user: user).map { NSNumber(value: $0) } ?? [])
    }

    func resume(reply: @escaping () -> Void) {
        helper?.resume(id: id)
        reply()
    }
}

let helper = Helper()
let listener = NSXPCListener(machServiceName: PauseHelper.label)
listener.delegate = helper
listener.resume()
// With no MacPopup connecting (started again after a crash), it quits after a while.
DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
    if helper.isIdle { exit(0) }
}
dispatchMain()
