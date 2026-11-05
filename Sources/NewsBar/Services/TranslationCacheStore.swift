import Foundation

/// File-based cache for translated RSS titles, keyed by `(title, targetLang)`.
/// Avoids re-translating the same title and hitting the free API rate limit.
actor TranslationCacheStore {

    private struct Entry: Codable {
        let translated: String
        let timestamp: Date
    }

    private let cacheDirectory: URL
    /// Legacy lookups used to enumerate the whole directory for every title.
    /// A per-actor listing makes a cold batch O(1) directory reads instead of
    /// O(n) while still seeing files written by this actor.
    private var knownFiles: Set<String>?

    init(cacheDirectory: URL? = nil) {
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else if TestIsolation.isActive {
            self.cacheDirectory = TestIsolation.directory("TranslationCache")
        } else {
            let appSupport = FileManager.default.urls(
                for: .cachesDirectory, in: .userDomainMask
            ).first!
            let bundleID = Bundle.main.bundleIdentifier ?? "com.newsbar"
            self.cacheDirectory = appSupport
                .appendingPathComponent(bundleID)
                .appendingPathComponent("TranslationCache")
        }
        try? PrivateFile.ensureDirectory(self.cacheDirectory)
    }

    private func cacheURL(for title: String, targetLang: String) -> URL {
        let identity = "translation-v2:\(targetLang.utf8.count):\(targetLang)\(title)"
        return cacheDirectory.appendingPathComponent("translation-v2-\(ContentIdentity.digest(identity)).json")
    }

    private func legacyURL(for title: String, targetLang: String) -> URL? {
        // Old names replace '/' with '_', so either character makes the
        // original input unknowable. The delimiter is also ambiguous in a key.
        guard !title.contains(where: { "/_|".contains($0) }),
              !targetLang.contains(where: { "/_|".contains($0) }) else { return nil }
        let filename = "\(targetLang)|\(title).json"
        guard fileNames().contains(filename) else { return nil }
        return cacheDirectory.appendingPathComponent(filename)
    }

    private func fileNames() -> Set<String> {
        if let knownFiles { return knownFiles }
        let files = Set((try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)) ?? [])
        knownFiles = files
        return files
    }

    private func loadEntry(at url: URL) -> Entry? {
        guard PrivateFile.tightenExistingFile(url),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    func cachedTranslation(for title: String, targetLang: String) -> String? {
        if let entry = loadEntry(at: cacheURL(for: title, targetLang: targetLang)) {
            return entry.translated
        }
        guard let legacy = legacyURL(for: title, targetLang: targetLang) else { return nil }
        return loadEntry(at: legacy)?.translated
    }

    func saveTranslation(
        _ translated: String, for title: String, targetLang: String, token: CacheWriteToken? = nil
    ) {
        guard token?.isCurrent != false else { return }
        let url = cacheURL(for: title, targetLang: targetLang)
        let entry = Entry(translated: translated, timestamp: Date())
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? PrivateFile.write(data, to: url, durable: false)
        knownFiles?.insert(url.lastPathComponent)
    }

    func clear() {
        if let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: nil
        ) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
        knownFiles = []
    }
}
