import CryptoKit
import Foundation

struct CacheEntry: Codable {
    let items: [NewsItem]
    let timestamp: Date
    let contentHash: String
    var aiSummary: String?
    var aiSummaryHash: String?

    static func contentIdentifier(for items: [NewsItem]) -> String {
        let content = items.map { "\($0.source.id):\($0.url):\($0.title)" }
            .sorted()
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(content.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    @available(*, deprecated, message: "Use contentIdentifier(for:) instead")
    static func hashForItems(_ items: [NewsItem]) -> String {
        contentIdentifier(for: items)
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
