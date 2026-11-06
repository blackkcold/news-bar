import AppKit

/// Owns the settings window's sidebar toggle.
///
/// Why AppKit and not a SwiftUI `.toolbar` item: on macOS 26 SwiftUI hosts the
/// default sidebar toggles per column, so the button hops from the sidebar's
/// toolbar to the detail's toolbar (and from leading to trailing) whenever the
/// column collapses. Removing the default item hands the window toolbar back to
/// AppKit, and a toolbar owned here keeps one fixed slot for the button's whole
/// lifetime.
///
/// The toolbar only stays ours while SwiftUI has no toolbar content of its own:
/// `SettingsWindow` must keep `.toolbar(removing: .sidebarToggle)` on the
/// sidebar and must not add `.toolbar { ... }` to the settings window.
@MainActor
final class SettingsToolbarController: NSObject, NSToolbarDelegate {
    static let toggleIdentifier = NSToolbarItem.Identifier("NewsBar.settings.sidebar")
    static let toolbarIdentifier = NSToolbar.Identifier("NewsBar.SettingsToolbar")

    private let state: SettingsSidebarState
    private let settings: AppSettings
    private weak var window: NSWindow?
    private weak var toggleItem: NSToolbarItem?
    private var keyMonitor: Any?
    private var isCreatingItem = false

    init(state: SettingsSidebarState, settings: AppSettings) {
        self.state = state
        self.settings = settings
        super.init()
        // The state changes from both the button and the view hierarchy; the
        // item has to mirror it either way.
        state.onChange = { [weak self] in self?.refresh() }
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    func install(on window: NSWindow) {
        self.window = window

        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        installKeyMonitor()
    }

    // MARK: - NSToolbarDelegate

    /// A leading flexible space pins the item to the trailing edge of the
    /// toolbar, where it keeps the same frame no matter which columns the split
    /// view shows. The retro skin has no columns to move, so it starts without
    /// the item at all.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        state.isCollapsible ? [.flexibleSpace, Self.toggleIdentifier] : [.flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.toggleIdentifier]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.toggleIdentifier else { return nil }

        isCreatingItem = true
        defer { isCreatingItem = false }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.target = self
        item.action = #selector(toggleSidebar)
        // AppKit re-enables items whose target responds to the action on every
        // validation pass; the item's availability is ours to decide.
        item.autovalidates = false
        // Navigational items migrate into the leading title cluster; this
        // button must not.
        item.isNavigational = false
        item.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: nil)
        toggleItem = item
        refresh()
        return item
    }

    // MARK: - State mirroring

    private func refresh() {
        if !isCreatingItem {
            syncPresence()
        }
        guard let item = toggleItem else { return }
        let language = settings.appLanguage
        let collapsed = state.isCollapsed

        item.label = L10n.string(
            collapsed ? "settings.sidebar.show" : "settings.sidebar.hide",
            language: language
        )
        item.paletteLabel = L10n.string("settings.sidebar.label", language: language)
        item.toolTip = item.label
    }

    /// The retro skin keeps a fixed two-column shell, so a sidebar toggle there
    /// would be a dead control. Remove the item instead of disabling it, and
    /// put it back when the modern skin returns.
    private func syncPresence() {
        guard let window, let toolbar = window.toolbar else { return }
        let present = toolbar.items.contains { $0.itemIdentifier == Self.toggleIdentifier }

        if state.isCollapsible, !present {
            toolbar.insertItem(withItemIdentifier: Self.toggleIdentifier, at: min(1, toolbar.items.count))
        } else if !state.isCollapsible, present,
                  let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == Self.toggleIdentifier }) {
            toggleItem = nil
            toolbar.removeItem(at: index)
        }
    }

    @objc private func toggleSidebar() {
        state.toggle()
    }

    // MARK: - Keyboard

    /// The app runs as an accessory with no menu bar, so the system's ⌃⌘S does
    /// not exist here. Mirror it while the settings window is key.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command, .control],
                  event.charactersIgnoringModifiers?.lowercased() == "s"
            else { return event }

            self.state.toggle()
            return nil
        }
    }
}
