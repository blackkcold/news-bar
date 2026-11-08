import Foundation

/// The notification payload is built by the pure alert policy and delivered by
/// `NotificationService`. Keeping it a value type makes the policy testable
/// without UserNotifications and keeps the service free of presentation code.
struct WeiboAlertNotification: Equatable, Sendable {
    var uid: String
    var screenName: String
    var title: String
    var subtitle: String
    var body: String
    var mid: String
    var url: String?
    var threadID: String
    var requestID: String
    var postCount: Int
    var firstPostAt: Date
}
