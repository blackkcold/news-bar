import XCTest
import UserNotifications
@testable import NewsBar

final class NotificationDigestTests: XCTestCase {
    private var originalLanguage: AppLanguage!

    override func setUp() {
        super.setUp()
        originalLanguage = L10n.currentLanguage
        L10n.currentLanguage = .zh
    }

    override func tearDown() {
        L10n.currentLanguage = originalLanguage
        super.tearDown()
    }

    private func item(
        _ title: String,
        source: NewsSource = .weibo,
        rank: Int? = nil
    ) -> NewsItem {
        NewsItem(
            title: title,
            url: "https://example.com/\(UUID().uuidString)",
            source: source,
            rank: rank
        )
    }

    private func encodedDigest(_ items: [NewsItem]) -> String {
        let digest = NotificationDigest(kind: "hourly", items: items)
        guard let raw = NotificationDigest.encode(digest) else {
            XCTFail("Digest encoding failed")
            return ""
        }
        return raw
    }

    func testDigestRoundTrip() {
        let items = [
            item("微博一", source: .weibo, rank: 1),
            item("微博二", source: .weibo, rank: 2),
            item("B站一", source: .bilibili, rank: 1)
        ]
        let digest = NotificationDigest(kind: "hourly", items: items)
        guard let raw = NotificationDigest.encode(digest),
              let decoded = NotificationDigest.decode(raw) else {
            return XCTFail("Digest round trip failed")
        }

        XCTAssertEqual(decoded.kind, "hourly")
        XCTAssertEqual(decoded.version, NotificationDigest.currentVersion)
        XCTAssertEqual(decoded.items.map(\.url), items.map(\.url))
        XCTAssertEqual(decoded.items.map(\.title), items.map(\.title))
        XCTAssertEqual(decoded.items.map(\.source), items.map(\.source))
        XCTAssertEqual(decoded.items.map(\.rank), items.map(\.rank))
    }

    func testLegacyPayloadRoutesToSingleNews() {
        let route = NotificationClickRouter.route(
            userInfo: [
                "type": "news",
                "url": "https://example.com/legacy",
                "title": "Legacy"
            ],
            actionIdentifier: UNNotificationDefaultActionIdentifier
        )

        XCTAssertEqual(route, .news(url: "https://example.com/legacy", title: "Legacy"))
    }

    func testDismissActionRoutesToDismiss() {
        let item = item("新闻")
        let route = NotificationClickRouter.route(
            userInfo: [
                "type": "news",
                "url": item.url,
                "digest": encodedDigest([item])
            ],
            actionIdentifier: UNNotificationDismissActionIdentifier
        )

        XCTAssertEqual(route, .dismiss)
    }

    func testMultiItemRoutesToDigest() {
        let items = [item("一"), item("二"), item("三")]
        let route = NotificationClickRouter.route(
            userInfo: ["digest": encodedDigest(items)],
            actionIdentifier: UNNotificationDefaultActionIdentifier
        )

        guard case let .digest(digest) = route else {
            return XCTFail("Expected digest route, got \(route)")
        }
        XCTAssertEqual(digest.items.count, 3)
    }

    func testSingleItemDigestRoutesToNews() {
        let item = item("唯一一条")
        let route = NotificationClickRouter.route(
            userInfo: ["digest": encodedDigest([item])],
            actionIdentifier: UNNotificationDefaultActionIdentifier
        )

        XCTAssertEqual(route, .news(url: item.url, title: item.displayTitle))
    }

    func testOpenDigestActionForcesDigestEvenWithSingleItem() {
        let item = item("唯一一条")
        let route = NotificationClickRouter.route(
            userInfo: ["digest": encodedDigest([item])],
            actionIdentifier: NotificationIdentifier.openDigestAction
        )

        guard case let .digest(digest) = route else {
            return XCTFail("Expected digest route, got \(route)")
        }
        XCTAssertEqual(digest.items.count, 1)
    }

    func testCorruptDigestFallsBackToNews() {
        let route = NotificationClickRouter.route(
            userInfo: [
                "type": "news",
                "url": "https://example.com/fallback",
                "title": "Fallback",
                "digest": "not-json"
            ],
            actionIdentifier: UNNotificationDefaultActionIdentifier
        )

        XCTAssertEqual(route, .news(url: "https://example.com/fallback", title: "Fallback"))
    }

    func testBurstRouteWins() {
        let route = NotificationClickRouter.route(
            userInfo: ["type": "burst", "eventID": "event-1"],
            actionIdentifier: UNNotificationDefaultActionIdentifier
        )

        XCTAssertEqual(route, .burst(eventID: "event-1"))
    }

    func testResearchPayloadRoutesToRecord() {
        let route = NotificationClickRouter.route(
            userInfo: ["type": "research", "recordID": "record-1", "title": "Topic"],
            actionIdentifier: UNNotificationDefaultActionIdentifier
        )

        XCTAssertEqual(route, .research(recordID: "record-1"))
    }

    func testMarkResearchReadActionRoutesToRecord() {
        let route = NotificationClickRouter.route(
            userInfo: ["type": "research", "recordID": "record-2"],
            actionIdentifier: NotificationIdentifier.markResearchReadAction
        )

        XCTAssertEqual(route, .markResearchRead(recordID: "record-2"))
    }

    func testResearchPayloadWithoutRecordIDFallsBackToDashboard() {
        let route = NotificationClickRouter.route(
            userInfo: ["type": "research", "title": "Topic"],
            actionIdentifier: UNNotificationDefaultActionIdentifier
        )

        XCTAssertEqual(route, .dashboard)
    }

    func testDailyPayloadWithoutURLRoutesToDashboard() {
        let route = NotificationClickRouter.route(
            userInfo: ["type": "daily"],
            actionIdentifier: UNNotificationDefaultActionIdentifier
        )

        XCTAssertEqual(route, .dashboard)
    }

    func testEmptyDigestFallsBackToDashboard() {
        let digest = NotificationDigest(kind: "hourly", items: [])
        guard let raw = NotificationDigest.encode(digest) else {
            return XCTFail("Digest encoding failed")
        }

        let route = NotificationClickRouter.route(
            userInfo: ["digest": raw],
            actionIdentifier: UNNotificationDefaultActionIdentifier
        )

        XCTAssertEqual(route, .dashboard)
    }

    func testTitleAndSubtitle() {
        let items = [
            item("微博一", source: .weibo),
            item("微博二", source: .weibo),
            item("B站一", source: .bilibili)
        ]
        let content = NotificationService.titleContent(items: items, daily: false)

        XCTAssertEqual(content.title, "NewsBar · 3 条更新")
        XCTAssertEqual(content.subtitle, "微博热搜 2 · B站热搜 1")
    }

    func testBodyHasUniformBullets() {
        let items = [item("一"), item("二"), item("三")]
        let content = NotificationService.titleContent(items: items, daily: false)
        let lines = content.body.split(separator: "\n")

        XCTAssertEqual(lines.count, 3)
        for line in lines {
            XCTAssertTrue(line.hasPrefix("• "), "Unexpected body line: \(line)")
        }
    }

    func testClipping() {
        let long = String(repeating: "a", count: 61)
        XCTAssertEqual(
            NotificationService.clipped(long),
            String(repeating: "a", count: 60) + "…"
        )
        XCTAssertEqual(NotificationService.clipped("short"), "short")
    }

    func testNormalizedPushCount() {
        XCTAssertEqual(NotificationService.normalizedPushCount(0), 1)
        XCTAssertEqual(NotificationService.normalizedPushCount(2), 2)
        XCTAssertEqual(NotificationService.normalizedPushCount(99), 3)
    }

    func testTitleContentEmbedsDecodableDigest() {
        let items = [item("一"), item("二"), item("三")]
        let content = NotificationService.titleContent(items: items, daily: true)
        let digest = NotificationDigest.decode(content.userInfo["digest"] as? String)

        XCTAssertEqual(digest?.items.count, 3)
        XCTAssertEqual(content.userInfo["url"] as? String, items[0].url)
        XCTAssertEqual(content.userInfo["newsItemID"] as? String, items[0].id)
        XCTAssertEqual(content.categoryIdentifier, NotificationIdentifier.digestCategory)
        XCTAssertEqual(content.threadIdentifier, "newsbar.digest")
    }

    func testEmptyItemsKeepsLegacyDailyPayload() {
        let content = NotificationService.titleContent(items: [], daily: true)

        XCTAssertEqual(content.title, "NewsBar 每日摘要")
        XCTAssertEqual(content.userInfo["type"] as? String, "daily")
        XCTAssertNil(content.userInfo["digest"])
    }
}
