import Foundation

/// Admission policy shared by every feed-triggered research origin.
/// User-initiated runs use the same global ledger cap but are not subject to
/// the automatic daily target or feed cadence.
///
/// The policy is deliberately deterministic: it runs before a record is
/// created, so a blocked candidate leaves no queued ghost behind. A failed run
/// also counts against the window — otherwise a broken provider would be retried
/// on every feed refresh.
enum ResearchAutomationPolicy {
    /// Ordinary automatic runs are spaced by one hour. A qualified urgent
    /// event may bypass this cadence, within the task and AI/search hard caps.
    static let minimumInterval: TimeInterval = 60 * 60
    /// Cheap skips (empty pool, keyword priority) do not spend the paid
    /// selector window, but they still must not re-rank on every refresh.
    static let cheapCheckInterval: TimeInterval = 5 * 60
    /// One running plus at most one waiting automatic job. Feed refreshes must
    /// never stack work the user did not ask for.
    static let maxActiveAutomaticRuns = 1
    static let ordinaryDailyTaskTarget = 3
    static let urgentWindow: TimeInterval = 2 * 60 * 60
    static let maximumUrgentExtras = 2

    /// How many user/agent-requested research jobs may be running or waiting.
    ///
    /// Automatic runs are capped at one, because a feed refresh must never stack
    /// work nobody asked for. An explicit request is different — it may be
    /// legitimate to queue a few — but "explicit" is not "unlimited": the CLI's
    /// `research start` can be called in a loop, and each job costs real search
    /// and AI budget. Measured before this cap existed: nothing bounded the
    /// manual queue at all, so distinct topics could pile up without limit and
    /// then drain on later days against a fresh daily allowance.
    static let maxActiveManualRuns = 3

    /// Whether one more explicit research request may be admitted.
    static func allowsManualAdmission(activeManualRuns: Int) -> Bool {
        activeManualRuns < maxActiveManualRuns
    }

    static func ordinaryDailyTarget(taskCap: Int) -> Int {
        max(0, min(ordinaryDailyTaskTarget, taskCap))
    }

    static func isUrgentWindow(_ date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= 0 && age <= urgentWindow
    }

    static func urgentExtraSlotAllows(
        eventID: String,
        starts: [AutomaticUrgentResearchStart],
        now: Date
    ) -> Bool {
        let recent = starts.filter { isUrgentWindow($0.startedAt, now: now) }
        return recent.filter(\.isExtra).count < maximumUrgentExtras
            && !recent.contains(where: { $0.eventID == eventID })
    }

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
