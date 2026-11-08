import Foundation

extension Notification.Name {
    /// Posted on the main actor after any monitor state change. The view model
    /// mirrors the service snapshot; the app delegate refreshes the menu badge.
    static let weiboMonitorChanged = Notification.Name("weiboMonitorChanged")
    /// Ask the dashboard to switch to the following feed.
    static let openWeiboFollowFeed = Notification.Name("openWeiboFollowFeed")
    /// Ask the settings window to select the Weibo monitor pane.
    static let switchToWeiboMonitor = Notification.Name("switchToWeiboMonitor")
}

protocol WeiboAlertNotifying: Sendable {
    func send(_ notification: WeiboAlertNotification, language: AppLanguage) async
    func sendAuthExpired(language: AppLanguage) async
}

/// Test/default notifier. Production injects the adapter that calls
/// `NotificationService`; keeping the protocol here lets the service be tested
/// without a notification center or a running app.
struct NoopWeiboAlertNotifier: WeiboAlertNotifying {
    func send(_ notification: WeiboAlertNotification, language: AppLanguage) async {}
    func sendAuthExpired(language: AppLanguage) async {}
}
