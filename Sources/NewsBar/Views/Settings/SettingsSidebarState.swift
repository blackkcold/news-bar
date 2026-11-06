import Observation
import SwiftUI

/// Shared owner of the settings sidebar's collapse state.
///
/// The toggle lives in an AppKit `NSToolbarItem` (see `SettingsToolbarController`),
/// outside the SwiftUI view that owns the `NavigationSplitView`. Both sides need
/// one source of truth, otherwise the button and the column layout drift apart.
@Observable
final class SettingsSidebarState {
    /// Bound to `NavigationSplitView(columnVisibility:)`.
    var visibility: NavigationSplitViewVisibility = .all

    /// The retro paper skin keeps its fixed two-column shell, so the toolbar
    /// item has nothing to toggle there and is shown disabled.
    var isCollapsible = true

    /// Called after any change that the AppKit toolbar item must mirror
    /// (collapse state, theme, language). Not observed: it is an action hook.
    @ObservationIgnored var onChange: (() -> Void)?

    var isCollapsed: Bool { visibility == .detailOnly }

    func toggle() {
        guard isCollapsible else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            visibility = isCollapsed ? .all : .detailOnly
        }
        onChange?()
    }
}
