import Foundation
import AppKit
import CryptoKit

final class UpdateChecker: ObservableObject {

    private static let repoOwner = "blackkcold"
    private static let repoName = "news-bar"

    private static let releaseAPIURLs: [(label: String, url: String)] = [
        ("GitHub",  "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"),
        ("ghproxy", "https://gh-proxy.com/https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"),
        ("ghproxy888", "https://gh.api.99988866.xyz/https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"),
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

        lastCheckDate = Date()

        guard let release = await fetchLatestRelease() else {
            return
        }

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

                guard let expectedSHA256 = await fetchSHA256FromGitHubDirect(release: release) else {
                    try? FileManager.default.removeItem(at: tempURL)
                    await MainActor.run { state = .error("无法获取校验文件，请从 GitHub 官方页面下载") }
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
        NSWorkspace.shared.activateFileViewerSelecting([url])
        state = .idle
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
    }

    // MARK: - Network Helpers

    private func fetchLatestRelease() async -> GitHubRelease? {
        for (index, entry) in Self.releaseAPIURLs.enumerated() {
            let label = entry.label
            let urlString = entry.url
            guard let url = URL(string: urlString) else { continue }

            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.timeoutInterval = 15

            do {
                let session = URLSession(configuration: .ephemeral)
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else { continue }
                guard (200...299).contains(httpResponse.statusCode) else {
                    if httpResponse.statusCode == 403 {
                        NSLog("[UpdateChecker] \(label): HTTP 403 (rate limited)")
                    } else {
                        NSLog("[UpdateChecker] \(label): HTTP \(httpResponse.statusCode)")
                    }
                    continue
                }

                let decoder = JSONDecoder()
                let release = try decoder.decode(GitHubRelease.self, from: data)

                if index > 0 {
                    let tagPattern = try! NSRegularExpression(pattern: "^v\\d+\\.\\d+\\.\\d+")
                    let range = NSRange(location: 0, length: release.tag_name.utf16.count)
                    guard tagPattern.firstMatch(in: release.tag_name, options: [], range: range) != nil else {
                        NSLog("[UpdateChecker] \(label): invalid tag format '\(release.tag_name)', skipping proxy")
                        continue
                    }
                }

                NSLog("[UpdateChecker] fetch succeeded via \(label), version=\(release.version)")
                return release
            } catch {
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
        }

        NSLog("[UpdateChecker] all URLs exhausted")
        return nil
    }

    private func fetchSHA256(from release: GitHubRelease) async -> String? {
        guard let sha256Asset = release.assets.first(where: { $0.name.hasSuffix(".sha256") }),
              let sha256URL = URL(string: sha256Asset.browser_download_url) else {
            return nil
        }

        do {
            let session = URLSession(configuration: .ephemeral)
            let (data, response) = try await session.data(from: sha256URL)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return nil }
            guard let content = String(data: data, encoding: .utf8) else { return nil }
            let hex = content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .filter { $0.isHexDigit }
            guard hex.count >= 64 else { return nil }
            return String(hex.prefix(64)).lowercased()
        } catch {
            return nil
        }
    }

    /// Always fetches the SHA256 from GitHub's direct API, ignoring proxy mirrors.
    /// This prevents a compromised proxy from serving a modified .sha256 file
    /// that matches a malicious DMG.
    private func fetchSHA256FromGitHubDirect(release _: GitHubRelease) async -> String? {
        guard let url = URL(string: Self.releaseAPIURLs[0].url) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 15

        do {
            let session = URLSession(configuration: .ephemeral)
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return nil }

            let decoder = JSONDecoder()
            let directRelease = try decoder.decode(GitHubRelease.self, from: data)

            guard let sha256Asset = directRelease.assets.first(where: { $0.name.hasSuffix(".sha256") }),
                  let sha256URL = URL(string: sha256Asset.browser_download_url) else {
                return nil
            }

            let (shaData, shaResponse) = try await session.data(from: sha256URL)
            guard let shaHTTPResponse = shaResponse as? HTTPURLResponse,
                  (200...299).contains(shaHTTPResponse.statusCode) else { return nil }
            guard let content = String(data: shaData, encoding: .utf8) else { return nil }

            let hex = content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .filter { $0.isHexDigit }
            guard hex.count >= 64 else { return nil }
            return String(hex.prefix(64)).lowercased()
        } catch {
            return nil
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
}
