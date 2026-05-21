import AppKit
import SwiftUI

extension Notification.Name {
    static let rssSourceAdded = Notification.Name("rssSourceAdded")
    static let switchToAITab = Notification.Name("switchToAITab")
    static let apiKeyConfigured = Notification.Name("apiKeyConfigured")
}

final class AppDelegate: NSObject, NSApplicationDelegate {

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            Task {
                await self.orchestrator?.refreshIfNeeded(settings: self.settings)
            }
        }

        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self, self.settings.autoRefreshEnabled else { return }
            Task {
                await self.orchestrator?.refreshIfNeeded(settings: self.settings)
            }
        }
    }

    private func scheduleAutoUpdateCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
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

    private func refreshAPIKeyIfNeeded() {
        let ref = settings.onePasswordRef
        let account = settings.currentProvider.apiKeyAccount()
        guard !ref.isEmpty,
              KeychainManager.isKeyStale(account: account),
              OnePasswordService.isInstalled() else { return }
        DispatchQueue.global().async { [self] in
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            let account = self.settings.currentProvider.apiKeyAccount()
            DispatchQueue.global().async {
                let existence = KeychainManager.checkAPIKeyExistence(account: account)
                DispatchQueue.main.async {
                    switch existence {
                    case .notFound:
                        if self.settings.aiSummaryEnabled {
                            self.handleMissingAPIKey()
                        }
                    case .existsAccessible, .existsNeedsAuth:
                        UserDefaults.standard.set(true, forKey: self.settings.currentProvider.keyExistsFlag())
                        break
                    }
                    self.refreshAPIKeyIfNeeded()
                }
            }
        }
    }

    private func loadAPIKeyFromKeychainIfNeeded() {
        guard settings.aiSummaryEnabled,
              settings.cachedAPIKey == nil else { return }
        let account = settings.currentProvider.apiKeyAccount()
        let hasKey = UserDefaults.standard.bool(forKey: settings.currentProvider.keyExistsFlag())
            || KeychainManager.checkAPIKeyExistence(account: account) != .notFound
        guard hasKey else { return }

        orchestrator?.aiSummaryState = .idle
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            if let key = KeychainManager.readAPIKey(account: account), !key.isEmpty {
                DispatchQueue.main.async {
                    self.settings.cachedAPIKey = key
                    Task {
                        await self.orchestrator?.manualRefresh(settings: self.settings)
                    }
                }
            }
        }
    }

    private func handleMissingAPIKey() {
        orchestrator?.aiSummaryState = .noKey
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
            self.orchestrator?.aiSummaryState = .idle
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
        popover.contentSize = NSSize(width: 360, height: 520)
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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NewsBar Settings"
        window.center()
        window.contentView = NSHostingView(
            rootView: SettingsWindow(initialTab: initialTab)
                .environment(settings)
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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
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
