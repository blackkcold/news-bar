import Foundation
import AppKit

final class UpdateChecker: ObservableObject {

    private static let repoOwner = "blackkcold"
    private static let repoName = "news-bar"
    private static let apiURL = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"

    private static let checkInterval: TimeInterval = 86400
    private static let updateCacheDir: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.newsbar"
        return caches.appendingPathComponent(bundleID).appendingPathComponent("Updates")
    }()

    @Published var state: UpdateState = .idle

    private var downloadTask: URLSessionDownloadTask?
    private lazy var urlSession: URLSession = {
        URLSession(configuration: .default)
    }()

    private var lastCheckDate: Date? {
        get { UserDefaults.standard.object(forKey: "lastUpdateCheckDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastUpdateCheckDate") }
    }

    private var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: "updateSkippedVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "updateSkippedVersion") }
    }

    // MARK: - Auto Update Check (called by AppDelegate on launch)

    func autoCheck() async {
        if let last = lastCheckDate, Date().timeIntervalSince(last) < Self.checkInterval {
            return
        }

        lastCheckDate = Date()

        guard let release = await fetchLatestRelease() else {
            return
        }

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

        guard versionIsNewer(release.version, than: AppVersion.current) else {
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

        Task {
            guard let release = await fetchLatestRelease() else {
                await MainActor.run { state = .error("获取下载地址失败") }
                return
            }

            guard let asset = release.assets.first(where: { $0.isDMG }),
                  let url = URL(string: asset.browser_download_url) else {
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

            let destinationURL = Self.updateCacheDir.appendingPathComponent(asset.name)

            do {
                let (tempURL, response) = try await urlSession.download(from: url)
                let httpResponse = response as? HTTPURLResponse

                guard let code = httpResponse?.statusCode, (200...299).contains(code) else {
                    await MainActor.run { state = .error("下载失败 (HTTP \(httpResponse?.statusCode ?? 0))") }
                    return
                }

                if !validateDownloadSize(tempURL: tempURL, expectedSize: asset.size) {
                    try? FileManager.default.removeItem(at: tempURL)
                    await MainActor.run { state = .error("文件校验失败，请重试") }
                    return
                }

                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: destinationURL)

                await MainActor.run { state = .downloadComplete(destinationURL) }
            } catch {
                await MainActor.run { state = .error("下载失败，请重试") }
            }
        }
    }

    // MARK: - Dismiss

    func dismissUpdate() {
        if case .updateAvailable(let version) = state {
            skippedVersion = version
        }
        state = .idle
    }

    func openDownloadedDMG() {
        guard case .downloadComplete(let url) = state else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        state = .idle
    }

    // MARK: - Helpers

    private func fetchLatestRelease() async -> GitHubRelease? {
        guard let url = URL(string: Self.apiURL) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NewsBar/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            guard (200...299).contains(httpResponse.statusCode) else { return nil }

            let decoder = JSONDecoder()
            return try decoder.decode(GitHubRelease.self, from: data)
        } catch {
            return nil
        }
    }

    private func validateDownloadSize(tempURL: URL, expectedSize: Int64) -> Bool {
        guard expectedSize > 0,
              let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
              let downloadedSize = attrs[.size] as? Int64 else {
            return true
        }
        let diff = abs(downloadedSize - expectedSize)
        return diff <= expectedSize / 10
    }
}
