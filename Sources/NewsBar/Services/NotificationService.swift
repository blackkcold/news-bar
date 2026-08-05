import Foundation
import UserNotifications

enum NotificationService {

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
        let content = UNMutableNotificationContent()
        content.title = L10n.string("notif.hourlyTitle", language: L10n.currentLanguage)
        let bodyText = topItems
            .map { SecurityPolicies.sanitizeHTMLContent($0.displayTitle) }
            .joined(separator: "\n• ")
        content.body = "• " + bodyText
        content.sound = nil

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
        let content = UNMutableNotificationContent()
        content.title = L10n.string("notif.dailyTitle", language: L10n.currentLanguage)
        content.body = topItems
            .map { SecurityPolicies.sanitizeHTMLContent($0.displayTitle) }
            .joined(separator: "\n• ")
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

    static func clearAllPending() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}