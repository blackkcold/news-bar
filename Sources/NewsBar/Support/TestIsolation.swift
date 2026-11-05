import Foundation

/// Keeps the XCTest process away from the user's real credentials, caches,
/// preferences and machine identity. Production behavior is unchanged.
enum TestIsolation {
    static let isActive: Bool = {
        if NSClassFromString("XCTestCase") != nil { return true }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        return ProcessInfo.processInfo.processName.contains("Tests")
    }()

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
