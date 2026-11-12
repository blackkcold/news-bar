import Foundation

/// A cached comment thread. `pagesLoaded` is part of the cache because the
/// controller's automatic pagination cap must survive a relaunch; otherwise a
/// reopened thread would silently request more pages than a fresh one.
struct CachedWeiboCommentThread: Codable, Equatable, Sendable {
    var page: WeiboCommentPage
    var pagesLoaded: Int
}

/// Disposable local comment cache. It never becomes the source of truth for
/// whether a post has comments: a missing file only means "fetch again".
actor WeiboCommentCache {
    static let maxComments = 100
    static let maxThreads = 80
    static let maxAge: TimeInterval = 7 * 24 * 3600

    private let root: URL

    init(root: URL = WeiboMonitorStore.defaultRoot()) {
        self.root = root
    }

    private var directory: URL {
        root.appendingPathComponent("comments", isDirectory: true)
    }

    func load(mid: String) async -> CachedWeiboCommentThread? {
        let url = fileURL(mid: mid)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        guard let data = try? Data(contentsOf: url) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard let thread = try? Self.decode(data) else {
            // A partial or future-version cache must never brick the thread.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard Date().timeIntervalSince(thread.page.fetchedAt) <= Self.maxAge else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        var trimmed = thread
        if trimmed.page.comments.count > Self.maxComments {
            trimmed.page.comments = Array(trimmed.page.comments.prefix(Self.maxComments))
        }
        trimmed.pagesLoaded = max(1, trimmed.pagesLoaded)
        return trimmed
    }

    func save(mid: String, thread: CachedWeiboCommentThread) async {
        var copy = thread
        if copy.page.comments.count > Self.maxComments {
            copy.page.comments = Array(copy.page.comments.prefix(Self.maxComments))
        }
        copy.pagesLoaded = max(1, copy.pagesLoaded)

        guard let data = try? Self.encode(copy) else { return }
        try? PrivateFile.write(data, to: fileURL(mid: mid), durable: false)
        prune()
    }

    func clear() async {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Files

    private func fileURL(mid: String) -> URL {
        let safe = mid.filter { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
        }
        let name = safe.isEmpty ? "unknown" : String(safe.prefix(80))
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    private func prune(now: Date = Date()) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var dated: [(url: URL, date: Date)] = []
        for url in urls where url.pathExtension == "json" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let date = values?.contentModificationDate ?? now
            if now.timeIntervalSince(date) > Self.maxAge {
                try? FileManager.default.removeItem(at: url)
            } else {
                dated.append((url, date))
            }
        }

        guard dated.count > Self.maxThreads else { return }
        dated.sort { $0.date < $1.date }
        let excess = dated.count - Self.maxThreads
        for item in dated.prefix(excess) {
            try? FileManager.default.removeItem(at: item.url)
        }
    }

    private static func encode(_ value: CachedWeiboCommentThread) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func decode(_ data: Data) throws -> CachedWeiboCommentThread {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CachedWeiboCommentThread.self, from: data)
    }
}
