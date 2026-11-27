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
    static let switchToReminder = Notification.Name("switchToReminder")
    static let switchToRSSTab = Notification.Name("switchToRSSTab")
    static let apiKeyConfigured = Notification.Name("apiKeyConfigured")
    static let fireFakeBurstPush = Notification.Name("fireFakeBurstPush")
    static let burstDetailRequest = Notification.Name("burstDetailRequest")
    static let fillBurstTestTopic = Notification.Name("fillBurstTestTopic")
    static let interestSettingsRequested = Notification.Name("interestSettingsRequested")
    static let switchToInterestSettings = Notification.Name("switchToInterestSettings")
    static let newsEventMonitorRequested = Notification.Name("newsEventMonitorRequested")
    static let browserSettingsRequested = Notification.Name("browserSettingsRequested")
    static let switchToBrowserTab = Notification.Name("switchToBrowserTab")
    static let researchRequested = Notification.Name("researchRequested")
    static let transientResearchRequested = Notification.Name("transientResearchRequested")
    static let openAISettingsRequested = Notification.Name("openAISettingsRequested")
    static let openRSSSettingsRequested = Notification.Name("openRSSSettingsRequested")
    static let fireTestNewsPush = Notification.Name("fireTestNewsPush")
    static let weiboBadgeSettingsChanged = Notification.Name("weiboBadgeSettingsChanged")
    static let agentAccessSettingChanged = Notification.Name("agentAccessSettingChanged")
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSWindowDelegate {

    // MARK: - Constants

    private static let schedulerTickInterval = RefreshPolicy.schedulerTick
    private static let startupDelay: TimeInterval = 2
    private static let updateCheckDelay: TimeInterval = 10
    private static let popoverSize = NSSize(width: 400, height: 520)
    private static let settingsSize = NSSize(width: 860, height: 620)
    private static let dashboardSize = NSSize(width: 1180, height: 860)
    private static let dashboardMinimumSize = NSSize(width: 960, height: 720)
    private static let researchCenterSize = NSSize(width: 1120, height: 760)
    private static let researchCenterMinimumSize = NSSize(width: 1000, height: 660)
    private static let researchWorkspaceSize = NSSize(width: 1180, height: 780)
    private static let researchWorkspaceMinimumSize = NSSize(width: 1040, height: 680)
    private static let newsEventCenterSize = NSSize(width: 1120, height: 760)
    private static let newsEventCenterMinimumSize = NSSize(width: 1000, height: 660)

    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?
    /// Shared with the settings window's AppKit toolbar item.
    private var settingsSidebarState: SettingsSidebarState!
    private var settingsToolbarController: SettingsToolbarController?
    private var dashboardWindow: NSWindow?
    private var researchWorkspaceWindow: NSWindow?
    private var researchWorkspaceModel: ResearchWorkspaceModel?
    private var transientResearchWindow: NSPanel?
    private var transientResearchModel: TransientResearchReportModel?
    private weak var transientResearchReturnWindow: NSWindow?
    /// True only while the *user* is dragging the panel's edge. Programmatic
    /// `setFrame` calls must not set it, or the panel would lock itself into
    /// whatever height it happened to be measured at and stop adapting.
    private var isUserResizingTransientResearch = false
    /// Set once the user has dragged the panel's edge. From then on the panel
    /// keeps the size the user chose, until they reset it by double-clicking
    /// the title bar.
    private var transientResearchSizeIsUserChosen = false
    /// True while the report panel is closing because the workspace took over,
    /// so the close path does not restore the window behind it or hide the Dock.
    private var isHandingOffTransientReport = false
    private var researchCenterWindow: NSWindow?
    private var researchCenterModel: ResearchCenterModel?
    private var newsEventCenterWindow: NSWindow?
    private var newsEventCenterModel: EventMonitorCenterModel?

    private var settings: AppSettings!
    private var weiboMonitor: WeiboMonitorViewModel?
    private var appearanceObservation: NSKeyValueObservation?
    private var lastWeiboUnread = -1
    private var orchestrator: NewsOrchestrator?
    private var updater: SparkleUpdater?
    private var agentCommandService: AgentCommandService?
    private var recommendationSummaryServer: RecommendationAgentSocketServer?
    private var autoRefreshTimer: Timer?
    private var newsEventStartupTask: Task<Void, Never>?
    private var newsEventTickTask: Task<Void, Never>?
    private var newsEventTickID: UUID?
    private var researchMaintenanceTimer: Timer?
    private var researchMaintenanceTask: Task<Void, Never>?
    private var dashboardRefreshTask: Task<Void, Never>?
    private var popoverRefreshTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isSystemSleeping = false
    private var isWakeRecoveryInProgress = false
    private var isTerminating = false
    private var terminationReplyPending = false

    private static let researchMaintenanceDelay: TimeInterval = 30
    private static let researchMaintenanceDebounce: Duration = .seconds(5)

    func applicationDidFinishLaunching(_ notification: Notification) {
        orchestrator = NewsOrchestrator()
        updater = SparkleUpdater()
        setupStatusBar()
        setupNotificationObservers()

        // 从 Keychain 迁移到加密文件存储（必须在任何读取之前）
        EncryptedKeyStore.migrateFromKeychainIfNeeded()
        settings = AppSettings()
        settingsSidebarState = SettingsSidebarState()
        MainActor.assumeIsolated {
            weiboMonitor = WeiboMonitorViewModel(settings: settings)
        }
        Task { await InterestController.shared.prepare() }
        MainActor.assumeIsolated { startRecommendationSummaryServer() }
        Task { await ReaderRuleListCache.prewarm() }
        setupWorkspaceObservers()

        // Bind the process-wide event controller to these settings before the
        // automation service and the workspace checker use it.
        _ = NewsEventController.shared(settings: settings)
        if let orchestrator = orchestrator {
            WorkspaceAutomationService.shared.start(
                orchestrator: orchestrator,
                settings: settings
            )
        }

        let agentService = AgentCommandService(
            settings: settings,
            research: orchestrator.map {
                ResearchAgentHooksFactory.production(settings: settings, orchestrator: $0)
            }
        ) { [weak self] in
            guard let self, let orchestrator = self.orchestrator else { return }
            Task { await orchestrator.manualRefresh(settings: self.settings) }
        }
        agentCommandService = agentService
        agentService.start()

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
        Task { await NotificationDeliveryLedger.shared.recoverSystemState() }
        Task { @MainActor [weak self] in
            await self?.weiboMonitor?.start()
            self?.updateWeiboBadge(force: true)
        }
        // No launch-time rescheduling: pending requests survive quit now, and the
        // startup refresh installs the digest-bearing daily request. Installing a
        // plain template here could race that refresh and overwrite it.

        // Local QA hook: `open NewsBar.app --args --show-settings` opens the
        // settings window without menu-bar interaction. Normal launches are
        // unaffected.
        if CommandLine.arguments.contains("--show-settings") {
            DispatchQueue.main.async { [weak self] in
                self?.openSettings(toAITab: true)
            }
        }
    }

    @MainActor
    private func startRecommendationSummaryServer() {
        let diagnostics = InterestController.shared.diagnostics
        // The switch may already be off at launch; mirror it before the socket
        // accepts a request.
        diagnostics.setAgentAccessEnabled(settings.agentAccessEnabled)
        let access = diagnostics.agentAccess
        let server = RecommendationAgentSocketServer(
            access: access,
            scope: { [weak diagnostics, weak access] in
                RecommendationAgentAccess.Scope(
                    diagnostics: diagnostics?.permissionGeneration ?? UUID(),
                    agent: access?.epoch ?? UUID()
                )
            },
            isAgentEnabled: { [weak self] in
                guard let self, !self.isTerminating else { return false }
                return self.settings?.agentAccessEnabled == true
            }
        )
        try? server.start()
        recommendationSummaryServer = server
    }

    private func scheduleStartupAndAutoRefresh() {
        newsEventStartupTask?.cancel()
        newsEventStartupTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.startupDelay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, !self.isTerminating else { return }
            await self.runNewsEventTick()
            guard !Task.isCancelled, !self.isTerminating else { return }
            self.newsEventStartupTask = nil
            Task { @MainActor [weak self] in
                guard let self, !self.isTerminating else { return }
                await self.orchestrator?.refreshIfNeeded(settings: self.settings, trigger: .startup)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.weiboMonitor?.tick(now: Date())
            }
        }

        let timer = Timer(timeInterval: Self.schedulerTickInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.scheduledTick()
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        autoRefreshTimer = timer
    }

    /// The monitor must run even when the news auto-refresh switch is off. The
    /// old timer returned early on `autoRefreshEnabled`, which would have made
    /// the monitor silently dead for the default configuration.
    @MainActor
    private func scheduledTick() async {
        guard !isSystemSleeping, !isWakeRecoveryInProgress, !isTerminating else { return }
        await weiboMonitor?.tick(now: Date())
        await runNewsEventTick()
        guard !isSystemSleeping, !isWakeRecoveryInProgress, !isTerminating else { return }
        guard settings.autoRefreshEnabled else { return }
        let visibility = currentRefreshVisibility
        await orchestrator?.refreshScheduled(
            settings: settings,
            visibility: visibility,
            trigger: .scheduled
        )
    }

    @MainActor
    private func runNewsEventTick() async {
        guard !isSystemSleeping, !isTerminating else { return }
        if let existing = newsEventTickTask {
            await existing.value
            if existing.isCancelled, !isSystemSleeping, !isTerminating, !Task.isCancelled {
                await runNewsEventTick()
            }
            return
        }
        let taskID = UUID()
        newsEventTickID = taskID
        let task = Task { @MainActor [weak self] in
            defer {
                if self?.newsEventTickID == taskID {
                    self?.newsEventTickTask = nil
                    self?.newsEventTickID = nil
                }
            }
            guard let self, !self.isTerminating, !self.isSystemSleeping else { return }
            let controller = NewsEventController.shared(settings: self.settings)
            await controller.recoverAndTick(now: Date(), sources: self.settings.activeSources)
        }
        newsEventTickTask = task
        await task.value
    }

    private var currentRefreshVisibility: RefreshVisibility {
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return .lowPower
        }
        if popover?.isShown == true
            || dashboardWindow?.isVisible == true
            || researchWorkspaceWindow?.isVisible == true
            || transientResearchWindow?.isVisible == true {
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
                self?.newsEventTickTask?.cancel()
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
                self.isWakeRecoveryInProgress = true
                Task { @MainActor in
                    defer { self.isWakeRecoveryInProgress = false }
                    guard !self.isTerminating else { return }
                    await self.runNewsEventTick()
                    guard !self.isTerminating else { return }
                    await self.weiboMonitor?.handleWake(now: Date())
                    guard self.settings.autoRefreshEnabled else { return }
                    let visibility = self.currentRefreshVisibility
                    await self.orchestrator?.refreshScheduled(
                        settings: self.settings,
                        visibility: visibility,
                        trigger: .wake
                    )
                }
            }
        )
    }

    /// Starts Sparkle's scheduler after the startup refresh has settled.
    /// Starting it during launch would race the first feed refresh for
    /// network and CPU on every cold start.
    private func scheduleAutoUpdateCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.updateCheckDelay) { [weak self] in
            self?.updater?.start()
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
            _ = ResearchMaintenance.shared.migrateAIQuotaIfNeeded(settings: self.settings)
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
            await ResearchMaintenance.shared.reclaimOrphanedQueuedRecords(activeIDs: excluding)
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
                WorkspaceTabStore.shared.terminateAll()
                NewsNavigationRouter.shared.close()
                NewsNavigationRouter.shared.dismissDigest()
                InterestController.shared.endListSession()
                // The dashboard keeps its follow pane alive while the window
                // exists; closing the window must release the notification
                // suppression that pane holds.
                WeiboMonitorViewModel.setFeedVisible(false)
                if self.researchCenterWindow?.isVisible != true,
                   self.researchWorkspaceWindow?.isVisible != true,
                   self.newsEventCenterWindow?.isVisible != true {
                    DockPresence.hide()
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow, window === self.researchWorkspaceWindow else { return }
            self.researchWorkspaceWindow = nil
            self.researchWorkspaceModel = nil
            if self.dashboardWindow?.isVisible != true,
               self.researchCenterWindow?.isVisible != true,
               self.newsEventCenterWindow?.isVisible != true {
                DockPresence.hide()
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow, window === self.researchCenterWindow else { return }
            self.researchCenterWindow = nil
            self.researchCenterModel = nil
            if self.dashboardWindow?.isVisible != true,
               self.researchWorkspaceWindow?.isVisible != true,
               self.newsEventCenterWindow?.isVisible != true {
                DockPresence.hide()
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow, window === self.newsEventCenterWindow else { return }
            self.newsEventCenterWindow = nil
            self.newsEventCenterModel = nil
            if self.dashboardWindow?.isVisible != true,
               self.researchWorkspaceWindow?.isVisible != true,
               self.researchCenterWindow?.isVisible != true {
                DockPresence.hide()
            }
        }
        NotificationCenter.default.addObserver(forName: .newsReaderRequested, object: nil, queue: .main) { [weak self] _ in
            self?.openDashboard(refresh: false)
        }
        NotificationCenter.default.addObserver(forName: .interestSettingsRequested, object: nil, queue: .main) { [weak self] _ in
            self?.openSettings()
            NotificationCenter.default.post(name: .switchToInterestSettings, object: nil)
        }
        NotificationCenter.default.addObserver(forName: .openAISettingsRequested, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.openSettings(toAITab: true)
            }
        }
        NotificationCenter.default.addObserver(forName: .openRSSSettingsRequested, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.openSettings(toRSS: true)
            }
        }
        NotificationCenter.default.addObserver(forName: .browserSettingsRequested, object: nil, queue: .main) { [weak self] _ in
            self?.openSettings()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .switchToBrowserTab, object: nil)
            }
        }
        NotificationCenter.default.addObserver(forName: .newsEventMonitorRequested, object: nil, queue: .main) { [weak self] notification in
            let eventID = notification.userInfo?["eventID"] as? String
            Task { @MainActor [weak self] in
                self?.openNewsEventMonitor(eventID: eventID)
            }
        }
        NotificationCenter.default.addObserver(forName: .transientResearchRequested, object: nil, queue: .main) { [weak self] notification in
            let recordID = notification.userInfo?["recordID"] as? String
            let eventID = notification.userInfo?["eventID"] as? String
            let versionID = notification.userInfo?["versionID"] as? String
            let compareFromVersionID = notification.userInfo?["compareFromVersionID"] as? String
            let sourceURL = notification.userInfo?["sourceURL"] as? String
            let title = notification.userInfo?["title"] as? String
            Task { @MainActor [weak self] in
                self?.openTransientResearch(
                    recordID: recordID,
                    eventID: eventID,
                    versionID: versionID,
                    compareFromVersionID: compareFromVersionID,
                    fallbackSourceURL: sourceURL,
                    fallbackTitle: title
                )
            }
        }
        NotificationCenter.default.addObserver(forName: .interestDataCleared, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.researchCenterWindow?.close()
                self?.researchCenterWindow?.contentViewController = nil
                self?.researchCenterWindow = nil
                self?.researchCenterModel = nil
                self?.researchWorkspaceWindow?.close()
                self?.researchWorkspaceWindow = nil
                self?.researchWorkspaceModel = nil
                WorkspaceTabStore.shared.terminateAll()
                await self?.orchestrator?.clearPersonalizedArtifacts()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .weiboBadgeSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateWeiboBadge(force: true)
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
                self?.openWorkspaceResearch(for: item)
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

        NotificationCenter.default.addObserver(
            forName: .weiboMonitorChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateWeiboBadge()
            }
        }

        // A live recommendation grant must die when the general Agent switch
        // closes, even if no CLI request arrives in between.
        NotificationCenter.default.addObserver(
            forName: .agentAccessSettingChanged,
            object: nil,
            queue: .main
        ) { notification in
            let enabled = notification.userInfo?["enabled"] as? Bool ?? false
            MainActor.assumeIsolated {
                InterestController.shared.diagnostics.setAgentAccessEnabled(enabled)
            }
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
        guard settings.hasUsableProviderSelection else { return false }
        if settings.isUsingCustomProvider {
            let accountFlag = "hasAIKey-\(settings.activeAPIKeyAccount)"
            return TestIsolation.defaults.bool(forKey: accountFlag)
        }
        let provider = settings.currentProvider
        let providerFlag = provider.keyExistsFlag()
        if TestIsolation.defaults.bool(forKey: providerFlag) {
            return true
        }

        let accountFlag = "hasAIKey-\(provider.apiKeyAccount())"
        guard TestIsolation.defaults.bool(forKey: accountFlag) else {
            return false
        }

        TestIsolation.defaults.set(true, forKey: providerFlag)
        return true
    }

    private func refreshAPIKeyIfNeeded() {
        Task { @MainActor [weak self] in
            guard let self else {
                NSLog("[Keychain] AppDelegate deallocated before 1Password key save")
                return
            }
            let context = self.settings.aiKeyContext
            let account = context.account
            let legacyRef = context.providerID.hasPrefix("custom:") ? "" : self.settings.onePasswordRef
            let intent = self.settings.aiCredentialIntentRevision
            guard self.currentProviderHasSavedKeyFlag() else { return }
            let store = EncryptedKeyStore()
            // A reference is scoped to the provider it was saved for; the legacy
            // single value is only a migration fallback.
            guard let snapshot = await store.onePasswordRefreshSnapshot(account: account, endpointIdentity: context.endpointIdentity),
                  let ref = snapshot.reference.value(orIfMissing: legacyRef), !ref.isEmpty,
                  await store.isKeyStale(account: account),
                  OnePasswordService.isInstalled() else { return }
            do {
                try await AIOnePasswordAutoRefresh.run(
                    reference: ref,
                    snapshot: snapshot,
                    store: store,
                    expectedIntent: intent,
                    readSecret: { try await OnePasswordService.readSecretAsync(reference: $0) },
                    currentAccount: { self.settings.activeAPIKeyAccount },
                    currentIntent: { self.settings.aiCredentialIntentRevision },
                    isContextCurrent: { self.settings.aiKeyContext == context },
                    activate: {
                        _ = self.settings.activateAPIKey($0, providerID: context.providerID, revision: context.revision)
                    }
                )
            } catch {
                // silent fail — will retry next launch
            }
        }
    }

    /// 启动时异步加载 API Key，确保定时器触发时 key 可用
    private func loadAPIKeyFromFile() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.settings.aiSummaryEnabled, self.settings.cachedAPIKey == nil,
                  self.currentProviderHasSavedKeyFlag() else { return }
            let context = self.settings.aiKeyContext
            let account = context.account
            let store = EncryptedKeyStore()
            switch await store.readProviderAPIKeyResult(account: account, endpointIdentity: context.endpointIdentity) {
            case .found(let key) where !key.isEmpty:
                _ = self.settings.activateAPIKey(key, providerID: context.providerID, revision: context.revision)
            case .failed:
                NSLog("[AppDelegate] Cached provider key read failed for \(account)")
            case .found, .missing:
                break
            }
        }
    }

    private func loadAPIKeyIfNeeded() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.settings.aiSummaryEnabled, self.settings.cachedAPIKey == nil else { return }
            guard self.currentProviderHasSavedKeyFlag() else {
                let keyOptional = self.settings.aiProvider == AIProvider.ollamaCloud.rawValue
                if self.orchestrator?.hasRenderableSummary != true {
                    self.orchestrator?.aiSummaryState = keyOptional ? .idle : .noKey
                }
                return
            }
            let context = self.settings.aiKeyContext
            let account = context.account
            let providerID = context.providerID
            self.orchestrator?.resetSummaryStateForKeyLookup()
            let store = EncryptedKeyStore()
            switch await store.readProviderAPIKeyResult(account: account, endpointIdentity: context.endpointIdentity) {
            case .found(let key) where !key.isEmpty:
                guard self.settings.activeAPIKeyAccount == account,
                      self.settings.activateAPIKey(key, providerID: providerID, revision: context.revision) else { return }
                for flag in AIProvider.loadedKeyFlagNames(providerID: providerID, account: account) {
                    TestIsolation.defaults.set(true, forKey: flag)
                }
                Task {
                    await self.orchestrator?.manualRefresh(settings: self.settings)
                }
            case .failed:
                // Keep the visible error card's existing path: do not pretend
                // the user has no key when the store simply could not read it.
                NSLog("[AppDelegate] Saved provider key read failed for \(account)")
                let message = AISearchError.keyReadFailed.message(self.settings.appLanguage)
                if self.orchestrator?.hasRenderableSummary == true {
                    self.orchestrator?.aiSummaryUpdateError = message
                } else {
                    self.orchestrator?.aiSummaryState = .error(message)
                }
            case .found, .missing:
                break
            }
        }
    }

    private func observeAPIKeyConfigured() {
        NotificationCenter.default.addObserver(
            forName: .apiKeyConfigured,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.orchestrator?.resetSummaryStateForKeyLookup() }
            Task {
                await self.orchestrator?.manualRefresh(settings: self.settings)
            }
        }
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Local UI verification hooks:
        //   --open-dashboard-window  opens the Dashboard window directly. The
        //        window calls DockPresence.show(), so it also gets a Dock tile
        //        and can be driven without hunting the menu-bar icon.
        //   --open-dashboard         shows the menu-bar popover.
        if ProcessInfo.processInfo.arguments.contains("--open-dashboard-window") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.openDashboard()
            }
        } else if ProcessInfo.processInfo.arguments.contains("--open-dashboard") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.togglePopover()
            }
        }

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
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateWeiboBadge(force: true) }
        }
    }

    @MainActor
    private func updateWeiboBadge(force: Bool = false) {
        guard let monitor = weiboMonitor else { return }
        let unread = settings.showsWeiboMenuBarBadge
            ? monitor.snapshot.unreadCount
            : 0
        guard force || unread != lastWeiboUnread else { return }
        lastWeiboUnread = unread
        let button = statusItem?.button
        button?.image = WeiboMenuBarBadge.image(unread: unread)
        button?.setAccessibilityLabel("NewsBar")
        button?.setAccessibilityValue(
            unread > 0 ? L10n.string("weibo.feed.unreadCount", unread) : ""
        )
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
        guard let orchestrator, let updater else { return }
        loadAPIKeyIfNeeded()

        let activePopover: NSPopover
        if let popover {
            activePopover = popover
        } else {
            let createdPopover = makePopover(
                orchestrator: orchestrator,
                updater: updater
            )
            popover = createdPopover
            activePopover = createdPopover
        }

        activePopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        schedulePopoverRefresh()
    }

    private func makePopover(
        orchestrator: NewsOrchestrator,
        updater: SparkleUpdater
    ) -> NSPopover {
        let contentView = PopoverContent(
            orchestrator: orchestrator,
            updater: updater,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onOpenDashboard: { [weak self] in self?.openDashboard() },
            onOpenResearchCenter: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    if let unread = await self.workspaceUnreadResearchSubjectID() {
                        self.openResearchWorkspace(subjectID: unread)
                    } else {
                        self.openResearchWorkspace()
                    }
                }
            },
            onOpenEventMonitor: { [weak self] in
                Task { @MainActor in self?.openNewsEventMonitor() }
            },
            onConfigureKey: { [weak self] in self?.openSettings(toAITab: true) },
            weiboMonitor: weiboMonitor
        )
        .environment(settings)

        let popover = NSPopover()
        popover.contentSize = Self.popoverSize
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: contentView)
        return popover
    }

    func openSettings(
        toAITab: Bool = false,
        toWeiboMonitor: Bool = false,
        toRSS: Bool = false,
        toReminder: Bool = false
    ) {
        popover?.performClose(nil)

        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if toWeiboMonitor {
                NotificationCenter.default.post(name: .switchToWeiboMonitor, object: nil)
            } else if toAITab {
                NotificationCenter.default.post(name: .switchToAITab, object: nil)
            } else if toRSS {
                NotificationCenter.default.post(name: .switchToRSSTab, object: nil)
            } else if toReminder {
                NotificationCenter.default.post(name: .switchToReminder, object: nil)
            }
            return
        }

        let initialPane: SettingsPane = toWeiboMonitor
            ? .weiboMonitor
            : (toAITab ? .ai : (toRSS ? .reading : (toReminder ? .notifications : .general)))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.settingsSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NewsBar Settings"
        window.center()
        window.contentView = NSHostingView(
            rootView: SettingsWindow(
                initialPane: initialPane,
                sidebarState: settingsSidebarState,
                weiboMonitor: weiboMonitor,
                updater: updater
            )
                .environment(settings)
                .environment(\.cacheClearAction) { [weak self] in
                    guard let self, let orchestrator = self.orchestrator else { return }
                    Task { await orchestrator.clearCache() }
                }
                .environment(\.searchProviderStatusAction) { [weak self] settings in
                    guard let orchestrator = self?.orchestrator else { return [] }
                    return await orchestrator.searchProviderStatuses(settings: settings)
                }
                .environment(\.searchAuthRetryAction) { [weak self] provider in
                    await self?.orchestrator?.clearSearchAuthBlock(for: provider)
                }
                .environment(\.rssHealthAction) { [weak self] settings in
                    self?.orchestrator?.rssHealthSnapshot(settings: settings) ?? []
                }
                .environment(\.researchHistoryClearAction) { [weak self] in
                    guard let orchestrator = self?.orchestrator else {
                        return ResearchClearResult(error: "orchestrator unavailable")
                    }
                    return await orchestrator.clearResearchHistory()
                }
        )

        // Install the toolbar after the hosting view exists: SwiftUI only hands
        // the window toolbar back to AppKit once it has no toolbar content of
        // its own, which is what the sidebar's `.toolbar(removing:)` arranges.
        MainActor.assumeIsolated {
            // Seed the theme before the toolbar is built so the retro skin
            // never flashes a toggle it is about to remove.
            settingsSidebarState.isCollapsible = settings.appTheme != .retroEditorial
            let toolbarController = SettingsToolbarController(state: settingsSidebarState, settings: settings)
            toolbarController.install(on: window)
            settingsToolbarController = toolbarController
        }

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
        window.center()
        window.contentViewController = NSHostingController(
            rootView: DashboardWindow(
                orchestrator: orchestrator,
                weiboMonitor: weiboMonitor,
                onOpenSettings: { [weak self] in self?.openSettings() },
                onConfigureAI: { [weak self] in self?.openSettings(toAITab: true) },
                onOpenResearchCenter: { [weak self] recordID in
                    Task { @MainActor in
                        guard let self else { return }
                        if let recordID {
                            self.openResearchCenter(selecting: recordID)
                        } else if let unread = await self.workspaceUnreadResearchSubjectID() {
                            self.openResearchWorkspace(subjectID: unread)
                        } else {
                            self.openResearchWorkspace()
                        }
                    }
                },
                onOpenTransientResearch: { [weak self] recordID, eventID in
                    Task { @MainActor [weak self] in
                        self?.openTransientResearch(recordID: recordID, eventID: eventID)
                    }
                },
                onOpenEventMonitor: { [weak self] in
                    Task { @MainActor in self?.openNewsEventMonitor() }
                },
                onOpenWorkspaceResult: { [weak self] result in
                    Task { @MainActor in self?.openWorkspaceSearchResult(result) }
                },
                onOpenWeiboMonitorSettings: { [weak self] in
                    self?.openSettings(toWeiboMonitor: true)
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
            let readers = ReaderSessionRegistry.all.sorted {
                !$0.isTabActive && $1.isTabActive
            }
            let needsReaderFlush = !readers.isEmpty
                && ReaderTerminationPolicy.needsCookieFlush(
                    cookieMemoryEnabled: settings?.readerCookieMemoryEnabled ?? false,
                    hasActiveReader: true
                )
            let needsMonitorFlush = settings?.weiboMonitorEnabled == true
                || !(weiboMonitor?.snapshot.users.isEmpty ?? true)
            let needsEventFlush = newsEventStartupTask != nil || newsEventTickTask != nil
            guard needsReaderFlush || needsMonitorFlush || needsEventFlush else {
                isTerminating = true
                return .terminateNow
            }

            terminationReplyPending = true
            Task { @MainActor in
                let watchdog = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(needsEventFlush ? 22 : 2))
                    replyToTerminationRequest()
                }
                isTerminating = true
                newsEventStartupTask?.cancel()
                newsEventTickTask?.cancel()
                let startupTask = newsEventStartupTask
                let eventTask = newsEventTickTask
                await self.weiboMonitor?.persistNow()
                for reader in readers {
                    await reader.flushCookiesBeforeTermination()
                }
                await eventTask?.value
                await startupTask?.value
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
        isTerminating = true
        WorkspaceAutomationService.shared.stop()
        newsEventStartupTask?.cancel()
        newsEventTickTask?.cancel()
        dashboardRefreshTask?.cancel()
        popoverRefreshTask?.cancel()
        researchMaintenanceTask?.cancel()
        autoRefreshTimer?.invalidate()
        researchMaintenanceTimer?.invalidate()
        weiboMonitor?.stop()
        agentCommandService?.stop()
        agentCommandService = nil
        recommendationSummaryServer?.stop()
        recommendationSummaryServer = nil
        MainActor.assumeIsolated {
            InterestController.shared.diagnostics.revokeAgentAccess()
        }
        appearanceObservation?.invalidate()
        appearanceObservation = nil
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { workspaceCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        settingsWindow?.close()
        dashboardWindow?.close()
        researchWorkspaceWindow?.close()
        researchCenterWindow?.close()
        newsEventCenterWindow?.close()
        transientResearchWindow?.close()
        popover?.close()
        // Pending requests are deliberately left in place: the daily summary is a
        // calendar trigger meant to fire after the app is gone. Clearing all of
        // them here cancelled the daily push for good on every quit.
    }

    // MARK: - Research workspace window

    /// The single window for subjects, events, evidence and research. Every
    /// legacy entry point resolves into this method.
    @MainActor
    func openResearchWorkspace(
        subjectID: String? = nil,
        researchID: String? = nil,
        eventID: String? = nil,
        answerID: String? = nil,
        startResearchDepth: ResearchDepth? = nil,
        evidenceHint: WorkspaceEvidenceFocus? = nil,
        segment: WorkspaceSegment? = nil
    ) {
        popover?.performClose(nil)

        Task { @MainActor [weak self] in
            guard let self else { return }
            var resolved = subjectID
            if resolved == nil {
                resolved = await self.resolveWorkspaceSubjectID(
                    recordID: researchID,
                    eventID: eventID
                )
            }

            if let existing = self.researchWorkspaceWindow, let model = self.researchWorkspaceModel {
                existing.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                DockPresence.show()
                await model.load()
                if resolved != nil || answerID != nil {
                    await model.handleNotification(
                        subjectID: resolved,
                        recordID: researchID,
                        eventID: eventID,
                        answerID: answerID,
                        evidenceHint: evidenceHint
                    )
                }
                if let segment, resolved != nil {
                    model.requestSegment(segment)
                }
                if let startResearchDepth, let resolved {
                    await model.startResearch(
                        id: resolved,
                        forceRefresh: false,
                        depth: startResearchDepth
                    )
                }
                return
            }

            guard let orchestrator = self.orchestrator else { return }
            let model = ResearchWorkspaceModel(
                orchestrator: orchestrator,
                settings: self.settings,
                store: WorkspaceSubjectStore.shared,
                coordinator: .shared,
                eventController: NewsEventController.shared(settings: self.settings),
                updateChecker: WorkspaceUpdateChecker.shared
            )
            self.researchWorkspaceModel = model

            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: Self.researchWorkspaceSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = L10n.string(
                "research.workspace.windowTitle",
                language: self.settings.appLanguage
            )
            window.minSize = Self.researchWorkspaceMinimumSize
            window.center()
            window.contentViewController = NSHostingController(
                rootView: ResearchWorkspaceView(model: model)
                    .environment(self.settings)
                    .id(self.settings.appLanguage)
            )
            window.isReleasedWhenClosed = false

            self.researchWorkspaceWindow = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            DockPresence.show()

            await model.load()
            if resolved != nil || answerID != nil {
                await model.handleNotification(
                    subjectID: resolved,
                    recordID: researchID,
                    eventID: eventID,
                    answerID: answerID,
                    evidenceHint: evidenceHint
                )
            }
            if let segment, resolved != nil {
                model.requestSegment(segment)
            }
            if let startResearchDepth, let resolved {
                await model.startResearch(
                    id: resolved,
                    forceRefresh: false,
                    depth: startResearchDepth
                )
            }
        }
    }

    /// Shows a single non-modal report window and leaves the reader, Dashboard
    /// search, and workspace management state in place underneath it.
    @MainActor
    func openTransientResearch(
        recordID: String? = nil,
        eventID: String? = nil,
        versionID: String? = nil,
        compareFromVersionID: String? = nil,
        fallbackSourceURL: String? = nil,
        fallbackTitle: String? = nil
    ) {
        guard recordID != nil || eventID != nil
                || fallbackSourceURL.flatMap(ReaderNavigationPolicy.allowedURL) != nil else { return }

        if transientResearchWindow?.isVisible != true {
            let candidate = NSApp.keyWindow ?? NSApp.mainWindow
            if let candidate, let currentPanel = transientResearchWindow, candidate === currentPanel {
                transientResearchReturnWindow = nil
            } else {
                transientResearchReturnWindow = candidate
            }
        }

        let model: TransientResearchReportModel
        if let existing = transientResearchModel {
            model = existing
        } else {
            model = TransientResearchReportModel()
            transientResearchModel = model
        }

        let window: NSPanel
        if let existing = transientResearchWindow {
            window = existing
        } else {
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: NSSize(width: 760, height: 760)),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.title = settings.appLanguage == .en ? "Research report" : "研究报告"
            // The floor belongs to the sizing rules, which express it in frame
            // coordinates: `contentMinSize` includes the title bar, and a value
            // copied from the SwiftUI content floor would clip that much again.
            panel.contentMinSize = NSSize(
                width: TransientResearchReportView.minimumWidth,
                height: ResearchPanelSizing.minimumFrameHeight
            )
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.delegate = self
            panel.center()
            panel.contentViewController = NSHostingController(
                rootView: TransientResearchReportView(
                    model: model,
                    onClose: { [weak self] in self?.transientResearchWindow?.performClose(nil) },
                    onOpenWorkspace: { [weak self] in
                        self?.handOffTransientReportToWorkspace(segment: nil)
                    },
                    onOpenEventTimeline: { [weak self] in
                        self?.handOffTransientReportToWorkspace(segment: .timeline)
                    },
                    onContentHeightChange: { [weak self, weak panel] contentHeight in
                        guard let self, let panel else { return }
                        self.fitTransientResearchPanel(panel, contentHeight: contentHeight)
                    }
                )
                .onChange(of: settings.resolvedColorScheme, initial: true) { [weak panel] _, scheme in
                    panel?.appearance = scheme.flatMap { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) }
                }
                // The header truncates the title to two lines, so the full
                // target title lives in the titlebar, Mission Control and the
                // Dock. Observing the model rather than writing once after
                // `open()` keeps it correct when `reload()` picks up a renamed
                // event or a record whose topic changed. A nil title leaves the
                // previous one: an unresolved target must not replace it with
                // a generic string.
                .onChange(of: model.windowTitle, initial: true) { [weak panel] _, title in
                    guard let title else { return }
                    panel?.title = title
                }
                .environment(settings)
                .id(settings.appLanguage)
            )
            transientResearchWindow = panel
            window = panel
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DockPresence.show()
        Task { @MainActor in
            await model.open(
                recordID: recordID,
                eventID: eventID,
                versionID: versionID,
                compareFromVersionID: compareFromVersionID,
                fallbackSourceURL: fallbackSourceURL,
                fallbackTitle: fallbackTitle,
                markReadOnOpen: settings.researchMarkReadOnOpen
            )
            // The header truncates the title to two lines, so the full target
            // title lives in the titlebar, Mission Control and the Dock. Set
            // only after the target resolved: an unresolved target must not
            // replace the previous title with a generic one.
            if let resolved = model.windowTitle {
                window.title = resolved
            }
        }
    }

    /// Notification delivery uses this to avoid interrupting the event or
    /// report the user is already reading in the visible Dashboard or panel.
    @MainActor
    func isResearchTargetVisibleAndAppActive(
        eventID: String? = nil,
        recordID: String? = nil
    ) -> Bool {
        guard NSApp.isActive else { return false }
        if transientResearchWindow?.isVisible == true,
           transientResearchWindow?.isMiniaturized != true,
           transientResearchModel?.matches(eventID: eventID, recordID: recordID) == true {
            return true
        }
        guard dashboardWindow?.isVisible == true,
              dashboardWindow?.isMiniaturized != true else { return false }
        return ResearchReadingContextRegistry.contains(eventID: eventID, recordID: recordID)
    }

    /// Fits the report panel to the content the view just measured.
    ///
    /// The panel keeps its top edge and grows or shrinks downward: anchoring
    /// the top keeps the title and the first line of body copy still, which is
    /// what stops the window from moving under the reader's eyes when the
    /// detail expands or a shorter report loads.
    ///
    /// A user who dragged the edge owns the height from then on. That is why
    /// the flag is set by `windowDidEndLiveResize` and never here: this method
    /// calls `setFrame`, and treating its own call as a user action would pin
    /// the panel at its first measurement.
    @MainActor
    private func fitTransientResearchPanel(_ panel: NSPanel, contentHeight: CGFloat) {
        guard panel.isVisible, !panel.isMiniaturized else { return }
        guard !transientResearchSizeIsUserChosen else { return }
        guard !isUserResizingTransientResearch else { return }

        let screen = panel.screen ?? NSScreen.main
        let visibleHeight = screen?.visibleFrame.height ?? 900
        let height = ResearchPanelSizing.frameHeight(
            contentHeight: contentHeight,
            screenVisibleHeight: visibleHeight
        )
        let current = panel.frame
        // A sub-point difference would still trigger a full layout pass on
        // every measurement, and the measurement itself changes once the panel
        // resizes. Ignoring it keeps the loop from oscillating.
        guard abs(current.height - height) >= 1 else { return }

        // The width is the user's (within the minimum); only the height adapts.
        let width = max(current.width, TransientResearchReportView.minimumWidth)
        let origin = ResearchPanelSizing.originKeepingTop(currentFrame: current, newHeight: height)
        panel.setFrame(
            NSRect(origin: origin, size: NSSize(width: width, height: height)),
            display: true,
            animate: false
        )
    }

    @MainActor
    func windowWillStartLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === transientResearchWindow else { return }
        isUserResizingTransientResearch = true
    }

    @MainActor
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === transientResearchWindow else { return }
        isUserResizingTransientResearch = false
        transientResearchSizeIsUserChosen = true
    }

    @MainActor
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === transientResearchWindow else { return }
        // Only a live drag counts as the user choosing a size. This method also
        // fires for `setFrame`, so the guard on the live flag is what keeps the
        // two apart.
        if isUserResizingTransientResearch {
            transientResearchSizeIsUserChosen = true
        }
    }

    /// Double-clicking the title bar is the standard macOS "put it back" gesture;
    /// here it also hands the height back to the content. The view reports a
    /// fresh measurement on the next layout pass, and `fitTransientResearchPanel`
    /// then applies it.
    @MainActor
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        guard window === transientResearchWindow else { return true }
        transientResearchSizeIsUserChosen = false
        return true
    }

    @MainActor
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === transientResearchWindow else { return }
        transientResearchWindow = nil
        transientResearchModel = nil
        isUserResizingTransientResearch = false
        transientResearchSizeIsUserChosen = false
        let returnWindow = transientResearchReturnWindow
        transientResearchReturnWindow = nil
        if let returnWindow, returnWindow.isVisible {
            DispatchQueue.main.async { returnWindow.makeKeyAndOrderFront(nil) }
        }
        if !isHandingOffTransientReport,
           settingsWindow?.isVisible != true,
           dashboardWindow?.isVisible != true,
           researchWorkspaceWindow?.isVisible != true,
           researchCenterWindow?.isVisible != true,
           newsEventCenterWindow?.isVisible != true,
           popover?.isShown != true {
            DockPresence.hide()
        }
    }

    /// Hands the report panel's record over to the workspace and closes the
    /// panel. Opening the workspace is asynchronous, so the close is immediate:
    /// the panel must not linger beside the workspace on the same record.
    @MainActor
    private func handOffTransientReportToWorkspace(segment: WorkspaceSegment?) {
        guard let model = transientResearchModel else { return }
        guard model.recordID != nil || model.eventID != nil else { return }
        // The workspace is the destination, not the window the panel came from.
        transientResearchReturnWindow = nil
        if let recordID = model.recordID {
            openResearchWorkspace(researchID: recordID, segment: segment)
        } else {
            // Event-only panels have no record to open; route by the event.
            openResearchWorkspace(eventID: model.eventID, segment: segment)
        }
        isHandingOffTransientReport = true
        transientResearchWindow?.performClose(nil)
        isHandingOffTransientReport = false
    }

    /// Compatibility wrapper for the old research-center call sites and both
    /// research notification routes.
    @MainActor
    func openResearchCenter(selecting recordID: String? = nil) {
        openResearchWorkspace(researchID: recordID)
    }

    /// Compatibility wrapper for the old event-monitor call sites. Without an
    /// event ID it opens the most recently active event-backed subject.
    @MainActor
    func openNewsEventMonitor(eventID: String? = nil) {
        if let eventID {
            openResearchWorkspace(eventID: eventID)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let store = WorkspaceSubjectStore.shared
            var subject = await store.subjects()
                .filter { !$0.eventIDs.isEmpty }
                .max { $0.lastActivityAt < $1.lastActivityAt }
            if subject == nil {
                await self.reconcileWorkspace()
                subject = await store.subjects()
                    .filter { !$0.eventIDs.isEmpty }
                    .max { $0.lastActivityAt < $1.lastActivityAt }
            }
            self.openResearchWorkspace(subjectID: subject?.id)
        }
    }

    /// The legacy burst entry no longer creates a research record directly.
    /// It reuses the topic's record or creates a followed subject and lets the
    /// workspace launcher own the single in-flight task.
    @MainActor
    func openBurstWindow(title: String) {
        guard let orchestrator else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await orchestrator.restoreResearchStateIfNeeded()
            if let recordID = await orchestrator.recordID(forTopic: title) {
                self.openResearchWorkspace(researchID: recordID)
                return
            }

            let store = WorkspaceSubjectStore.shared
            _ = await store.bootstrap()
            var subject = await store.subjects().first {
                TopicFingerprint.normalized($0.title) == TopicFingerprint.normalized(title)
            }
            if subject == nil {
                subject = try? await store.createSubject(
                    title: title,
                    aliases: [],
                    isFollowed: true,
                    now: Date()
                )
            }
            guard let subject else {
                self.openResearchWorkspace()
                return
            }
            guard ResearchConsent.presentIfNeeded(settings: self.settings) else {
                self.openResearchWorkspace(subjectID: subject.id)
                return
            }
            self.openResearchWorkspace(
                subjectID: subject.id,
                startResearchDepth: self.settings.researchDepth
            )
        }
    }

    /// `.researchRequested` is a seed for the unified launcher, not a second
    /// task entry. The subject carries the page URL so a later start has a real
    /// seed instead of a fabricated Weibo home page.
    @MainActor
    private func openWorkspaceResearch(for item: NewsItem) {
        guard ResearchConsent.presentIfNeeded(settings: settings) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let store = WorkspaceSubjectStore.shared
            _ = await store.bootstrap()
            let topicKey = TopicFingerprint.key(for: item.title)

            var subject = await store.subjects().first { candidate in
                guard !candidate.isArchived else { return false }
                if TopicFingerprint.normalized(candidate.title) == TopicFingerprint.normalized(item.title) {
                    return true
                }
                return candidate.aliases.contains {
                    TopicFingerprint.normalized($0) == TopicFingerprint.normalized(item.title)
                }
            }
            if subject == nil,
               let record = await ResearchStore.shared.latestRecord(topicKey: topicKey) {
                subject = await store.subject(containingResearchID: record.id)
            }
            if subject == nil {
                subject = try? await store.createSubject(
                    title: item.title,
                    aliases: [],
                    isFollowed: true,
                    now: Date()
                )
            }
            guard let subject else {
                self.openResearchWorkspace()
                return
            }
            let subjectID = subject.id
            _ = try? await store.updateSubject(id: subjectID) { latest in
                latest.isFollowed = true
                latest.markUserStateChanged(at: Date())
                if latest.seedURL == nil {
                    latest.seedURL = item.readerURL ?? item.url
                }
            }

            self.openResearchWorkspace(
                subjectID: subjectID,
                startResearchDepth: self.settings.researchDepth
            )
        }
    }

    // MARK: - Workspace resolution

    @MainActor
    private func openWorkspaceSearchResult(_ result: WorkspaceSearchResult) {
        switch result {
        case let .subject(id, _, _, _):
            openResearchWorkspace(subjectID: id)
        case let .report(recordID, _, _, _, _):
            openTransientResearch(recordID: recordID, eventID: nil)
        case let .evidence(resultID, subjectID, title, snippet, url):
            openResearchWorkspace(
                subjectID: subjectID,
                evidenceHint: WorkspaceEvidenceFocus(
                    resultID: resultID,
                    canonicalURL: ContentIdentity.canonicalURL(url),
                    quoteHint: snippet,
                    title: title
                )
            )
        case let .answer(id, _, _, _):
            openResearchWorkspace(answerID: id)
        }
    }

    /// The popover research chip means "unread research", not just "the first
    /// remembered subject". It selects the newest unread report-backed subject.
    private func workspaceUnreadResearchSubjectID() async -> String? {
        let store = WorkspaceSubjectStore.shared
        _ = await store.bootstrap()
        let entries = await ResearchStore.shared.index()
        let candidates = entries
            .filter { !$0.isRead && $0.hasReport && $0.issue == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
        for entry in candidates {
            if let subject = await store.subject(containingResearchID: entry.id) {
                return subject.id
            }
        }
        return nil
    }

    private func resolveWorkspaceSubjectID(recordID: String?, eventID: String?) async -> String? {        let store = WorkspaceSubjectStore.shared
        if let recordID,
           let subject = await store.subject(containingResearchID: recordID) {
            return subject.id
        }
        if let eventID,
           let subject = await store.subject(containingEventID: eventID) {
            return subject.id
        }
        guard recordID != nil || eventID != nil else { return nil }
        // A legacy payload may predate the workspace index. Reconcile once
        // before opening so a valid record/event never lands on an empty window.
        await reconcileWorkspace()
        if let recordID,
           let subject = await store.subject(containingResearchID: recordID) {
            return subject.id
        }
        if let eventID,
           let subject = await store.subject(containingEventID: eventID) {
            return subject.id
        }
        return nil
    }

    private func reconcileWorkspace() async {
        let store = WorkspaceSubjectStore.shared
        _ = await store.bootstrap()
        let research = await ResearchStore.shared.index()
        let events = (try? await NewsEventStore.shared.events()) ?? []
        let existing = await store.subjects()
        let result = WorkspaceReconciler().reconcile(
            research: research,
            events: events,
            existing: existing,
            now: Date()
        )
        let changed = !result.changedIDs.isEmpty
            || !result.createdIDs.isEmpty
            || result.subjects.count != existing.count
        if changed {
            try? await store.saveAll(result.subjects)
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
        let payloadSubjectID = (userInfo["subjectID"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        }
        let parsedDigest = NotificationDigest.decode(userInfo["digest"] as? String)
        let digestCount = parsedDigest?.items.count ?? -1
        let digestResearchCount = parsedDigest?.researchItems.count ?? -1
        notificationLog.notice(
            "[Notify] action=\(response.actionIdentifier, privacy: .public) type=\((userInfo["type"] as? String) ?? "-", privacy: .public) digestNews=\(digestCount, privacy: .public) digestResearch=\(digestResearchCount, privacy: .public) route=\(route.label, privacy: .public)"
        )
        if response.actionIdentifier != UNNotificationDismissActionIdentifier,
           let semanticID = userInfo["semanticID"] as? String {
            Task { await NotificationDeliveryLedger.shared.markRead(semanticID: semanticID) }
        }
        switch route {
        case .dismiss:
            break
        case .burst(let eventID):
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.orchestrator?.restoreResearchStateIfNeeded()
                if let payloadSubjectID {
                    self.openResearchWorkspace(subjectID: payloadSubjectID)
                } else if let recordID = await self.orchestrator?.recordID(forTopic: eventID) {
                    self.openResearchWorkspace(researchID: recordID)
                } else {
                    self.openResearchWorkspace()
                }
            }
        case .newsEvent(let eventID):
            Task { @MainActor [weak self] in
                self?.openResearchWorkspace(
                    subjectID: payloadSubjectID,
                    eventID: eventID
                )
            }
        case .research(let recordID):
            Task { @MainActor [weak self] in
                self?.openResearchWorkspace(
                    subjectID: payloadSubjectID,
                    researchID: recordID
                )
            }
        case let .researchReport(recordID, eventID, versionID, compareFromVersionID):
            let sourceURL = userInfo["sourceURL"] as? String ?? userInfo["url"] as? String
            let title = userInfo["title"] as? String
            Task { @MainActor [weak self] in
                self?.openTransientResearch(
                    recordID: recordID,
                    eventID: eventID,
                    versionID: versionID,
                    compareFromVersionID: compareFromVersionID,
                    fallbackSourceURL: sourceURL,
                    fallbackTitle: title
                )
            }
        case let .researchCorrection(recordID, eventID, versionID, compareFromVersionID, sourceURL, title):
            let safeSourceURL = sourceURL.flatMap { ReaderNavigationPolicy.allowedURL($0)?.absoluteString }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if recordID != nil || eventID != nil {
                    self.openTransientResearch(
                        recordID: recordID,
                        eventID: eventID,
                        versionID: versionID,
                        compareFromVersionID: compareFromVersionID,
                        fallbackSourceURL: safeSourceURL,
                        fallbackTitle: title
                    )
                } else if let safeSourceURL {
                    NewsNavigationRouter.shared.open(
                        url: safeSourceURL,
                        title: title ?? "",
                        surface: "notificationCorrection"
                    )
                } else {
                    self.openDashboard(refresh: false)
                }
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
        case .weibo(let mid, let uid, let url):
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.openDashboard(refresh: false)
                NotificationCenter.default.post(name: .openWeiboFollowFeed, object: nil)
                if !mid.isEmpty {
                    await self.weiboMonitor?.markRead(mid: mid, uid: uid)
                }
                let fallbackURL = mid.isEmpty ? nil : "https://m.weibo.cn/detail/\(mid)"
                let destination = (url?.isEmpty == false) ? url : fallbackURL
                if let destination {
                    NewsNavigationRouter.shared.open(
                        url: destination,
                        title: "",
                        item: nil,
                        surface: "weiboNotification"
                    )
                }
            }
        case .muteWeibo(let uid):
            Task { @MainActor [weak self] in
                await self?.weiboMonitor?.mute(uid)
            }
        case .markWeiboRead(let mid, let uid):
            Task { @MainActor [weak self] in
                await self?.weiboMonitor?.markRead(mid: mid, uid: uid)
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
        let userInfo = notification.request.content.userInfo
        let type = userInfo["type"] as? String
        let eventID = userInfo["eventID"] as? String
        let recordID = userInfo["recordID"] as? String
        let semanticID = userInfo["semanticID"] as? String
        let digestResearchItems = NotificationDigest.decode(userInfo["digest"] as? String)?.researchItems ?? []
        if type == "weibo",
           WeiboFeedPresence.isVisible,
           WeiboFeedPresence.isAppActive {
            // The user is looking at the following feed; insert the post and
            // skip the banner instead of covering the list they are reading.
            completionHandler([])
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                completionHandler([.banner, .sound])
                return
            }
            var matchedItems: [NotificationDigestResearchItem] = []
            if !digestResearchItems.isEmpty {
                matchedItems = digestResearchItems.filter { item in
                    self.isResearchTargetVisibleAndAppActive(eventID: item.eventID, recordID: item.recordID)
                }
            } else if self.isResearchTargetVisibleAndAppActive(eventID: eventID, recordID: recordID) {
                completionHandler([])
                if let semanticID {
                    await NotificationDeliveryLedger.shared.markSuppressed(semanticID: semanticID)
                }
                return
            }
            guard !matchedItems.isEmpty else {
                completionHandler([.banner, .sound])
                return
            }
            completionHandler([])
            for item in matchedItems {
                await NotificationDeliveryLedger.shared.markSuppressed(item)
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        WeiboFeedPresence.setAppActive(true)
    }

    func applicationWillResignActive(_ notification: Notification) {
        WeiboFeedPresence.setAppActive(false)
    }
}
