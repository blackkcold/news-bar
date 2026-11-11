import Foundation

/// The version this build reports.
///
/// `build.sh` copies `version.txt` into the bundle and writes the same value
/// into `Info.plist`, so the three sources agree in a packaged app. The
/// fallbacks exist for `swift run` and for unusual development launches.
enum AppVersion {
    /// Current app version, resolved from multiple sources.
    static let current: String = {
        // 1. Bundle resource (version.txt copied by build.sh)
        if let url = Bundle.main.url(forResource: "version", withExtension: "txt"),
           let v = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        // 2. Info.plist (set by build.sh for release builds)
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !v.isEmpty,
           v != "$(CURRENT_PROJECT_VERSION)" {
            return v
        }

        // 3. Development runs from the package root can read the checked-in version file.
        let devVersionURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("version.txt")
        if let v = try? String(contentsOf: devVersionURL, encoding: .utf8) {
            let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        // 4. Hardcoded fallback for unusual development launches.
        return "1.4.2"
    }()
}
