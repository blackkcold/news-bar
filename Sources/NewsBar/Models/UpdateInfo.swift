import Foundation

// MARK: - GitHub API Response Models

/// Provenance of a fetched release metadata payload.
///
/// - canonical: Metadata was fetched directly from the canonical GitHub API
///   (`https://api.github.com/...`). Only canonical provenance can authorize
///   an automatic DMG download, because the digest and artifact URL are
///   guaranteed to originate from GitHub.
/// - proxy: Metadata was fetched from a third-party proxy mirror. Proxy
///   metadata may be used to *surface* update availability to the user, but
///   must never authorize an automatic download — the proxy can tamper with
///   both the SHA-256 digest and the artifact download URL.
enum ReleaseProvenance: Equatable {
    case canonical
    case proxy(label: String)
}

struct GitHubRelease: Decodable {
    let tag_name: String
    let name: String?
    let body: String?
    let assets: [GitHubAsset]

    /// Provenance of this release metadata. Defaults to `.canonical` when
    /// decoded directly from the GitHub API (e.g. in tests). The
    /// `UpdateChecker` sets this to `.proxy` when the payload arrives via a
    /// third-party mirror.
    var provenance: ReleaseProvenance = .canonical

    /// Version string with optional "v" prefix stripped.
    var version: String {
        var v = tag_name
        if v.hasPrefix("v") || v.hasPrefix("V") {
            v.removeFirst()
        }
        return v
    }

    /// Convenience: `true` when metadata originated from canonical GitHub.
    var isCanonical: Bool {
        if case .canonical = provenance { return true }
        return false
    }

    init(
        tag_name: String,
        name: String?,
        body: String?,
        assets: [GitHubAsset],
        provenance: ReleaseProvenance = .canonical
    ) {
        self.tag_name = tag_name
        self.name = name
        self.body = body
        self.assets = assets
        self.provenance = provenance
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag_name = try c.decode(String.self, forKey: .tag_name)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        assets = try c.decode([GitHubAsset].self, forKey: .assets)
        provenance = .canonical
    }

    private enum CodingKeys: String, CodingKey {
        case tag_name, name, body, assets
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
        return "1.4.2"
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
