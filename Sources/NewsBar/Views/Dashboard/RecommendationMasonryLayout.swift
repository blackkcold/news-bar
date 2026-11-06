import CoreGraphics
import Foundation

/// One card as the masonry layout needs to see it. The layout only reads
/// identity, title length and whether a reserved image area exists, so a card
/// never has to lay itself out to participate in column assignment.
struct RecommendationMasonryEntry: Equatable, Sendable {
    let id: String
    let title: String
    let hasImage: Bool
}

/// Deterministic column assignment for the recommendation feed.
///
/// The feed is a real masonry, not a row-aligned grid: each card goes to the
/// currently shortest column. Assignment only depends on the ordered entries,
/// the column count and the column width, so appending another page of
/// recommendations never moves a card the reader has already seen.
///
/// Widths and breakpoints live in `WaterfallLayout` so the RSS feed on the
/// browse page cannot drift back to a hard-coded column count.
enum RecommendationMasonryLayout {
    static let columnSpacing = WaterfallLayout.columnSpacing
    static let cardSpacing = WaterfallLayout.cardSpacing
    static let cardHorizontalPadding: CGFloat = 14
    static let maxTitleLines = 4

    /// Breakpoints are measured on the recommendation area, not the window.
    /// The reader can narrow the feed to 280–440 pt while the window stays wide.
    static func columnCount(for width: CGFloat) -> Int {
        WaterfallLayout.columnCount(for: width)
    }

    static func columnWidth(for width: CGFloat, columns: Int) -> CGFloat {
        WaterfallLayout.columnWidth(for: width, columns: columns)
    }

    /// Reserve the image box before the download finishes. A wide single column
    /// gets a taller banner; multi-column cards stay compact. Clamping keeps a
    /// very narrow reader pane readable and a very wide window from turning the
    /// image into a half-screen poster.
    static func imageHeight(forColumnWidth width: CGFloat) -> CGFloat {
        min(220, max(112, width * 0.5))
    }

    /// Title width is estimated from the rendered character widths rather than
    /// character count: CJK glyphs are roughly twice as wide as Latin ones at
    /// the same point size.
    static func estimatedTitleLines(_ title: String, columnWidth: CGFloat) -> Int {
        WaterfallLayout.estimatedTitleLines(
            title,
            availableWidth: max(40, columnWidth - cardHorizontalPadding * 2),
            maxLines: maxTitleLines
        )
    }

    static func estimatedHeight(
        title: String,
        hasImage: Bool,
        columnWidth: CGFloat
    ) -> CGFloat {
        let lines = CGFloat(estimatedTitleLines(title, columnWidth: columnWidth))
        // 28 pt body padding + 16 pt meta row + 28 pt action row + spacing.
        let body: CGFloat = 92 + 20 * lines
        if hasImage {
            return body + imageHeight(forColumnWidth: columnWidth) + 6
        }
        // The text-only card carries a small source rule instead of an image.
        return body + 8
    }

    /// Returns, for each column, the indexes of the entries it owns. Indexes
    /// refer to the original ordered array so ranking position and attribution
    /// never change when the visual column changes.
    static func columns(
        for entries: [RecommendationMasonryEntry],
        columnCount: Int,
        columnWidth: CGFloat
    ) -> [[Int]] {
        WaterfallLayout.distribute(
            entryHeights: entries.map {
                estimatedHeight(
                    title: $0.title,
                    hasImage: $0.hasImage,
                    columnWidth: columnWidth
                )
            },
            columnCount: columnCount
        )
    }
}
