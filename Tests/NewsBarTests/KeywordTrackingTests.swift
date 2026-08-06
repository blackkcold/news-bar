import XCTest
@testable import NewsBar

final class KeywordTrackingTests: XCTestCase {

    private func makeSettings(keywords: [String]) -> AppSettings {
        let settings = AppSettings()
        settings.keywordList = keywords
        return settings
    }

    func testActiveKeywordsTrimsAndFiltersEmpty() {
        let settings = makeSettings(keywords: ["  apple  ", "", "   ", "Tesla"])
        XCTAssertEqual(settings.activeKeywords, ["apple", "Tesla"])
    }

    func testKeywordMatchesCaseInsensitive() {
        let settings = makeSettings(keywords: ["apple"])
        XCTAssertTrue(settings.keywordMatches("Apple 发布新系统"))
        XCTAssertTrue(settings.keywordMatches("APPLE 股价创新高"))
        XCTAssertFalse(settings.keywordMatches("香蕉价格波动"))
    }

    func testKeywordMatchesAnyOfMultiple() {
        let settings = makeSettings(keywords: ["apple", "tesla"])
        XCTAssertTrue(settings.keywordMatches("Tesla 发布新车"))
        XCTAssertTrue(settings.keywordMatches("Apple 发布会"))
        XCTAssertFalse(settings.keywordMatches("三星发布新机"))
    }

    func testKeywordMatchesEmptyListReturnsFalse() {
        let settings = makeSettings(keywords: [])
        XCTAssertFalse(settings.keywordMatches("任何标题"))
    }

    func testKeywordMatchesDiacriticInsensitive() {
        let settings = makeSettings(keywords: ["cafe"])
        XCTAssertTrue(settings.keywordMatches("Café 开业"))
    }

    func testKeywordMatchesSubstring() {
        let settings = makeSettings(keywords: ["ai"])
        XCTAssertTrue(settings.keywordMatches("AI 技术发展"))
        XCTAssertTrue(settings.keywordMatches("人工智能 AI 应用"))
    }
}
