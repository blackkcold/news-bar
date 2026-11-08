import XCTest
@testable import NewsBar

private actor FakeWeiboFeed: WeiboFeedFetching {
    private var pages: [String: [Int: [WeiboPost]]] = [:]
    private var forcedOutcome: WeiboFetchOutcome?
    private(set) var requests: [(uid: String, page: Int, at: Date)] = []
    private var longTexts: [String: String] = [:]
    private var missingDateKeys: Set<String> = []

    func setPage(uid: String, page: Int, posts: [WeiboPost]) {
        pages[uid, default: [:]][page] = posts
    }

    func setDateMissing(uid: String, page: Int) {
        missingDateKeys.insert("\(uid):\(page)")
    }

    func setOutcome(_ outcome: WeiboFetchOutcome?) {
        forcedOutcome = outcome
    }

    func setLongText(mid: String, text: String) {
        longTexts[mid] = text
    }

    func fetchPage(
        uid: String,
        screenName: String,
        page: Int,
        credentials: WeiboCredentials,
        now: Date
    ) async -> WeiboFetchOutcome {
        requests.append((uid, page, now))
        if let forcedOutcome { return forcedOutcome }
        let posts = pages[uid]?[page] ?? []
        let parsed = WeiboParsedPage(
            posts: posts,
            screenName: "测试博主",
            avatarURL: nil,
            sinceMid: posts.first?.mid,
            rawCount: posts.count,
            dateMissing: missingDateKeys.contains("\(uid):\(page)")
        )
        return .success(page: parsed, tier: .desktop, latency: 0.01)
    }

    func fetchLongText(mid: String, credentials: WeiboCredentials) async -> String? {
        longTexts[mid]
    }

    var requestCount: Int { requests.count }
}

private actor FakeWeiboNotifier: WeiboAlertNotifying {
    private(set) var notifications: [WeiboAlertNotification] = []
    private(set) var authAlerts = 0

    func send(_ notification: WeiboAlertNotification, language: AppLanguage) async {
        notifications.append(notification)
    }

    func sendAuthExpired(language: AppLanguage) async {
        authAlerts += 1
    }
}

final class WeiboMonitorServiceTests: XCTestCase {
    private var root: URL!
    private var store: WeiboMonitorStore!
    private var feed: FakeWeiboFeed!
    private var notifier: FakeWeiboNotifier!
    private var service: WeiboMonitorService!

    private var config: WeiboMonitorConfig {
        WeiboMonitorConfig(
            enabled: true,
            notifyEnabled: true,
            p0Seconds: 120,
            p1Seconds: 300,
            p2Seconds: 900,
            nightEnabled: false,
            // These tests cover the pre-filter notification rules. Relevance
            // filtering has its own suite.
            relevanceEnabled: false,
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
            .appendingPathComponent("WeiboMonitorServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = WeiboMonitorStore(root: root)
        feed = FakeWeiboFeed()
        notifier = FakeWeiboNotifier()
        service = WeiboMonitorService(
            store: store,
            feed: feed,
            notifier: notifier,
            planner: WeiboPollPlanner(calendar: WeiboMonitorTestSupport.calendar),
            alertPolicy: WeiboAlertPolicy(calendar: WeiboMonitorTestSupport.calendar),
            rng: WeiboRNG(seed: 42),
            sleeper: { _ in },
            autoFlushAlerts: false,
            changeNotifier: {},
            authAlertRecorder: { _ in }
        )
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

    private func uid() throws -> String {
        try XCTUnwrap(WeiboMonitorService.parseUID("https://weibo.com/u/1234567890"))
    }

    private func makePost(
        mid: String,
        text: String,
        createdAt: Date,
        isTop: Bool = false,
        isLongText: Bool = false
    ) -> WeiboPost {
        WeiboPost(
            mid: mid,
            bid: "B\(mid)",
            uid: "1234567890",
            screenName: "测试博主",
            text: text,
            createdAt: createdAt,
            fetchedAt: createdAt,
            isLongText: isLongText,
            url: WeiboPost.makeURL(uid: "1234567890", bid: "B\(mid)", mid: mid),
            isTop: isTop
        )
    }

    func testFirstBaselineIsReadAndDoesNotNotify() async throws {
        let now = Date()
        let uid = try uid()
        _ = try await service.addUser(input: uid, priority: .p0, now: now)
        await feed.setPage(
            uid: uid,
            page: 1,
            posts: [makePost(mid: "1", text: "旧帖", createdAt: now.addingTimeInterval(-60))]
        )

        await service.tick(
            now: now, config: config, credentials: credentials, isLowPower: false, isOnline: true
        )
        let snapshot = await service.snapshot()

        XCTAssertEqual(snapshot.postsByUID[uid]?.count, 1)
        XCTAssertEqual(snapshot.unreadCount, 0)
        let notifications = await notifier.notifications
        XCTAssertTrue(notifications.isEmpty)
    }

    func testNewPostBecomesUnreadAndNotifiesOnce() async throws {
        let now = Date()
        let uid = try uid()
        _ = try await service.addUser(input: uid, priority: .p0, now: now)
        let old = makePost(mid: "1", text: "旧帖", createdAt: now.addingTimeInterval(-60))
        await feed.setPage(uid: uid, page: 1, posts: [old])
        await service.tick(
            now: now, config: config, credentials: credentials, isLowPower: false, isOnline: true
        )

        let later = now.addingTimeInterval(120)
        let new = makePost(mid: "2", text: "新的爆料", createdAt: later.addingTimeInterval(-30))
        await feed.setPage(uid: uid, page: 1, posts: [new, old])
        await service.tick(
            now: later, config: config, credentials: credentials, isLowPower: false, isOnline: true
        )

        var snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.unreadCount, 1)
        await service.flushAlerts(now: later.addingTimeInterval(45))
        var notifications = await notifier.notifications
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.mid, "2")

        // A second fetch of the same page must not duplicate the notification.
        let next = later.addingTimeInterval(120)
        await service.tick(
            now: next, config: config, credentials: credentials, isLowPower: false, isOnline: true
        )
        await service.flushAlerts(now: next.addingTimeInterval(45))
        notifications = await notifier.notifications
        XCTAssertEqual(notifications.count, 1)
        snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.unreadCount, 1)
    }

    func testPinnedOldPostIsNotTreatedAsNew() async throws {
        let now = Date()
        let uid = try uid()
        _ = try await service.addUser(input: uid, priority: .p0, now: now)
        let old = makePost(mid: "1", text: "旧帖", createdAt: now.addingTimeInterval(-60))
        await feed.setPage(uid: uid, page: 1, posts: [old])
        await service.tick(
            now: now, config: config, credentials: credentials, isLowPower: false, isOnline: true
        )

        let later = now.addingTimeInterval(120)
        let pinned = makePost(
            mid: "old-top",
            text: "置顶老帖",
            createdAt: now.addingTimeInterval(-2 * 3600),
            isTop: true
        )
        await feed.setPage(uid: uid, page: 1, posts: [pinned, old])
        await service.tick(
            now: later, config: config, credentials: credentials, isLowPower: false, isOnline: true
        )
        await service.flushAlerts(now: later.addingTimeInterval(45))

        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.unreadCount, 0)
        let notifications = await notifier.notifications
        XCTAssertTrue(notifications.isEmpty)
    }

    func testLongGapQueuesOnlyOneNotificationAndMarksGap() async throws {
        let now = Date()
        let uid = try uid()
        _ = try await service.addUser(input: uid, priority: .p0, now: now)
        let old = makePost(mid: "1", text: "旧帖", createdAt: now.addingTimeInterval(-60))
        await feed.setPage(uid: uid, page: 1, posts: [old])
        await service.tick(
            now: now, config: config, credentials: credentials, isLowPower: false, isOnline: true
        )

        let muchLater = now.addingTimeInterval(8 * 3600)
        let firstNew = makePost(
            mid: "2",
            text: "睡醒后的第一条",
            createdAt: muchLater.addingTimeInterval(-600)
        )
        let secondNew = makePost(
            mid: "3",
            text: "睡醒后的第二条",
            createdAt: muchLater.addingTimeInterval(-300)
        )
        await feed.setPage(uid: uid, page: 1, posts: [secondNew, firstNew])
        await feed.setPage(uid: uid, page: 2, posts: [])
        await service.tick(
            now: muchLater, config: config, credentials: credentials, isLowPower: false, isOnline: true
        )
        await service.flushAlerts(now: muchLater.addingTimeInterval(45))

        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.unreadCount, 2)
        XCTAssertTrue(snapshot.users.first?.gapSuspected == true)
        let notifications = await notifier.notifications
        XCTAssertTrue(notifications.isEmpty, "a lost baseline must not backfill")
    }

    func testLongGapWithBaselineFoundQueuesOneNotification() async throws {
        let now = Date()
        let uid = try uid()
        _ = try await service.addUser(input: uid, priority: .p0, now: now)
        let old = makePost(mid: "1", text: "旧帖", createdAt: now.addingTimeInterval(-60))
        await feed.setPage(uid: uid, page: 1, posts: [old])
        await service.tick(
            now: now, config: config, credentials: credentials, isLowPower: false, isOnline: true
        )

        let muchLater = now.addingTimeInterval(8 * 3600)
        let firstNew = makePost(
            mid: "2",
            text: "睡醒后的第一条",
            createdAt: muchLater.addingTimeInterval(-600)
        )
        let secondNew = makePost(
            mid: "3",
            text: "睡醒后的第二条",
            createdAt: muchLater.addingTimeInterval(-300)
        )
        await feed.setPage(uid: uid, page: 1, posts: [secondNew, firstNew])
        await feed.setPage(uid: uid, page: 2, posts: [old])
        await service.tick(
            now: muchLater, config: config, credentials: credentials, isLowPower: false, isOnline: true
        )
        await service.flushAlerts(now: muchLater.addingTimeInterval(45))

        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.unreadCount, 2)
        XCTAssertFalse(snapshot.users.first?.gapSuspected == true)
        let notifications = await notifier.notifications
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.mid, "3")
    }

    func testThreeEmptyResponsesSlowDownInsteadOfKeepingTheNormalCadence() async throws {
        let now = Date()
        let uid = try uid()
        _ = try await service.addUser(input: uid, priority: .p0, now: now)
        let old = makePost(mid: "1", text: "旧帖", createdAt: now.addingTimeInterval(-60))
        await feed.setPage(uid: uid, page: 1, posts: [old])
        await service.tick(
            now: now, config: config, credentials: credentials, isLowPower: false, isOnline: true
        )

        await feed.setPage(uid: uid, page: 1, posts: [])
        var tick = now.addingTimeInterval(180)
        for _ in 0..<3 {
            await service.tick(
                now: tick, config: config, credentials: credentials, isLowPower: false, isOnline: true
            )
            tick = tick.addingTimeInterval(180)
        }
        let thirdTick = tick.addingTimeInterval(-180)
        let snapshot = await service.snapshot()
        let next = try XCTUnwrap(snapshot.users.first?.nextDueAt)
        XCTAssertGreaterThanOrEqual(
            next.timeIntervalSince(thirdTick),
            2 * config.interval(for: .p0),
            "three empty responses must double the interval"
        )
    }

    func testDateMissingPostsDoNotNotify() async throws {
        let now = Date()
        let uid = try uid()
        _ = try await service.addUser(input: uid, priority: .p0, now: now)
        let old = makePost(mid: "1", text: "旧帖", createdAt: now.addingTimeInterval(-60))
        await feed.setPage(uid: uid, page: 1, posts: [old])
        await service.tick(
            now: now, config: config, credentials: credentials, isLowPower: false, isOnline: true
        )

        let later = now.addingTimeInterval(180)
        let new = makePost(mid: "2", text: "日期缺失的新帖", createdAt: later)
        await feed.setPage(uid: uid, page: 1, posts: [new, old])
        await feed.setDateMissing(uid: uid, page: 1)
        await service.tick(
            now: later, config: config, credentials: credentials, isLowPower: false, isOnline: true
        )
        await service.flushAlerts(now: later.addingTimeInterval(45))

        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.unreadCount, 0)
        let notifications = await notifier.notifications
        XCTAssertTrue(notifications.isEmpty)
    }

    func testLongTextIsUsedForNotification() async throws {
        let now = Date()
        let uid = try uid()
        _ = try await service.addUser(input: uid, priority: .p0, now: now)
        let old = makePost(mid: "1", text: "旧帖", createdAt: now.addingTimeInterval(-60))
        await feed.setPage(uid: uid, page: 1, posts: [old])
        await service.tick(
            now: now, config: config, credentials: credentials, isLowPower: false, isOnline: true
        )

        let later = now.addingTimeInterval(180)
        let new = makePost(
            mid: "2",
            text: "短文本",
            createdAt: later,
            isLongText: true
        )
        await feed.setPage(uid: uid, page: 1, posts: [new, old])
        await feed.setLongText(
            mid: "2",
            text: "这是补全后的长文正文，包含 Ultra 和芯片信息"
        )
        await service.tick(
            now: later, config: config, credentials: credentials, isLowPower: false, isOnline: true
        )
        await service.flushAlerts(now: later.addingTimeInterval(45))

        let notifications = await notifier.notifications
        XCTAssertEqual(notifications.count, 1)
        XCTAssertTrue(notifications.first?.body.contains("补全后的长文") == true)
    }

    func testBackfillOnFirstAdd() async throws {
        let now = Date()
        let uid = try uid()
        _ = try await service.addUser(input: uid, priority: .p0, now: now)
        let recent = makePost(
            mid: "1",
            text: "半小时前",
            createdAt: now.addingTimeInterval(-1800)
        )
        await feed.setPage(uid: uid, page: 1, posts: [recent])

        var backfillConfig = config
        backfillConfig.backfillHours = 1
        await service.tick(
            now: now, config: backfillConfig, credentials: credentials, isLowPower: false, isOnline: true
        )
        await service.flushAlerts(now: now.addingTimeInterval(45))

        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.unreadCount, 1)
        let notifications = await notifier.notifications
        XCTAssertEqual(notifications.count, 1)
    }

    func testNightStartDefersP1ToMorning() async throws {
        let night = WeiboMonitorTestSupport.date(2026, 11, 7, 3, 0)
        let nightRoot = root.appendingPathComponent("night", isDirectory: true)
        let nightStore = WeiboMonitorStore(root: nightRoot)
        let nightUser = WeiboMonitorTestSupport.user(priority: .p1, now: night)
        try await nightStore.save(users: [nightUser], now: night)

        let nightService = WeiboMonitorService(
            store: nightStore,
            feed: FakeWeiboFeed(),
            notifier: NoopWeiboAlertNotifier(),
            planner: WeiboPollPlanner(calendar: WeiboMonitorTestSupport.calendar),
            alertPolicy: WeiboAlertPolicy(calendar: WeiboMonitorTestSupport.calendar),
            rng: WeiboRNG(seed: 1),
            sleeper: { _ in },
            autoFlushAlerts: false,
            changeNotifier: {},
            authAlertRecorder: { _ in }
        )
        var nightConfig = config
        nightConfig.nightEnabled = true
        nightConfig.nightStartMinute = 30
        nightConfig.nightEndMinute = 450
        await nightService.start(now: night, config: nightConfig)

        let snapshot = await nightService.snapshot()
        let due = try XCTUnwrap(snapshot.users.first?.nextDueAt)
        let components = WeiboMonitorTestSupport.calendar.dateComponents([.hour, .minute], from: due)
        XCTAssertEqual(components.hour, 7)
        XCTAssertEqual(components.minute, 30)
    }

    func testRateLimitPausesTheAccountAndSkipsNextDue() async throws {
        let now = Date()
        let uid = try uid()
        _ = try await service.addUser(input: uid, priority: .p0, now: now)
        await feed.setOutcome(.failure(kind: .rateLimited, message: "429", retryAfter: 3600))
        await service.tick(
            now: now, config: config, credentials: credentials, isLowPower: false, isOnline: true
        )
        let requestsAfterFailure = await feed.requestCount
        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.users.first?.lastErrorKind, .rateLimited)
        XCTAssertTrue((snapshot.users.first?.pausedUntil ?? .distantPast) > now)

        await service.tick(
            now: now.addingTimeInterval(120),
            config: config,
            credentials: credentials,
            isLowPower: false,
            isOnline: true
        )
        let requestsAfterSecondTick = await feed.requestCount
        XCTAssertEqual(requestsAfterSecondTick, requestsAfterFailure)
    }

    func testAuthExpirySendsOneAlertAndProbesAfterFifteenMinutes() async throws {
        let now = Date()
        let uid = try uid()
        _ = try await service.addUser(input: uid, priority: .p0, now: now)
        await feed.setOutcome(.failure(kind: .authExpired, message: "login", retryAfter: nil))
        await service.tick(
            now: now, config: config, credentials: credentials, isLowPower: false, isOnline: true
        )
        var snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.loginState, .expired)
        var authAlerts = await notifier.authAlerts
        XCTAssertEqual(authAlerts, 1)
        let requestsAfterFailure = await feed.requestCount

        // No probe during the fifteen-minute cool-down.
        await service.tick(
            now: now.addingTimeInterval(60),
            config: config,
            credentials: credentials,
            isLowPower: false,
            isOnline: false
        )
        let requestsDuringCooldown = await feed.requestCount
        XCTAssertEqual(requestsDuringCooldown, requestsAfterFailure)

        await feed.setOutcome(nil)
        await feed.setPage(
            uid: uid,
            page: 1,
            posts: [makePost(mid: "1", text: "恢复后的基线", createdAt: now.addingTimeInterval(960))]
        )
        await service.tick(
            now: now.addingTimeInterval(16 * 60),
            config: config,
            credentials: credentials,
            isLowPower: false,
            isOnline: true
        )
        snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.loginState, .loggedIn)
        let requestsAfterProbe = await feed.requestCount
        XCTAssertEqual(requestsAfterProbe, requestsAfterFailure + 1)
        authAlerts = await notifier.authAlerts
        XCTAssertEqual(authAlerts, 1)
    }

    func testMarkReadClearsUnread() async throws {
        let now = Date()
        let uid = try uid()
        _ = try await service.addUser(input: uid, priority: .p0, now: now)
        let old = makePost(mid: "1", text: "旧帖", createdAt: now.addingTimeInterval(-60))
        await feed.setPage(uid: uid, page: 1, posts: [old])
        await service.tick(
            now: now, config: config, credentials: credentials, isLowPower: false, isOnline: true
        )
        let later = now.addingTimeInterval(120)
        let new = makePost(mid: "2", text: "新帖", createdAt: later.addingTimeInterval(-30))
        await feed.setPage(uid: uid, page: 1, posts: [new, old])
        await service.tick(
            now: later, config: config, credentials: credentials, isLowPower: false, isOnline: true
        )
        await service.markRead(mid: "2", now: later)
        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.unreadCount, 0)
    }

    func testParseUIDVariants() {
        XCTAssertEqual(WeiboMonitorService.parseUID("1234567890"), "1234567890")
        XCTAssertEqual(
            WeiboMonitorService.parseUID("https://weibo.com/u/1234567890"),
            "1234567890"
        )
        XCTAssertEqual(
            WeiboMonitorService.parseUID("https://m.weibo.cn/u/1234567890"),
            "1234567890"
        )
        XCTAssertEqual(
            WeiboMonitorService.parseUID("weibo.com/1234567890"),
            "1234567890"
        )
        XCTAssertNil(WeiboMonitorService.parseUID("https://example.com/u/1234567890"))
        XCTAssertNil(WeiboMonitorService.parseUID("abc"))
    }

    func testAddDuplicateAndInvalidInput() async throws {
        let now = Date()
        _ = try await service.addUser(input: "1234567890", priority: .p0, now: now)
        do {
            _ = try await service.addUser(input: "1234567890", priority: .p0, now: now)
            XCTFail("duplicate should throw")
        } catch {
            XCTAssertEqual(error as? WeiboMonitorAddError, .duplicate)
        }
        do {
            _ = try await service.addUser(input: "not-a-uid", priority: .p0, now: now)
            XCTFail("invalid input should throw")
        } catch {
            XCTAssertEqual(error as? WeiboMonitorAddError, .invalidInput)
        }
    }
}
