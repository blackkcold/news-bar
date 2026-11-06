import CoreGraphics
import XCTest
@testable import NewsBar

final class DashboardRSSMasonryLayoutTests: XCTestCase {
    func testColumnsFollowTheSharedWaterfallRuleAndNeverOverflow() {
        let items = makeItems(count: 12)
        for width in [280.0, 440.0, 556.0, 756.0, 812.0, 840.0, 1_016.0, 1_200.0] {
            let plan = DashboardAdaptiveRSSMasonryFeed.plan(
                for: items,
                width: width,
                prefersSingleColumn: false
            )
            XCTAssertEqual(
                plan.columnCount,
                WaterfallLayout.columnCount(for: width),
                "width \(width)"
            )
            XCTAssertEqual(
                plan.columnCount,
                RecommendationMasonryLayout.columnCount(for: width),
                "The two feeds must switch columns at the same slot width: \(width)"
            )
            XCTAssertEqual(plan.columns.count, plan.columnCount, "width \(width)")
            XCTAssertEqual(
                plan.columns.flatMap { $0 }.sorted(),
                Array(items.indices),
                "width \(width)"
            )
            let occupied = CGFloat(plan.columnCount) * plan.columnWidth
                + CGFloat(plan.columnCount - 1) * WaterfallLayout.columnSpacing
            XCTAssertEqual(
                occupied,
                width - DashboardAdaptiveRSSMasonryFeed.contentInset,
                accuracy: 0.5,
                "width \(width)"
            )
        }
    }

    func testVoiceOverForcesOneColumnAndKeepsReadingOrder() {
        let items = makeItems(count: 6)
        let plan = DashboardAdaptiveRSSMasonryFeed.plan(
            for: items,
            width: 1_200,
            prefersSingleColumn: true
        )
        XCTAssertEqual(plan.columnCount, 1)
        XCTAssertEqual(plan.columns, [Array(items.indices)])
        XCTAssertEqual(
            plan.columnWidth,
            1_200 - DashboardAdaptiveRSSMasonryFeed.contentInset,
            accuracy: 0.5
        )
    }

    func testWideRSSSlotAddsColumnsInsteadOfStretchingTwoCards() {
        let items = makeItems(count: 9)
        let compact = DashboardAdaptiveRSSMasonryFeed.plan(
            for: items,
            width: 440,
            prefersSingleColumn: false
        )
        let wide = DashboardAdaptiveRSSMasonryFeed.plan(
            for: items,
            width: 1_200,
            prefersSingleColumn: false
        )
        XCTAssertEqual(compact.columnCount, 1)
        XCTAssertEqual(wide.columnCount, 3)
        XCTAssertLessThan(
            wide.columnWidth,
            compact.columnWidth,
            "Wider slots add columns instead of stretching one card across the page"
        )
    }

    private func makeItems(count: Int) -> [NewsItem] {
        (0..<count).map { index in
            NewsItem(
                title: "RSS item \(index) with a representative headline",
                url: "https://example.com/rss/\(index)",
                source: .rss(name: "Source", url: "https://example.com/feed"),
                rank: index
            )
        }
    }
}
