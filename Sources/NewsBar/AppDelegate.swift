import AppKit
import SwiftUI
import UserNotifications
import os

/// Notification-click diagnostics. `NSLog` is not captured for a GUI app
/// launched by `open`, so route decisions go to unified logging instead.
private let notificationLog = Logger(subsystem: "com.newsbar.app", category: "notifications")

extension Notification.Name {
    static let rssSourceAdded = Notification.Name("rssSourceAdded")
    static let switchToAITab = Notification.Name("switchToAITab")
    static let apiKeyConfigured = Notification.Name("apiKeyConfigured")
    static let fireFakeBurstPush = Notification.Name("fireFakeBurstPush")
    static let burstDetailRequest = Notification.Name("burstDetailRequest")
    static let fillBurstTestTopic = Notification.Name("fillBurstTestTopic")
    static let interestSettingsRequested = Notification.Name("interestSettingsRequested")
    static let switchToInterestSettings = Notification.Name("switchToInterestSettings")
    static let browserSettingsRequested = Notification.Name("browserSettingsRequested")
    static let switchToBrowserTab = Notification.Name("switchToBrowserTab")
    static let researchRequested = Notification.Name("researchRequested")
    static let fireTestNewsPush = Notification.Name("fireTestNewsPush")
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    // MARK: - Constants

    private static let schedulerTickInterval = RefreshPolicy.schedulerTick
    private static let startupDelay: TimeInterval = 2
    private static let updateCheckDelay: TimeInterval = 10
    private static let popoverSize = NSSize(width: 400, height: 520)
    private static let settingsSize = NSSize(width: 640, height: 560)
    private static let dashboardSize = NSSize(width: 1180, height: 860)
    private static let dashboardMinimumSize = NSSize(width: 960, height: 720)
    private static let researchCenterSize = NSSize(width: 1120, height: 760)
    private static let researchCenterMinimumSize = NSSize(width: 1000, height: 660)

    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?
    private var dashboardWindow: NSWindow?
    private var researchCenterWindow: NSWindow?
    private var researchCenterModel: ResearchCenterModel?

    private var settings: AppSettings!
    private var orchestrator: NewsOrchestrator?
    private var updateChecker: UpdateChecker?
    private var autoRefreshTimer: Timer?
    private var researchMaintenanceTimer: Timer?
    private var researchMaintenanceTask: Task<Void, Never>?
    private var dashboardRefreshTask: Task<Void, Never>?
    private var popoverRefreshTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isSystemSleeping = false
    private var terminationReplyPending = false

    private static let researchMaintenanceDelay: TimeInterval = 30
    private static let researchMaintenanceDebounce: Duration = .seconds(5)

    func applicationDidFinishLaunching(_ notification: Notification) {
        orchestrator = NewsOrchestrator()
        updateChecker = UpdateChecker()
        setupStatusBar()
        setupNotificationObservers()

        // 从 Keychain 迁移到加密文件存储（必须在任何读取之前）
        EncryptedKeyStore.migrateFromKeychainIfNeeded()
        settings = AppSettings()
        Task { await InterestController.shared.prepare() }
        Task { await ReaderRuleListCache.prewarm() }
        setupWorkspaceObservers()

        preloadCachedNews()
        loadAPIKeyFromFile()
        observeAPIKeyConfigured()
        refreshAPIKeyIfNeeded()
        scheduleStartupAndAutoRefresh()
        scheduleAutoUpdateCheck()
        scheduleResearchMaintenance()

        Task { _ = await NotificationService.requestAuthorization() }
        NotificationService.registerCategories()
        UNUserNotificationCenter.current().delegate = self
        // No launch-time rescheduling: pending requests survive quit now, and the
        // startup refresh installs the digest-bearing daily request. Installing a
        // plain template here could race that refresh and overwrite it.
    }

    private func scheduleStartupAndAutoRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startupDelay) { [weak self] in
            guard let self else { return }
            Task {
                await self.orchestrator?.refreshIfNeeded(settings: self.settings, trigger: .startup)
            }
        }

        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: Self.schedulerTickInterval, repeats: true) { [weak self] _ in
            guard let self,
                  self.settings.autoRefreshEnabled,
                  !self.isSystemSleeping else { return }
            let visibility = self.currentRefreshVisibility
            Task {
                await self.orchestrator?.refreshScheduled(
                    settings: self.settings,
                    visibility: visibility,
                    trigger: .scheduled
                )
            }
        }
    }

    private var currentRefreshVisibility: RefreshVisibility {
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return .lowPower
        }
        if popover?.isShown == true || dashboardWindow?.isVisible == true {
            return .visible
        }
        return .background
    }

    private func setupWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.isSystemSleeping = true
            }
        )
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.isSystemSleeping = false
                guard self.settings.autoRefreshEnabled else { return }
                let visibility = self.currentRefreshVisibility
                Task {
                    await self.orchestrator?.refreshScheduled(
                        settings: self.settings,
                        visibility: visibility,
                        trigger: .wake
                    )
                }
            }
        )
    }

    private func scheduleAutoUpdateCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.updateCheckDelay) { [weak self] in
            guard let self else { return }
            Task {
                await self.updateChecker?.autoCheck()
            }
        }
    }

    // MARK: - Research maintenance

    /// One-time ledger migration plus the periodic history/cache enforcement
    /// pass: 30 seconds after launch, debounced after record changes, and daily
    /// at 04:00. The settings page also triggers it immediately on limit changes.
    private func scheduleResearchMaintenance() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await ResearchMaintenance.shared.migrateLedgerIfNeeded(settings: self.settings)
            _ = await SearchKeyStore.migrateLegacyFirecrawlKey(settings: self.settings)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.researchMaintenanceDelay) { [weak self] in
            self?.runResearchMaintenance()
        }

        NotificationCenter.default.addObserver(
            forName: .researchRecordsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.researchMaintenanceTask?.cancel()
            self.researchMaintenanceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.researchMaintenanceDebounce)
                guard !Task.isCancelled else { return }
                self?.runResearchMaintenance()
            }
        }

        let calendar = Calendar.current
        guard let next = calendar.nextDate(
            after: Date(),
            matching: DateComponents(hour: 4, minute: 0),
            matchingPolicy: .nextTime
        ) else { return }
        let timer = Timer(fire: next, interval: 86_400, repeats: true) { [weak self] _ in
            self?.runResearchMaintenance()
        }
        RunLoop.main.add(timer, forMode: .common)
        researchMaintenanceTimer = timer
    }

    private func runResearchMaintenance() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var excluding = ResearchCoordinator.shared.activeRecordIDs()
            if let selected = ResearchSelectionTracker.shared.selectedID {
                excluding.insert(selected)
            }
            await ResearchMaintenance.shared.runEnforcement(
                settings: self.settings,
                excluding: excluding
            )
            await self.orchestrator?.refreshResearchSummary()
        }
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow, window === self.dashboardWindow else { return }
            Task { @MainActor in
                self.dashboardRefreshTask?.cancel()
                self.dashboardRefreshTask = nil
                NewsNavigationRouter.shared.close()
                NewsNavigationRouter.shared.dismissDigest()
                InterestController.shared.endListSession()
                DockPresence.hide()
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow, window === self.researchCenterWindow else { return }
            self.researchCenterWindow = nil
            self.researchCenterModel = nil
            if self.dashboardWindow?.isVisible != true { DockPresence.hide() }
        }
        NotificationCenter.default.addObserver(forName: .newsReaderRequested, object: nil, queue: .main) { [weak self] _ in
            self?.openDashboard(refresh: false)
        }
        NotificationCenter.default.addObserver(forName: .interestSettingsRequested, object: nil, queue: .main) { [weak self] _ in
            self?.openSettings()
            NotificationCenter.default.post(name: .switchToInterestSettings, object: nil)
        }
        NotificationCenter.default.addObserver(forName: .browserSettingsRequested, object: nil, queue: .main) { [weak self] _ in
            self?.openSettings()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .switchToBrowserTab, object: nil)
            }
        }
        NotificationCenter.default.addObserver(forName: .interestDataCleared, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.researchCenterWindow?.close()
                self?.researchCenterWindow?.contentViewController = nil
                self?.researchCenterWindow = nil
                self?.researchCenterModel = nil
                await self?.orchestrator?.clearPersonalizedArtifacts()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .rssSourceAdded,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let url = notification.userInfo?["url"] as? String,
                  let name = notification.userInfo?["name"] as? String else { return }
            Task {
                await self.orchestrator?.refreshRSSSource(url: url, name: name, settings: self.settings)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .fireFakeBurstPush,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let orchestrator = self.orchestrator else { return }
            Task { @MainActor in
                await orchestrator.fireFakeBurstPush(settings: self.settings)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .burstDetailRequest,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let title = notification.userInfo?["title"] as? String else { return }
            Task { @MainActor [weak self] in self?.openBurstWindow(title: title) }
        }

        NotificationCenter.default.addObserver(
            forName: .researchRequested,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let item = notification.userInfo?["item"] as? NewsItem else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard ResearchConsent.presentIfNeeded(settings: self.settings) else { return }
                if let recordID = await self.orchestrator?.startManualResearch(item: item, settings: self.settings) {
                    self.openResearchCenter(selecting: recordID)
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: .fillBurstTestTopic,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let orchestrator = self.orchestrator else { return }
            Task { @MainActor in
                let top = await orchestrator.fillBurstTestWithTopTrend()
                if !top.isEmpty {
                    self.settings.burstTestTopic = top
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: .fireTestNewsPush,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.sendTestNewsPush() }
        }
    }

    /// Developer-tab hook: delivers a real aggregated push right now, so the
    /// click → dashboard → digest-sheet path can be verified without waiting for
    /// the hourly schedule.
    @MainActor
    private func sendTestNewsPush() async {
        guard let orchestrator else { return }
        await orchestrator.loadCached(settings: settings)
        let items = NotificationSelectionPolicy.select(
            items: orchestrator.allActiveItems(settings: settings),
            state: InterestController.shared.state,
            count: settings.pushCount
        )
        await NotificationService.sendHourlyPush(items: items, count: settings.pushCount)
    }

    private func preloadCachedNews() {
        Task { [weak self] in
            guard let self, let orchestrator = self.orchestrator else { return }
            await orchestrator.preloadCached(settings: self.settings)
        }
    }

    private func currentProviderHasSavedKeyFlag() -> Bool {
        if settings.isUsingCustomProvider {
            let accountFlag = "hasAIKey-\(settings.activeAPIKeyAccount)"
            return UserDefaults.standard.bool(forKey: accountFlag)
        }
        let provider = settings.currentProvider
        let providerFlag = provider.keyExistsFlag()
        if UserDefaults.standard.bool(forKey: providerFlag) {
            return true
        }

        let accountFlag = "hasAIKey-\(provider.apiKeyAccount())"
        guard UserDefaults.standard.bool(forKey: accountFlag) else {
            return false
        }

        UserDefaults.standard.set(true, forKey: providerFlag)
        return true
    }

    private func refreshAPIKeyIfNeeded() {
        let ref = settings.onePasswordRef
        let account = settings.activeAPIKeyAccount
        guard currentProviderHasSavedKeyFlag(),
              !ref.isEmpty else { return }
        Task { [weak self] in
            guard let self else {
                NSLog("[Keychain] AppDelegate deallocated before 1Password key save")
                return
            }
            let store = EncryptedKeyStore()
            guard await store.isKeyStale(account: account),
                  OnePasswordService.isInstalled() else { return }
            do {
                let key = try await OnePasswordService.readSecretAsync(reference: ref)
                if await store.saveAPIKey(key, account: account) {
                    await MainActor.run {
                        self.settings.cachedAPIKey = key
                    }
                }
            } catch {
                // silent fail — will retry next launch
            }
        }
    }

    /// 启动时异步加载 API Key，确保定时器触发时 key 可用
    private func loadAPIKeyFromFile() {
        guard settings.aiSummaryEnabled, settings.cachedAPIKey == nil else { return }
        guard currentProviderHasSavedKeyFlag() else { return }
        let account = settings.activeAPIKeyAccount
        let providerID = settings.aiProvider
        let revision = settings.modelCatalogRevision
        Task { [weak self] in
            guard let self else { return }
            let store = EncryptedKeyStore()
            if let key = await store.readAPIKey(account: account), !key.isEmpty {
                await MainActor.run {
                    _ = self.settings.activateAPIKey(key, providerID: providerID, revision: revision)
                }
            }
        }
    }

    private func loadAPIKeyIfNeeded() {
        guard settings.aiSummaryEnabled,
              settings.cachedAPIKey == nil else { return }
        guard currentProviderHasSavedKeyFlag() else {
            Task { @MainActor in orchestrator?.aiSummaryState = .noKey }
            return
        }
        let account = settings.activeAPIKeyAccount
        let providerID = settings.aiProvider
        let revision = settings.modelCatalogRevision

        Task { @MainActor in orchestrator?.aiSummaryState = .idle }
        Task { [weak self] in
            guard let self else { return }
            let store = EncryptedKeyStore()
            if let key = await store.readAPIKey(account: account), !key.isEmpty {
                await MainActor.run {
                    guard self.settings.activateAPIKey(key, providerID: providerID, revision: revision) else { return }
                    UserDefaults.standard.set(true, forKey: self.settings.currentProvider.keyExistsFlag())
                    UserDefaults.standard.set(true, forKey: "hasAIKey-\(self.settings.activeAPIKeyAccount)")
                    Task {
                        await self.orchestrator?.manualRefresh(settings: self.settings)
                    }
                }
            }
        }
    }

    private func handleMissingAPIKey() {
        Task { @MainActor in orchestrator?.aiSummaryState = .noKey }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "hasShownAIKeySetupPrompt") { return }

        let alert = NSAlert()
        alert.messageText = "app.alert.noKeyTitle".localized
        alert.informativeText = "app.alert.noKeyBody".localized
        alert.alertStyle = .informational
        alert.addButton(withTitle: "app.alert.goToSettings".localized)
        alert.addButton(withTitle: "app.alert.later".localized)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            self.openSettings(toAITab: true)
        } else {
            defaults.set(true, forKey: "hasShownAIKeySetupPrompt")
        }
    }

    private func observeAPIKeyConfigured() {
        NotificationCenter.default.addObserver(
            forName: .apiKeyConfigured,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.orchestrator?.aiSummaryState = .idle }
            Task {
                await self.orchestrator?.manualRefresh(settings: self.settings)
            }
        }
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            let icon = NSImage(
                systemSymbolName: "newspaper.fill",
                accessibilityDescription: "NewsBar"
            )
            icon?.isTemplate = true
            button.image = icon
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }

        if let popover, popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover(relativeTo: button)
        }
    }

    private func showPopover(relativeTo button: NSStatusBarButton) {
        guard let orchestrator, let updateChecker else { return }
        loadAPIKeyIfNeeded()

        let activePopover: NSPopover
        if let popover {
            activePopover = popover
        } else {
            let createdPopover = makePopover(
                orchestrator: orchestrator,
                updateChecker: updateChecker
            )
            popover = createdPopover
            activePopover = createdPopover
        }

        activePopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        schedulePopoverRefresh()
    }

    private func makePopover(
        orchestrator: NewsOrchestrator,
        updateChecker: UpdateChecker
    ) -> NSPopover {
        let contentView = PopoverContent(
            orchestrator: orchestrator,
            updateChecker: updateChecker,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onOpenDashboard: { [weak self] in self?.openDashboard() },
            onOpenResearchCenter: { [weak self] in
                Task { @MainActor in self?.openResearchCenter() }
            },
            onConfigureKey: { [weak self] in self?.openSettings(toAITab: true) }
        )
        .environment(settings)

        let popover = NSPopover()
        popover.contentSize = Self.popoverSize
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: contentView)
        return popover
    }

    func openSettings(toAITab: Bool = false) {
        popover?.performClose(nil)

        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if toAITab {
                NotificationCenter.default.post(name: .switchToAITab, object: nil)
            }
            return
        }

        let initialTab = toAITab ? 3 : 0

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.settingsSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NewsBar Settings"
        window.center()
        window.contentView = NSHostingView(
            rootView: SettingsWindow(initialTab: initialTab)
                .environment(settings)
                .environment(\.cacheClearAction) { [weak self] in
                    guard let self, let orchestrator = self.orchestrator else { return }
                    Task { await orchestrator.clearCache() }
                }
        )
        window.isReleasedWhenClosed = false

        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func requestVisibleRefreshIfNeeded() {
        guard settings.autoRefreshEnabled else { return }
        Task {
            await orchestrator?.refreshScheduled(
                settings: settings,
                visibility: currentRefreshVisibility,
                trigger: .scheduled
            )
        }
    }

    /// Let the popover draw its first frame from cached data before a network
    /// refresh starts changing source state under the user's eyes.
    private func schedulePopoverRefresh(after delay: Duration = .milliseconds(350)) {
        popoverRefreshTask?.cancel()
        popoverRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.popover?.isShown == true else { return }
            self.requestVisibleRefreshIfNeeded()
        }
    }

    /// Let the dashboard draw its first frame and cached content before a
    /// network refresh starts changing source state under the user's eyes.
    private func scheduleDashboardRefresh(after delay: Duration = .milliseconds(450)) {
        dashboardRefreshTask?.cancel()
        dashboardRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.dashboardWindow?.isVisible == true else { return }
            self.requestVisibleRefreshIfNeeded()
        }
    }

    func openDashboard(refresh: Bool = true) {
        popover?.performClose(nil)

        if let existing = dashboardWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            MainActor.assumeIsolated { DockPresence.show() }
            if refresh { scheduleDashboardRefresh() }
            return
        }

        guard let orchestrator else { return }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.dashboardSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NewsBar Dashboard"
        window.titleVisibility = .hidden
        window.minSize = Self.dashboardMinimumSize
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.center()
        window.contentViewController = NSHostingController(
            rootView: DashboardWindow(
                orchestrator: orchestrator,
                onOpenSettings: { [weak self] in self?.openSettings() },
                onConfigureAI: { [weak self] in self?.openSettings(toAITab: true) },
                onOpenResearchCenter: { [weak self] recordID in
                    Task { @MainActor in self?.openResearchCenter(selecting: recordID) }
                }
            )
            .environment(settings)
        )
        window.isReleasedWhenClosed = false

        dashboardWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated { DockPresence.show() }
        if refresh { scheduleDashboardRefresh() }
    }

    /// Give the open reader one last cookie capture before the process exits.
    /// A hung cookie store must never keep the app from quitting, so the reply
    /// is guarded and a watchdog answers after two seconds regardless.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let active = ReaderSessionRegistry.active,
                  ReaderTerminationPolicy.needsCookieFlush(
                      cookieMemoryEnabled: settings?.readerCookieMemoryEnabled ?? false,
                      hasActiveReader: true
                  ) else { return .terminateNow }

            terminationReplyPending = true
            Task { @MainActor in
                let watchdog = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    replyToTerminationRequest()
                }
                await active.flushCookiesBeforeTermination()
                watchdog.cancel()
                replyToTerminationRequest()
            }
            return .terminateLater
        }
    }

    private func replyToTerminationRequest() {
        guard terminationReplyPending else { return }
        terminationReplyPending = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        dashboardRefreshTask?.cancel()
        popoverRefreshTask?.cancel()
        researchMaintenanceTask?.cancel()
        autoRefreshTimer?.invalidate()
        researchMaintenanceTimer?.invalidate()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { workspaceCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        settingsWindow?.close()
        dashboardWindow?.close()
        researchCenterWindow?.close()
        popover?.close()
        // Pending requests are deliberately left in place: the daily summary is a
        // calendar trigger meant to fire after the app is gone. Clearing all of
        // them here cancelled the daily push for good on every quit.
    }

    // MARK: - Research center window

    /// Legacy entry point: find the exact-topic record, or create a manual
    /// record when the topic has no history. The research center is now the
    /// single detail window.
    @MainActor
    func openBurstWindow(title: String) {
        guard let orchestrator else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await orchestrator.restoreResearchStateIfNeeded()
            if let recordID = await orchestrator.recordID(forTopic: title) {
                self.openResearchCenter(selecting: recordID)
            } else if ResearchConsent.presentIfNeeded(settings: self.settings),
                      let recordID = await orchestrator.startManualResearch(title: title, settings: self.settings) {
                self.openResearchCenter(selecting: recordID)
            } else {
                self.openResearchCenter()
            }
        }
    }

    @MainActor
    func openResearchCenter(selecting recordID: String? = nil) {
        popover?.performClose(nil)

        if let existing = researchCenterWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let recordID, let model = researchCenterModel {
                Task { @MainActor in await model.select(recordID) }
            }
            return
        }

        guard let orchestrator else { return }
        let model = ResearchCenterModel(orchestrator: orchestrator, settings: settings)
        researchCenterModel = model

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.researchCenterSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string("research.center.windowTitle")
        window.minSize = Self.researchCenterMinimumSize
        window.center()
        window.contentViewController = NSHostingController(
            rootView: ResearchCenterView(model: model)
                .environment(settings)
        )
        window.isReleasedWhenClosed = false

        researchCenterWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated { DockPresence.show() }

        if let recordID {
            Task { @MainActor in await model.select(recordID) }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let route = NotificationClickRouter.route(
            userInfo: userInfo,
            actionIdentifier: response.actionIdentifier
        )
        let digestCount = NotificationDigest.decode(userInfo["digest"] as? String)?.items.count ?? -1
        notificationLog.notice(
            "[Notify] action=\(response.actionIdentifier, privacy: .public) type=\((userInfo["type"] as? String) ?? "-", privacy: .public) digestItems=\(digestCount, privacy: .public) route=\(route.label, privacy: .public)"
        )
        switch route {
        case .dismiss:
            break
        case .burst(let eventID):
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.orchestrator?.restoreResearchStateIfNeeded()
                if let recordID = await self.orchestrator?.recordID(forTopic: eventID) {
                    self.openResearchCenter(selecting: recordID)
                } else {
                    self.openResearchCenter()
                }
            }
        case .research(let recordID):
            Task { @MainActor [weak self] in
                self?.openResearchCenter(selecting: recordID)
            }
        case .markResearchRead(let recordID):
            Task { @MainActor [weak self] in
                await self?.orchestrator?.markResearchRead(recordID: recordID)
            }
        case .digest(let digest):
            Task { @MainActor [weak self] in
                self?.openDashboard(refresh: false)
                // The dashboard window may be created by the call above; wait
                // one run-loop turn so its first view pass can mount the sheet.
                DispatchQueue.main.async {
                    NewsNavigationRouter.shared.presentDigest(NewsDigestRequest(digest: digest))
                }
            }
        case .news(let url, let title):
            Task { @MainActor in
                let item = InterestController.shared.state.contents[ContentIdentity.id(for: url)]?.item
                NewsNavigationRouter.shared.open(url: url, title: title, item: item, surface: "notification")
            }
        case .dashboard:
            Task { @MainActor [weak self] in self?.presentLiveDigestIfPossible() }
        }
        completionHandler()
    }

    /// Opens the dashboard for a click that carries no usable digest, then shows
    /// the sheet from the items this app already has. Waiting on `loadCached`
    /// covers the first click after launch, when the in-memory lists are still
    /// empty; if nothing cached is available the click keeps the old behaviour.
    private func presentLiveDigestIfPossible() {
        openDashboard(refresh: false)
        guard let orchestrator else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await orchestrator.loadCached(settings: self.settings)
            let items = NotificationDigestFallback.items(
                from: orchestrator.allActiveItems(settings: self.settings),
                limit: self.settings.pushCount
            )
            guard !items.isEmpty else { return }
            NewsNavigationRouter.shared.presentDigest(
                NewsDigestRequest(items: items, kind: NewsDigestRequest.liveKind)
            )
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
