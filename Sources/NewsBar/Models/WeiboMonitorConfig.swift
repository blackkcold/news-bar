import Foundation

/// A value snapshot of the settings the monitor needs. Passing this into the
/// service keeps network code away from `AppSettings` and makes every
/// scheduling decision reproducible in tests.
struct WeiboMonitorConfig: Equatable, Sendable {
    var enabled: Bool = false
    var notifyEnabled: Bool = true
    var p0Seconds: Int = 120
    var p1Seconds: Int = 300
    var p2Seconds: Int = 900
    var nightEnabled: Bool = true
    /// Minutes after midnight. 30 = 00:30, 450 = 07:30.
    var nightStartMinute: Int = 30
    var nightEndMinute: Int = 450
    var perAccountHourlyCap: Int = 6
    var globalHourlyCap: Int = 20
    var keywordNotifyEnabled: Bool = true
    var keywordList: [String] = []
    var backfillHours: Int = 0
    /// Local relevance filtering. Disabled means every post stays visible and
    /// every old notification rule applies unchanged.
    var relevanceEnabled: Bool = true
    var relevanceMode: WeiboRelevanceMode = .balanced
    /// Opt-in decision-model correction. Off by default: the cloud endpoint
    /// receives the post body, so it must be a deliberate choice.
    var relevanceAICorrection: Bool = false
    var relevancePreferLocal: Bool = false
    var language: AppLanguage = .zh
    /// Last time the one-shot "login expired" alert was delivered. The service
    /// only reads it; the view model persists the new value.
    var lastAuthAlertAt: Date?

    static let `default` = WeiboMonitorConfig()

    @MainActor
    static func from(_ settings: AppSettings) -> WeiboMonitorConfig {
        WeiboMonitorConfig(
            enabled: settings.weiboMonitorEnabled,
            notifyEnabled: settings.weiboMonitorNotifyEnabled,
            p0Seconds: settings.weiboMonitorP0Seconds,
            p1Seconds: settings.weiboMonitorP1Seconds,
            p2Seconds: settings.weiboMonitorP2Seconds,
            nightEnabled: settings.weiboMonitorNightEnabled,
            nightStartMinute: settings.weiboMonitorNightStartMinute,
            nightEndMinute: settings.weiboMonitorNightEndMinute,
            perAccountHourlyCap: settings.weiboMonitorPerAccountHourlyCap,
            globalHourlyCap: settings.weiboMonitorGlobalHourlyCap,
            keywordNotifyEnabled: settings.weiboMonitorKeywordNotifyEnabled,
            keywordList: settings.weiboMonitorKeywordList,
            backfillHours: min(max(settings.weiboMonitorBackfillHours, 0), 2),
            relevanceEnabled: settings.weiboMonitorRelevanceEnabled,
            relevanceMode: settings.weiboMonitorRelevanceMode,
            relevanceAICorrection: settings.weiboMonitorRelevanceAICorrection,
            relevancePreferLocal: settings.weiboMonitorRelevancePreferLocal,
            language: settings.appLanguage,
            lastAuthAlertAt: settings.weiboMonitorAuthAlertAt
        )
    }

    func interval(for priority: WeiboMonitorPriority) -> TimeInterval {
        let configured: Int
        switch priority {
        case .p0: configured = p0Seconds
        case .p1: configured = p1Seconds
        case .p2: configured = p2Seconds
        }
        return max(priority.minimumInterval, TimeInterval(configured))
    }

    var hasKeywords: Bool {
        keywordList.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The mode that actually applies to an account. A per-account override
    /// wins; the global switch still turns everything off.
    func effectiveRelevanceMode(for user: WeiboMonitorUser) -> WeiboRelevanceMode {
        guard relevanceEnabled else { return .off }
        return user.relevanceMode ?? relevanceMode
    }
}
