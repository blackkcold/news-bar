import Foundation

/// A post as it is kept in the local feed. The parser fills every field; the
/// reader never touches the raw JSON again. `screenName` is a snapshot so a
/// removed account still renders correctly in the feed.
struct WeiboPost: Codable, Identifiable, Equatable, Sendable {
    var mid: String
    var bid: String?
    var uid: String
    var screenName: String
    var text: String
    var createdAt: Date
    var fetchedAt: Date
    var isLongText: Bool
    var isRetweet: Bool
    var retweetText: String?
    var imageURLs: [String]
    var url: String
    var read: Bool
    var isTop: Bool
    /// Optional platform counters captured with the feed response. Missing is
    /// not zero, and these are not the platform's post view count.
    var commentCount: Int?
    var repostCount: Int?
    var likeCount: Int?
    var metricsFetchedAt: Date?
    /// Local relevance decision. Optional on purpose: an old `posts.json` has
    /// no such key and must still decode, and a post fetched while filtering
    /// is off stays nil.
    var relevance: WeiboPostRelevance?

    var id: String { mid }

    /// The UI collapses this post into the "filtered" section. A nil decision
    /// is always visible: filtering must never hide something it did not judge.
    var isCollapsedByRelevance: Bool {
        relevance?.verdict.isCollapsed == true
    }

    var displayText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return retweetText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var webURL: URL? { URL(string: url) }

    static func makeURL(uid: String, bid: String?, mid: String) -> String {
        if let bid, !bid.isEmpty {
            return "https://weibo.com/\(uid)/\(bid)"
        }
        return "https://m.weibo.cn/detail/\(mid)"
    }

    init(
        mid: String,
        bid: String?,
        uid: String,
        screenName: String,
        text: String,
        createdAt: Date,
        fetchedAt: Date,
        isLongText: Bool = false,
        isRetweet: Bool = false,
        retweetText: String? = nil,
        imageURLs: [String] = [],
        url: String,
        read: Bool = false,
        isTop: Bool = false,
        relevance: WeiboPostRelevance? = nil,
        commentCount: Int? = nil,
        repostCount: Int? = nil,
        likeCount: Int? = nil,
        metricsFetchedAt: Date? = nil
    ) {
        self.mid = mid
        self.bid = bid
        self.uid = uid
        self.screenName = screenName
        self.text = text
        self.createdAt = createdAt
        self.fetchedAt = fetchedAt
        self.isLongText = isLongText
        self.isRetweet = isRetweet
        self.retweetText = retweetText
        self.imageURLs = imageURLs
        self.url = url
        self.read = read
        self.isTop = isTop
        self.relevance = relevance
        self.commentCount = commentCount
        self.repostCount = repostCount
        self.likeCount = likeCount
        self.metricsFetchedAt = metricsFetchedAt ?? ((commentCount != nil || repostCount != nil || likeCount != nil) ? fetchedAt : nil)
    }
}
