import Foundation
import UserNotifications

enum NotificationService {
    static let maxPushCount = 3

    /// Builds the notification content for an aggregated push. The first item
    /// keeps the legacy `url`/`title`/`newsItemID` keys so notifications that
    /// were already delivered before the digest payload existed still open a
    /// single article; new notifications additionally carry a decodable digest.
    static func titleContent(items: [NewsItem], daily: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()

        guard !items.isEmpty else {
            content.title = L10n.string(daily ? "notif.dailyTitle" : "notif.hourlyTitle", language: L10n.currentLanguage)
            content.userInfo = ["type": "daily"]
            return content
        }

        content.title = L10n.string(
            daily ? "notif.dailyTitleCount" : "notif.hourlyTitleCount",
            language: L10n.currentLanguage,
            items.count
        )
        content.subtitle = sourceSummary(items)
        content.body = items.map { "• " + clipped($0.displayTitle) }.joined(separator: "\n")
        content.sound = .default
        content.threadIdentifier = "newsbar.digest"
        content.categoryIdentifier = NotificationIdentifier.digestCategory
        content.interruptionLevel = .active

        var userInfo: [String: Any] = ["type": "news"]
        if let first = items.first {
            userInfo["url"] = first.url
            userInfo["title"] = first.displayTitle
            userInfo["newsItemID"] = first.id
            userInfo["snapshotAsOf"] = Date().timeIntervalSince1970
        }
        if let digest = NotificationDigest.encode(
            NotificationDigest(kind: daily ? "daily" : "hourly", items: items)
        ) {
            userInfo["digest"] = digest
        }
        content.userInfo = userInfo
        return content
    }

    static func registerCategories() {
        let openDigest = UNNotificationAction(
            identifier: NotificationIdentifier.openDigestAction,
            title: L10n.string("notif.action.openDigest"),
            options: [.foreground]
        )
        let digestCategory = UNNotificationCategory(
            identifier: NotificationIdentifier.digestCategory,
            actions: [openDigest],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        let openResearch = UNNotificationAction(
            identifier: NotificationIdentifier.openResearchAction,
            title: L10n.string("research.action.open"),
            options: [.foreground]
        )
        let markRead = UNNotificationAction(
            identifier: NotificationIdentifier.markResearchReadAction,
            title: L10n.string("research.action.markRead"),
            options: []
        )
        let researchCategory = UNNotificationCategory(
            identifier: NotificationIdentifier.researchCategory,
            actions: [openResearch, markRead],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        // setNotificationCategories is replace-all; both categories must be
        // registered together or the digest actions disappear.
        UNUserNotificationCenter.current().setNotificationCategories([digestCategory, researchCategory])
    }

    /// "微博热搜 2 · B站热搜 1", keeping first-seen order and capping at three
    /// source names.
    static func sourceSummary(_ items: [NewsItem]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for item in items {
            let name = item.source.displayName
            if counts[name] == nil {
                order.append(name)
            }
            counts[name, default: 0] += 1
        }

        let visible = order.prefix(3).map { "\($0) \(counts[$0, default: 0])" }
        guard !visible.isEmpty else { return "" }
        let joined = visible.joined(separator: " · ")
        return order.count > 3 ? "\(joined) \(L10n.string("notif.digest.etc"))" : joined
    }

    static func clipped(_ text: String, limit: Int = 60) -> String {
        let sanitized = SecurityPolicies.sanitizeHTMLContent(text)
        guard sanitized.count > limit else { return sanitized }
        return String(sanitized.prefix(limit)) + "…"
    }

    /// Keeps the settings value and the service in agreement even if an old
    /// UserDefaults value (or a corrupted one) is outside 1...3.
    static func normalizedPushCount(_ count: Int) -> Int {
        min(max(count, 1), maxPushCount)
    }

    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            NSLog("[NotificationService] Authorization failed: %@", error.localizedDescription)
            return false
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func sendHourlyPush(items: [NewsItem], count: Int) async {
        guard count > 0, !items.isEmpty else { return }

        let topItems = Array(items.prefix(normalizedPushCount(count)))
        let content = titleContent(items: topItems, daily: false)

        let request = UNNotificationRequest(
            identifier: "hourly-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func rescheduleDailyPush(items: [NewsItem], count: Int, hour: Int, minute: Int = 0) {
        guard count > 0, !items.isEmpty else { return }

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["daily-summary"])

        let topItems = Array(items.prefix(normalizedPushCount(count)))
        let content = titleContent(items: topItems, daily: true)

        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute

        // A frozen title snapshot is sent once, not repeated indefinitely after app exit.
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
        let request = UNNotificationRequest(
            identifier: "daily-summary",
            content: content,
            trigger: trigger
        )
        center.add(request) { error in
            if let error = error {
                NSLog("[NotificationService] rescheduleDailyPush failed: %@", error.localizedDescription)
            }
        }
    }

    static func scheduleDailyPush(hour: Int, minute: Int = 0) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["daily-summary"])

        let content = UNMutableNotificationContent()
        content.title = L10n.string("notif.dailyTitle", language: L10n.currentLanguage)
        content.body = L10n.string("notif.clickToView", language: L10n.currentLanguage)
        content.sound = nil
        content.userInfo = ["type": "daily"]

        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(
            identifier: "daily-summary",
            content: content,
            trigger: trigger
        )
        center.add(request) { error in
            if let error = error {
                NSLog("[NotificationService] scheduleDailyPush failed: %@", error.localizedDescription)
            }
        }
    }

    /// Sends a single notification for a Weibo "爆" (burst) topic. The research
    /// `summary` becomes the body; `userInfo` carries the event identity so the
    /// notification delegate can route a click to the burst research window.
    static func sendBurstNotification(title: String, summary: String, eventID: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = SecurityPolicies.sanitizeHTMLContent(summary)
        content.sound = .default
        content.userInfo = ["type": "burst", "eventID": eventID]
        content.categoryIdentifier = "burst"

        let request = UNNotificationRequest(
            identifier: "burst-\(eventID)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("[NotificationService] sendBurstNotification failed: %@", error.localizedDescription)
            }
        }
    }

    /// Sends one notification when a research record reaches `ready`. The
    /// record ID is the routing key; the title is only a display fallback.
    static func sendResearchNotification(record: ResearchRecord) {
        guard let report = record.report else { return }

        let language = L10n.currentLanguage
        let titlePrefix: String
        switch record.origin {
        case .burst:
            titlePrefix = L10n.string("notif.burstTitle", language: language)
        case .keyword:
            titlePrefix = L10n.string("notif.keywordTitle", language: language)
        case .manual:
            titlePrefix = L10n.string("research.notifTitle", language: language)
        }

        let content = UNMutableNotificationContent()
        content.title = "\(titlePrefix) \(record.topic)"
        let body = report.summary.isEmpty ? report.overview : report.summary
        content.body = SecurityPolicies.sanitizeHTMLContent(
            body.isEmpty ? L10n.string("burst.noSummary", language: language) : body
        )
        content.sound = .default
        content.threadIdentifier = "research"
        content.categoryIdentifier = NotificationIdentifier.researchCategory
        content.userInfo = [
            "type": "research",
            "recordID": record.id,
            "title": record.topic,
        ]

        let request = UNNotificationRequest(
            identifier: "research-\(record.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("[NotificationService] sendResearchNotification failed: %@", error.localizedDescription)
            }
        }
    }

    static func clearAllPending() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    static func clearPersonalizedNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}
