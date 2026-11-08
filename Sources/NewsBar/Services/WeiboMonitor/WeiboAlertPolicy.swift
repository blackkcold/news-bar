import Foundation

enum WeiboAlertSuppression: Equatable, Sendable {
    case monitoringDisabled
    case notifyDisabled
    case muted
    case notifyModeFeedOnly
    case priorityFeedOnly
    case keywordsMissed
    case keywordsUnavailable
    case quietHours
    case accountCap
    case globalCap
    /// The relevance model collapsed the post, so it never becomes a push.
    case filteredByRelevance(WeiboRelevanceVerdict)

    var titleKey: String {
        switch self {
        case .monitoringDisabled: return "weibo.suppressed.monitoringDisabled"
        case .notifyDisabled: return "weibo.suppressed.notifyDisabled"
        case .muted: return "weibo.suppressed.muted"
        case .notifyModeFeedOnly: return "weibo.suppressed.notifyModeFeedOnly"
        case .priorityFeedOnly: return "weibo.suppressed.priorityFeedOnly"
        case .keywordsMissed: return "weibo.suppressed.keywordsMissed"
        case .keywordsUnavailable: return "weibo.suppressed.keywordsUnavailable"
        case .quietHours: return "weibo.suppressed.quietHours"
        case .accountCap: return "weibo.suppressed.accountCap"
        case .globalCap: return "weibo.suppressed.globalCap"
        case .filteredByRelevance(let verdict):
            return "weibo.suppressed.relevance.\(verdict.rawValue)"
        }
    }
}

enum WeiboAlertDecision: Equatable, Sendable {
    case notify
    case feedOnly(WeiboAlertSuppression)

    var shouldNotify: Bool {
        if case .notify = self { return true }
        return false
    }

    var suppression: WeiboAlertSuppression? {
        if case .feedOnly(let reason) = self { return reason }
        return nil
    }
}

/// Decides whether a new post becomes a system notification. Delivery and
/// persistence happen elsewhere; this type is pure so every rule is testable.
struct WeiboAlertPolicy: Sendable {
    var calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func decision(
        for post: WeiboPost,
        user: WeiboMonitorUser,
        config: WeiboMonitorConfig,
        now: Date,
        accountNotificationsLastHour: Int,
        globalNotificationsLastHour: Int,
        verdict: WeiboRelevanceVerdict? = nil
    ) -> WeiboAlertDecision {
        guard config.enabled else { return .feedOnly(.monitoringDisabled) }
        guard config.notifyEnabled else { return .feedOnly(.notifyDisabled) }
        guard !user.isMuted(now: now) else { return .feedOnly(.muted) }

        // Collapsed posts are decided here, before any mode-specific rule.
        // `nil` means "not judged" and stays fail-open.
        if let verdict, verdict.isCollapsed {
            return .feedOnly(.filteredByRelevance(verdict))
        }

        if user.notifyMode == .feedOnly {
            return .feedOnly(.notifyModeFeedOnly)
        }

        if user.priority == .p2 && user.notifyMode != .all {
            return .feedOnly(.priorityFeedOnly)
        }

        if user.priority == .p1 && user.notifyMode == .keywords {
            // A post the relevance model calls relevant already expresses the
            // account's beat; a keyword list must not veto it a second time.
            if verdict != .relevant {
                guard config.keywordNotifyEnabled else { return .feedOnly(.keywordsUnavailable) }
                guard config.hasKeywords else { return .feedOnly(.keywordsMissed) }
                guard Self.matchesKeywords(post.displayText, keywords: config.keywordList) else {
                    return .feedOnly(.keywordsMissed)
                }
            }
        }

        if user.priority != .p0 && isQuietHours(now) {
            return .feedOnly(.quietHours)
        }

        if accountNotificationsLastHour >= config.perAccountHourlyCap {
            return .feedOnly(.accountCap)
        }
        if globalNotificationsLastHour >= config.globalHourlyCap {
            return .feedOnly(.globalCap)
        }

        return .notify
    }

    func isQuietHours(_ date: Date) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return minute >= 23 * 60 + 30 || minute < 8 * 60
    }

    static func matchesKeywords(_ text: String, keywords: [String]) -> Bool {
        let haystack = text.lowercased()
        guard !haystack.isEmpty else { return false }
        return keywords.contains { keyword in
            let needle = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !needle.isEmpty && haystack.contains(needle)
        }
    }

    /// Builds the one notification for a batch of posts from one account. The
    /// batch is at most 45 seconds old, so "just now" is accurate enough and
    /// avoids a clock-skew-looking timestamp in the subtitle.
    func notification(
        for posts: [WeiboPost],
        user: WeiboMonitorUser,
        language: AppLanguage,
        now: Date
    ) -> WeiboAlertNotification? {
        guard let latest = posts.max(by: { $0.createdAt < $1.createdAt }) else { return nil }
        let count = posts.count
        let title: String
        let subtitle: String
        let body: String
        let requestID: String

        if count == 1 {
            title = user.screenName
            subtitle = L10n.string("weibo.notif.subtitle", language: language, timeString(latest.createdAt, language: language))
            body = clipped(latest.displayText, language: language)
            requestID = "weibo-\(latest.mid)"
        } else {
            title = L10n.string("weibo.notif.aggregateTitle", language: language, user.screenName, count)
            subtitle = L10n.string("weibo.notif.aggregateSubtitle", language: language)
            let firstText = clipped(latest.displayText, language: language)
            body = L10n.string("weibo.notif.aggregateBody", language: language, firstText, count)
            requestID = "weibo-\(user.uid)-\(latest.mid)"
        }

        return WeiboAlertNotification(
            uid: user.uid,
            screenName: user.screenName,
            title: title,
            subtitle: subtitle,
            body: body,
            mid: latest.mid,
            url: latest.url,
            threadID: "weibo.\(user.uid)",
            requestID: requestID,
            postCount: count,
            firstPostAt: posts.map(\.createdAt).min() ?? now
        )
    }

    private func clipped(_ text: String, language: AppLanguage) -> String {
        let sanitized = SecurityPolicies.sanitizeHTMLContent(text)
        let fallback = L10n.string("weibo.notif.emptyBody", language: language)
        let value = sanitized.isEmpty ? fallback : sanitized
        let limit = 80
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "…"
    }

    private func timeString(_ date: Date, language: AppLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language.bcp47)
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
