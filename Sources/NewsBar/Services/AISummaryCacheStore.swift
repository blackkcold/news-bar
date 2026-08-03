import Foundation

struct AISummaryCacheEntry: Codable, Sendable {
    let summary: String
    let items: [NewsItem]
    let contentHash: String
    let trendHistoryHash: String
    let generatedAt: Date
    let trendItemCount: Int
}

actor AISummaryCacheStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let bundleID = Bundle.main.bundleIdentifier ?? "com.newsbar"
            self.fileURL = caches
                .appendingPathComponent(bundleID)
                .appendingPathComponent("ai-summary.json")
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
