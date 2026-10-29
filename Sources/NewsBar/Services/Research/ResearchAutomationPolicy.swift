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
    /// Cheap skips (empty pool, keyword priority) do not spend the paid
    /// selector window, but they still must not re-rank on every refresh.
    static let cheapCheckInterval: TimeInterval = 5 * 60
    /// One running plus at most one waiting automatic job. Feed refreshes must
    /// never stack work the user did not ask for.
    static let maxActiveAutomaticRuns = 1

    /// Only a paid judgement or a started run may consume the hourly selector
    /// window. An empty pool or a keyword pass must not hide a later burst for
    /// a full hour.
    static func skipConsumesCheckWindow(_ kind: ResearchAutomaticDecision.Kind) -> Bool {
        switch kind {
        case .skippedNoCandidates, .skippedKeywordPriority:
            return false
        default:
            return true
        }
    }

    static func cheapCheckAllows(now: Date, lastCheapCheckAt: Date?) -> Bool {
        guard let lastCheapCheckAt else { return true }
        return now.timeIntervalSince(lastCheapCheckAt) >= cheapCheckInterval
    }

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

/// Explicit keywords outrank inferred interest, but only while a match is
/// still actionable. A keyword already researched or blocked must not keep
/// hiding the interest and public-chart paths.
enum ResearchKeywordPriority {
    static func hasUnprocessedMatch(
        items: [NewsItem],
        keywords: [String],
        handledPairs: Set<String>,
        handledTitles: Set<String>,
        isBlocked: (NewsItem) -> Bool
    ) -> Bool {
        guard !keywords.isEmpty else { return false }
        for item in items {
            guard !isBlocked(item), !handledTitles.contains(item.title) else { continue }
            guard let keyword = keywords.first(where: { TitleFeatures.matches($0, in: item.title) }) else { continue }
            if !handledPairs.contains("\(keyword)\n\(item.title)") { return true }
        }
        return false
    }
}
