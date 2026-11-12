import XCTest
@testable import NewsBar

private actor FakeCommentFetcher: WeiboCommentFetching {
    private var outcomes: [String: WeiboCommentOutcome] = [:]
    private(set) var requests: [(mid: String, cursor: String?)] = []

    private func key(_ mid: String, _ cursor: String?) -> String {
        "\(mid)|\(cursor ?? "")"
    }

    func setOutcome(mid: String, cursor: String?, outcome: WeiboCommentOutcome) {
        outcomes[key(mid, cursor)] = outcome
    }

    func fetchComments(
        mid: String,
        uid: String,
        authorUID: String?,
        cursor: String?,
        credentials: WeiboCredentials,
        now: Date
    ) async -> WeiboCommentOutcome {
        requests.append((mid, cursor))
        return outcomes[key(mid, cursor)] ?? .failure(.unknown)
    }

    var requestCount: Int { requests.count }
}

@MainActor
final class WeiboCommentControllerTests: XCTestCase {
    private var root: URL!
    private var cache: WeiboCommentCache!
    private var fetcher: FakeCommentFetcher!
    private var controller: WeiboCommentController!
    private let now = WeiboMonitorTestSupport.date(2026, 11, 12, 12, 0)

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeiboCommentControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cache = WeiboCommentCache(root: root)
        fetcher = FakeCommentFetcher()
        controller = WeiboCommentController(
            fetcher: fetcher,
            cache: cache,
            cacheFreshness: 10 * 60,
            minimumRequestInterval: 0
        )
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        cache = nil
        fetcher = nil
        controller = nil
        try await super.tearDown()
    }

    private func post(mid: String = "9001") -> WeiboPost {
        WeiboPost(
            mid: mid,
            bid: nil,
            uid: "77",
            screenName: "作者",
            text: "正文",
            createdAt: now,
            fetchedAt: now,
            url: WeiboPost.makeURL(uid: "77", bid: nil, mid: mid)
        )
    }

    private func page(
        mid: String,
        ids: [String],
        total: Int?,
        cursor: String?,
        fetchedAt: Date? = nil
    ) -> WeiboCommentPage {
        let date = fetchedAt ?? now
        let comments = ids.enumerated().map { index, id in
            WeiboComment(
                id: id,
                mid: mid,
                uid: "\(index + 1)",
                screenName: "读者\(index)",
                avatarURL: nil,
                text: "评论 \(id)",
                createdAt: date.addingTimeInterval(TimeInterval(-index)),
                likeCount: index,
                replyToName: nil,
                isAuthor: false
            )
        }
        return WeiboCommentPage(
            comments: comments,
            total: total,
            nextCursor: cursor,
            fetchedAt: date,
            tier: .desktop
        )
    }

    func testLoadFetchesFirstPageAndCachesIt() async {
        await fetcher.setOutcome(
            mid: "9001",
            cursor: nil,
            outcome: .success(page: page(mid: "9001", ids: ["a", "b"], total: 2, cursor: "next"), latency: 0.01)
        )

        await controller.load(post: post(), credentials: .none)

        let thread = controller.thread(for: "9001")
        XCTAssertEqual(thread.state, .loaded)
        XCTAssertEqual(thread.comments.map(\.id), ["a", "b"])
        XCTAssertEqual(thread.total, 2)
        XCTAssertEqual(thread.pagesLoaded, 1)
        let requestCount = await fetcher.requestCount
        let cachedCount = await cache.load(mid: "9001")?.page.comments.count
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(cachedCount, 2)
    }

    func testFreshCacheSkipsNetwork() async {
        let cached = page(mid: "9001", ids: ["a"], total: 1, cursor: nil, fetchedAt: Date())
        await cache.save(mid: "9001", thread: CachedWeiboCommentThread(page: cached, pagesLoaded: 1))

        await controller.load(post: post(), credentials: .none)

        XCTAssertEqual(controller.thread(for: "9001").comments.map(\.id), ["a"])
        let requestCount = await fetcher.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testAuthRequiredState() async {
        await fetcher.setOutcome(mid: "9001", cursor: nil, outcome: .failure(.authRequired))
        await controller.load(post: post(), credentials: .none)
        XCTAssertEqual(controller.thread(for: "9001").state, .authRequired)
    }

    func testRateLimitCooldownBlocksRepeatedLoad() async {
        await fetcher.setOutcome(
            mid: "9001",
            cursor: nil,
            outcome: .failure(.rateLimited(retryAfter: 60))
        )
        await controller.load(post: post(), credentials: .none)
        guard case .rateLimited = controller.thread(for: "9001").state else {
            return XCTFail("expected rate-limited state")
        }

        await controller.load(post: post(), credentials: .none)
        let requestCount = await fetcher.requestCount
        XCTAssertEqual(requestCount, 1, "A cooldown must prevent a second request")
    }

    func testLoadMoreAppendsAndDeduplicates() async {
        await fetcher.setOutcome(
            mid: "9001",
            cursor: nil,
            outcome: .success(page: page(mid: "9001", ids: ["a"], total: 2, cursor: "2"), latency: 0.01)
        )
        await fetcher.setOutcome(
            mid: "9001",
            cursor: "2",
            outcome: .success(page: page(mid: "9001", ids: ["a", "b"], total: 2, cursor: nil), latency: 0.01)
        )

        await controller.load(post: post(), credentials: .none)
        await controller.loadMore(post: post(), credentials: .none)

        let thread = controller.thread(for: "9001")
        XCTAssertEqual(thread.comments.map(\.id), ["a", "b"])
        XCTAssertEqual(thread.pagesLoaded, 2)
        let requestCount = await fetcher.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    func testSuccessfulEmptyPageShowsEmpty() async {
        await fetcher.setOutcome(
            mid: "9001",
            cursor: nil,
            outcome: .success(page: page(mid: "9001", ids: [], total: 0, cursor: nil), latency: 0.01)
        )
        await controller.load(post: post(), credentials: .none)
        XCTAssertEqual(controller.thread(for: "9001").state, .empty)
    }

    func testRefreshQueuesNewCommentsWithoutMovingVisibleRows() async {
        await fetcher.setOutcome(
            mid: "9001",
            cursor: nil,
            outcome: .success(page: page(mid: "9001", ids: ["a"], total: 1, cursor: nil), latency: 0.01)
        )
        await controller.load(post: post(), credentials: .none)

        await fetcher.setOutcome(
            mid: "9001",
            cursor: nil,
            outcome: .success(page: page(mid: "9001", ids: ["new", "a"], total: 2, cursor: nil), latency: 0.01)
        )
        await controller.load(post: post(), credentials: .none, force: true)

        var thread = controller.thread(for: "9001")
        XCTAssertEqual(thread.comments.map(\.id), ["a"], "Visible rows stay put during a refresh")
        XCTAssertEqual(thread.pendingComments.map(\.id), ["new"])
        XCTAssertEqual(thread.newComments, 1)

        await controller.applyPending(mid: "9001")
        thread = controller.thread(for: "9001")
        XCTAssertEqual(thread.comments.map(\.id), ["new", "a"])
        XCTAssertEqual(thread.newComments, 0)
    }

    func testRefreshFailureKeepsVisibleRowsAndReportsInline() async {
        await fetcher.setOutcome(
            mid: "9001",
            cursor: nil,
            outcome: .success(page: page(mid: "9001", ids: ["a"], total: 1, cursor: nil), latency: 0.01)
        )
        await controller.load(post: post(), credentials: .none)

        await fetcher.setOutcome(mid: "9001", cursor: nil, outcome: .failure(.network))
        await controller.load(post: post(), credentials: .none, force: true)

        let thread = controller.thread(for: "9001")
        XCTAssertEqual(thread.state, .loaded)
        XCTAssertEqual(thread.comments.map(\.id), ["a"])
        XCTAssertEqual(thread.loadMoreError, .network)
    }

    func testStaleCacheRefreshesUnderneath() async {
        let stale = page(
            mid: "9001",
            ids: ["old"],
            total: 1,
            cursor: nil,
            fetchedAt: now.addingTimeInterval(-20 * 60)
        )
        await cache.save(mid: "9001", thread: CachedWeiboCommentThread(page: stale, pagesLoaded: 1))
        await fetcher.setOutcome(
            mid: "9001",
            cursor: nil,
            outcome: .success(page: page(mid: "9001", ids: ["new", "old"], total: 2, cursor: nil), latency: 0.01)
        )

        await controller.load(post: post(), credentials: .none)

        let thread = controller.thread(for: "9001")
        let requestCount = await fetcher.requestCount
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(thread.comments.map(\.id), ["old"])
        XCTAssertEqual(thread.pendingComments.map(\.id), ["new"])
        XCTAssertEqual(thread.total, 2)
    }
}
