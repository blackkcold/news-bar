import Dispatch
import Observation

/// Observable selection state shared by the Settings sidebar and detail pane.
/// The sidebar commits synchronously; expensive detail construction is queued
/// for the next main-loop turn and only the latest generation is allowed through.
@MainActor
@Observable
final class SettingsPaneSelection {
    typealias DetailCommitAction = @MainActor () -> Void
    typealias DetailCommitScheduler = @MainActor (@escaping DetailCommitAction) -> Void

    private(set) var selectedPane: SettingsPane
    private(set) var presentedPane: SettingsPane

    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private let scheduleDetailCommit: DetailCommitScheduler

    init(
        initialPane: SettingsPane = .general,
        scheduleDetailCommit: @escaping DetailCommitScheduler = { action in
            DispatchQueue.main.async(execute: action)
        }
    ) {
        self.selectedPane = initialPane
        self.presentedPane = initialPane
        self.scheduleDetailCommit = scheduleDetailCommit
    }

    func select(_ pane: SettingsPane) {
        selectedPane = pane
        generation &+= 1
        let requestedGeneration = generation

        // Incrementing the generation cancels any queued older commit. The
        // callback is deliberately deferred so the List can publish its new
        // selection before the right pane constructs the selected Settings form.
        scheduleDetailCommit { [weak self] in
            guard let self,
                  self.generation == requestedGeneration,
                  self.selectedPane == pane else { return }
            self.presentedPane = pane
        }
    }
}

/// Optional observation point for isolated, off-screen Settings window tests.
/// The real header and detail view write their identities when they appear.
@MainActor
final class SettingsPaneRenderSnapshot {
    private(set) var renderedHeaderTitle: String?
    private(set) var renderedContentPane: SettingsPane?
    private(set) var renderedContentHistory: [SettingsPane] = []

    func recordHeader(for pane: SettingsPane) {
        renderedHeaderTitle = L10n.string(pane.headingKey)
    }

    func recordContent(for pane: SettingsPane) {
        renderedContentPane = pane
        renderedContentHistory.append(pane)
    }
}
