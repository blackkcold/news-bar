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
enum RecommendationMasonryLayout {
    static let columnSpacing: CGFloat = 12
    static let cardSpacing: CGFloat = 12
    static let cardHorizontalPadding: CGFloat = 14
    static let maxTitleLines = 4

    /// Breakpoints are measured on the recommendation area, not the window.
    /// The reader can narrow the feed to 320–480 pt while the window stays wide.
    static func columnCount(for width: CGFloat) -> Int {
        if width >= 960 { return 3 }
        if width >= 560 { return 2 }
        return 1
    }

    static func columnWidth(for width: CGFloat, columns: Int) -> CGFloat {
        let count = max(1, columns)
        let gaps = CGFloat(count - 1) * columnSpacing
        return max(0, (width - gaps) / CGFloat(count))
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
        let available = max(40, columnWidth - cardHorizontalPadding * 2)
        let normalized = title
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return 1 }
        let width: CGFloat = normalized.reduce(0) { partial, character in
            let scalar = character.unicodeScalars.first?.value ?? 0
            return partial + (scalar > 0x2E80 ? 15 : 7.6)
        }
        let lines = Int(ceil(width / available))
        return min(maxTitleLines, max(1, lines))
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
        let count = max(1, columnCount)
        guard count > 1 else { return [Array(entries.indices)] }

        var columns = Array(repeating: [Int](), count: count)
        var heights = Array(repeating: CGFloat.zero, count: count)

        for (index, entry) in entries.enumerated() {
            var target = 0
            for candidate in 1..<count where heights[candidate] < heights[target] {
                target = candidate
            }
            columns[target].append(index)
            heights[target] += estimatedHeight(
                title: entry.title,
                hasImage: entry.hasImage,
                columnWidth: columnWidth
            ) + cardSpacing
        }
        return columns
    }
}
