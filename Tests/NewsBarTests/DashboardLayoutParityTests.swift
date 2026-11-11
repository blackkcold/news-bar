import CoreGraphics
import XCTest
@testable import NewsBar

final class DashboardLayoutParityTests: XCTestCase {
    func testFilterMetricsMatchDashboardBaseline() {
        XCTAssertEqual(DashboardFilterMetrics.searchIconSize, 13)
        XCTAssertEqual(DashboardFilterMetrics.searchTextSize, 13)
        XCTAssertEqual(DashboardFilterMetrics.searchClearSize, 12)
        XCTAssertEqual(DashboardFilterMetrics.searchHorizontalPadding, 12)
        XCTAssertEqual(DashboardFilterMetrics.searchVerticalPadding, 9)
        XCTAssertEqual(DashboardFilterMetrics.searchCornerRadius, 12)
        XCTAssertEqual(DashboardFilterMetrics.searchStackSpacing, 10)
        XCTAssertEqual(DashboardFilterMetrics.searchRetroBorderWidth, 1.4)
        XCTAssertEqual(DashboardFilterMetrics.chipFontSize, 11)
        XCTAssertEqual(DashboardFilterMetrics.chipHorizontalPadding, 12)
        XCTAssertEqual(DashboardFilterMetrics.chipVerticalPadding, 6)
        XCTAssertEqual(DashboardFilterMetrics.countFontSize, 10)
    }

    func testSourceBrowserIndexFollowsVisibleSidebarSections() {
        XCTAssertEqual(
            DashboardSectionIndex.sourceBrowser(hasHotTrends: false, hasFollowing: false),
            "02"
        )
        XCTAssertEqual(
            DashboardSectionIndex.sourceBrowser(hasHotTrends: true, hasFollowing: false),
            "03"
        )
        XCTAssertEqual(
            DashboardSectionIndex.sourceBrowser(hasHotTrends: false, hasFollowing: true),
            "03"
        )
        XCTAssertEqual(
            DashboardSectionIndex.sourceBrowser(hasHotTrends: true, hasFollowing: true),
            "04"
        )
    }

    func testDefaultWindowMatchesRSSItemWidth() {
        let contentWidth: CGFloat = 1180 - 40
        XCTAssertEqual(contentWidth, 1140, accuracy: 0.001)

        let sourceSlot = contentWidth
            - DashboardLayoutMetrics.sidebarWidth
            - DashboardLayoutMetrics.sidebarGap
        XCTAssertEqual(sourceSlot, 784, accuracy: 0.001)

        let rss = DashboardAdaptiveRSSMasonryFeed.plan(
            for: makeItems(count: 6),
            width: sourceSlot,
            prefersSingleColumn: false
        )
        XCTAssertEqual(rss.columnCount, 2)
        XCTAssertEqual(rss.columnWidth, 372, accuracy: 0.001)

        let followingWidth = FollowingMasonryLayout.feedWidth(for: contentWidth)
        XCTAssertEqual(followingWidth, 1140, accuracy: 0.001)
        let followingColumns = FollowingMasonryLayout.columnCount(for: followingWidth)
        XCTAssertEqual(followingColumns, 3)
        XCTAssertEqual(
            FollowingMasonryLayout.columnWidth(for: followingWidth, columns: followingColumns),
            372,
            accuracy: 0.001
        )
    }

    func testWideWindowCapsFollowingAt1140() {
        let contentWidth: CGFloat = 1440 - 40
        XCTAssertEqual(contentWidth, 1400, accuracy: 0.001)

        let followingWidth = FollowingMasonryLayout.feedWidth(for: contentWidth)
        XCTAssertEqual(followingWidth, 1140, accuracy: 0.001)
        XCTAssertEqual(contentWidth - followingWidth, 260, accuracy: 0.001)

        let columns = FollowingMasonryLayout.columnCount(for: followingWidth)
        XCTAssertEqual(columns, 3)
        XCTAssertEqual(
            FollowingMasonryLayout.columnWidth(for: followingWidth, columns: columns),
            372,
            accuracy: 0.001
        )
    }

    func testMinimumWindowKeepsThreeColumns() {
        let contentWidth: CGFloat = 960 - 40
        XCTAssertEqual(contentWidth, 920, accuracy: 0.001)

        let columns = FollowingMasonryLayout.columnCount(for: contentWidth)
        XCTAssertEqual(columns, 3)
        XCTAssertEqual(
            FollowingMasonryLayout.columnWidth(for: contentWidth, columns: columns),
            298.666,
            accuracy: 0.01
        )
    }

    func testReaderCompactWidthStaysSingleColumn() {
        let width: CGFloat = 440
        XCTAssertEqual(FollowingMasonryLayout.feedWidth(for: width), 440, accuracy: 0.001)
        XCTAssertEqual(FollowingMasonryLayout.columnCount(for: width), 1)
    }

    private func makeItems(count: Int) -> [NewsItem] {
        (0..<count).map { index in
            NewsItem(
                title: "测试标题 \(index)",
                url: "https://example.com/\(index)",
                source: .rss(name: "测试源", url: "https://example.com/feed"),
                rank: index
            )
        }
    }
}
