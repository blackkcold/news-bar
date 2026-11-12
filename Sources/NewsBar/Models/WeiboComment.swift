import Foundation

/// How a comment thread was fetched. Kept on the page so a later refresh can
/// tell which endpoint the cached data came from without re-deriving it.
enum WeiboCommentTier: String, Codable, Sendable, Equatable {
    case desktop
    case mobile
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
