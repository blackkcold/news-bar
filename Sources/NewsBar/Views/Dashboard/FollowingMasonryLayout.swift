import CoreGraphics
import Foundation

/// Geometry for the following waterfall. Card height is estimated from the
/// account row, body text and cover image so the shared `WaterfallLayout`
/// can assign columns without laying every card out first.
enum FollowingMasonryLayout {
    static let cardPadding: CGFloat = 12
    static let imageHeightCap: CGFloat = 190
    static let imageHeightFloor: CGFloat = 96

    /// The widest the following waterfall may get. 3 × 372 + 2 × 12 = 1140,
    /// which makes every card exactly as wide as an RSS item card at the
    /// default 1180-wide window. Wider windows keep the card size and leave
    /// trailing space rather than growing the reading measure.
    static let maxFeedWidth: CGFloat = 1140

    static func feedWidth(for availableWidth: CGFloat) -> CGFloat {
        min(max(1, availableWidth), maxFeedWidth)
    }

    static func columnCount(for width: CGFloat) -> Int {
        WaterfallLayout.columnCount(for: width)
    }

    static func columnWidth(for width: CGFloat, columns: Int) -> CGFloat {
        WaterfallLayout.columnWidth(for: width, columns: columns)
    }

    static func imageHeight(forColumnWidth width: CGFloat) -> CGFloat {
        min(imageHeightCap, max(imageHeightFloor, width * 0.54))
    }

    static func estimatedHeight(
        entry: FollowingPostEntry,
        columnWidth: CGFloat
    ) -> CGFloat {
        let textWidth = max(40, columnWidth - cardPadding * 2)
        let lines = CGFloat(WaterfallLayout.estimatedTitleLines(
            entry.post.displayText,
            availableWidth: textWidth,
            maxLines: 6
        ))
        let account: CGFloat = 24
        let body = 18 * lines
        let image = entry.post.imageURLs.isEmpty
            ? 0
            : imageHeight(forColumnWidth: columnWidth) + 6
        let meta: CGFloat = 18
        return cardPadding * 2 + account + 6 + body + image + 6 + meta
    }

    static func columns(
        for entries: [FollowingPostEntry],
        columnCount: Int,
        columnWidth: CGFloat
    ) -> [[Int]] {
        let key = WaterfallPlanKey(
            model: .following,
            entries: entries.map {
                WaterfallPlanKey.Entry(
                    id: $0.id,
                    title: $0.post.displayText,
                    hasImage: !$0.post.imageURLs.isEmpty
                )
            },
            columnCount: columnCount,
            columnWidth: columnWidth
        )
        return WaterfallPlanCache.shared.plan(for: key) {
            WaterfallLayout.distribute(
                entryHeights: entries.map {
                    estimatedHeight(entry: $0, columnWidth: key.columnWidth)
                },
                columnCount: columnCount
            )
        }
    }
}
