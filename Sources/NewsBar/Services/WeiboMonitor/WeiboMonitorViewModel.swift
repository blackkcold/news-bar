import Foundation
import Network
import SwiftUI
import UserNotifications
import os

/// The main-actor facade the SwiftUI layers use. The service stays an actor;
/// this object mirrors its latest snapshot and serializes user actions.
@MainActor
@Observable
final class WeiboMonitorViewModel {
    private static let logger = Logger(subsystem: "com.newsbar.app", category: "weibo-monitor")
    private let settings: AppSettings
    private let service: WeiboMonitorService
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.newsbar.app.weibo-monitor.network")
    private var changeObserver: NSObjectProtocol?
    private var activityToken: NSObjectProtocol?
    private var isOnline = true
    private var isStarted = false
    private var relevanceDeciders: [any WeiboRelevanceDeciding] = []
    private var relevanceDeciderSignature: String?

    private(set) var snapshot: WeiboMonitorSnapshot = .empty
    private(set) var isWorking = false
    private(set) var isAdding = false
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    var actionError: String?

    init(settings: AppSettings, service: WeiboMonitorService? = nil) {
        self.settings = settings
        if let service {
            self.service = service
        } else {
            let store = WeiboMonitorStore()
            self.service = WeiboMonitorService(
                store: store,
                notifier: WeiboNotificationAdapter(),
                authAlertRecorder: { [weak settings] date in
                    await MainActor.run {
                        settings?.weiboMonitorAuthAlertAt = date
                    }
                }
            )
        }

        changeObserver = NotificationCenter.default.addObserver(
            forName: .weiboMonitorChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isOnline = path.status == .satisfied
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    deinit {
        pathMonitor.cancel()
    }

    // MARK: - Lifecycle

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        let config = WeiboMonitorConfig.from(settings)
        await service.start(now: Date(), config: config)
        updateActivity(enabled: config.enabled)
        await refreshNotificationStatus()
        await refresh()
    }

    func stop() {
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
        pathMonitor.cancel()
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
            self.changeObserver = nil
        }
    }

    func tick(now: Date = Date()) async {
        if !isStarted {
            await start()
        }
        let config = WeiboMonitorConfig.from(settings)
        updateActivity(enabled: config.enabled)
        let credentials = await loadCredentials()
        await service.tick(
            now: now,
            config: config,
            credentials: credentials,
            isLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            isOnline: isOnline,
            relevanceDeciders: resolveRelevanceDeciders()
        )
        await refresh()
    }

    func handleWake(now: Date = Date()) async {
        await service.handleWake(now: now)
        await tick(now: now)
    }

    func refresh() async {
        snapshot = await service.snapshot()
    }

    func refreshNotificationStatus() async {
        // The XCTest host has no app bundle; asking UserNotifications for its
        // status there raises. The rendering tests still need the rest of the
        // page, so use a benign value in tests.
        if TestIsolation.isActive {
            notificationStatus = .authorized
            return
        }
        notificationStatus = await NotificationService.authorizationStatus()
        if notificationStatus == .denied {
            Self.logger.notice("authorizationDenied")
        }
    }

    // MARK: - Account actions

    @discardableResult
    func addUser(
        input: String,
        priority: WeiboMonitorPriority = .p1,
        notifyMode: WeiboNotifyMode? = nil
    ) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        isAdding = true
        defer {
            isWorking = false
            isAdding = false
        }
        do {
            _ = try await service.addUser(
                input: input,
                priority: priority,
                notifyMode: notifyMode,
                now: Date()
            )
            actionError = nil
            await tick()
            return true
        } catch let error as WeiboMonitorAddError {
            actionError = L10n.string(
                error == .duplicate ? "weibo.accounts.addDuplicate" : "weibo.accounts.addInvalid",
                language: settings.appLanguage
            )
            return false
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }

    func removeUser(_ uid: String) async {
        await run { [self] in await self.service.removeUser(uid: uid, now: Date()) }
    }

    func setPriority(_ uid: String, priority: WeiboMonitorPriority) async {
        await run { [self] in await self.service.setPriority(uid: uid, priority: priority, now: Date()) }
    }

    func setNotifyMode(_ uid: String, mode: WeiboNotifyMode) async {
        await run { [self] in await self.service.setNotifyMode(uid: uid, mode: mode, now: Date()) }
    }

    func setRelevanceMode(_ uid: String, mode: WeiboRelevanceMode?) async {
        await run { [self] in
            await self.service.setRelevanceMode(uid: uid, mode: mode, now: Date())
        }
    }

    func setEnabled(_ uid: String, enabled: Bool) async {
        await run { [self] in await self.service.setEnabled(uid: uid, enabled: enabled, now: Date()) }
    }

    func checkNow(_ uid: String) async {
        await run { [self] in await self.service.checkNow(uid: uid, now: Date()) }
        await tick()
    }

    func checkAll() async {
        await run { [self] in await self.service.checkAll(now: Date()) }
        await tick()
    }

    func mute(_ uid: String, for duration: TimeInterval = 3600) async {
        let until = Date().addingTimeInterval(duration)
        await run { [self] in await self.service.mute(uid: uid, until: until, now: Date()) }
    }

    func resumeUser(_ uid: String) async {
        await run { [self] in await self.service.resumeUser(uid: uid, now: Date()) }
        await tick()
    }

    func pauseAll(for duration: TimeInterval = 3600) async {
        let until = Date().addingTimeInterval(duration)
        await run { [self] in await self.service.pauseAll(until: until, now: Date()) }
    }

    func resumeAll() async {
        await run { [self] in await self.service.resumeAll(now: Date()) }
        await tick()
    }

    func markRead(mid: String, uid: String? = nil) async {
        await run { [self] in await self.service.markRead(mid: mid, now: Date()) }
    }

    func markAllRead() async {
        await run { [self] in await self.service.markAllRead(now: Date()) }
    }

    func clearGap(uid: String? = nil) async {
        await run { [self] in await self.service.clearGap(uid: uid, now: Date()) }
    }

    func persistNow() async {
        await service.persistNow(now: Date())
    }

    // MARK: - Navigation

    func openLogin() {
        NewsNavigationRouter.shared.open(
            url: "https://weibo.com",
            title: "微博",
            item: nil,
            surface: "weiboLogin"
        )
    }

    func openPost(_ post: WeiboPost) {
        Task { await markRead(mid: post.mid, uid: post.uid) }
        NotificationCenter.default.post(name: .openWeiboFollowFeed, object: nil)
        NewsNavigationRouter.shared.open(
            url: post.url,
            title: post.screenName,
            item: nil,
            surface: "weiboFollowing"
        )
    }

    func openNotificationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Helpers

    private func run(_ action: @escaping @MainActor () async -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        await action()
        actionError = nil
        await refresh()
    }

    /// Clients are rebuilt only when the relevant settings change, so a toggle
    /// takes effect on the next tick instead of requiring an app restart.
    private func resolveRelevanceDeciders() -> [any WeiboRelevanceDeciding] {
        let enabled = settings.weiboMonitorRelevanceAICorrection
            && settings.weiboMonitorRelevancePrivacyAckAt != nil
        let preferLocal = settings.weiboMonitorRelevancePreferLocal
        let signature = "\(enabled)-\(preferLocal)"
        if relevanceDeciderSignature == signature {
            return relevanceDeciders
        }
        relevanceDeciderSignature = signature
        guard enabled else {
            relevanceDeciders = []
            return []
        }
        var deciders: [any WeiboRelevanceDeciding] = []
        if preferLocal {
            deciders.append(WeiboSystemOneClient.ollamaLocal())
            deciders.append(WeiboSystemOneClient.openCodeFree())
        } else {
            deciders.append(WeiboSystemOneClient.openCodeFree())
            deciders.append(WeiboSystemOneClient.ollamaLocal())
        }
        relevanceDeciders = deciders
        return deciders
    }

    private func loadCredentials() async -> WeiboCredentials {
        let desktop = await BrowserDataController.shared.cookiesForInjection(host: "weibo.com")
        let mobile = await BrowserDataController.shared.cookiesForInjection(host: "m.weibo.cn")
        let desktopHeader = Self.cookieHeader(from: desktop)
        let mobileHeader = Self.cookieHeader(from: mobile)
        return WeiboCredentials(
            desktopCookieHeader: desktopHeader,
            mobileCookieHeader: mobileHeader,
            hasDesktopLogin: desktop.contains { $0.name == "SUB" && !$0.value.isEmpty },
            hasMobileLogin: mobile.contains { $0.name == "SUB" && !$0.value.isEmpty }
        )
    }

    private static func cookieHeader(from cookies: [HTTPCookie]) -> String? {
        guard !cookies.isEmpty else { return nil }
        let fields = HTTPCookie.requestHeaderFields(with: cookies)
        return fields["Cookie"]
    }

    private func updateActivity(enabled: Bool) {
        if enabled, activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.background],
                reason: "Weibo monitor polling"
            )
        } else if !enabled, let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
    }

    /// The notification delegate runs outside the main actor. It only needs a
    /// lock-protected boolean, not the whole view model.
    static func setFeedVisible(_ visible: Bool) {
        WeiboFeedPresence.setVisible(visible)
    }
}

private let weiboFeedPresenceLock = NSLock()
private struct WeiboFeedPresenceState {
    var isVisible = false
    var isAppActive = true
}
private var weiboFeedPresenceState = WeiboFeedPresenceState()

enum WeiboFeedPresence {
    static var isVisible: Bool {
        weiboFeedPresenceLock.lock()
        defer { weiboFeedPresenceLock.unlock() }
        return weiboFeedPresenceState.isVisible
    }

    static var isAppActive: Bool {
        weiboFeedPresenceLock.lock()
        defer { weiboFeedPresenceLock.unlock() }
        return weiboFeedPresenceState.isAppActive
    }

    static func setVisible(_ visible: Bool) {
        weiboFeedPresenceLock.lock()
        weiboFeedPresenceState.isVisible = visible
        weiboFeedPresenceLock.unlock()
    }

    static func setAppActive(_ active: Bool) {
        weiboFeedPresenceLock.lock()
        weiboFeedPresenceState.isAppActive = active
        weiboFeedPresenceLock.unlock()
    }
}
