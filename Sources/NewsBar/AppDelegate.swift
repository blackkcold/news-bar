import AppKit
import SwiftUI

extension Notification.Name {
    static let rssSourceAdded = Notification.Name("rssSourceAdded")
    static let switchToAITab = Notification.Name("switchToAITab")
    static let apiKeyConfigured = Notification.Name("apiKeyConfigured")
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Constants

    private static let autoRefreshInterval: TimeInterval = 3600
    private static let startupDelay: TimeInterval = 2
    private static let updateCheckDelay: TimeInterval = 10
    private static let keychainReadDelay: TimeInterval = 1.5
    private static let popoverSize = NSSize(width: 360, height: 520)
    private static let settingsSize = NSSize(width: 560, height: 420)
    private static let dashboardSize = NSSize(width: 420, height: 600)

    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?
    private var dashboardWindow: NSWindow?

    private let settings = AppSettings()
    private var orchestrator: NewsOrchestrator?
    private var updateChecker: UpdateChecker?
    private var autoRefreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        orchestrator = NewsOrchestrator()
        updateChecker = UpdateChecker()
        setupStatusBar()
        setupNotificationObservers()

        // 迁移旧 DeepSeek Keychain 条目（必须在任何读取之前）
        settings.migrateLegacyKeyIfNeeded()

        scheduleDelayedKeychainRead()
        observeAPIKeyConfigured()
        refreshAPIKeyIfNeeded()
        scheduleStartupAndAutoRefresh()
        scheduleAutoUpdateCheck()
    }

    private func scheduleStartupAndAutoRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startupDelay) { [weak self] in
            guard let self else { return }
            Task {
                await self.orchestrator?.refreshIfNeeded(settings: self.settings, trigger: .startup)
            }
        }

        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: Self.autoRefreshInterval, repeats: true) { [weak self] _ in
            guard let self, self.settings.autoRefreshEnabled else { return }
            Task {
                await self.orchestrator?.refreshIfNeeded(settings: self.settings, trigger: .timer1h)
            }
        }
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
                await self.orchestrator?.refreshRSSSource(url: url, name: name)
            }
        }
    }

    private func currentProviderHasSavedKeyFlag() -> Bool {
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
        let account = settings.currentProvider.apiKeyAccount()
        guard currentProviderHasSavedKeyFlag(),
              !ref.isEmpty,
              KeychainManager.isKeyStale(account: account),
              OnePasswordService.isInstalled() else { return }
        DispatchQueue.global().async { [weak self] in
            guard let self else {
                NSLog("[Keychain] AppDelegate deallocated before 1Password key save")
                return
            }
            do {
                let key = try OnePasswordService.readSecret(reference: ref)
                if KeychainManager.saveAPIKey(key, account: account) {
                    DispatchQueue.main.async {
                        self.settings.cachedAPIKey = key
                    }
                }
            } catch {
                // silent fail — will retry next launch
            }
        }
    }

    private func scheduleDelayedKeychainRead() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keychainReadDelay) { [weak self] in
            guard let self else { return }

            guard self.currentProviderHasSavedKeyFlag() else {
                if self.settings.aiSummaryEnabled {
                    self.handleMissingAPIKey()
                }
                return
            }
        }
    }

    private func loadAPIKeyFromKeychainIfNeeded() {
        guard settings.aiSummaryEnabled,
              settings.cachedAPIKey == nil else { return }
        guard currentProviderHasSavedKeyFlag() else {
            Task { @MainActor in orchestrator?.aiSummaryState = .noKey }
            return
        }
        let account = settings.currentProvider.apiKeyAccount()

        Task { @MainActor in orchestrator?.aiSummaryState = .idle }
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            if let key = KeychainManager.readAPIKey(account: account), !key.isEmpty {
                DispatchQueue.main.async {
                    UserDefaults.standard.set(true, forKey: self.settings.currentProvider.keyExistsFlag())
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
        alert.messageText = "未配置 API Key"
        alert.informativeText = "AI 总结功能需要配置 API Key 才能使用。\n是否前往设置进行配置？"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "前往设置")
        alert.addButton(withTitle: "稍后再说")

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
        guard let orchestrator = orchestrator else { return }
        loadAPIKeyFromKeychainIfNeeded()

        let contentView = PopoverContent(
            orchestrator: orchestrator,
            updateChecker: updateChecker ?? UpdateChecker(),
            onOpenSettings: { [weak self] in self?.openSettings() },
            onOpenDashboard: { [weak self] in self?.openDashboard() },
            onConfigureKey: { [weak self] in self?.openSettings(toAITab: true) }
        )
        .environment(settings)

        let popover = NSPopover()
        popover.contentSize = Self.popoverSize
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: contentView)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        self.popover = popover
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

    func openDashboard() {
        popover?.performClose(nil)

        if let existing = dashboardWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.dashboardSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NewsBar Dashboard"
        window.center()
        window.contentView = NSHostingView(
            rootView: DashboardWindow(orchestrator: orchestrator!)
                .environment(settings)
        )
        window.isReleasedWhenClosed = false

        dashboardWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        autoRefreshTimer?.invalidate()
        settingsWindow?.close()
        dashboardWindow?.close()
        popover?.close()
    }
}
