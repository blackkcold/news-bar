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
    let digest: String?

    var isDMG: Bool {
        name.hasSuffix(".dmg") || content_type == "application/x-apple-diskimage"
    }

    var sha256Digest: String? {
        guard let digest else { return nil }

        let trimmed = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "sha256:"
        let hex: String
        if trimmed.lowercased().hasPrefix(prefix) {
            hex = String(trimmed.dropFirst(prefix.count))
        } else {
            hex = trimmed
        }

        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex.lowercased()
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

        // 3. Development runs from the package root can read the checked-in version file.
        let devVersionURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("version.txt")
        if let v = try? String(contentsOf: devVersionURL, encoding: .utf8) {
            let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        // 4. Hardcoded fallback for unusual development launches.
        return "1.4.0"
    }()
}

// MARK: - Semantic Version Comparison

/// Returns `true` if `a` is semantically newer than `b`.
/// Supports `major.minor.patch` format; extra segments are ignored.
/// Non-numeric segments are treated as 0.
func versionIsNewer(_ a: String, than b: String) -> Bool {
    let aParts = semanticVersionCore(a)
    let bParts = semanticVersionCore(b)

    for i in 0..<3 {
        let av = aParts[i]
        let bv = bParts[i]
        if av > bv { return true }
        if av < bv { return false }
    }
    return false
}

private func semanticVersionCore(_ version: String) -> [Int] {
    var normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.hasPrefix("v") || normalized.hasPrefix("V") {
        normalized.removeFirst()
    }

    let withoutPrerelease = normalized
        .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        .first ?? ""
    let core = withoutPrerelease
        .split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        .first ?? ""
    var parts = core.split(separator: ".").prefix(3).map { Int($0) ?? 0 }
    while parts.count < 3 {
        parts.append(0)
    }
    return parts
}
