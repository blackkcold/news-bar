import Foundation

/// Keeps the XCTest process away from the user's real credentials, caches,
/// preferences and machine identity. Production behavior is unchanged.
enum TestIsolation {
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var forcedActive = false

    /// The agent executable calls this before any store or preference is
    /// touched. It must not depend on an environment variable being read at
    /// the right time.
    static func activate() {
        stateLock.lock()
        forcedActive = true
        stateLock.unlock()
    }

    static var isActive: Bool {
        stateLock.lock()
        let forced = forcedActive
        stateLock.unlock()
        if forced { return true }
        // Agent CLI runs are isolated on request: they render or read without
        // touching the running app's preferences and caches.
        if ProcessInfo.processInfo.environment["NEWSBAR_AGENT_ISOLATED"] == "1" { return true }
        if NSClassFromString("XCTestCase") != nil { return true }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        return ProcessInfo.processInfo.processName.contains("Tests")
    }

    static let root: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NewsBarTestIsolation-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func directory(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var defaults: UserDefaults {
        guard isActive else { return .standard }
        return UserDefaults(
            suiteName: "NewsBarTestDefaults-\(ProcessInfo.processInfo.processIdentifier)"
        ) ?? .standard
    }

    static var machineIdentifier: (@Sendable () throws -> String)? {
        isActive ? { "fictional-test-machine" } : nil
    }
}
