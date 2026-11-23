// pause-client <pid>...: asks MacPopup's pause helper to stop the processes, as another program would (signed ad-hoc,
// as swiftc signs it). Prints "connection invalidated (refused)", "stopped: [pids]", an error (domain, code: NSXPCConnectionCodeSigningRequirementFailure
// is 4102) or "no answer".
import Foundation
@objc protocol PauseHelperProtocol {
    func freeze(_ pids: [NSNumber], reply: @escaping ([NSNumber]) -> Void)
    func resume(reply: @escaping () -> Void)
}
let connection = NSXPCConnection(machServiceName: "com.aury.macpopup.pause-helper", options: .privileged)
connection.remoteObjectInterface = NSXPCInterface(with: PauseHelperProtocol.self)
connection.invalidationHandler = { print("connection invalidated (refused)"); exit(0) }
connection.resume()
let proxy = connection.remoteObjectProxyWithErrorHandler { error in
    let error = error as NSError
    print("error: \(error.domain) \(error.code): \(error.localizedDescription)"); exit(0)
} as! PauseHelperProtocol
proxy.freeze(CommandLine.arguments.dropFirst().compactMap { Int32($0) }.map { NSNumber(value: $0) }) { stopped in
    print("stopped: \(stopped)")
    exit(0)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 5) { print("no answer"); exit(0) }
dispatchMain()
