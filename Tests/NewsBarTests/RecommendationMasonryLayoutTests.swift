import CoreGraphics
import XCTest
@testable import NewsBar

final class RecommendationMasonryLayoutTests: XCTestCase {
    func testColumnCountUsesTheSharedWaterfallBreakpoints() {
        for width in stride(from: 200.0, through: 1_400.0, by: 7.0) {
            XCTAssertEqual(
                RecommendationMasonryLayout.columnCount(for: width),
                WaterfallLayout.columnCount(for: width),
                "width \(width)"
            )
        }
        XCTAssertEqual(RecommendationMasonryLayout.columnCount(for: 320), 1)
        XCTAssertEqual(RecommendationMasonryLayout.columnCount(for: 555), 1)
        XCTAssertEqual(RecommendationMasonryLayout.columnCount(for: 556), 2)
        XCTAssertEqual(RecommendationMasonryLayout.columnCount(for: 839), 2)
        XCTAssertEqual(RecommendationMasonryLayout.columnCount(for: 840), 3)
        XCTAssertEqual(RecommendationMasonryLayout.columnCount(for: 1_400), 3)
    }

    func testColumnWidthSubtractsOnlyTheGapsBetweenColumns() {
        XCTAssertEqual(
            RecommendationMasonryLayout.columnWidth(for: 800, columns: 2),
            394,
            accuracy: 0.001
        )
        XCTAssertEqual(
            RecommendationMasonryLayout.columnWidth(for: 960, columns: 3),
            312,
            accuracy: 0.001
        )
        XCTAssertEqual(
            RecommendationMasonryLayout.columnWidth(for: 400, columns: 1),
            400,
            accuracy: 0.001
        )
    }

    func testImageHeightIsClampedForNarrowAndWideColumns() {
        XCTAssertEqual(RecommendationMasonryLayout.imageHeight(forColumnWidth: 100), 112)
        XCTAssertEqual(RecommendationMasonryLayout.imageHeight(forColumnWidth: 386), 193)
        XCTAssertEqual(RecommendationMasonryLayout.imageHeight(forColumnWidth: 1_200), 220)
    }

    func testChineseTitlesWrapSoonerThanLatinTitles() {
        let width: CGFloat = 386
        let latinLines = RecommendationMasonryLayout.estimatedTitleLines(
            "A short English headline about a local event",
            columnWidth: width
        )
        let chineseLines = RecommendationMasonryLayout.estimatedTitleLines(
            "一条关于本地事件与产业变化的简短中文新闻标题",
            columnWidth: width
        )
        XCTAssertGreaterThanOrEqual(chineseLines, latinLines)
    }

    func testEstimatedTitleLinesAreCappedAtFour() {
        let long = String(repeating: "这是一个非常长的中文标题", count: 20)
        XCTAssertEqual(
            RecommendationMasonryLayout.estimatedTitleLines(long, columnWidth: 320),
            4
        )
    }

    func testImageCardIsEstimatedTallerThanTextCard() {
        let title = "同一标题"
        let withImage = RecommendationMasonryLayout.estimatedHeight(
            title: title, hasImage: true, columnWidth: 386
        )
        let withoutImage = RecommendationMasonryLayout.estimatedHeight(
            title: title, hasImage: false, columnWidth: 386
        )
        XCTAssertGreaterThan(withImage, withoutImage)
    }

    func testColumnsCoverEveryEntryExactlyOnce() {
        let entries = makeEntries(count: 37)
        let columns = RecommendationMasonryLayout.columns(
            for: entries,
            columnCount: 3,
            columnWidth: 312
        )

        XCTAssertEqual(columns.count, 3)
        let flattened = columns.flatMap { $0 }
        XCTAssertEqual(flattened.count, entries.count)
        XCTAssertEqual(Set(flattened), Set(entries.indices))
    }

    func testAppendingAPageDoesNotMoveExistingCards() {
        let entries = makeEntries(count: 60)
        let firstPage = RecommendationMasonryLayout.columns(
            for: Array(entries.prefix(20)),
            columnCount: 2,
            columnWidth: 386
        )
        let secondPage = RecommendationMasonryLayout.columns(
            for: Array(entries.prefix(40)),
            columnCount: 2,
            columnWidth: 386
        )

        for column in 0..<2 {
            let existingPrefix = Array(secondPage[column].prefix(firstPage[column].count))
            XCTAssertEqual(
                existingPrefix,
                firstPage[column],
                "Column \(column) reshuffled cards that were already visible"
            )
        }
    }

    func testRankingOrderIsPreservedInsideEachColumn() {
        let entries = makeEntries(count: 30)
        let columns = RecommendationMasonryLayout.columns(
            for: entries,
            columnCount: 3,
            columnWidth: 312
        )
        for column in columns {
            XCTAssertEqual(column, column.sorted())
        }
    }

    func testSingleColumnKeepsRankingOrder() {
        let entries = makeEntries(count: 12)
        let columns = RecommendationMasonryLayout.columns(
            for: entries,
            columnCount: 1,
            columnWidth: 320
        )
        XCTAssertEqual(columns, [Array(entries.indices)])
    }

    func testEmptyFeedProducesEmptyColumns() {
        let columns = RecommendationMasonryLayout.columns(
            for: [],
            columnCount: 3,
            columnWidth: 312
        )
        XCTAssertEqual(columns, [[], [], []])
    }

    private func makeEntries(count: Int) -> [RecommendationMasonryEntry] {
        (0..<count).map { index in
            RecommendationMasonryEntry(
                id: "item-\(index)",
                title: index.isMultiple(of: 3)
                    ? "这是一条中文新闻标题，长度大约用于测试列高估算 \(index)"
                    : "A representative English headline number \(index) for layout testing",
                hasImage: !index.isMultiple(of: 2)
            )
        }
    }
}
