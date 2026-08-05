import Foundation

/// File-based cache for translated RSS titles, keyed by `(title, targetLang)`.
/// Avoids re-translating the same title and hitting the free API rate limit.
actor TranslationCacheStore {

    private struct Entry: Codable {
        let translated: String
        let timestamp: Date
    }

    private let cacheDirectory: URL

    init(cacheDirectory: URL? = nil) {
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            let appSupport = FileManager.default.urls(
                for: .cachesDirectory, in: .userDomainMask
            ).first!
            let bundleID = Bundle.main.bundleIdentifier ?? "com.newsbar"
            self.cacheDirectory = appSupport
                .appendingPathComponent(bundleID)
                .appendingPathComponent("TranslationCache")
            try? FileManager.default.createDirectory(
                at: self.cacheDirectory, withIntermediateDirectories: true
            )
        }
    }

    private func cacheURL(for key: String) -> URL {
        let filename = key.replacingOccurrences(of: "/", with: "_") + ".json"
        return cacheDirectory.appendingPathComponent(filename)
    }

    func cachedTranslation(for title: String, targetLang: String) -> String? {
        let key = "\(targetLang)|\(title)"
        let url = cacheURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            return nil
        }
        return entry.translated
    }

    func saveTranslation(_ translated: String, for title: String, targetLang: String) {
        let key = "\(targetLang)|\(title)"
        let url = cacheURL(for: key)
        let entry = Entry(translated: translated, timestamp: Date())
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        if let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: nil
        ) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
