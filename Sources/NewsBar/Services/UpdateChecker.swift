import Foundation
import AppKit
import CryptoKit

final class UpdateChecker: ObservableObject {

    private static let repoOwner = "blackkcold"
    private static let repoName = "news-bar"

    private static let releaseAPIURL =
        "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"

    /// Official release page used when the unauthenticated API is rate-limited.
    /// GitHub redirects this to `/releases/tag/vX.Y.Z`, which lets the app
    /// recover the version without a third-party mirror.
    private static let releasesPageURL = URL(
        string: "https://github.com/\(repoOwner)/\(repoName)/releases/latest"
    )!

    /// GitHub-owned download hosts. Only these hosts are permitted for
    /// automatic DMG downloads. The artifact URL must come from canonical
    /// GitHub metadata and resolve to a GitHub-owned host.
    private static let githubOwnedHosts: Set<String> = [
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    private static let checkInterval: TimeInterval = 86400
    private static let updateCacheDir: URL = {
        if TestIsolation.isActive { return TestIsolation.directory("Updates") }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.newsbar"
        return caches.appendingPathComponent(bundleID).appendingPathComponent("Updates")
    }()

    @Published var state: UpdateState = .idle

    var devMode: Bool {
        TestIsolation.defaults.bool(forKey: "updateDevMode")
    }

    private var cachedRelease: GitHubRelease?

    private var lastCheckDate: Date? {
        get { TestIsolation.defaults.object(forKey: "lastUpdateCheckDate") as? Date }
        set { TestIsolation.defaults.set(newValue, forKey: "lastUpdateCheckDate") }
    }

    private var skippedVersion: String? {
        get { TestIsolation.defaults.string(forKey: "updateSkippedVersion") }
        set { TestIsolation.defaults.set(newValue, forKey: "updateSkippedVersion") }
    }

    private var downloadTask: Task<Void, Never>?
    private var downloadingVersion: String?
    private var downloadJob: UUID?

    // MARK: - Auto Update Check (called by AppDelegate on launch)

    func autoCheck() async {
        if let last = lastCheckDate, Date().timeIntervalSince(last) < Self.checkInterval {
            return
        }

        guard let release = await fetchLatestRelease() else {
            return
        }

        // Only a successful fetch advances the 24h timer; a transient API
        // failure should not suppress retries for a whole day.
        lastCheckDate = Date()
        cachedRelease = release

        guard versionIsNewer(release.version, than: AppVersion.current) else {
            return
        }

        guard release.version != skippedVersion else {
            return
        }

        await MainActor.run {
            state = .updateAvailable(release.version)
        }
    }

    // MARK: - Manual Update Check

    func manualCheck() async {
        await MainActor.run { state = .checking }

        guard let release = await fetchLatestRelease() else {
            await MainActor.run { state = .error("网络异常，请检查连接后重试") }
            return
        }

        cachedRelease = release

        guard devMode || versionIsNewer(release.version, than: AppVersion.current) else {
            await MainActor.run { state = .upToDate(AppVersion.current) }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if case .upToDate = state {
                await MainActor.run { state = .idle }
            }
            return
        }

        lastCheckDate = Date()
        await MainActor.run { state = .updateAvailable(release.version) }
    }

    // MARK: - Download

    func downloadUpdate() {
        guard case .updateAvailable(let version) = state, downloadTask == nil else { return }
        // Claim the state synchronously so a double click cannot start two
        // downloads that race for the same file and state.
        let job = UUID()
        downloadJob = job
        state = .downloading(0)
        downloadingVersion = version

        downloadTask = Task {
            defer {
                if downloadJob == job {
                    downloadTask = nil
                    downloadJob = nil
                    downloadingVersion = nil
                }
            }
            if Task.isCancelled {
                await restoreAvailableState(version: version)
                return
            }
            let release: GitHubRelease
            if let cached = cachedRelease {
                release = cached
            } else {
                guard let fetched = await fetchLatestRelease() else {
                    if downloadJob == job { await setError("update.error.fetchFailed") }
                    return
                }
                release = fetched
            }
            if Task.isCancelled {
                await restoreAvailableState(version: version)
                return
            }

            guard let dmgAsset = release.assets.first(where: { $0.isDMG }),
                  let dmgURL = URL(string: dmgAsset.browser_download_url),
                  dmgURL.scheme?.lowercased() == "https" else {
                await setError("update.error.noAsset")
                return
            }

            guard Self.canAuthorizeAutoDownload(
                provenance: release.provenance,
                downloadHost: dmgURL.host
            ) else {
                await setError(release.provenance.isGitHubOfficial
                    ? "update.error.untrustedHost"
                    : "update.error.mirror")
                return
            }

            try? FileManager.default.createDirectory(at: Self.updateCacheDir, withIntermediateDirectories: true)
            let destinationURL = Self.updateCacheDir.appendingPathComponent(
                URL(fileURLWithPath: dmgAsset.name).lastPathComponent
            )

            do {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 900
                let session = URLSession(configuration: configuration)
                let (tempURL, response) = try await session.download(
                    for: URLRequest(url: dmgURL),
                    delegate: UpdateDownloadRedirectGuard()
                )
                defer { try? FileManager.default.removeItem(at: tempURL) }
                if Task.isCancelled { return }

                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    await setError("update.error.downloadHTTP")
                    return
                }
                guard validateDownloadSize(tempURL: tempURL, expectedSize: dmgAsset.size) else {
                    await setError("update.error.size")
                    return
                }

                let expectedSHA256: String?
                if let digest = dmgAsset.sha256Digest {
                    expectedSHA256 = digest
                } else {
                    expectedSHA256 = await fetchSHA256Sidecar(version: release.version)
                }
                guard let expectedSHA256 else {
                    await setError("update.error.noDigest")
                    return
                }
                try Task.checkCancellation()
                guard validateSHA256(tempURL: tempURL, expected: expectedSHA256) else {
                    await setError("update.error.checksum")
                    return
                }

                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                cachedRelease = nil
                if downloadJob == job {
                    await MainActor.run { state = .downloadComplete(destinationURL) }
                }
            } catch is CancellationError {
                await restoreAvailableState(version: version)
            } catch {
                if Task.isCancelled {
                    await restoreAvailableState(version: version)
                } else if downloadJob == job {
                    await setError("update.error.downloadFailed")
                }
            }
        }
    }

    private func setError(_ key: String) async {
        let message = L10n.string(key)
        await MainActor.run { state = .error(message) }
    }

    private func restoreAvailableState(version: String) async {
        await MainActor.run {
            state = .updateAvailable(version)
        }
    }

    private func fetchSHA256Sidecar(version: String) async -> String? {
        guard let url = Self.releaseAssetURL(version: version, suffix: ".dmg.sha256") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let session = URLSession(configuration: .ephemeral)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return Self.parseSHA256File(text)
        } catch {
            return nil
        }
    }

    // MARK: - Dismiss

    func dismissUpdate() {
        if case .updateAvailable(let version) = state {
            skippedVersion = version
        }
        cachedRelease = nil
        state = .idle
    }

    func openDownloadedDMG() {
        guard case .downloadComplete(let url) = state else { return }
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        state = .idle
    }

    func cancelDownload() {
        // Let the task's own defer clear the job identity and restore state;
        // clearing it here would let a stale task overwrite a newer download.
        downloadTask?.cancel()
    }

    // MARK: - Network Helpers

    private func fetchLatestRelease() async -> GitHubRelease? {
        if let release = await fetchAPILatestRelease() {
            return release
        }
        if let release = await fetchGitHubHTMLFallback() {
            return release
        }
        NSLog("[UpdateChecker] all official sources exhausted")
        return nil
    }

    private func fetchAPILatestRelease() async -> GitHubRelease? {
        guard let url = URL(string: Self.releaseAPIURL) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("NewsBar/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let session = URLSession(configuration: .ephemeral)
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            guard (200...299).contains(httpResponse.statusCode) else {
                if httpResponse.statusCode == 403 {
                    NSLog("[UpdateChecker] GitHub API: HTTP 403 (rate limited)")
                } else {
                    NSLog("[UpdateChecker] GitHub API: HTTP \(httpResponse.statusCode)")
                }
                return nil
            }

            var release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            release.provenance = .canonical
            NSLog("[UpdateChecker] fetch succeeded via GitHub API, version=\(release.version)")
            return release
        } catch {
            logNetworkError(error, label: "GitHub API")
            return nil
        }
    }

    /// Official GitHub HTML fallback. No third-party mirror is involved:
    /// - the redirect must land on github.com/blackkcold/news-bar/releases/tag/vX.Y.Z
    /// - asset URLs are constructed under the same repository release path
    /// - the SHA-256 sidecar is fetched from that same release
    func fetchGitHubHTMLFallback() async -> GitHubRelease? {
        var pageRequest = URLRequest(url: Self.releasesPageURL)
        pageRequest.setValue("text/html", forHTTPHeaderField: "Accept")
        pageRequest.setValue("NewsBar/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        pageRequest.timeoutInterval = 15

        do {
            let session = URLSession(configuration: .ephemeral)
            let (_, response) = try await session.data(for: pageRequest)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let finalURL = httpResponse.url,
                  let version = Self.version(fromReleasePageURL: finalURL),
                  let dmgURL = Self.releaseAssetURL(version: version, suffix: ".dmg"),
                  let shaURL = Self.releaseAssetURL(version: version, suffix: ".dmg.sha256") else {
                NSLog("[UpdateChecker] GitHub HTML: release page did not resolve to a semantic tag")
                return nil
            }

            var shaRequest = URLRequest(url: shaURL)
            shaRequest.setValue("text/plain", forHTTPHeaderField: "Accept")
            shaRequest.setValue("NewsBar/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
            shaRequest.timeoutInterval = 15
            let (shaData, shaResponse) = try await session.data(for: shaRequest)
            guard let shaHTTP = shaResponse as? HTTPURLResponse,
                  (200...299).contains(shaHTTP.statusCode),
                  let text = String(data: shaData, encoding: .utf8),
                  let digest = Self.parseSHA256File(text) else {
                NSLog("[UpdateChecker] GitHub HTML: SHA-256 sidecar unavailable")
                return nil
            }

            let asset = GitHubAsset(
                name: "NewsBar-\(version).dmg",
                browser_download_url: dmgURL.absoluteString,
                size: 0,
                content_type: "application/x-apple-diskimage",
                digest: "sha256:\(digest)"
            )
            let release = GitHubRelease(
                tag_name: "v\(version)",
                name: nil,
                body: nil,
                assets: [asset],
                provenance: .githubHTML
            )
            NSLog("[UpdateChecker] fetch succeeded via GitHub HTML, version=\(version)")
            return release
        } catch {
            logNetworkError(error, label: "GitHub HTML")
            return nil
        }
    }

    private func logNetworkError(_ error: Error, label: String) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                NSLog("[UpdateChecker] \(label): timeout")
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                NSLog("[UpdateChecker] \(label): DNS/Host failed")
            case NSURLErrorNotConnectedToInternet:
                NSLog("[UpdateChecker] \(label): no internet")
            default:
                NSLog("[UpdateChecker] \(label): URLError code=\(nsError.code)")
            }
        } else {
            NSLog("[UpdateChecker] \(label): \(error.localizedDescription)")
        }
    }

    // MARK: - Validation

    private func validateDownloadSize(tempURL: URL, expectedSize: Int64) -> Bool {
        guard expectedSize > 0,
              let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
              let downloadedSize = attrs[.size] as? Int64 else {
            return true
        }
        let diff = abs(downloadedSize - expectedSize)
        let tolerance = max(expectedSize / 100, 1024)
        return diff <= tolerance
    }

    private func validateSHA256(tempURL: URL, expected: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: tempURL) else { return false }
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = try? handle.read(upToCount: 1 << 20)
            guard let chunk, !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        let actual = hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
        return actual == expected.lowercased()
    }

    // MARK: - Official HTML Fallback Helpers (pure, testable)

    /// Extracts `X.Y.Z` from a final `github.com/<owner>/<repo>/releases/tag/vX.Y.Z`
    /// URL. Rejects non-GitHub hosts, other repositories and non-semantic tags.
    static func version(fromReleasePageURL url: URL) -> String? {
        guard url.host?.lowercased() == "github.com" else { return nil }
        let parts = url.pathComponents
        guard parts.contains(repoOwner), parts.contains(repoName),
              let tagIndex = parts.firstIndex(of: "tag"),
              tagIndex + 1 < parts.count else { return nil }

        let tag = parts[tagIndex + 1]
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return version
    }

    /// Builds a release asset URL under this repository's official path.
    static func releaseAssetURL(version: String, suffix: String) -> URL? {
        guard version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/download/v\(version)/NewsBar-\(version)\(suffix)")
    }

    /// Parses a published `.sha256` sidecar (hash only, or `hash  filename`).
    static func parseSHA256File(_ text: String) -> String? {
        guard let token = text.split(whereSeparator: {
            $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r"
        }).first else { return nil }

        let value = String(token)
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
        return value.lowercased()
    }

    // MARK: - Trust Chain Helpers (pure, testable)

    /// Returns `true` if `host` is a GitHub-owned download host.
    /// Comparison is case-insensitive.
    static func isGitHubOwnedHost(_ host: String?) -> Bool {
        guard let host else { return false }
        return githubOwnedHosts.contains(host.lowercased())
    }

    /// Determines whether a release with the given provenance and artifact
    /// download host is authorized for automatic download.
    ///
    /// Both conditions must hold:
    /// 1. Metadata provenance is official GitHub (API or github.com page).
    /// 2. The artifact download URL host is GitHub-owned.
    static func canAuthorizeAutoDownload(provenance: ReleaseProvenance, downloadHost: String?) -> Bool {
        guard provenance.isGitHubOfficial else { return false }
        return isGitHubOwnedHost(downloadHost)
    }
}

/// Restricts every redirect during an update download to HTTPS and a
/// GitHub-owned host. The initial asset URL was already authorized; this
/// closes the gap while URLSession follows GitHub's storage redirects.
private final class UpdateDownloadRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              UpdateChecker.isGitHubOwnedHost(url.host) else { return nil }
        return request
    }
}
