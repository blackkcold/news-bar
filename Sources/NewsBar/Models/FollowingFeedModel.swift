import Foundation

/// One following post joined with its account. The waterfall card needs both
/// the post body and the account identity (avatar, display name, priority),
/// so the join happens once in the model instead of in every card.
struct FollowingPostEntry: Identifiable, Equatable, Sendable {
    let post: WeiboPost
    let user: WeiboMonitorUser

    var id: String { post.mid }
}

/// The standalone following page's filter state. `includeCollapsed` mirrors
/// the relevance setting: when filtering is off there is nothing collapsed,
/// and when it is on the view keeps the collapsed section as an explicit
/// escape hatch.
struct FollowingFeedQuery: Equatable, Sendable {
    var filter: WeiboFollowingFilter = .all
    var accountUID: String? = nil
    var searchText: String = ""
    var includeCollapsed: Bool = false
}

/// Pure filtering/selection for every following surface: the standalone
/// waterfall, the "关注动态" recommendation block and the sidebar card.
enum FollowingFeedModel {
    static func entries(
        snapshot: WeiboMonitorSnapshot,
        query: FollowingFeedQuery
    ) -> [FollowingPostEntry] {
        let users = Dictionary(uniqueKeysWithValues: snapshot.users.map { ($0.uid, $0) })
        let search = normalized(query.searchText)
        let includesCollapsed = query.filter != .unread
            && (query.includeCollapsed || !search.isEmpty)

        var result: [FollowingPostEntry] = []
        for (uid, posts) in snapshot.postsByUID {
            guard let user = users[uid] else { continue }
            if query.filter == .p0, user.priority != .p0 { continue }
            if let accountUID = query.accountUID, accountUID != uid { continue }

            for post in posts {
                if query.filter == .unread {
                    guard !post.read, !post.isCollapsedByRelevance else { continue }
                } else if post.isCollapsedByRelevance, !includesCollapsed {
                    continue
                }
                if !search.isEmpty, !matches(post, user: user, search: search) {
                    continue
                }
                result.append(FollowingPostEntry(post: post, user: user))
            }
        }

        return result.sorted(by: newestFirst)
    }

    static func recentEntries(
        snapshot: WeiboMonitorSnapshot,
        limit: Int,
        includeCollapsed: Bool = false
    ) -> [FollowingPostEntry] {
        guard limit > 0 else { return [] }
        let users = Dictionary(uniqueKeysWithValues: snapshot.users.map { ($0.uid, $0) })
        var result: [FollowingPostEntry] = []
        for (uid, posts) in snapshot.postsByUID {
            guard let user = users[uid] else { continue }
            for post in posts where includeCollapsed || !post.isCollapsedByRelevance {
                result.append(FollowingPostEntry(post: post, user: user))
            }
        }
        return Array(result.sorted(by: newestFirst).prefix(limit))
    }

    static func unreadCount(
        snapshot: WeiboMonitorSnapshot,
        query: FollowingFeedQuery
    ) -> Int {
        entries(snapshot: snapshot, query: query).reduce(0) {
            $0 + ($1.post.read ? 0 : 1)
        }
    }

    /// The relevance-collapsed block stays outside the waterfall. Search
    /// intentionally searches through collapsed posts instead, so a
    /// half-remembered post is never unreachable; in that case this returns
    /// empty and the searchable waterfall carries the collapsed matches.
    static func collapsedPosts(
        snapshot: WeiboMonitorSnapshot,
        query: FollowingFeedQuery
    ) -> [WeiboPost] {
        guard query.filter != .unread, normalized(query.searchText).isEmpty else { return [] }
        let users = Dictionary(uniqueKeysWithValues: snapshot.users.map { ($0.uid, $0) })
        var result: [WeiboPost] = []
        for (uid, posts) in snapshot.postsByUID {
            guard let user = users[uid] else { continue }
            if query.filter == .p0, user.priority != .p0 { continue }
            if let accountUID = query.accountUID, accountUID != uid { continue }
            result.append(contentsOf: posts.filter(\.isCollapsedByRelevance))
        }
        return result.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.mid > rhs.mid
        }
    }

    private static func matches(
        _ post: WeiboPost,
        user: WeiboMonitorUser,
        search: String
    ) -> Bool {
        post.displayText.localizedCaseInsensitiveContains(search)
            || post.screenName.localizedCaseInsensitiveContains(search)
            || user.screenName.localizedCaseInsensitiveContains(search)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func newestFirst(_ lhs: FollowingPostEntry, _ rhs: FollowingPostEntry) -> Bool {
        if lhs.post.createdAt != rhs.post.createdAt {
            return lhs.post.createdAt > rhs.post.createdAt
        }
        return lhs.post.mid > rhs.post.mid
    }
}
