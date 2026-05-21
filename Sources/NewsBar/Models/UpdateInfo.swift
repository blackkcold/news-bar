import Foundation

// MARK: - GitHub API Response Models

struct GitHubRelease: Decodable {
    let tag_name: String
    let name: String?
    let body: String?
    let assets: [GitHubAsset]

    /// Version string with optional "v" prefix stripped.
    var version: String {
        var v = tag_name
        if v.hasPrefix("v") || v.hasPrefix("V") {
            v.removeFirst()
        }
        return v
    }
}

struct GitHubAsset: Decodable {
    let name: String
    let browser_download_url: String
    let size: Int64
    let content_type: String?

    var isDMG: Bool {
        name.hasSuffix(".dmg") || content_type == "application/x-apple-diskimage"
    }
}

// MARK: - Update State

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate(String)
    case updateAvailable(String)
    case downloading(Double)
    case downloadComplete(URL)
    case error(String)
}

// MARK: - App Version

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

        // 3. Hardcoded fallback for development builds
        return "1.1.0"
    }()
}

// MARK: - Semantic Version Comparison

/// Returns `true` if `a` is semantically newer than `b`.
/// Supports `major.minor.patch` format; extra segments are ignored.
/// Non-numeric segments are treated as 0.
func versionIsNewer(_ a: String, than b: String) -> Bool {
    let aParts = a.split(separator: ".").prefix(3).compactMap { Int($0) }
    let bParts = b.split(separator: ".").prefix(3).compactMap { Int($0) }

    for i in 0..<max(aParts.count, bParts.count) {
        let av = i < aParts.count ? aParts[i] : 0
        let bv = i < bParts.count ? bParts[i] : 0
        if av > bv { return true }
        if av < bv { return false }
    }
    return false
}
