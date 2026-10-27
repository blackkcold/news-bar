import Foundation

enum NotificationIdentifier {
    static let digestCategory = "newsbar.news"
    static let openDigestAction = "newsbar.openDigest"
}

/// Payload embedded in a delivered notification so a click can list every
/// aggregated item instead of only the first one.
struct NotificationDigest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let kind: String
    let generatedAt: Date
    let items: [NewsItem]

    init(kind: String, generatedAt: Date = Date(), items: [NewsItem]) {
        self.version = Self.currentVersion
        self.kind = kind
        self.generatedAt = generatedAt
        self.items = items
    }

    static func encode(_ digest: NotificationDigest) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(digest) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ raw: String?) -> NotificationDigest? {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(NotificationDigest.self, from: data)
    }
}
