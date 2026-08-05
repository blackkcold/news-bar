import Foundation

struct AISummaryCacheEntry: Codable, Sendable {
    let summary: String
    let items: [NewsItem]
    let contentHash: String
    let trendHistoryHash: String
    let generatedAt: Date
    let trendItemCount: Int
    let language: AppLanguage

    init(
        summary: String,
        items: [NewsItem],
        contentHash: String,
        trendHistoryHash: String,
        generatedAt: Date,
        trendItemCount: Int,
        language: AppLanguage = .zh
    ) {
        self.summary = summary
        self.items = items
        self.contentHash = contentHash
        self.trendHistoryHash = trendHistoryHash
        self.generatedAt = generatedAt
        self.trendItemCount = trendItemCount
        self.language = language
    }

    private enum CodingKeys: String, CodingKey {
        case summary, items, contentHash, trendHistoryHash, generatedAt, trendItemCount, language
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decode(String.self, forKey: .summary)
        items = try c.decode([NewsItem].self, forKey: .items)
        contentHash = try c.decode(String.self, forKey: .contentHash)
        trendHistoryHash = try c.decode(String.self, forKey: .trendHistoryHash)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        trendItemCount = try c.decode(Int.self, forKey: .trendItemCount)
        language = (try? c.decodeIfPresent(AppLanguage.self, forKey: .language)) ?? .zh
    }
}

actor AISummaryCacheStore {
    private let fileURL: URL

    init(fileURL: URL? = nil, language: AppLanguage = .zh) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let bundleID = Bundle.main.bundleIdentifier ?? "com.newsbar"
            self.fileURL = caches
                .appendingPathComponent(bundleID)
                .appendingPathComponent("ai-summary-\(language.rawValue).json")
        }
    }

    func load() -> AISummaryCacheEntry? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(AISummaryCacheEntry.self, from: data)
    }

    func save(_ entry: AISummaryCacheEntry) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entry)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[AISummaryCacheStore] persist failed: %@", error.localizedDescription)
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
