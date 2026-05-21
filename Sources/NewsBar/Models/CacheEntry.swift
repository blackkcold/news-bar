import Foundation

struct CacheEntry: Codable {
    let items: [NewsItem]
    let timestamp: Date
    let contentHash: String
    var aiSummary: String?
    var aiSummaryHash: String?

    static func hashForItems(_ items: [NewsItem]) -> String {
        let titles = items.map(\.title).sorted().joined(separator: "|")
        let data = Data(titles.utf8)
        return data.base64EncodedString()
    }

    var isStale: Bool {
        let interval = Date().timeIntervalSince(timestamp)
        return interval > 15 * 60
    }

    func hasNewContent(comparedTo other: CacheEntry) -> Bool {
        contentHash != other.contentHash
    }

    func shouldSummarize() -> Bool {
        guard let hash = aiSummaryHash, let _ = aiSummary else { return true }
        return hash != contentHash
    }
}
