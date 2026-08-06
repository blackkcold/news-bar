import XCTest
@testable import NewsBar

final class BurstResearchParserTests: XCTestCase {

    func testParsesFullResearch() {
        let json = """
        {
          "summary": "某事件引发广泛关注。",
          "overview": "事件从起因逐步发酵，引发讨论。",
          "timeline": [
            {"date": "2026-08-03", "title": "起因", "detail": "事件首次被曝出。"},
            {"date": "2026-08-05", "title": "发酵", "detail": "话题冲上热搜。"}
          ],
          "sources": ["https://example.com/a", "https://example.com/b"],
          "needsRefetch": false,
          "refetchURLs": []
        }
        """
        let research = BurstResearchParser.parse(json)
        XCTAssertNotNil(research)
        let r = research!
        XCTAssertEqual(r.summary, "某事件引发广泛关注。")
        XCTAssertFalse(r.overview.isEmpty)
        XCTAssertEqual(r.timeline.count, 2)
        XCTAssertEqual(r.timeline[0].date, "2026-08-03")
        XCTAssertEqual(r.sources.count, 2)
        XCTAssertFalse(r.needsRefetch)
    }

    func testParsesCodeFencedJSON() {
        let json = """
        ```json
        {"summary": "带代码围栏的总结", "overview": "正文", "timeline": [], "sources": [], "needsRefetch": false, "refetchURLs": []}
        ```
        """
        let research = BurstResearchParser.parse(json)
        XCTAssertNotNil(research)
        XCTAssertEqual(research?.summary, "带代码围栏的总结")
    }

    func testParsesEmptyTimeline() {
        let json = """
        {"summary": "s", "overview": "o", "timeline": [], "sources": [], "needsRefetch": false, "refetchURLs": []}
        """
        let research = BurstResearchParser.parse(json)
        XCTAssertNotNil(research)
        XCTAssertTrue(research?.timeline.isEmpty == true)
    }

    func testReturnsNilWhenNoUsableContent() {
        let json = """
        {"summary": "", "overview": "", "timeline": [], "sources": [], "needsRefetch": false, "refetchURLs": []}
        """
        XCTAssertNil(BurstResearchParser.parse(json))
    }

    func testReturnsNilForNonJSON() {
        XCTAssertNil(BurstResearchParser.parse("这不是 JSON"))
    }

    func testFiltersInvalidSourceURLs() {
        let json = """
        {"summary": "s", "overview": "o", "timeline": [], "sources": ["https://ok.com", "javascript:alert(1)", "ftp://bad.com"], "needsRefetch": false, "refetchURLs": []}
        """
        let research = BurstResearchParser.parse(json)
        XCTAssertEqual(research?.sources, ["https://ok.com"])
    }

    func testHasUsableContent() {
        let empty = BurstResearch()
        XCTAssertFalse(BurstResearchParser.hasUsableContent(empty))
        var withOverview = BurstResearch()
        withOverview.overview = "有内容"
        XCTAssertTrue(BurstResearchParser.hasUsableContent(withOverview))
    }

    func testParseStampsSearchStatus() {
        let json = """
        {"summary": "s", "overview": "o", "timeline": [], "sources": [], "needsRefetch": false, "refetchURLs": []}
        """
        let research = BurstResearchParser.parse(json, searchStatus: .failed)
        XCTAssertEqual(research?.searchStatus, .failed)
        XCTAssertEqual(research?.summary, "s")
    }

    func testParseDefaultSearchStatusIsNone() {
        let json = """
        {"summary": "s", "overview": "o", "timeline": [], "sources": [], "needsRefetch": false, "refetchURLs": []}
        """
        let research = BurstResearchParser.parse(json)
        XCTAssertNotNil(research)
        XCTAssertEqual(research?.searchStatus, BurstSearchStatus.none)
    }

    func testEmptyBurstResearchDefaultsToNoneSearchStatus() {
        XCTAssertEqual(BurstResearch().searchStatus, BurstSearchStatus.none)
    }
}
