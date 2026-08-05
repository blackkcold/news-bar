import AppKit
import SwiftUI

extension Notification.Name {
    static let rssSourceAdded = Notification.Name("rssSourceAdded")
    static let switchToAITab = Notification.Name("switchToAITab")
    static let apiKeyConfigured = Notification.Name("apiKeyConfigured")
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Constants

    private static let schedulerTickInterval = RefreshPolicy.schedulerTick
    private static let startupDelay: TimeInterval = 2
    private static let updateCheckDelay: TimeInterval = 10
    private static let popoverSize = NSSize(width: 400, height: 520)
    private static let settingsSize = NSSize(width: 560, height: 420)
    private static let dashboardSize = NSSize(width: 1180, height: 860)
    private static let dashboardMinimumSize = NSSize(width: 960, height: 720)

    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?
    private var dashboardWindow: NSWindow?

    private var settings: AppSettings!
    private var orchestrator: NewsOrchestrator?
    private var updateChecker: UpdateChecker?
    private var autoRefreshTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isSystemSleeping = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        orchestrator = NewsOrchestrator()
        updateChecker = UpdateChecker()
        setupStatusBar()
        setupNotificationObservers()

        // 从 Keychain 迁移到加密文件存储（必须在任何读取之前）
        EncryptedKeyStore.migrateFromKeychainIfNeeded()
        settings = AppSettings()
        setupWorkspaceObservers()

        preloadCachedNews()
        loadAPIKeyFromFile()
        observeAPIKeyConfigured()
        refreshAPIKeyIfNeeded()
        scheduleStartupAndAutoRefresh()
        scheduleAutoUpdateCheck()

        Task { _ = await NotificationService.requestAuthorization() }
        if settings.dailyPushEnabled {
            NotificationService.scheduleDailyPush(hour: settings.dailyPushHour, minute: settings.dailyPushMinute)
        }
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

    private func setupNotificationObservers() {
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
        Task { [weak self] in
            guard let self else { return }
            let store = EncryptedKeyStore()
            if let key = await store.readAPIKey(account: account), !key.isEmpty {
                await MainActor.run {
                    self.settings.cachedAPIKey = key
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

        Task { @MainActor in orchestrator?.aiSummaryState = .idle }
        Task { [weak self] in
            guard let self else { return }
            let store = EncryptedKeyStore()
            if let key = await store.readAPIKey(account: account), !key.isEmpty {
                await MainActor.run {
                    UserDefaults.standard.set(true, forKey: self.settings.currentProvider.keyExistsFlag())
                    UserDefaults.standard.set(true, forKey: "hasAIKey-\(self.settings.activeAPIKeyAccount)")
                    self.settings.cachedAPIKey = key
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
        requestVisibleRefreshIfNeeded()
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

        let initialTab = toAITab ? 2 : 0

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

    func openDashboard() {
        popover?.performClose(nil)

        if let existing = dashboardWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            requestVisibleRefreshIfNeeded()
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
                onConfigureAI: { [weak self] in self?.openSettings(toAITab: true) }
            )
            .environment(settings)
        )
        window.isReleasedWhenClosed = false

        dashboardWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        requestVisibleRefreshIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        autoRefreshTimer?.invalidate()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { workspaceCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        settingsWindow?.close()
        dashboardWindow?.close()
        popover?.close()
        NotificationService.clearAllPending()
    }
}
