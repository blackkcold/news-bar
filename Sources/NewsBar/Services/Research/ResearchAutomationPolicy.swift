import Foundation

/// Hard admission budget shared by every feed-triggered research origin
/// (burst and keyword). User-initiated runs are exempt.
///
/// The policy is deliberately deterministic: it runs before a record is
/// created, so a blocked candidate leaves no queued ghost behind. A failed run
/// also counts against the window — otherwise a broken provider would be retried
/// on every feed refresh.
enum ResearchAutomationPolicy {
    /// Any 60-minute window may start at most one automatic run.
    static let minimumInterval: TimeInterval = 60 * 60
    /// One running plus at most one waiting automatic job. Feed refreshes must
    /// never stack work the user did not ask for.
    static let maxActiveAutomaticRuns = 1

    static func allows(
        now: Date,
        lastStartedAt: Date?,
        activeAutomaticRuns: Int
    ) -> Bool {
        guard activeAutomaticRuns < maxActiveAutomaticRuns else { return false }
        guard let lastStartedAt else { return true }
        return now.timeIntervalSince(lastStartedAt) >= minimumInterval
    }

    /// Seconds left in the current window; 0 when a run is allowed.
    static func remainingCooldown(now: Date, lastStartedAt: Date?) -> TimeInterval {
        guard let lastStartedAt else { return 0 }
        return max(0, minimumInterval - now.timeIntervalSince(lastStartedAt))
    }
}
