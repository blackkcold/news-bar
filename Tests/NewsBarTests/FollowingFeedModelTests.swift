import XCTest
@testable import NewsBar

final class FollowingFeedModelTests: XCTestCase {
    private let now = WeiboMonitorTestSupport.date(2026, 11, 9, 12, 0)

    private func snapshot(
        users: [WeiboMonitorUser],
        posts: [String: [WeiboPost]]
    ) -> WeiboMonitorSnapshot {
        var snapshot = WeiboMonitorSnapshot()
        snapshot.users = users
        snapshot.postsByUID = posts
        snapshot.unreadCount = posts.values
            .flatMap { $0 }
            .filter { !$0.read && !$0.isCollapsedByRelevance }
            .count
        snapshot.isEnabled = true
        snapshot.loginState = .loggedIn
        return snapshot
    }

    private func collapsedPost(
        mid: String,
        uid: String,
        name: String,
        text: String,
        createdAt: Date
    ) -> WeiboPost {
        var post = WeiboMonitorTestSupport.post(
            mid: mid,
            uid: uid,
            name: name,
            text: text,
            createdAt: createdAt
        )
        post.relevance = WeiboPostRelevance(
            adScore: 0.1,
            interestScore: 0.1,
            verdict: .filtered,
            reasons: ["mediaStructure"],
            decidedAt: createdAt
        )
        return post
    }

    func testEntriesFilterByAccountReadAndPriority() {
        let userA = WeiboMonitorTestSupport.user(uid: "1", name: "A", priority: .p0, now: now)
        let userB = WeiboMonitorTestSupport.user(uid: "2", name: "B", priority: .p1, now: now)
        let a1 = WeiboMonitorTestSupport.post(mid: "a1", uid: "1", name: "A", text: "A1", createdAt: now.addingTimeInterval(-10), read: false)
        let a2 = WeiboMonitorTestSupport.post(mid: "a2", uid: "1", name: "A", text: "A2", createdAt: now.addingTimeInterval(-20), read: true)
        let b1 = WeiboMonitorTestSupport.post(mid: "b1", uid: "2", name: "B", text: "B1", createdAt: now.addingTimeInterval(-30), read: false)
        let snapshot = snapshot(users: [userA, userB], posts: ["1": [a2, a1], "2": [b1]])

        let all = FollowingFeedModel.entries(
            snapshot: snapshot,
            query: FollowingFeedQuery()
        )
        XCTAssertEqual(all.map(\.post.mid), ["a1", "a2", "b1"])

        let unread = FollowingFeedModel.entries(
            snapshot: snapshot,
            query: FollowingFeedQuery(filter: .unread)
        )
        XCTAssertEqual(unread.map(\.post.mid), ["a1", "b1"])

        let p0 = FollowingFeedModel.entries(
            snapshot: snapshot,
            query: FollowingFeedQuery(filter: .p0)
        )
        XCTAssertEqual(p0.map(\.post.mid), ["a1", "a2"])

        let accountB = FollowingFeedModel.entries(
            snapshot: snapshot,
            query: FollowingFeedQuery(accountUID: "2")
        )
        XCTAssertEqual(accountB.map(\.post.mid), ["b1"])
    }

    func testSearchSeesCollapsedPostsButNormalFeedHidesThem() {
        let user = WeiboMonitorTestSupport.user(uid: "1", name: "A", priority: .p1, now: now)
        let visible = WeiboMonitorTestSupport.post(mid: "v", uid: "1", name: "A", text: "visible", createdAt: now.addingTimeInterval(-10))
        let hidden = collapsedPost(
            mid: "h",
            uid: "1",
            name: "A",
            text: "hidden keyword",
            createdAt: now.addingTimeInterval(-20)
        )
        let snapshot = snapshot(users: [user], posts: ["1": [visible, hidden]])

        let normal = FollowingFeedModel.entries(
            snapshot: snapshot,
            query: FollowingFeedQuery(filter: .all)
        )
        XCTAssertEqual(normal.map(\.post.mid), ["v"])

        let search = FollowingFeedModel.entries(
            snapshot: snapshot,
            query: FollowingFeedQuery(searchText: "hidden")
        )
        XCTAssertEqual(search.map(\.post.mid), ["h"])
    }

    func testCollapsedPostsRespectFilterAndSearch() {
        let user = WeiboMonitorTestSupport.user(uid: "1", name: "A", priority: .p0, now: now)
        let visible = WeiboMonitorTestSupport.post(mid: "v", uid: "1", name: "A", text: "visible", createdAt: now.addingTimeInterval(-10))
        let hidden = collapsedPost(
            mid: "h",
            uid: "1",
            name: "A",
            text: "hidden",
            createdAt: now.addingTimeInterval(-20)
        )
        let snapshot = snapshot(users: [user], posts: ["1": [visible, hidden]])

        XCTAssertEqual(
            FollowingFeedModel.collapsedPosts(snapshot: snapshot, query: FollowingFeedQuery()).map(\.mid),
            ["h"]
        )
        XCTAssertTrue(
            FollowingFeedModel.collapsedPosts(
                snapshot: snapshot,
                query: FollowingFeedQuery(filter: .unread)
            ).isEmpty
        )
        XCTAssertTrue(
            FollowingFeedModel.collapsedPosts(
                snapshot: snapshot,
                query: FollowingFeedQuery(searchText: "hidden")
            ).isEmpty
        )
    }

    func testRecentEntriesSortsLimitsAndCanIncludeCollapsed() {
        let userA = WeiboMonitorTestSupport.user(uid: "1", name: "A", priority: .p0, now: now)
        let userB = WeiboMonitorTestSupport.user(uid: "2", name: "B", priority: .p1, now: now)
        let a = WeiboMonitorTestSupport.post(mid: "a", uid: "1", name: "A", text: "a", createdAt: now.addingTimeInterval(-60))
        let b = WeiboMonitorTestSupport.post(mid: "b", uid: "2", name: "B", text: "b", createdAt: now.addingTimeInterval(-30))
        let hidden = collapsedPost(
            mid: "h",
            uid: "1",
            name: "A",
            text: "h",
            createdAt: now.addingTimeInterval(-10)
        )
        let snapshot = snapshot(users: [userA, userB], posts: ["1": [a, hidden], "2": [b]])

        let recent = FollowingFeedModel.recentEntries(snapshot: snapshot, limit: 2)
        XCTAssertEqual(recent.map(\.post.mid), ["b", "a"])

        let withCollapsed = FollowingFeedModel.recentEntries(
            snapshot: snapshot,
            limit: 3,
            includeCollapsed: true
        )
        XCTAssertEqual(withCollapsed.map(\.post.mid), ["h", "b", "a"])
    }

    func testUnreadCountUsesVisibleEntries() {
        let user = WeiboMonitorTestSupport.user(uid: "1", name: "A", priority: .p0, now: now)
        let unread = WeiboMonitorTestSupport.post(mid: "u", uid: "1", name: "A", text: "u", createdAt: now, read: false)
        let read = WeiboMonitorTestSupport.post(mid: "r", uid: "1", name: "A", text: "r", createdAt: now.addingTimeInterval(-1), read: true)
        let snapshot = snapshot(users: [user], posts: ["1": [unread, read]])

        XCTAssertEqual(
            FollowingFeedModel.unreadCount(snapshot: snapshot, query: FollowingFeedQuery()),
            1
        )
        XCTAssertEqual(
            FollowingFeedModel.unreadCount(
                snapshot: snapshot,
                query: FollowingFeedQuery(filter: .unread)
            ),
            1
        )
    }

    /// Search re-runs `contents` on every keystroke. Measure it on a large
    /// snapshot so a future change cannot quietly turn typing into a stall; the
    /// bound is loose because this runs in a debug test build.
    func testContentsSearchCostStaysUnderAFrameBudgetForAThousandPosts() {
        let user = WeiboMonitorTestSupport.user(uid: "1", name: "A", priority: .p1, now: now)
        let posts = (0..<1_000).map { index in
            WeiboMonitorTestSupport.post(
                mid: "m\(index)",
                uid: "1",
                name: "A",
                text: "第\(index)条正文，包含一些中英文 mixed content",
                createdAt: now.addingTimeInterval(TimeInterval(-index))
            )
        }
        let snapshot = snapshot(users: [user], posts: ["1": posts])
        let query = FollowingFeedQuery(searchText: "mixed")

        var best = TimeInterval.greatestFiniteMagnitude
        for _ in 0..<5 {
            let start = Date()
            let contents = FollowingFeedModel.contents(snapshot: snapshot, query: query)
            best = min(best, Date().timeIntervalSince(start))
            XCTAssertEqual(contents.entries.count, 1_000)
        }
        print("PERF following-contents 1000 posts, debug: \(Int(best * 1000)) ms")
        XCTAssertLessThan(best, 0.25)
    }

    func testEmptySnapshotIsSafe() {
        let snapshot = WeiboMonitorSnapshot()
        XCTAssertTrue(FollowingFeedModel.entries(snapshot: snapshot, query: FollowingFeedQuery()).isEmpty)
        XCTAssertTrue(FollowingFeedModel.recentEntries(snapshot: snapshot, limit: 5).isEmpty)
        XCTAssertEqual(FollowingFeedModel.unreadCount(snapshot: snapshot, query: FollowingFeedQuery()), 0)
        XCTAssertTrue(FollowingFeedModel.collapsedPosts(snapshot: snapshot, query: FollowingFeedQuery()).isEmpty)
        XCTAssertTrue(FollowingFeedModel.contents(snapshot: snapshot, query: FollowingFeedQuery()).entries.isEmpty)
    }

    /// The page builds its rows, its count and its collapsed block from one
    /// scan. These expectations are written out by hand rather than compared
    /// with the delegating wrappers, so the combined pass is pinned on its own.
    func testContentsPinsEveryQueryCombination() {
        let userA = WeiboMonitorTestSupport.user(uid: "1", name: "A", priority: .p0, now: now)
        let userB = WeiboMonitorTestSupport.user(uid: "2", name: "B", priority: .p1, now: now)
        let a1 = WeiboMonitorTestSupport.post(mid: "a1", uid: "1", name: "A", text: "A1 visible", createdAt: now.addingTimeInterval(-10))
        let a2 = WeiboMonitorTestSupport.post(mid: "a2", uid: "1", name: "A", text: "A2 read", createdAt: now.addingTimeInterval(-20), read: true)
        let a3 = collapsedPost(mid: "a3", uid: "1", name: "A", text: "A3 hidden", createdAt: now.addingTimeInterval(-30))
        let b1 = WeiboMonitorTestSupport.post(mid: "b1", uid: "2", name: "B", text: "B1 visible", createdAt: now.addingTimeInterval(-40))
        let b2 = collapsedPost(mid: "b2", uid: "2", name: "B", text: "B2 hidden", createdAt: now.addingTimeInterval(-50))
        let snapshot = snapshot(users: [userA, userB], posts: ["1": [a1, a3, a2], "2": [b1, b2]])

        let cases: [(FollowingFeedQuery, [String], [String])] = [
            (FollowingFeedQuery(), ["a1", "a2", "b1"], ["a3", "b2"]),
            (FollowingFeedQuery(filter: .unread), ["a1", "b1"], []),
            (FollowingFeedQuery(filter: .p0), ["a1", "a2"], ["a3"]),
            (FollowingFeedQuery(accountUID: "2"), ["b1"], ["b2"]),
            (FollowingFeedQuery(searchText: "hidden"), ["a3", "b2"], []),
            (FollowingFeedQuery(searchText: "B2"), ["b2"], []),
            (FollowingFeedQuery(filter: .p0, searchText: "visible"), ["a1"], []),
            (FollowingFeedQuery(includeCollapsed: true),
             ["a1", "a2", "a3", "b1", "b2"], ["a3", "b2"]),
            (FollowingFeedQuery(filter: .unread, searchText: "hidden"), [], []),
            (FollowingFeedQuery(accountUID: "1", includeCollapsed: true),
             ["a1", "a2", "a3"], ["a3"]),
        ]

        for (query, expectedEntries, expectedCollapsed) in cases {
            let contents = FollowingFeedModel.contents(snapshot: snapshot, query: query)
            XCTAssertEqual(
                contents.entries.map(\.post.mid),
                expectedEntries,
                "entries diverged for \(query)"
            )
            XCTAssertEqual(
                contents.collapsedPosts.map(\.mid),
                expectedCollapsed,
                "collapsed posts diverged for \(query)"
            )
        }
    }
}
