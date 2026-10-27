import Foundation
import UserNotifications

/// The decision a notification click resolves to, independent of AppKit so it
/// can be unit tested without a running application.
enum NotificationRoute: Equatable {
    case dismiss
    case burst(eventID: String)
    case digest(NotificationDigest)
    case news(url: String, title: String)
    case dashboard

    /// Short, log-safe name. The digest payload is deliberately not printed.
    var label: String {
        switch self {
        case .dismiss: return "dismiss"
        case .burst: return "burst"
        case .digest(let digest): return "digest(\(digest.items.count))"
        case .news: return "news"
        case .dashboard: return "dashboard"
        }
    }
}

enum NotificationClickRouter {
    static func route(
        userInfo: [AnyHashable: Any],
        actionIdentifier: String
    ) -> NotificationRoute {
        if actionIdentifier == UNNotificationDismissActionIdentifier {
            return .dismiss
        }

        if let type = userInfo["type"] as? String, type == "burst",
           let eventID = userInfo["eventID"] as? String {
            return .burst(eventID: eventID)
        }

        let digest = NotificationDigest.decode(userInfo["digest"] as? String)
        if let digest, !digest.items.isEmpty {
            if digest.items.count > 1 || actionIdentifier == NotificationIdentifier.openDigestAction {
                return .digest(digest)
            }
            if let first = digest.items.first {
                return .news(url: first.url, title: first.displayTitle)
            }
        }

        if let type = userInfo["type"] as? String, type == "news",
           let url = userInfo["url"] as? String {
            return .news(url: url, title: userInfo["title"] as? String ?? "")
        }

        return .dashboard
    }
}
