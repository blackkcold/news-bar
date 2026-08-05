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
    /// Weibo trending status: "爆" / "沸" / "热" / "新" (nil when none).
    var hotLabel: String? = nil
    /// Optional translated title (RSS only, when English UI + translation enabled).
    /// The original `title` is always preserved for the AI summary prompt.
    var translatedTitle: String? = nil

    init(
        title: String,
        url: String,
        source: NewsSource,
        rank: Int? = nil,
        imageURL: String? = nil,
        hotLabel: String? = nil,
        translatedTitle: String? = nil
    ) {
        let identity = "\(source.id)\n\(url)"
        let digest = SHA256.hash(data: Data(identity.utf8))
        self.id = digest.map { String(format: "%02x", $0) }.joined()
        self.title = title
        self.url = url
        self.source = source
        self.rank = rank
        self.timestamp = Date()
        self.imageURL = imageURL
        self.hotLabel = hotLabel
        self.translatedTitle = translatedTitle
    }

    /// Title to display in the UI: translated when available, otherwise the original.
    var displayTitle: String {
        translatedTitle ?? title
    }

    /// Returns a copy with the translated title set, preserving all other fields.
    func withTranslatedTitle(_ translated: String) -> NewsItem {
        var copy = self
        copy.translatedTitle = translated
        return copy
    }
}
