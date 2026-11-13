import Foundation
import UserNotifications

/// The decision a notification click resolves to, independent of AppKit so it
/// can be unit tested without a running application.
enum NotificationRoute: Equatable {
    case dismiss
    case burst(eventID: String)
    case newsEvent(eventID: String)
    case research(recordID: String)
    case markResearchRead(recordID: String)
    case digest(NotificationDigest)
    case news(url: String, title: String)
    case weibo(mid: String, uid: String, url: String?)
    case muteWeibo(uid: String)
    case markWeiboRead(mid: String, uid: String)
    case dashboard

    /// Short, log-safe name. The digest payload is deliberately not printed.
    var label: String {
        switch self {
        case .dismiss: return "dismiss"
        case .burst: return "burst"
        case .newsEvent: return "newsEvent"
        case .research: return "research"
        case .markResearchRead: return "markResearchRead"
        case .digest(let digest): return "digest(\(digest.items.count))"
        case .news: return "news"
        case .weibo: return "weibo"
        case .muteWeibo: return "muteWeibo"
        case .markWeiboRead: return "markWeiboRead"
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

        if let type = userInfo["type"] as? String, type == "weibo" {
            let uid = userInfo["uid"] as? String ?? ""
            let mid = userInfo["mid"] as? String ?? ""
            if actionIdentifier == NotificationIdentifier.muteWeiboAction, !uid.isEmpty {
                return .muteWeibo(uid: uid)
            }
            if actionIdentifier == NotificationIdentifier.markWeiboReadAction, !mid.isEmpty {
                return .markWeiboRead(mid: mid, uid: uid)
            }
            let rawURL = userInfo["url"] as? String
            let url = (rawURL?.isEmpty == false) ? rawURL : nil
            return .weibo(mid: mid, uid: uid, url: url)
        }

        if let type = userInfo["type"] as? String, type == "research",
           let recordID = userInfo["recordID"] as? String {
            if actionIdentifier == NotificationIdentifier.markResearchReadAction {
                return .markResearchRead(recordID: recordID)
            }
            return .research(recordID: recordID)
        }

        if let type = userInfo["type"] as? String, type == "newsEvent",
           let eventID = userInfo["eventID"] as? String, !eventID.isEmpty {
            return .newsEvent(eventID: eventID)
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
