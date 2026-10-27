import XCTest
@testable import NewsBar

final class WeiboHotFeedTests: XCTestCase {
    func testAjaxParserKeepsTwentyRowsAndHotLabels() throws {
        let realtime: [[String: Any]] = (0..<25).map { index in
            var entry: [String: Any] = ["word": "热点 \(index)"]
            if index == 0 {
                entry["label_name"] = "爆"
            }
            return entry
        }
        let payload: [String: Any] = ["data": ["realtime": realtime]]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let items = try WeiboHotService.parseAjaxResponse(data: data)
        XCTAssertEqual(items.count, 20)
        XCTAssertEqual(items.first?.hotLabel, "爆")

        let feed = WeiboHotService.makeFeed(items: items, hotLabelsAvailable: true)
        XCTAssertEqual(feed.displayItems.count, 5)
        XCTAssertEqual(feed.detectionItems.count, 20)
        XCTAssertTrue(feed.hotLabelsAvailable)
        XCTAssertEqual(feed.displayItems.compactMap(\.rank), [1, 2, 3, 4, 5])
    }

    func testHTMLFallbackKeepsRowsButReportsNoHotLabels() throws {
        let anchors = (0..<8)
            .map { "<a href=\"/weibo?q=topic\($0)\">话题 \($0)</a>" }
            .joined()
        let html = "<html><body>\(anchors)</body></html>"

        let items = try WeiboHotService.parseSummaryHTML(html)
        XCTAssertEqual(items.count, 8)
        XCTAssertTrue(items.allSatisfy { $0.hotLabel == nil })

        let feed = WeiboHotService.makeFeed(items: items, hotLabelsAvailable: false)
        XCTAssertEqual(feed.displayItems.count, 5)
        XCTAssertEqual(feed.detectionItems.count, 8)
        XCTAssertFalse(feed.hotLabelsAvailable)
    }
}
