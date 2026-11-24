import XCTest
@testable import NewsBar

final class RSSFirstRunTests: XCTestCase {
    func testAutoExpandsOnlyWithoutSources() {
        XCTAssertTrue(RSSRecommendationVisibility.isExpanded(state: "auto", sourceCount: 0))
        XCTAssertFalse(RSSRecommendationVisibility.isExpanded(state: "auto", sourceCount: 1))
    }

    func testExplicitStateWinsOverSourceCount() {
        XCTAssertTrue(RSSRecommendationVisibility.isExpanded(state: "expanded", sourceCount: 3))
        XCTAssertFalse(RSSRecommendationVisibility.isExpanded(state: "collapsed", sourceCount: 0))
    }
}
