import Foundation

enum WeiboLoginState: String, Sendable, Equatable {
    case unknown
    case loggedIn
    case mobileOnly
    case anonymous
    case expired

    var titleKey: String { "weibo.login.\(rawValue)" }

    var isUsableForDesktopFeed: Bool { self == .loggedIn }
}

/// Cookie snapshots are reduced to request headers on the main actor. The
/// service never sees `HTTPCookie` objects, which keeps it free of WebKit
/// concerns and safe to call from any executor.
struct WeiboCredentials: Sendable, Equatable {
    var desktopCookieHeader: String?
    var mobileCookieHeader: String?
    var hasDesktopLogin: Bool
    var hasMobileLogin: Bool

    static let none = WeiboCredentials(
        desktopCookieHeader: nil,
        mobileCookieHeader: nil,
        hasDesktopLogin: false,
        hasMobileLogin: false
    )

    var loginState: WeiboLoginState {
        if hasDesktopLogin { return .loggedIn }
        if hasMobileLogin { return .mobileOnly }
        return .anonymous
    }
}

struct WeiboMonitorEvent: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case info
        case success
        case warning
        case error
    }

    let id: UUID
    let at: Date
    let kind: Kind
    let message: String

    init(at: Date, kind: Kind, message: String) {
        self.id = UUID()
        self.at = at
        self.kind = kind
        self.message = message
    }
}

struct WeiboAccountFeedGroup: Identifiable, Equatable, Sendable {
    var user: WeiboMonitorUser
    var posts: [WeiboPost]
    var unreadCount: Int

    var id: String { user.uid }
}

/// Everything the monitor surfaces need. Built by the service on demand; the
/// view model mirrors the latest value so SwiftUI never reads actor state.
struct WeiboMonitorSnapshot: Equatable, Sendable {
    var users: [WeiboMonitorUser] = []
    var postsByUID: [String: [WeiboPost]] = [:]
    var unreadCount: Int = 0
    var loginState: WeiboLoginState = .unknown
    var isEnabled: Bool = false
    var isTicking: Bool = false
    var isOnline: Bool = true
    var pausedUntil: Date?
    var authPausedUntil: Date?
    var lastTickAt: Date?
    var nextCheckAt: Date?
    var events: [WeiboMonitorEvent] = []
    var storeError: String?
    var todayPostCount: Int = 0
    var gapSuspectedCount: Int = 0

    static let empty = WeiboMonitorSnapshot()

    var isPaused: Bool {
        if let pausedUntil, pausedUntil > Date() { return true }
        if let authPausedUntil, authPausedUntil > Date() { return true }
        return false
    }

    /// Accounts in feed order: P0 first, then the account whose latest post is
    /// newest. Within an account, newest first.
    var groups: [WeiboAccountFeedGroup] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        _ = startOfDay
        return users
            .map { user in
                let posts = (postsByUID[user.uid] ?? [])
                    .sorted { $0.createdAt > $1.createdAt }
                let unread = posts.reduce(0) {
                    $0 + (($1.read || $1.isCollapsedByRelevance) ? 0 : 1)
                }
                return WeiboAccountFeedGroup(user: user, posts: posts, unreadCount: unread)
            }
            .filter { !$0.posts.isEmpty || $0.user.isBaselinePending }
            .sorted { lhs, rhs in
                if lhs.user.priority.rank != rhs.user.priority.rank {
                    return lhs.user.priority.rank < rhs.user.priority.rank
                }
                let lhsDate = lhs.posts.first?.createdAt ?? lhs.user.addedAt
                let rhsDate = rhs.posts.first?.createdAt ?? rhs.user.addedAt
                return lhsDate > rhsDate
            }
    }

    /// Posts the relevance model collapsed. Used by the feed's one-line
    /// "filtered" summary and by the account badge copy.
    var collapsedPostCount: Int {
        postsByUID.values.reduce(0) { partial, posts in
            partial + posts.reduce(0) { $0 + ($1.isCollapsedByRelevance ? 1 : 0) }
        }
    }

    var nextCheckDescriptionDate: Date? {
        users
            .filter { $0.enabled }
            .compactMap(\.nextDueAt)
            .min()
    }
}
