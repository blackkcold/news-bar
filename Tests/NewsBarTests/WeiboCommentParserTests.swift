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

    // MARK: - Styled runs

    func testRunsExtractHTTPSLinkAndKeepSurroundingText() throws {
        let raw = "看这个<a href='https://example.com/news?id=1&amp;x=2'>网页链接</a>很有意思"
        let runs = try XCTUnwrap(WeiboCommentParser.parseRuns(raw))

        XCTAssertEqual(runs.map(\.kind), [.text, .link, .text])
        XCTAssertEqual(runs[0].text, "看这个")
        XCTAssertEqual(runs[1].text, "网页链接")
        XCTAssertEqual(runs[1].url, "https://example.com/news?id=1&x=2")
        XCTAssertEqual(runs[2].text, "很有意思")
    }

    func testRunsKeepWhitespaceAroundAnchors() throws {
        let raw = "Nice shot <a href='https://example.com/a'>this one</a> is great"
        let runs = try XCTUnwrap(WeiboCommentParser.parseRuns(raw))
        XCTAssertEqual(
            runs.map(\.text).joined(),
            "Nice shot this one is great",
            "Fragment-level trimming used to delete the spaces around the anchor"
        )

        let block = "第一段<br/><a href='https://example.com/b'>链接</a><br/>第二段"
        let blockRuns = try XCTUnwrap(WeiboCommentParser.parseRuns(block))
        XCTAssertEqual(blockRuns.map(\.text).joined(), "第一段\n链接\n第二段")
        XCTAssertEqual(blockRuns.first?.text, "第一段\n", "A line break before the anchor is semantic")
    }

    func testRunsLinkMentionsAndTopicsToTheGivenHref() throws {
        let raw = "回复<a href='https://m.weibo.cn/n/%E6%9F%90%E4%BA%BA'>@某人</a>:"
            + "<a href='https://s.weibo.com/weibo?q=%23%E8%AF%9D%E9%A2%98%23'>#话题#</a>"
        let runs = try XCTUnwrap(WeiboCommentParser.parseRuns(raw))

        let mention = try XCTUnwrap(runs.first { $0.kind == .mention })
        XCTAssertEqual(mention.text, "@某人")
        XCTAssertEqual(
            mention.url,
            "https://m.weibo.cn/n/%E6%9F%90%E4%BA%BA",
            "The href is Weibo's own; reusing it is not guessing a route"
        )

        let topic = try XCTUnwrap(runs.first { $0.kind == .topic })
        XCTAssertEqual(topic.text, "#话题#")
        XCTAssertEqual(topic.url, "https://s.weibo.com/weibo?q=%23%E8%AF%9D%E9%A2%98%23")
    }

    func testMentionLabelOnExternalHostStaysALink() throws {
        let raw = "<a href='https://example.com/u/1'>@某人</a>"
        let runs = try XCTUnwrap(WeiboCommentParser.parseRuns(raw))

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].kind, .link, "An @ label on another host is not a Weibo mention")
        XCTAssertEqual(runs[0].url, "https://example.com/u/1")
    }

    func testAnchorWithoutHrefIsNotALink() throws {
        let raw = "看图<a data-href='https://example.com/a' name='x'>说明</a>"
        XCTAssertNil(
            WeiboCommentParser.parseRuns(raw),
            "data-href is not the anchor's href and must not become a link"
        )
    }

    func testUppercaseAnchorStillParses() throws {
        let raw = "看<A HREF='https://example.com/A'>大写</A>"
        let runs = try XCTUnwrap(WeiboCommentParser.parseRuns(raw))

        XCTAssertEqual(runs.first { $0.kind == .link }?.url, "https://example.com/A")
    }

    func testRunsUnwrapSinaURLRedirect() throws {
        let raw = "<a href='https://weibo.cn/sinaurl?u=https%3A%2F%2Fexample.com%2Fstory%3Fid%3D7'>故事</a>"
        let runs = try XCTUnwrap(WeiboCommentParser.parseRuns(raw))

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].kind, .link)
        XCTAssertEqual(runs[0].url, "https://example.com/story?id=7")
    }

    func testSinaURLTargetWithEncodedColonIsNotDecodedTwice() throws {
        // Decodes once to `https://example.com/?q=%3A`. A second decode would
        // turn the target's own encoded colon into a literal one.
        let raw = "<a href='https://weibo.cn/sinaurl?u=https%3A%2F%2Fexample.com%2F%3Fq%3D%253A'>x</a>"
        let runs = try XCTUnwrap(WeiboCommentParser.parseRuns(raw))

        XCTAssertEqual(runs[0].url, "https://example.com/?q=%3A")
    }

    func testDoublyEncodedSinaURLStillUnwraps() throws {
        let raw = "<a href='https://weibo.cn/sinaurl?u=https%253A%252F%252Fexample.com%252Fa'>双层</a>"
        let runs = try XCTUnwrap(WeiboCommentParser.parseRuns(raw))

        XCTAssertEqual(runs[0].url, "https://example.com/a")
    }

    func testRunsDowngradeNonHTTPSLinksToText() throws {
        let raw = "<a href='http://example.com/x'>明文</a>"
        let runs = try XCTUnwrap(WeiboCommentParser.parseRuns(raw))

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].kind, .text)
        XCTAssertNil(
            runs[0].url,
            "The reader only loads https; a http anchor would look tappable and never render"
        )
    }

    func testRunsIgnoreEmojiImages() throws {
        let emojiOnly = "好的<span class=\"url-icon\"><img alt=\"[doge]\" src=\"https://face.example/x.png\" /></span>"
        XCTAssertNil(
            WeiboCommentParser.parseRuns(emojiOnly),
            "A body without an anchor stays on the plain text path"
        )

        let mixed = emojiOnly + "<a href='https://example.com'>链接</a>"
        let runs = try XCTUnwrap(WeiboCommentParser.parseRuns(mixed))
        XCTAssertEqual(runs.map(\.kind), [.text, .link])
        XCTAssertTrue(runs[0].text.contains("[doge]"))
        XCTAssertFalse(runs.contains { $0.kind == .link && $0.text.isEmpty })
    }

    func testParseAttachesRunsOnlyToMarkedUpComments() throws {
        let payload: [String: Any] = [
            "ok": 1,
            "data": [
                [
                    "idstr": "1",
                    "text_raw": "看<a href='https://example.com/a'>链接</a>",
                    "user": ["screen_name": "A"],
                ],
                [
                    "idstr": "2",
                    "text_raw": "纯文本",
                    "user": ["screen_name": "B"],
                ],
            ],
        ]
        let page = try WeiboCommentParser.parse(
            data(payload),
            mid: "1",
            tier: .desktop,
            fetchedAt: now
        )

        XCTAssertEqual(page.comments[0].runs?.count, 2)
        XCTAssertEqual(page.comments[0].runs?[1].kind, .link)
        XCTAssertNil(page.comments[1].runs)
        XCTAssertEqual(page.comments[1].text, "纯文本")
    }

    func testLikedFlagIsParsedOnlyWhenPresent() throws {
        let payload: [String: Any] = [
            "ok": 1,
            "data": [
                [
                    "id": 1,
                    "text": "已赞",
                    "user": ["id": 1, "screen_name": "A"],
                    "liked": true,
                    "like_counts": 3,
                ],
                [
                    "id": 2,
                    "text": "未标",
                    "user": ["id": 2, "screen_name": "B"],
                ],
            ],
        ]

        let page = try WeiboCommentParser.parse(
            data(payload),
            mid: "9",
            tier: .desktop,
            fetchedAt: now
        )

        XCTAssertEqual(page.comments[0].liked, true)
        XCTAssertEqual(page.comments[0].likeCount, 3)
        XCTAssertNil(page.comments[1].liked)
    }
}
