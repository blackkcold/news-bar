import Foundation

actor CacheManager {

    private let cacheDirectory: URL

    init(cacheDirectory: URL? = nil) {
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else if TestIsolation.isActive {
            self.cacheDirectory = TestIsolation.directory("Cache")
        } else {
            let appSupport = FileManager.default.urls(
                for: .cachesDirectory, in: .userDomainMask
            ).first!
            let bundleID = Bundle.main.bundleIdentifier ?? "com.newsbar"
            self.cacheDirectory = appSupport
                .appendingPathComponent(bundleID)
                .appendingPathComponent("Cache")
        }
        try? FileManager.default.createDirectory(
            at: self.cacheDirectory, withIntermediateDirectories: true
        )
    }

    private func cacheURL(for source: NewsSource) -> URL {
        let identity: String
        switch source {
        case .weibo: identity = "weibo"
        case .bilibili: identity = "bilibili"
        case let .rss(_, url): identity = "rss:\(url)"
        }
        return cacheDirectory.appendingPathComponent("feed-v2-\(ContentIdentity.digest(identity)).json")
    }

    private func legacyCacheURL(for source: NewsSource) -> URL {
        let filename = source.id.replacingOccurrences(of: "/", with: "_") + ".json"
        return cacheDirectory.appendingPathComponent(filename)
    }

    private func belongsToSource(_ item: NewsItem, source: NewsSource) -> Bool {
        switch (item.source, source) {
        case (.weibo, .weibo), (.bilibili, .bilibili):
            return true
        case let (.rss(_, actual), .rss(_, expected)):
            return actual.utf8.elementsEqual(expected.utf8)
        default:
            return false
        }
    }

    func load(for source: NewsSource) -> CacheEntry? {
        if let data = try? Data(contentsOf: cacheURL(for: source)),
           let entry = try? JSONDecoder().decode(CacheEntry.self, from: data) {
            return entry
        }
        guard let data = try? Data(contentsOf: legacyCacheURL(for: source)),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data),
              !entry.items.isEmpty,
              entry.items.allSatisfy({ belongsToSource($0, source: source) }) else { return nil }
        return entry
    }

    func save(_ entry: CacheEntry, for source: NewsSource, token: CacheWriteToken? = nil) {
        guard token?.isCurrent != false else { return }
        let url = cacheURL(for: source)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func hasNewContent(for source: NewsSource, newItems: [NewsItem]) -> Bool {
        guard let existing = load(for: source) else { return true }
        let newHash = CacheEntry.contentIdentifier(for: newItems)
        return newHash != existing.contentHash
    }

    func markValidated(
        for source: NewsSource,
        at date: Date = Date(),
        eTag: String? = nil,
        lastModified: String? = nil,
        token: CacheWriteToken? = nil
    ) -> CacheEntry? {
        guard token?.isCurrent != false else { return nil }
        guard var existing = load(for: source) else { return nil }
        existing.lastValidatedAt = date
        if let eTag { existing.eTag = eTag }
        if let lastModified { existing.lastModified = lastModified }
        save(existing, for: source, token: token)
        return existing
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
