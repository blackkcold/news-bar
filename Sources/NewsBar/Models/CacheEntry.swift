import CryptoKit
import Foundation

struct CacheEntry: Codable {
    static let maxDisplayableAge: TimeInterval = 24 * 60 * 60

    let items: [NewsItem]
    /// 内容实际变化的时间，用于展示与内容版本判断。
    let timestamp: Date
    let contentHash: String
    var aiSummary: String?
    var aiSummaryHash: String?
    /// 最近一次成功向服务端验证的时间。旧缓存缺失时回退到 timestamp。
    var lastValidatedAt: Date?
    var eTag: String?
    var lastModified: String?

    init(
        items: [NewsItem],
        timestamp: Date,
        contentHash: String,
        aiSummary: String? = nil,
        aiSummaryHash: String? = nil,
        lastValidatedAt: Date? = nil,
        eTag: String? = nil,
        lastModified: String? = nil
    ) {
        self.items = items
        self.timestamp = timestamp
        self.contentHash = contentHash
        self.aiSummary = aiSummary
        self.aiSummaryHash = aiSummaryHash
        self.lastValidatedAt = lastValidatedAt
        self.eTag = eTag
        self.lastModified = lastModified
    }

    private enum CodingKeys: String, CodingKey {
        case items, timestamp, contentHash, aiSummary, aiSummaryHash
        case lastValidatedAt, eTag, lastModified
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([NewsItem].self, forKey: .items)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        aiSummary = try container.decodeIfPresent(String.self, forKey: .aiSummary)
        aiSummaryHash = try container.decodeIfPresent(String.self, forKey: .aiSummaryHash)
        lastValidatedAt = try container.decodeIfPresent(Date.self, forKey: .lastValidatedAt)
        eTag = try container.decodeIfPresent(String.self, forKey: .eTag)
        lastModified = try container.decodeIfPresent(String.self, forKey: .lastModified)
    }

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
        let interval = Date().timeIntervalSince(lastValidatedAt ?? timestamp)
        return interval > 15 * 60
    }

    func isExpired(at date: Date = Date()) -> Bool {
        date.timeIntervalSince(lastValidatedAt ?? timestamp) > Self.maxDisplayableAge
    }

    var isExpired: Bool {
        isExpired(at: Date())
    }

    func hasNewContent(comparedTo other: CacheEntry) -> Bool {
        contentHash != other.contentHash
    }

    func shouldSummarize() -> Bool {
        guard let hash = aiSummaryHash, let _ = aiSummary else { return true }
        return hash != contentHash
    }
}
