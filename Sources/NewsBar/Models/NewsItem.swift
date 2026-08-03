import CryptoKit
import Foundation

struct NewsItem: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let url: String
    let source: NewsSource
    let rank: Int?
    let timestamp: Date
    var imageURL: String? = nil

    init(title: String, url: String, source: NewsSource, rank: Int? = nil, imageURL: String? = nil) {
        let identity = "\(source.id)\n\(url)"
        let digest = SHA256.hash(data: Data(identity.utf8))
        self.id = digest.map { String(format: "%02x", $0) }.joined()
        self.title = title
        self.url = url
        self.source = source
        self.rank = rank
        self.timestamp = Date()
        self.imageURL = imageURL
    }
}
