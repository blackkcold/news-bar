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

/// The exact inputs a masonry plan depends on.
///
/// Hashing the titles is cheaper than re-estimating every card's wrapped lines,
/// and the key carries the full text (not a length) so an edited card can never
/// reuse a stale plan.
struct WaterfallPlanKey: Hashable {
    enum Model: String, Hashable {
        case following
        case recommendation
        case rss
    }

    struct Entry: Hashable {
        let id: String
        let title: String
        let hasImage: Bool
    }

    let model: Model
    let entries: [Entry]
    let columnCount: Int
    /// Half-points. Continuous window resizing produces a stream of widths whose
    /// difference cannot move a card visibly; quantising keeps the plan stable
    /// through that stream while still changing at every real breakpoint.
    let columnWidthHalfPoints: Int

    init(model: Model, entries: [Entry], columnCount: Int, columnWidth: CGFloat) {
        self.model = model
        self.entries = entries
        self.columnCount = columnCount
        self.columnWidthHalfPoints = Self.halfPoints(for: columnWidth)
    }

    /// The width the plan is built with. It is the quantised value, not the raw
    /// one, so a key always maps to exactly one plan — building with the raw
    /// width let two widths in the same half-point bucket produce different
    /// column assignments depending on which one populated the cache first.
    var columnWidth: CGFloat {
        CGFloat(columnWidthHalfPoints) / 2
    }

    private static func halfPoints(for width: CGFloat) -> Int {
        guard width.isFinite else { return 0 }
        // Clamp before converting: a huge finite width would trap in Int().
        let clamped = min(max(width, 0), 100_000)
        return Int((clamped * 2).rounded())
    }
}

/// Bounded memo for masonry plans. A plan is a pure function of its key, so a
/// hit is always equal to what a rebuild would produce. Thread-safe: the plan
/// functions are also called from tests and from non-main contexts.
final class WaterfallPlanCache: @unchecked Sendable {
    static let shared = WaterfallPlanCache()

    private let lock = NSLock()
    private var storage: [WaterfallPlanKey: [[Int]]] = [:]
    private var order: [WaterfallPlanKey] = []
    private let capacity: Int

    init(capacity: Int = 8) {
        self.capacity = max(1, capacity)
    }

    func plan(for key: WaterfallPlanKey, build: () -> [[Int]]) -> [[Int]] {
        lock.lock()
        if let hit = storage[key] {
            order.removeAll { $0 == key }
            order.append(key)
            lock.unlock()
            return hit
        }
        lock.unlock()

        let built = build()

        lock.lock()
        // Another thread may have built the same plan while this one worked.
        if let hit = storage[key] {
            lock.unlock()
            return hit
        }
        storage[key] = built
        order.append(key)
        while order.count > capacity {
            let oldest = order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
        lock.unlock()
        return built
    }

    func removeAll() {
        lock.lock()
        storage.removeAll()
        order.removeAll()
        lock.unlock()
    }
}
