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
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.newsbar"
        return caches.appendingPathComponent(bundleID).appendingPathComponent("Updates")
    }()

    @Published var state: UpdateState = .idle

    var devMode: Bool {
        UserDefaults.standard.bool(forKey: "updateDevMode")
    }

    private var cachedRelease: GitHubRelease?

    private var lastCheckDate: Date? {
        get { UserDefaults.standard.object(forKey: "lastUpdateCheckDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastUpdateCheckDate") }
    }

    private var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: "updateSkippedVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "updateSkippedVersion") }
    }

    private var downloadTask: Task<Void, Never>?

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
        guard case .updateAvailable = state else { return }

        downloadTask = Task {
            let release: GitHubRelease
            if let cached = cachedRelease {
                release = cached
            } else {
                guard let fetched = await fetchLatestRelease() else {
                    await MainActor.run { state = .error("获取下载地址失败") }
                    return
                }
                release = fetched
            }

            guard let dmgAsset = release.assets.first(where: { $0.isDMG }),
                  let dmgURL = URL(string: dmgAsset.browser_download_url) else {
                await MainActor.run { state = .error("未找到 DMG 文件") }
                return
            }

            // Trust chain: automatic download requires an official GitHub
            // source (API or github.com release page) AND a GitHub-owned
            // download host. Proxy metadata never authorizes a download.
            guard Self.canAuthorizeAutoDownload(
                provenance: release.provenance,
                downloadHost: dmgURL.host
            ) else {
                let message = release.provenance.isGitHubOfficial
                    ? "下载地址非 GitHub 官方域名，已拒绝自动下载。请从 GitHub 官方页面下载。"
                    : "更新信息来自第三方镜像，无法自动下载。请从 GitHub 官方页面下载。"
                await MainActor.run { state = .error(message) }
                return
            }

            await MainActor.run { state = .downloading(0) }

            try? FileManager.default.createDirectory(at: Self.updateCacheDir, withIntermediateDirectories: true)

            if let contents = try? FileManager.default.contentsOfDirectory(at: Self.updateCacheDir, includingPropertiesForKeys: nil) {
                for file in contents where file.pathExtension == "dmg" {
                    try? FileManager.default.removeItem(at: file)
                }
            }

            let destinationURL = Self.updateCacheDir.appendingPathComponent(dmgAsset.name)

            do {
                let session = URLSession(configuration: .ephemeral)
                let (tempURL, response) = try await session.download(from: dmgURL)
                let httpResponse = response as? HTTPURLResponse

                guard let code = httpResponse?.statusCode, (200...299).contains(code) else {
                    await MainActor.run { state = .error("下载失败 (HTTP \(httpResponse?.statusCode ?? 0))") }
                    return
                }

                if !validateDownloadSize(tempURL: tempURL, expectedSize: dmgAsset.size) {
                    try? FileManager.default.removeItem(at: tempURL)
                    await MainActor.run { state = .error("文件校验失败，请重试") }
                    return
                }

                let expectedSHA256 = dmgAsset.sha256Digest

                guard let expectedSHA256 else {
                    try? FileManager.default.removeItem(at: tempURL)
                    await MainActor.run { state = .error("无法获取校验信息，请从 GitHub 官方页面下载") }
                    return
                }

                if !validateSHA256(tempURL: tempURL, expected: expectedSHA256) {
                    try? FileManager.default.removeItem(at: tempURL)
                    await MainActor.run { state = .error("文件校验失败，请重试") }
                    return
                }

                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: destinationURL)

                cachedRelease = nil

                await MainActor.run { state = .downloadComplete(destinationURL) }
            } catch {
                await MainActor.run { state = .error("下载失败，请重试") }
            }

            downloadTask = nil
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
        downloadTask?.cancel()
        downloadTask = nil
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
        guard let data = try? Data(contentsOf: tempURL) else { return false }
        let digest = SHA256.hash(data: data)
        let actual = digest.compactMap { String(format: "%02x", $0) }.joined()
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
