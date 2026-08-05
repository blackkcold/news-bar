import Foundation

enum NewsSource: Identifiable, Hashable, Codable, Sendable {
    case weibo
    case bilibili
    case rss(name: String, url: String)

    var id: String {
        switch self {
        case .weibo: return "weibo"
        case .bilibili: return "bilibili"
        case let .rss(_, url): return url
        }
    }

    var displayName: String {
        switch self {
        case .weibo: return L10n.string("source.weibo")
        case .bilibili: return L10n.string("source.bilibili")
        case let .rss(name, _): return name
        }
    }

    var iconName: String {
        switch self {
        case .weibo: return "safari"
        case .bilibili: return "play.rectangle"
        case .rss: return "antenna.radiowaves.left.and.right"
        }
    }

    var isBuiltIn: Bool {
        switch self {
        case .weibo, .bilibili: return true
        case .rss: return false
        }
    }
}

extension NewsSource {
    enum CodingKeys: String, CodingKey {
        case type, name, url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "weibo":
            self = .weibo
        case "bilibili":
            self = .bilibili
        case "rss":
            let name = try container.decode(String.self, forKey: .name)
            let url = try container.decode(String.self, forKey: .url)
            self = .rss(name: name, url: url)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown source type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .weibo:
            try container.encode("weibo", forKey: .type)
        case .bilibili:
            try container.encode("bilibili", forKey: .type)
        case let .rss(name, url):
            try container.encode("rss", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(url, forKey: .url)
        }
    }
}
