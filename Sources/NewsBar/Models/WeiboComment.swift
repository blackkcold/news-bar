import Foundation

/// How a comment thread was fetched. Kept on the page so a later refresh can
/// tell which endpoint the cached data came from without re-deriving it.
enum WeiboCommentTier: String, Codable, Sendable, Equatable {
    case desktop
    case mobile
}

/// One styled span of a comment body. The comment payload is HTML; parsing it
/// on the fetch actor keeps `AttributedString` construction out of layout.
///
/// `.mention` and `.topic` carry the href Weibo supplied for them, so they stay
/// clickable while keeping their own accent styling (no underline). The URL is
/// always the platform's own, never a guessed profile or search route.
struct WeiboCommentRun: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text
        case link
        case mention
        case topic
    }

    var kind: Kind
    var text: String
    /// Only for `.link`, `.mention` and `.topic`, and already checked against
    /// `ReaderNavigationPolicy`.
    var url: String?
}

/// One comment as shown under a post. Optional fields are deliberately
/// optional: a missing like count is not zero, and a missing reply target must
/// not be invented from the parent comment body.
struct WeiboComment: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var mid: String
    var uid: String
    var screenName: String
    var avatarURL: String?
    var text: String
    var createdAt: Date
    var likeCount: Int?
    var replyToName: String?
    var isAuthor: Bool
    /// Parsed spans of the raw body. `nil` means the payload carried no markup
    /// (or the comment came from a cache written before this field existed).
    /// Optional on purpose: `comments/*.json` from an older build has no such
    /// key and must still decode, because a decode failure deletes the file.
    var runs: [WeiboCommentRun]?
    /// Whether the signed-in account liked this comment when the page was
    /// fetched. `nil` for caches written before likes were tracked.
    var liked: Bool? = nil
}

/// One successful page of a comment thread.
struct WeiboCommentPage: Codable, Equatable, Sendable {
    var comments: [WeiboComment]
    /// `nil` means the platform did not tell us. It is not the same as zero.
    var total: Int?
    /// Cursor for the next page; `nil` means the thread ended (or the source
    /// did not provide cursors at all).
    var nextCursor: String?
    var fetchedAt: Date
    var tier: WeiboCommentTier
}

enum WeiboCommentOutcome: Sendable, Equatable {
    case success(page: WeiboCommentPage, latency: TimeInterval)
    case failure(WeiboCommentFailure)
}

enum WeiboCommentIssue: Equatable, Sendable {
    case network
    case server
    case parseChanged
    case challenge
    case authRequired
    case rateLimited(until: Date)
    case unknown
}

enum WeiboCommentLoadState: Equatable, Sendable {
    case idle
    case loadingFirst
    case loaded
    case loadingMore
    case empty
    case authRequired
    case rateLimited(until: Date)
    case failed(WeiboCommentIssue, canRetry: Bool)
}

enum WeiboCommentLimits {
    static let maxComments = 100
    static let maxPages = 5
}

/// UI-facing thread state. The controller replaces whole values so SwiftUI's
/// observation fires once per meaningful change rather than once per field.
struct WeiboCommentThread: Equatable, Sendable {
    var postID: String
    var comments: [WeiboComment] = []
    var pendingComments: [WeiboComment] = []
    var total: Int?
    var nextCursor: String?
    var state: WeiboCommentLoadState = .idle
    var pagesLoaded: Int = 0
    var fetchedAt: Date?
    var tier: WeiboCommentTier = .desktop
    var loadMoreError: WeiboCommentIssue?
    var newComments: Int = 0
    var isRefreshing = false

    var canLoadMore: Bool {
        state == .loaded
            && nextCursor != nil
            && pagesLoaded < WeiboCommentLimits.maxPages
            && comments.count < WeiboCommentLimits.maxComments
    }

    var displayTotal: Int {
        max(total ?? comments.count, comments.count + pendingComments.count)
    }
}

protocol WeiboCommentFetching: Sendable {
    func fetchComments(
        mid: String,
        uid: String,
        authorUID: String?,
        cursor: String?,
        credentials: WeiboCredentials,
        now: Date
    ) async -> WeiboCommentOutcome
}

enum WeiboCommentFailure: Error, Equatable, Sendable {
    case authRequired
    case rateLimited(retryAfter: TimeInterval?)
    case challenge
    case network
    case server
    case parseChanged
    case unknown
}

enum WeiboCommentParserError: Error, Equatable {
    case invalidJSON
    case notOK
    case shapeChanged
}
