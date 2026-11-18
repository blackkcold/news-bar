import Foundation
import UserNotifications

/// The decision a notification click resolves to, independent of AppKit so it
/// can be unit tested without a running application.
enum NotificationRoute: Equatable {
    case dismiss
    case burst(eventID: String)
    case newsEvent(eventID: String)
    case research(recordID: String)
    case researchReport(recordID: String, eventID: String?, versionID: String?, compareFromVersionID: String?)
    case researchCorrection(
        recordID: String?,
        eventID: String?,
        versionID: String?,
        compareFromVersionID: String?,
        sourceURL: String?,
        title: String?
    )
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
        case .researchReport: return "researchReport"
        case .researchCorrection: return "researchCorrection"
        case .markResearchRead: return "markResearchRead"
        case .digest(let digest): return "digest(\(digest.itemCount))"
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
            if userInfo["eventID"] is String
                || userInfo["versionID"] is String
                || userInfo["compareFromVersionID"] is String
                || userInfo["semanticID"] is String {
                return .researchReport(
                    recordID: recordID,
                    eventID: userInfo["eventID"] as? String,
                    versionID: userInfo["versionID"] as? String,
                    compareFromVersionID: userInfo["compareFromVersionID"] as? String
                )
            }
            return .research(recordID: recordID)
        }

        if let type = userInfo["type"] as? String, type == "researchCorrection" {
            return .researchCorrection(
                recordID: userInfo["recordID"] as? String,
                eventID: userInfo["eventID"] as? String,
                versionID: userInfo["versionID"] as? String,
                compareFromVersionID: userInfo["compareFromVersionID"] as? String,
                sourceURL: userInfo["sourceURL"] as? String ?? userInfo["url"] as? String,
                title: userInfo["title"] as? String
            )
        }

        if let type = userInfo["type"] as? String, type == "newsEvent",
           let eventID = userInfo["eventID"] as? String, !eventID.isEmpty {
            if userInfo["change"] as? String == NewsEventChangeKind.correction.rawValue {
                return .researchCorrection(
                    recordID: userInfo["recordID"] as? String,
                    eventID: eventID,
                    versionID: userInfo["versionID"] as? String,
                    compareFromVersionID: userInfo["compareFromVersionID"] as? String,
                    sourceURL: userInfo["url"] as? String,
                    title: userInfo["title"] as? String
                )
            }
            if let url = userInfo["url"] as? String {
                return .news(url: url, title: userInfo["title"] as? String ?? "")
            }
            return .newsEvent(eventID: eventID)
        }

        if let type = userInfo["type"] as? String, type == "burst",
           let eventID = userInfo["eventID"] as? String {
            return .burst(eventID: eventID)
        }

        let digest = NotificationDigest.decode(userInfo["digest"] as? String)
        if let digest, !digest.items.isEmpty || !digest.researchItems.isEmpty {
            if !digest.researchItems.isEmpty { return .digest(digest) }
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
