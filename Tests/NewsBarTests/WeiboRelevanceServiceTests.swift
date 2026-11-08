import XCTest
@testable import NewsBar

private actor RelevanceFakeFeed: WeiboFeedFetching {
    private var pages: [String: [Int: [WeiboPost]]] = [:]
    private(set) var requests: [(uid: String, page: Int, at: Date)] = []

    func setPage(uid: String, page: Int, posts: [WeiboPost]) {
        pages[uid, default: [:]][page] = posts
    }

    func fetchPage(
        uid: String,
        screenName: String,
        page: Int,
        credentials: WeiboCredentials,
        now: Date
    ) async -> WeiboFetchOutcome {
        requests.append((uid, page, now))
        let posts = pages[uid]?[page] ?? []
        let parsed = WeiboParsedPage(
            posts: posts,
            screenName: "测试博主",
            avatarURL: nil,
            sinceMid: posts.first?.mid,
            rawCount: posts.count,
            dateMissing: false
        )
        return .success(page: parsed, tier: .desktop, latency: 0.01)
    }

    func fetchLongText(mid: String, credentials: WeiboCredentials) async -> String? {
        nil
    }
}

private actor RelevanceFakeNotifier: WeiboAlertNotifying {
    private(set) var notifications: [WeiboAlertNotification] = []

    func send(_ notification: WeiboAlertNotification, language: AppLanguage) async {
        notifications.append(notification)
    }

    func sendAuthExpired(language: AppLanguage) async {}
}

private actor FailingRelevanceDecider: WeiboRelevanceDeciding {
    let providerID = "failing"
    let isLocal = false
    let isFree = true
    private(set) var calls = 0

    func decide(
        text: String,
        context: WeiboDecisionContext
    ) async throws -> WeiboDecisionResult {
        calls += 1
        throw WeiboDecisionError.transport("offline")
    }
}

final class WeiboRelevanceServiceTests: XCTestCase {
    private var root: URL!
    private var store: WeiboMonitorStore!
    private var feed: RelevanceFakeFeed!
    private var notifier: RelevanceFakeNotifier!
    private var service: WeiboMonitorService!

    private var config: WeiboMonitorConfig {
        WeiboMonitorConfig(
            enabled: true,
            notifyEnabled: true,
            p0Seconds: 120,
            p1Seconds: 300,
            p2Seconds: 900,
            nightEnabled: false,
            relevanceEnabled: true,
            relevanceMode: .balanced,
            language: .zh
        )
    }

    private var credentials: WeiboCredentials {
        WeiboCredentials(
            desktopCookieHeader: "SUB=abc; SUBP=def",
            mobileCookieHeader: nil,
            hasDesktopLogin: true,
            hasMobileLogin: false
        )
    }

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeiboRelevanceServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = WeiboMonitorStore(root: root)
        feed = RelevanceFakeFeed()
        notifier = RelevanceFakeNotifier()
        service = makeService()
        await service.start(now: Date(), config: config)
    }

    override func tearDown() async throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        store = nil
        feed = nil
        notifier = nil
        service = nil
        try await super.tearDown()
    }

    private func makeService(
        deciders: [any WeiboRelevanceDeciding] = []
    ) -> WeiboMonitorService {
        WeiboMonitorService(
            store: store,
            feed: feed,
            notifier: notifier,
            relevanceDeciders: deciders,
            rng: WeiboRNG(seed: 42),
            sleeper: { _ in },
            autoFlushAlerts: false,
            changeNotifier: {},
            authAlertRecorder: { _ in }
        )
    }

    private func makePost(
        mid: String,
        text: String,
        createdAt: Date
    ) -> WeiboPost {
        WeiboPost(
            mid: mid,
            bid: "B\(mid)",
            uid: "1234567890",
            screenName: "测试博主",
            text: text,
            createdAt: createdAt,
            fetchedAt: createdAt,
            url: WeiboPost.makeURL(uid: "1234567890", bid: "B\(mid)", mid: mid)
        )
    }

    /// Establishes a one-post baseline so the next fetch has a real "new" post.
    private func primeBaseline(uid: String, now: Date) async {
        let old = makePost(
            mid: "1",
            text: "旧帖",
            createdAt: now.addingTimeInterval(-60)
        )
        await feed.setPage(uid: uid, page: 1, posts: [old])
        await service.tick(
            now: now,
            config: config,
            credentials: credentials,
            isLowPower: false,
            isOnline: true
        )
    }

    private func fetchNewPost(
        uid: String,
        post: WeiboPost,
        now: Date
    ) async {
        let old = makePost(
            mid: "1",
            text: "旧帖",
            createdAt: now.addingTimeInterval(-600)
        )
        await feed.setPage(uid: uid, page: 1, posts: [post, old])
        await service.tick(
            now: now,
            config: config,
            credentials: credentials,
            isLowPower: false,
            isOnline: true
        )
        await service.flushAlerts(now: now.addingTimeInterval(45))
    }

    func testAdIsStoredCollapsedAndNeverNotifies() async throws {
        let now = Date()
        let uid = try XCTUnwrap(WeiboMonitorService.parseUID("https://weibo.com/u/1234567890"))
        _ = try await service.addUser(input: uid, priority: .p0, now: now)
        await primeBaseline(uid: uid, now: now)

        let later = now.addingTimeInterval(120)
        let ad = makePost(
            mid: "2",
            text: "转发+评论，抽 5 位送出【小米 17 Pro】",
            createdAt: later.addingTimeInterval(-30)
        )
        await fetchNewPost(uid: uid, post: ad, now: later)

        let snapshot = await service.snapshot()
        let stored = snapshot.postsByUID[uid]?.first { $0.mid == "2" }
        XCTAssertEqual(stored?.relevance?.verdict, .filtered)
        XCTAssertEqual(snapshot.unreadCount, 0)
        let notifications = await notifier.notifications
        XCTAssertTrue(notifications.isEmpty)
    }

    func testRelevantPostStillNotifies() async throws {
        let now = Date()
        let uid = try XCTUnwrap(WeiboMonitorService.parseUID("https://weibo.com/u/1234567890"))
        _ = try await service.addUser(input: uid, priority: .p0, now: now)
        await primeBaseline(uid: uid, now: now)

        let later = now.addingTimeInterval(120)
        let post = makePost(
            mid: "2",
            text: "小米 17 Pro 独家爆料：7000mAh 电池，120W 充电，6.9 英寸屏幕",
            createdAt: later.addingTimeInterval(-30)
        )
        await fetchNewPost(uid: uid, post: post, now: later)

        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.postsByUID[uid]?.first { $0.mid == "2" }?.relevance?.verdict, .relevant)
        XCTAssertEqual(snapshot.unreadCount, 1)
        let notifications = await notifier.notifications
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.mid, "2")
    }

    func testOffTopicPostIsCollapsedAndDoesNotCountAsUnread() async throws {
        let now = Date()
        let uid = try XCTUnwrap(WeiboMonitorService.parseUID("https://weibo.com/u/1234567890"))
        _ = try await service.addUser(input: uid, priority: .p0, now: now)
        await primeBaseline(uid: uid, now: now)

        let later = now.addingTimeInterval(120)
        let post = makePost(
            mid: "2",
            text: "排队一小时终于吃上了，这家的包子真不错，下次还来",
            createdAt: later.addingTimeInterval(-30)
        )
        await fetchNewPost(uid: uid, post: post, now: later)

        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.postsByUID[uid]?.first { $0.mid == "2" }?.relevance?.verdict, .offTopic)
        XCTAssertEqual(snapshot.unreadCount, 0)
        let notifications = await notifier.notifications
        XCTAssertTrue(notifications.isEmpty)
    }

    func testDisablingTheFilterRestoresTheOldNotificationBehaviour() async throws {
        let now = Date()
        let uid = try XCTUnwrap(WeiboMonitorService.parseUID("https://weibo.com/u/1234567890"))
        _ = try await service.addUser(input: uid, priority: .p0, now: now)
        await primeBaseline(uid: uid, now: now)

        var unfiltered = config
        unfiltered.relevanceEnabled = false
        let later = now.addingTimeInterval(120)
        let ad = makePost(
            mid: "2",
            text: "转发+评论，抽 5 位送出【小米 17 Pro】",
            createdAt: later.addingTimeInterval(-30)
        )
        let old = makePost(
            mid: "1",
            text: "旧帖",
            createdAt: now.addingTimeInterval(-600)
        )
        await feed.setPage(uid: uid, page: 1, posts: [ad, old])
        await service.tick(
            now: later,
            config: unfiltered,
            credentials: credentials,
            isLowPower: false,
            isOnline: true
        )
        await service.flushAlerts(now: later.addingTimeInterval(45))

        let snapshot = await service.snapshot()
        XCTAssertNil(snapshot.postsByUID[uid]?.first { $0.mid == "2" }?.relevance)
        XCTAssertEqual(snapshot.unreadCount, 1)
        let notifications = await notifier.notifications
        XCTAssertEqual(notifications.count, 1)
    }

    func testDecisionModelFailureLeavesTheRuleVerdictInPlace() async throws {
        let now = Date()
        let uid = try XCTUnwrap(WeiboMonitorService.parseUID("https://weibo.com/u/1234567890"))
        let decider = FailingRelevanceDecider()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeiboRelevanceServiceAITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let aiService = WeiboMonitorService(
            store: WeiboMonitorStore(root: root),
            feed: feed,
            notifier: notifier,
            relevanceDeciders: [decider],
            rng: WeiboRNG(seed: 42),
            sleeper: { _ in },
            autoFlushAlerts: false,
            changeNotifier: {},
            authAlertRecorder: { _ in }
        )
        var aiConfig = config
        aiConfig.relevanceAICorrection = true
        await aiService.start(now: now, config: aiConfig)
        _ = try await aiService.addUser(input: uid, priority: .p0, now: now)

        let old = makePost(mid: "1", text: "旧帖", createdAt: now.addingTimeInterval(-60))
        await feed.setPage(uid: uid, page: 1, posts: [old])
        await aiService.tick(
            now: now,
            config: aiConfig,
            credentials: credentials,
            isLowPower: false,
            isOnline: true
        )

        let later = now.addingTimeInterval(120)
        let post = makePost(
            mid: "2",
            text: "排队一小时终于吃上了，这家的包子真不错，下次还来",
            createdAt: later.addingTimeInterval(-30)
        )
        await feed.setPage(uid: uid, page: 1, posts: [post, old])
        await aiService.tick(
            now: later,
            config: aiConfig,
            credentials: credentials,
            isLowPower: false,
            isOnline: true
        )

        let snapshot = await aiService.snapshot()
        XCTAssertEqual(
            snapshot.postsByUID[uid]?.first { $0.mid == "2" }?.relevance?.verdict,
            .offTopic
        )
        XCTAssertEqual(
            snapshot.postsByUID[uid]?.first { $0.mid == "2" }?.relevance?.decider,
            "rules"
        )
        let calls = await decider.calls
        XCTAssertGreaterThan(calls, 0, "the decider should have been tried")
    }

    func testChangingTheModeReevaluatesStoredPosts() async throws {
        let now = Date()
        let uid = try XCTUnwrap(WeiboMonitorService.parseUID("https://weibo.com/u/1234567890"))
        _ = try await service.addUser(input: uid, priority: .p0, now: now)
        await primeBaseline(uid: uid, now: now)

        let later = now.addingTimeInterval(120)
        let post = makePost(
            mid: "2",
            text: "新机开箱在这里：https://item.taobao.com/item.htm?id=1",
            createdAt: later.addingTimeInterval(-30)
        )
        await fetchNewPost(uid: uid, post: post, now: later)

        var snapshot = await service.snapshot()
        XCTAssertEqual(
            snapshot.postsByUID[uid]?.first { $0.mid == "2" }?.relevance?.verdict,
            .lowConfidence
        )

        var strict = config
        strict.relevanceMode = .strict
        let next = later.addingTimeInterval(120)
        await service.tick(
            now: next,
            config: strict,
            credentials: credentials,
            isLowPower: false,
            isOnline: true
        )
        snapshot = await service.snapshot()
        XCTAssertEqual(
            snapshot.postsByUID[uid]?.first { $0.mid == "2" }?.relevance?.verdict,
            .filtered
        )
    }

    func testAccountOverrideAlwaysShowClearsTheVerdict() async throws {
        let now = Date()
        let uid = try XCTUnwrap(WeiboMonitorService.parseUID("https://weibo.com/u/1234567890"))
        _ = try await service.addUser(input: uid, priority: .p0, now: now)
        await primeBaseline(uid: uid, now: now)

        let later = now.addingTimeInterval(120)
        let post = makePost(
            mid: "2",
            text: "排队一小时终于吃上了，这家的包子真不错，下次还来",
            createdAt: later.addingTimeInterval(-30)
        )
        await fetchNewPost(uid: uid, post: post, now: later)

        await service.setRelevanceMode(uid: uid, mode: .off, now: later)
        let snapshot = await service.snapshot()
        XCTAssertNil(snapshot.postsByUID[uid]?.first { $0.mid == "2" }?.relevance)
    }
}
