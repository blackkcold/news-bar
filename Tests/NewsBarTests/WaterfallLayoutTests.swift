import CoreGraphics
import XCTest
@testable import NewsBar

final class WaterfallLayoutTests: XCTestCase {
    func testColumnCountGrowsOnlyWhenEveryColumnKeepsTheMinimumCardWidth() {
        let gap = WaterfallLayout.columnSpacing
        let minimum = WaterfallLayout.minCardWidth

        XCTAssertEqual(WaterfallLayout.columnCount(for: 0), 1)
        XCTAssertEqual(WaterfallLayout.columnCount(for: minimum), 1)
        XCTAssertEqual(WaterfallLayout.columnCount(for: minimum * 2 + gap - 0.5), 1)
        XCTAssertEqual(WaterfallLayout.columnCount(for: minimum * 2 + gap), 2)
        XCTAssertEqual(WaterfallLayout.columnCount(for: minimum * 3 + gap * 2 - 0.5), 2)
        XCTAssertEqual(WaterfallLayout.columnCount(for: minimum * 3 + gap * 2), 3)
        XCTAssertEqual(WaterfallLayout.columnCount(for: 4_000), WaterfallLayout.maxColumns)
    }

    func testColumnWidthKeepsTheMinimumAtEveryThreshold() {
        for columns in 1...WaterfallLayout.maxColumns {
            let width = WaterfallLayout.minimumWidth(forColumns: columns)
            XCTAssertEqual(WaterfallLayout.columnCount(for: width), columns)
            XCTAssertGreaterThanOrEqual(
                WaterfallLayout.columnWidth(for: width, columns: columns),
                WaterfallLayout.minCardWidth - 0.001
            )
        }
    }

    func testColumnWidthSubtractsOnlyTheGapsBetweenColumns() {
        XCTAssertEqual(WaterfallLayout.columnWidth(for: 840, columns: 3), 272, accuracy: 0.001)
        XCTAssertEqual(WaterfallLayout.columnWidth(for: 556, columns: 2), 272, accuracy: 0.001)
        XCTAssertEqual(WaterfallLayout.columnWidth(for: 400, columns: 1), 400, accuracy: 0.001)
        XCTAssertEqual(WaterfallLayout.columnWidth(for: 0, columns: 3), 0, accuracy: 0.001)
    }

    func testShortestColumnAssignmentCoversEveryEntryAndBalancesHeight() {
        let heights: [CGFloat] = [320, 90, 240, 120, 300, 80, 160]
        let columns = WaterfallLayout.distribute(entryHeights: heights, columnCount: 3)

        XCTAssertEqual(columns.count, 3)
        XCTAssertEqual(columns.flatMap { $0 }.sorted(), Array(heights.indices))

        let loads = columns.map { indexes in
            indexes.reduce(CGFloat.zero) { partial, index in
                partial + heights[index] + WaterfallLayout.cardSpacing
            }
        }
        let tallest = (heights.max() ?? 0) + WaterfallLayout.cardSpacing
        XCTAssertLessThanOrEqual(
            (loads.max() ?? 0) - (loads.min() ?? 0),
            tallest + 0.001,
            "A greedy shortest-column pass must stay within one card of perfect balance"
        )
    }

    func testSingleColumnKeepsReadingOrder() {
        let heights: [CGFloat] = [120, 80, 200]
        XCTAssertEqual(
            WaterfallLayout.distribute(entryHeights: heights, columnCount: 1),
            [Array(heights.indices)]
        )
    }

    func testEmptyEntriesProduceEmptyColumns() {
        XCTAssertEqual(
            WaterfallLayout.distribute(entryHeights: [], columnCount: 3),
            [[], [], []]
        )
    }

    func testEstimatedTitleLinesUsesAvailableWidthAndCap() {
        let long = String(repeating: "这是一个非常长的中文标题", count: 20)
        XCTAssertEqual(
            WaterfallLayout.estimatedTitleLines(long, availableWidth: 300, maxLines: 3),
            3
        )
        XCTAssertEqual(
            WaterfallLayout.estimatedTitleLines("短标题", availableWidth: 300, maxLines: 4),
            1
        )
    }
}
