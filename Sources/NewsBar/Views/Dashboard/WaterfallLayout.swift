import CoreGraphics
import Foundation

/// Shared geometry for every waterfall surface in the dashboard.
///
/// Column counts are derived from the smallest readable slot instead of
/// hand-tuned width constants: a new column only exists once the slot can keep
/// `minCardWidth`. The recommendation feed reads exactly that; the RSS feed
/// sits inside a source card whose fixed 28 pt inset narrows its cards slightly,
/// but that inset never changes the column-count decision, so both surfaces
/// switch columns at the same dashboard width.
enum WaterfallLayout {
    static let columnSpacing: CGFloat = 12
    static let cardSpacing: CGFloat = 12
    static let minCardWidth: CGFloat = 272
    static let maxColumns = 3

    static func minimumWidth(forColumns columns: Int) -> CGFloat {
        let count = max(1, columns)
        return CGFloat(count) * minCardWidth + CGFloat(count - 1) * columnSpacing
    }

    static func columnCount(for width: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        var count = 1
        while count < maxColumns, width >= minimumWidth(forColumns: count + 1) {
            count += 1
        }
        return count
    }

    static func columnWidth(for width: CGFloat, columns: Int) -> CGFloat {
        let count = max(1, columns)
        guard width.isFinite, width > 0 else { return 0 }
        return max(0, (width - CGFloat(count - 1) * columnSpacing) / CGFloat(count))
    }

    /// Greedy shortest-column assignment. The returned indexes refer to the
    /// original ordered array, so ranking position and card identity never
    /// change when the visual column changes.
    static func distribute(entryHeights: [CGFloat], columnCount: Int) -> [[Int]] {
        let count = max(1, columnCount)
        guard count > 1 else { return [Array(entryHeights.indices)] }

        var columns = Array(repeating: [Int](), count: count)
        var heights = Array(repeating: CGFloat.zero, count: count)
        for (index, height) in entryHeights.enumerated() {
            var target = 0
            for candidate in 1..<count where heights[candidate] < heights[target] {
                target = candidate
            }
            columns[target].append(index)
            heights[target] += max(0, height.isFinite ? height : 0) + cardSpacing
        }
        return columns
    }

    /// Estimated wrapped lines for a card title. Widths come from the rendered
    /// character mix rather than the character count: CJK glyphs are roughly
    /// twice as wide as Latin ones at the same point size.
    static func estimatedTitleLines(
        _ title: String,
        availableWidth: CGFloat,
        maxLines: Int
    ) -> Int {
        let width = max(40, availableWidth.isFinite ? availableWidth : 40)
        let normalized = title
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return 1 }
        let measured: CGFloat = normalized.reduce(0) { partial, character in
            let scalar = character.unicodeScalars.first?.value ?? 0
            return partial + (scalar > 0x2E80 ? 15 : 7.6)
        }
        let lines = Int(ceil(measured / width))
        return min(max(1, maxLines), max(1, lines))
    }
}
