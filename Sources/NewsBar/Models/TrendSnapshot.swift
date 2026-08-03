import Foundation

struct TrendSnapshot: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let weiboItems: [NewsItem]
    let bilibiliItems: [NewsItem]
    let contentHash: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        weiboItems: [NewsItem],
        bilibiliItems: [NewsItem],
        contentHash: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.weiboItems = weiboItems
        self.bilibiliItems = bilibiliItems
        self.contentHash = contentHash
    }
}

struct TrendChangeSummary: Equatable, Sendable {
    let score: Int
    let historyHash: String
    let context: String

    var isSignificant: Bool { score >= 5 }

    static let none = TrendChangeSummary(score: 0, historyHash: "", context: "")
}
