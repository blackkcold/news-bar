import Foundation

/// One-automatic-page latch shared by the masonry feeds.
///
/// The "load more" control prefetches a page when it enters the viewport. The
/// latch makes that happen once per approach: staying visible (short list,
/// resize, reflow) cannot walk through the whole feed, and leaving the viewport
/// re-arms it for the next approach.
struct MasonryPrefetchLatch: Equatable {
    private(set) var isLatched = false

    /// Returns true exactly when a page should load for this visibility event.
    mutating func visibilityChanged(_ visible: Bool) -> Bool {
        guard visible else {
            isLatched = false
            return false
        }
        guard !isLatched else { return false }
        isLatched = true
        return true
    }
}
