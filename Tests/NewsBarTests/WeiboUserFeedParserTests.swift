import XCTest
@testable import NewsBar

final class WeiboUserFeedParserTests: XCTestCase {
    private let calendar = WeiboMonitorTestSupport.calendar

    func testParsesT0Fields() throws {
        let page = try WeiboFeedParser.parseT0(
            WeiboMonitorTestSupport.t0Fixture(),
            uid: "1001",
            fallbackScreenName: "fallback",
            fetchedAt: WeiboMonitorTestSupport.date(2026, 11, 7, 10, 0)
        )

        XCTAssertEqual(page.posts.count, 2)
        XCTAssertEqual(page.screenName, "数码闲聊站")
        XCTAssertEqual(page.avatarURL, "https://tvax1.sinaimg.cn/avatar.jpg")
        XCTAssertEqual(page.rawCount, 2)
        XCTAssertFalse(page.dateMissing)

        let first = try XCTUnwrap(page.posts.first)
        XCTAssertEqual(first.mid, "1002")
        XCTAssertEqual(first.bid, "B2")
        XCTAssertEqual(first.text, "第二条 链接 & 内容 'quoted'")
        XCTAssertEqual(first.createdAt, WeiboMonitorTestSupport.date(2026, 11, 7, 9, 58))
        XCTAssertTrue(first.isLongText)
        XCTAssertFalse(first.isTop)
        XCTAssertEqual(first.imageURLs, ["https://wx1.sinaimg.cn/large/one.jpg"])
        XCTAssertEqual(first.url, "https://weibo.com/1001/B2")

        let second = try XCTUnwrap(page.posts.last)
        XCTAssertTrue(second.isRetweet)
        XCTAssertEqual(second.retweetText, "被转发的原文")
        XCTAssertTrue(second.isTop)
    }

    func testParsesT1CardsIncludingNestedGroups() throws {
        let now = WeiboMonitorTestSupport.date(2026, 11, 7, 12, 0)
        let page = try WeiboFeedParser.parseT1(
            WeiboMonitorTestSupport.t1Fixture(),
            uid: "2001",
            fallbackScreenName: "fallback",
            fetchedAt: now,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(page.posts.count, 2)
        XCTAssertEqual(page.sinceMid, "2001")
        XCTAssertEqual(page.posts.first?.text, "T1 内容 & 更多")
        XCTAssertEqual(page.posts.last?.text, "嵌套卡片")
        let components = calendar.dateComponents([.year, .month, .day], from: page.posts[0].createdAt)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 11)
        XCTAssertEqual(components.day, 7)
    }

    func testShortDateCrossesYearBoundaryBackwards() throws {
        let now = WeiboMonitorTestSupport.date(2026, 1, 2, 12, 0)
        let result = try XCTUnwrap(
            WeiboFeedParser.parseShortDate("12-31", now: now, calendar: calendar)
        )
        let components = calendar.dateComponents([.year, .month, .day], from: result)
        XCTAssertEqual(components.year, 2025)
        XCTAssertEqual(components.month, 12)
        XCTAssertEqual(components.day, 31)
    }

    func testCleanTextStripsTagsEntitiesAndWhitespace() {
        let raw = """
        <p>第一段&nbsp;内容</p><br/>第二段 &amp; &#39;引号&#39; &#x1F600;
        """
        let cleaned = WeiboFeedParser.cleanText(raw)
        XCTAssertTrue(cleaned.contains("第一段 内容"), cleaned)
        XCTAssertTrue(cleaned.contains("第二段 & '引号' 😀"), cleaned)
        XCTAssertFalse(cleaned.contains("<"))
        XCTAssertFalse(cleaned.contains("&amp;"))
    }

    func testParseLongText() {
        let data = (try? JSONSerialization.data(withJSONObject: [
            "ok": 1,
            "data": ["longTextContent": "<p>长文 <b>正文</b></p>"],
        ])) ?? Data()
        XCTAssertEqual(WeiboFeedParser.parseLongText(data), "长文 正文")
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(
            try WeiboFeedParser.parseT0(
                Data("not-json".utf8),
                uid: "1",
                fallbackScreenName: "x",
                fetchedAt: Date()
            )
        )
    }

    func testNonOKPayloadThrows() {
        let data = (try? JSONSerialization.data(withJSONObject: ["ok": -100])) ?? Data()
        XCTAssertThrowsError(
            try WeiboFeedParser.parseT0(
                data,
                uid: "1",
                fallbackScreenName: "x",
                fetchedAt: Date()
            )
        )
    }

    func testMissingDateFallsBackToFetchTime() throws {
        let fetchedAt = WeiboMonitorTestSupport.date(2026, 11, 7, 10, 0)
        let data = (try? JSONSerialization.data(withJSONObject: [
            "ok": 1,
            "data": ["list": [[
                "idstr": "999",
                "text_raw": "无日期",
            ]]],
        ])) ?? Data()
        let page = try WeiboFeedParser.parseT0(
            data,
            uid: "1",
            fallbackScreenName: "x",
            fetchedAt: fetchedAt
        )
        XCTAssertTrue(page.dateMissing)
        XCTAssertEqual(page.posts.first?.createdAt, fetchedAt)
    }
}
