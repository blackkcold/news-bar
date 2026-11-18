import Observation

/// Observable source of truth shared by the Settings sidebar, detail pane, and
/// route tests. Keeping pane selection explicit also lets non-UI entry points
/// drive the same state as a sidebar selection.
@Observable
final class SettingsPaneSelection {
    var selectedPane: SettingsPane

    init(initialPane: SettingsPane = .general) {
        self.selectedPane = initialPane
    }
}

/// Optional observation point for isolated, off-screen Settings window tests.
/// The real header and detail view write their identities when they appear.
@MainActor
final class SettingsPaneRenderSnapshot {
    private(set) var renderedHeaderTitle: String?
    private(set) var renderedContentPane: SettingsPane?

    func recordHeader(for pane: SettingsPane) {
        renderedHeaderTitle = L10n.string(pane.headingKey)
    }

    func recordContent(for pane: SettingsPane) {
        renderedContentPane = pane
    }
}
