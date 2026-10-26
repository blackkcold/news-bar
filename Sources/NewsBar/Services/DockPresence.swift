import AppKit

/// Shows a Dock tile while the Dashboard window exists and removes it again on close.
///
/// The app is a menu-bar agent (`LSUIElement` + `.accessory`), so it normally has no
/// Dock presence. Switching to `.regular` for the lifetime of the Dashboard keeps the
/// menu-bar behaviour intact while giving the window a real app identity: Dock tile,
/// Cmd-Tab entry and a menu bar.
@MainActor
enum DockPresence {
    private static var isVisible = false
    private static var didResolveIcon = false
    private static var cachedIcon: NSImage?
    private static var didInstallMenu = false

    static func show() {
        guard !isVisible else { return }
        isVisible = true

        installApplicationIconIfNeeded()
        installMinimalMainMenuIfNeeded()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func hide() {
        guard isVisible else { return }
        isVisible = false
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Icon

    private static func installApplicationIconIfNeeded() {
        if !didResolveIcon {
            didResolveIcon = true
            cachedIcon = loadAppIcon()
        }
        if let cachedIcon {
            NSApp.applicationIconImage = cachedIcon
        }
    }

    /// Packaged builds get the icon from `CFBundleIconFile`; `swift run` builds fall
    /// back to the repository copy so the Dock never shows a generic executable icon.
    private static func loadAppIcon() -> NSImage? {
        var candidates: [URL] = []

        if let bundled = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            candidates.append(bundled)
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/AppIcon.icns"))
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/AppIcon.icns")
        )

        // Sources/NewsBar/Services/DockPresence.swift -> package root.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(packageRoot.appendingPathComponent("Resources/AppIcon.icns"))

        for url in candidates {
            if let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }

    // MARK: - Menu bar

    private static var usesChinese: Bool { L10n.currentLanguage == .zh }

    /// A `.regular` app is expected to have an app menu. Building a small one avoids
    /// an empty menu bar that looks like a broken build.
    private static func installMinimalMainMenuIfNeeded() {
        guard !didInstallMenu, NSApp.mainMenu == nil else { return }
        didInstallMenu = true

        let appName = "NewsBar"
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: usesChinese ? "关于 \(appName)" : "About \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: usesChinese ? "隐藏 \(appName)" : "Hide \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = appMenu.addItem(
            withTitle: usesChinese ? "隐藏其他" : "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: usesChinese ? "显示全部" : "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: usesChinese ? "退出 \(appName)" : "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: usesChinese ? "编辑" : "Edit")
        editMenu.addItem(withTitle: usesChinese ? "撤销" : "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: usesChinese ? "重做" : "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: usesChinese ? "剪切" : "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: usesChinese ? "复制" : "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: usesChinese ? "粘贴" : "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: usesChinese ? "全选" : "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: usesChinese ? "窗口" : "Window")
        windowMenu.addItem(
            withTitle: usesChinese ? "最小化" : "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: usesChinese ? "缩放" : "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: usesChinese ? "前置全部窗口" : "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}
