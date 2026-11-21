import Foundation

/// The environment variables for test runs and debugging (MACPOPUP_TEST_SCRIPT, MACPOPUP_DEBUG_OCR_DIR, …): read only
/// in development builds, debug builds and those scripts/build.sh makes with MACPOPUP_DEVELOPMENT (test copies), and
/// where `enabled` is set (the command-line tools). The app as shipped ignores them.
public enum DevelopmentEnvironment {
    #if DEBUG || MACPOPUP_DEVELOPMENT
    nonisolated(unsafe) public static var enabled = true
    #else
    nonisolated(unsafe) public static var enabled = false
    #endif

    public static subscript(name: String) -> String? {
        enabled ? ProcessInfo.processInfo.environment[name] : nil
    }

    /// All of them (empty when they're ignored).
    public static var all: [String: String] {
        enabled ? ProcessInfo.processInfo.environment : [:]
    }
}
