import XCTest
@testable import NewsBar

final class WeiboRelevanceModelTests: XCTestCase {
    private let model = WeiboRelevanceModel()
    private let now = WeiboMonitorTestSupport.date(2026, 11, 7, 12, 0)

    private func evaluate(
        _ text: String,
        imageCount: Int = 0,
        keywords: [String] = [],
        peers: [WeiboCrossPostReference] = [],
        mode: WeiboRelevanceMode = .balanced
    ) -> WeiboPostRelevance {
        let index = WeiboCrossPostIndex(references: peers, now: now)
        return model.evaluate(
            text: text,
            imageCount: imageCount,
            accountBaseline: 0.5,
            userKeywords: keywords,
            crossPostIndex: index,
            mode: mode,
            now: now
        )
    }

    // MARK: - Ads

    func testLotteryPlatformNoticeIsFiltered() {
        let relevance = evaluate("恭喜 @小明 获得【耳机】。公示链接：网页链接 微博抽奖平台")
        XCTAssertEqual(relevance.verdict, .filtered)
        XCTAssertGreaterThanOrEqual(relevance.adScore, 0.9)
        XCTAssertTrue(relevance.reasons.contains("lotteryPlatform"))
    }

    func testLotteryWithCallToActionIsFiltered() {
        let relevance = evaluate("转发+评论，抽 5 位送出【小米 17 Pro】，关注我了解更多")
        XCTAssertEqual(relevance.verdict, .filtered)
        XCTAssertGreaterThanOrEqual(relevance.adScore, 0.9)
    }

    func testDrawCountWithoutCallToActionIsUncertain() {
        let relevance = evaluate("这次准备了 3 台新机，抽 3 位朋友")
        XCTAssertEqual(relevance.verdict, .lowConfidence)
        XCTAssertGreaterThanOrEqual(relevance.adScore, 0.35)
        XCTAssertLessThan(relevance.adScore, 0.6)
    }

    func testFoodPostMentioningCheckoutIsNotAnAd() {
        // The naive keyword model called this an ad because of "下单".
        let relevance = evaluate("排队一小时终于吃上了，这家的包子真不错，下次不能在这家下单了", imageCount: 1)
        XCTAssertNotEqual(relevance.verdict, .filtered)
        XCTAssertLessThan(relevance.adScore, 0.35)
    }

    func testNewsMentioningShoppingAppIsNotAnAd() {
        let relevance = evaluate("亚马逊接入 Uber Eats，用户可以直接在购物 App 里点外卖了")
        XCTAssertNotEqual(relevance.verdict, .filtered)
        XCTAssertLessThan(relevance.adScore, 0.35)
    }

    func testHardwareSpecsCancelASalesMatch() {
        // Transaction wording plus a product entity is an ad, but a dense
        // spec sheet is the signature of a review, not a sales post.
        let relevance = evaluate(
            "小米 17 Pro 券后 4999 元，6.9 英寸屏幕，7000mAh 电池，120W 充电，2 亿像素"
        )
        XCTAssertLessThan(relevance.adScore, 0.35)
        XCTAssertNotEqual(relevance.verdict, .filtered)
    }

    func testShoppingLinkAloneIsUncertain() {
        let relevance = evaluate("新机开箱在这里：https://item.taobao.com/item.htm?id=1")
        XCTAssertEqual(relevance.verdict, .lowConfidence)
        XCTAssertGreaterThanOrEqual(relevance.adScore, 0.35)
        XCTAssertLessThan(relevance.adScore, 0.6)
    }

    // MARK: - Interest

    func testShortLeakStaysRelevant() {
        let relevance = evaluate("独家，又有一家超大杯有变动，项目暂停中")
        XCTAssertEqual(relevance.verdict, .relevant)
        XCTAssertGreaterThanOrEqual(relevance.interestScore, 0.45)
    }

    func testDinnerPostIsOffTopic() {
        let relevance = evaluate("排队一小时终于吃上了，这家的包子真不错", imageCount: 1)
        XCTAssertEqual(relevance.verdict, .offTopic)
    }

    func testHolidayCalendarIsOffTopic() {
        let relevance = evaluate("2027 假期日历出炉，图片来源：央视新闻，转发收藏")
        XCTAssertEqual(relevance.verdict, .offTopic)
    }

    func testMoviePosterIsOffTopic() {
        let relevance = evaluate("漫威新电影海报发布，明年上映", imageCount: 1)
        XCTAssertEqual(relevance.verdict, .offTopic)
    }

    func testAiNewsStaysRelevant() {
        let relevance = evaluate("Kimi 开源了新的模型权重，上下文长度提升到 256k，推理成本下降一半")
        XCTAssertEqual(relevance.verdict, .relevant)
    }

    func testUserKeywordLiftsAnOtherwiseGenericPost() {
        let without = evaluate("这次的新品有点意思")
        let withKeyword = evaluate("这次的新品有点意思", keywords: ["新品"])
        XCTAssertGreaterThan(withKeyword.interestScore, without.interestScore)
        XCTAssertEqual(withKeyword.verdict, .relevant)
    }

    // MARK: - Cross-account repost

    func testCrossPostLiftsSoftPromotionToUncertain() {
        let target = "荣耀MagicOS月月新功能发布会现场这次更新带来了全新的系统体验和多项实用功能"
        let peerText = String(target.prefix(18)) + "0123456789abcdefghijklmnopqrstuvwxyz"
        let peer = WeiboCrossPostReference(
            uid: "other",
            text: peerText,
            createdAt: now.addingTimeInterval(-3600)
        )
        let relevance = evaluate(target, peers: [peer])
        XCTAssertEqual(relevance.verdict, .lowConfidence)
        XCTAssertTrue(relevance.reasons.contains { $0.hasPrefix("crossPost:") })
    }

    func testWeakCrossPostDoesNotChangeTheVerdict() {
        let target = "荣耀MagicOS月月新功能发布会现场这次更新带来了全新的系统体验和多项实用功能"
        let peerText = String(target.prefix(10)) + "0123456789abcdefghijklmnopqrstuvwxyz"
        let peer = WeiboCrossPostReference(
            uid: "other",
            text: peerText,
            createdAt: now.addingTimeInterval(-3600)
        )
        let relevance = evaluate(target, peers: [peer])
        XCTAssertEqual(relevance.verdict, .relevant)
        XCTAssertFalse(relevance.reasons.contains { $0.hasPrefix("crossPost:") })
    }

    func testCrossPostIgnoresPostsOlderThanSeventyTwoHours() {
        let target = "荣耀MagicOS月月新功能发布会现场这次更新带来了全新的系统体验和多项实用功能"
        let peerText = String(target.prefix(18)) + "0123456789abcdefghijklmnopqrstuvwxyz"
        let stale = WeiboCrossPostReference(
            uid: "other",
            text: peerText,
            createdAt: now.addingTimeInterval(-73 * 3600)
        )
        let relevance = evaluate(target, peers: [stale])
        XCTAssertEqual(relevance.verdict, .relevant)
    }

    func testContainmentUsesTheShorterSetAsDenominator() {
        let shared = Set((0..<6).map { "s\($0)" })
        let a = shared.union(Set((0..<94).map { "a\($0)" }))   // 100 grams
        let b = shared.union(Set((0..<18).map { "b\($0)" }))   // 24 grams
        XCTAssertEqual(
            WeiboTextFingerprint.containment(a, b),
            6.0 / 24.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            WeiboTextFingerprint.containment(b, a),
            6.0 / 24.0,
            accuracy: 0.0001
        )
    }

    // MARK: - Modes

    func testStrictModeFiltersAtFortyPercentAdScore() {
        let text = "新机开箱在这里：https://item.taobao.com/item.htm?id=1"
        XCTAssertEqual(evaluate(text, mode: .balanced).verdict, .lowConfidence)
        XCTAssertEqual(evaluate(text, mode: .strict).verdict, .filtered)
    }

    func testLooseModeKeepsAWeakAdEvidencePostUnfiltered() {
        let text = "新机开箱在这里：https://item.taobao.com/item.htm?id=1"
        let relevance = evaluate(text, mode: .loose)
        XCTAssertNotEqual(relevance.verdict, .filtered)
    }

    func testOffModeNeverCollapses() {
        let text = "转发+评论，抽 5 位送出【小米 17 Pro】"
        let relevance = evaluate(text, mode: .off)
        XCTAssertEqual(relevance.verdict, .relevant)
    }

    // MARK: - Explaining

    func testEveryDecisionCarriesAReason() {
        let samples = [
            "转发+评论，抽 5 位送出【小米 17 Pro】",
            "独家，又有一家超大杯有变动，项目暂停中",
            "2027 假期日历出炉，图片来源：央视新闻",
            "今天随便说两句",
        ]
        for text in samples {
            XCTAssertFalse(evaluate(text).reasons.isEmpty, text)
        }
    }
}
