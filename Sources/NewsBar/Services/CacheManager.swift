import Foundation

actor CacheManager {

    private let cacheDirectory: URL

    init() {
        let appSupport = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.newsbar"
        self.cacheDirectory = appSupport
            .appendingPathComponent(bundleID)
            .appendingPathComponent("Cache")
        try? FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true
        )
    }

    private func cacheURL(for source: NewsSource) -> URL {
        let filename = source.id.replacingOccurrences(of: "/", with: "_") + ".json"
        return cacheDirectory.appendingPathComponent(filename)
    }

    func load(for source: NewsSource) -> CacheEntry? {
        let url = cacheURL(for: source)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data) else {
            return nil
        }
        return entry
    }

    func save(_ entry: CacheEntry, for source: NewsSource) {
        let url = cacheURL(for: source)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func hasNewContent(for source: NewsSource, newItems: [NewsItem]) -> Bool {
        guard let existing = load(for: source) else { return true }
        let newHash = CacheEntry.contentIdentifier(for: newItems)
        return newHash != existing.contentHash
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
