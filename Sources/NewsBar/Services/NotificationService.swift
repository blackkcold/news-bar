import Foundation
import UserNotifications

enum NotificationService {

    /// Title-only fallback; never starts an AI request to produce a notification.
    static func titleContent(items: [NewsItem], daily: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = L10n.string(daily ? "notif.dailyTitle" : "notif.hourlyTitle", language: L10n.currentLanguage)
        content.body = items.map { SecurityPolicies.sanitizeHTMLContent($0.displayTitle) }.joined(separator: "\n• ")
        content.sound = nil
        if let first = items.first {
            content.userInfo = ["type": "news", "url": first.url, "title": first.displayTitle, "newsItemID": first.id,
                                "snapshotAsOf": Date().timeIntervalSince1970]
        } else { content.userInfo = ["type": "daily"] }
        return content
    }

    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge])
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

        let topItems = Array(items.prefix(count))
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

        let topItems = Array(items.prefix(count))
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

    static func clearAllPending() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    static func clearPersonalizedNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}
