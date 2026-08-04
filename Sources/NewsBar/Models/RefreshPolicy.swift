import Foundation

enum RefreshVisibility: Equatable, Sendable {
    case visible
    case background
    case lowPower
}

struct BatchProgress: Equatable, Sendable {
    var completed: Int
    var total: Int

    static let zero = BatchProgress(completed: 0, total: 0)
}

enum RefreshPolicy {
    static let schedulerTick: TimeInterval = 60
    static let visibleHotInterval: TimeInterval = 5 * 60
    static let backgroundHotInterval: TimeInterval = 30 * 60
    static let lowPowerHotInterval: TimeInterval = 60 * 60

    static let activeRSSInterval: TimeInterval = 30 * 60
    static let normalRSSInterval: TimeInterval = 60 * 60
    static let quietRSSInterval: TimeInterval = 3 * 60 * 60
    static let trendSummaryMinimumInterval: TimeInterval = 30 * 60
    static let dailySummaryMinimumInterval: TimeInterval = 4 * 60 * 60

    /// Regular baseline before an automatic summary may regenerate (1 hour).
    static let autoSummaryInterval: TimeInterval = 60 * 60
    /// Minimum gap before the same "爆" (burst) Weibo topic retriggers an immediate summary.
    static let burstSummaryCooldown: TimeInterval = 15 * 60

    static func rssFailureRetryInterval(failureCount: Int) -> TimeInterval {
        guard failureCount > 0 else { return normalRSSInterval }
        let exponent = min(failureCount - 1, 4)
        return min(15 * 60 * TimeInterval(1 << exponent), quietRSSInterval)
    }

    static func hotInterval(for visibility: RefreshVisibility) -> TimeInterval {
        switch visibility {
        case .visible: return visibleHotInterval
        case .background: return backgroundHotInterval
        case .lowPower: return lowPowerHotInterval
        }
    }

    static func rssInterval(
        unchangedRefreshCount: Int,
        changedRecently: Bool,
        visibility: RefreshVisibility
    ) -> TimeInterval {
        if visibility == .lowPower { return quietRSSInterval }
        if unchangedRefreshCount >= 6 { return quietRSSInterval }
        if changedRecently { return activeRSSInterval }
        return normalRSSInterval
    }

    static func jittered(_ interval: TimeInterval, key: String) -> TimeInterval {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let normalized = Double(hash % 2_001) / 10_000 - 0.1
        return interval * (1 + normalized)
    }

    static func isDue(
        lastRefresh: Date?,
        interval: TimeInterval,
        key: String,
        now: Date = Date()
    ) -> Bool {
        guard let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) >= jittered(interval, key: key)
    }
}
