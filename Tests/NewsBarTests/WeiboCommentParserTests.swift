import XCTest
@testable import NewsBar

final class WeiboCommentParserTests: XCTestCase {
    private let calendar = WeiboMonitorTestSupport.calendar
    private let now = WeiboMonitorTestSupport.date(2026, 11, 12, 12, 0)

    private func data(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }

    func testParsesDesktopCommentsWithTotalCursorAndReplyAuthor() throws {
        let payload: [String: Any] = [
            "ok": 1,
            "data": [
                [
                    "id": 501,
                    "idstr": "501",
                    "text_raw": "回复<a href='https://m.weibo.cn/n/某人'>@某人</a>:好看<span class=\"url-icon\"><img alt=\"[吃瓜]\" src=\"https://face.example/x.png\" /></span>",
                    "created_at": "Thu Nov 12 10:00:00 +0800 2026",
                    "user": [
                        "id": 77,
                        "screen_name": "甲",
                        "profile_image_url": "https://wx.example/a.jpg",
                    ],
                    "like_counts": 12,
                    "reply_comment": ["user": ["screen_name": "被回复者"]],
                ],
                [
                    "id": 502,
                    "text": "普通评论<br>第二行 &amp; more",
                    "created_at": "刚刚",
                    "user": ["id": 78, "screen_name": "乙"],
                    "like_count": 0,
                ],
            ],
            "total_number": 128,
            "max_id": 999,
        ]

        let page = try WeiboCommentParser.parse(
            data(payload),
            mid: "9001",
            authorUID: "77",
            tier: .desktop,
            fetchedAt: now,
            calendar: calendar
        )

        XCTAssertEqual(page.comments.count, 2)
        XCTAssertEqual(page.total, 128)
        XCTAssertEqual(page.nextCursor, "999")
        XCTAssertEqual(page.tier, .desktop)
        XCTAssertEqual(page.fetchedAt, now)

        let first = try XCTUnwrap(page.comments.first)
        XCTAssertEqual(first.id, "501")
        XCTAssertEqual(first.mid, "9001")
        XCTAssertEqual(first.uid, "77")
        XCTAssertEqual(first.screenName, "甲")
        XCTAssertEqual(first.avatarURL, "https://wx.example/a.jpg")
        XCTAssertEqual(first.likeCount, 12)
        XCTAssertEqual(first.replyToName, "被回复者")
        XCTAssertTrue(first.isAuthor)
        XCTAssertTrue(first.text.contains("[吃瓜]"), first.text)
        XCTAssertTrue(first.text.contains("好看"), first.text)
        XCTAssertFalse(first.text.contains("<"), first.text)
        XCTAssertEqual(first.createdAt, WeiboMonitorTestSupport.date(2026, 11, 12, 10, 0))

        let second = try XCTUnwrap(page.comments.last)
        XCTAssertEqual(second.likeCount, 0)
        XCTAssertFalse(second.isAuthor)
        XCTAssertTrue(second.text.contains("第二行"), second.text)
        XCTAssertTrue(second.text.contains("&"), second.text)
        XCTAssertFalse(second.text.contains("&amp;"), second.text)
        XCTAssertEqual(second.createdAt, now)
    }

    func testParsesNormalizedArrayShapeWithoutInventingTotalOrCursor() throws {
        let payload: [[String: Any]] = [
            [
                "id": 600,
                "text": "移动端评论<span class=\"url-icon\"><img alt=\"[doge]\" src=\"x\" /></span>",
                "created_at": "2分钟前",
                "source": "来自 广东",
                "user": ["id": 90, "screen_name": "丙"],
                "reply_id": 12,
                "reply_text": "父评论正文",
            ],
        ]

        let page = try WeiboCommentParser.parse(
            data(payload),
            mid: "9002",
            tier: .mobile,
            fetchedAt: now,
            calendar: calendar
        )

        XCTAssertEqual(page.comments.count, 1)
        XCTAssertNil(page.total)
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(page.tier, .mobile)
        let comment = try XCTUnwrap(page.comments.first)
        XCTAssertEqual(comment.text, "移动端评论[doge]")
        XCTAssertEqual(comment.createdAt, now.addingTimeInterval(-120))
        XCTAssertNil(comment.replyToName)
    }

    func testZeroTotalIsConfirmedButMissingTotalIsUnknown() throws {
        let zero = try WeiboCommentParser.parse(
            data(["ok": 1, "data": [], "total_number": 0]),
            mid: "1",
            tier: .desktop,
            fetchedAt: now
        )
        XCTAssertEqual(zero.total, 0)
        XCTAssertTrue(zero.comments.isEmpty)

        let missing = try WeiboCommentParser.parse(
            data(["ok": 1, "data": [], "max_id": 0]),
            mid: "1",
            tier: .desktop,
            fetchedAt: now
        )
        XCTAssertNil(missing.total)
        XCTAssertNil(missing.nextCursor, "A zero cursor means the thread ended")
    }

    func testRejectsNotOKPayloads() {
        XCTAssertThrowsError(
            try WeiboCommentParser.parse(
                data(["ok": -100]),
                mid: "1",
                tier: .desktop,
                fetchedAt: now
            )
        )
    }

    func testSkipsMalformedEntriesAndDeduplicatesIDs() throws {
        let payload: [String: Any] = [
            "ok": 1,
            "data": [
                ["idstr": "1", "text": "a", "user": ["screen_name": "A"]],
                ["idstr": "1", "text": "duplicate", "user": ["screen_name": "A"]],
                ["text": "missing id", "user": ["screen_name": "B"]],
                ["idstr": "2", "text": "no user"],
                ["idstr": "3", "text": "valid", "user": ["screen_name": "C"]],
            ],
            "total_number": 3,
        ]

        let page = try WeiboCommentParser.parse(
            data(payload),
            mid: "1",
            tier: .desktop,
            fetchedAt: now
        )
        XCTAssertEqual(page.comments.map(\.id), ["1", "3"])
        XCTAssertEqual(page.comments.first?.text, "a")
    }

    func testRelativeDatesResolveAgainstFetchTime() throws {
        let payload: [String: Any] = [
            "ok": 1,
            "data": [
                ["idstr": "1", "text": "刚刚", "created_at": "刚刚", "user": ["screen_name": "A"]],
                ["idstr": "2", "text": "分钟", "created_at": "5分钟前", "user": ["screen_name": "A"]],
                ["idstr": "3", "text": "小时", "created_at": "3小时前", "user": ["screen_name": "A"]],
                ["idstr": "4", "text": "昨天", "created_at": "昨天 08:30", "user": ["screen_name": "A"]],
            ],
        ]
        let page = try WeiboCommentParser.parse(
            data(payload),
            mid: "1",
            tier: .desktop,
            fetchedAt: now,
            calendar: calendar
        )
        XCTAssertEqual(page.comments[0].createdAt, now)
        XCTAssertEqual(page.comments[1].createdAt, now.addingTimeInterval(-300))
        XCTAssertEqual(page.comments[2].createdAt, now.addingTimeInterval(-3 * 3600))
        let yesterday = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: page.comments[3].createdAt)
        XCTAssertEqual(yesterday.year, 2026)
        XCTAssertEqual(yesterday.month, 11)
        XCTAssertEqual(yesterday.day, 11)
        XCTAssertEqual(yesterday.hour, 8)
        XCTAssertEqual(yesterday.minute, 30)
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(
            try WeiboCommentParser.parse(
                Data("not-json".utf8),
                mid: "1",
                tier: .desktop,
                fetchedAt: now
            )
        )
    }
}
