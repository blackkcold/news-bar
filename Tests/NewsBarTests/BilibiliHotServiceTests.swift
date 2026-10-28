import XCTest
@testable import NewsBar

@MainActor
final class BilibiliHotServiceTests: XCTestCase {
    func testVideoOpensCanonicalURLWithoutChangingFeedIdentity() throws {
        let data = Data("""
        {"data":{"list":[{"title":"Video","short_link_v2":"https://b23.tv/example","bvid":"BV1xx411c7mD"}]}}
        """.utf8)
        let item = try XCTUnwrap(BilibiliHotService.decode(data).first)
        let router = NewsNavigationRouter()
        router.open(item, surface: "test")

        XCTAssertEqual(item.url, "https://b23.tv/example")
        XCTAssertEqual(router.selection?.url, "https://www.bilibili.com/video/BV1xx411c7mD")
    }

    func testMalformedVideoIDCannotChangeDestination() throws {
        let data = Data("""
        {"data":{"list":[{"title":"Video","short_link_v2":"https://b23.tv/example","bvid":"BV1xx411c7mD/../../private"}]}}
        """.utf8)
        let item = try XCTUnwrap(BilibiliHotService.decode(data).first)
        let router = NewsNavigationRouter()
        router.open(item, surface: "test")

        XCTAssertEqual(router.selection?.url, "https://b23.tv/example")
    }

    func testPreviouslyCachedNewsItemWithoutReaderURLStillDecodes() throws {
        let item = NewsItem(title: "Video", url: "https://b23.tv/example", source: .bilibili)
        let encoded = try JSONEncoder().encode(item)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "readerURL")
        let oldData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(NewsItem.self, from: oldData)
        XCTAssertEqual(decoded.id, item.id)
        XCTAssertNil(decoded.readerURL)
    }
}
