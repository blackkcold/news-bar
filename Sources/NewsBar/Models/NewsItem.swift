import Foundation

struct NewsItem: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let url: String
    let source: NewsSource
    let rank: Int?
    let timestamp: Date

    init(title: String, url: String, source: NewsSource, rank: Int? = nil) {
        self.id = "\(source.id)-\(url.hashValue)"
        self.title = title
        self.url = url
        self.source = source
        self.rank = rank
        self.timestamp = Date()
    }
}
