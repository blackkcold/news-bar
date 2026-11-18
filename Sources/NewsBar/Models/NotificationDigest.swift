import Foundation

enum NotificationIdentifier {
    static let digestCategory = "newsbar.news"
    static let openDigestAction = "newsbar.openDigest"
    static let researchCategory = "newsbar.research"
    static let openResearchAction = "newsbar.openResearch"
    static let markResearchReadAction = "newsbar.markResearchRead"

    static let weiboCategory = "newsbar.weibo"
    static let openWeiboAction = "newsbar.weibo.open"
    static let muteWeiboAction = "newsbar.weibo.mute1h"
    static let markWeiboReadAction = "newsbar.weibo.markRead"

    /// Stable request identifiers. A fixed identifier makes the system replace
    /// the previous request and delivered banner instead of piling one up per
    /// hour or per launch.
    static let hourlyRequest = "hourly-summary"
    static let dailyRequest = "daily-summary"
}

/// Payload embedded in a delivered notification so a click can list every
/// aggregated item instead of only the first one.
struct NotificationDigest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let kind: String
    let generatedAt: Date
    let items: [NewsItem]
    let researchItems: [NotificationDigestResearchItem]

    var itemCount: Int {
        let newsIDs = Set(items.map(\.id))
        let attached = researchItems.filter { item in
            guard let relatedID = item.relatedNewsItemID else { return false }
            return newsIDs.contains(relatedID)
        }.count
        return items.count + researchItems.count - attached
    }

    init(
        kind: String,
        generatedAt: Date = Date(),
        items: [NewsItem],
        researchItems: [NotificationDigestResearchItem] = []
    ) {
        self.version = Self.currentVersion
        self.kind = kind
        self.generatedAt = generatedAt
        self.items = items
        self.researchItems = researchItems
    }

    private enum CodingKeys: String, CodingKey {
        case version, kind, generatedAt, items, researchItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "hourly"
        generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt) ?? .distantPast
        items = try container.decodeIfPresent([NewsItem].self, forKey: .items) ?? []
        researchItems = try container.decodeIfPresent(
            [NotificationDigestResearchItem].self,
            forKey: .researchItems
        ) ?? []
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

enum NotificationDigestResearchKind: String, Codable, Sendable {
    case eventUpdate
    case reportReady
    case correction
}

enum NotificationDigestUrgency: String, Codable, Sendable {
    case ordinary
    case major
    case urgentCorrection
}

/// A compact report/event reference in an existing news digest. Detail text is
/// present only after the user explicitly enables detailed notification preview.
struct NotificationDigestResearchItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: NotificationDigestResearchKind
    let title: String
    let detail: String?
    let eventID: String?
    let recordID: String?
    let versionID: String?
    let compareFromVersionID: String?
    let sourceURL: String?
    let createdAt: Date
    /// Optional so digests already scheduled by older app versions still decode.
    var urgency: NotificationDigestUrgency? = nil
    /// When the same event already occupies a digest news slot, the research
    /// action is attached to that row and does not consume another slot.
    var relatedNewsItemID: String? = nil
}
