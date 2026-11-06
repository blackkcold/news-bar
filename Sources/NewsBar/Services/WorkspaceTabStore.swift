import Foundation
import Observation

struct WorkspaceTab: Identifiable {
    let id: UUID
    let request: NewsReaderRequest
}

/// Owns the article tabs and their reader models. The browse pane is implicit:
/// `activeID == nil` means the user is looking at the list, and every model is
/// suspended rather than destroyed, so returning to a tab keeps its page.
@MainActor
@Observable
final class WorkspaceTabStore {
    static let shared = WorkspaceTabStore()

    private(set) var tabs: [WorkspaceTab] = []
    private(set) var activeID: UUID?
    @ObservationIgnored private var models: [UUID: NewsReaderModel] = [:]

    var activeTab: WorkspaceTab? {
        guard let activeID else { return nil }
        return tabs.first { $0.id == activeID }
    }

    var activeRequest: NewsReaderRequest? { activeTab?.request }

    func openOrActivate(_ request: NewsReaderRequest) {
        if let existing = tabs.first(where: { $0.request.id == request.id }) {
            activate(existing.id)
            return
        }
        let tab = WorkspaceTab(id: UUID(), request: request)
        tabs.append(tab)
        models[tab.id] = NewsReaderModel(request: request)
        activate(tab.id)
    }

    func activate(_ id: UUID) {
        guard activeID != id else { return }
        let previous = activeID
        activeID = id
        if let previous { models[previous]?.setTabActive(false) }
        models[id]?.setTabActive(true)
    }

    /// The reader is dismissed but the tabs remain. Their WebViews stay alive;
    /// only the reading clock and keyboard shortcuts stop.
    func deactivate() {
        if let activeID { models[activeID]?.setTabActive(false) }
        activeID = nil
    }

    func model(for tab: WorkspaceTab) -> NewsReaderModel {
        if let model = models[tab.id] { return model }
        let model = NewsReaderModel(request: tab.request)
        models[tab.id] = model
        return model
    }

    /// Returns the tab that should become active. `nil` means no article tab is
    /// left and the browse pane should be shown.
    func close(_ id: UUID) -> WorkspaceTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return activeTab
        }
        let wasActive = activeID == id
        let removed = tabs.remove(at: index)
        models[removed.id]?.stop()
        models[removed.id] = nil

        guard wasActive else { return activeTab }
        guard !tabs.isEmpty else {
            activeID = nil
            return nil
        }
        let nextIndex = min(index, tabs.count - 1)
        let next = tabs[nextIndex]
        activeID = next.id
        models[next.id]?.setTabActive(true)
        return next
    }

    func request(for id: UUID) -> NewsReaderRequest? {
        tabs.first { $0.id == id }?.request
    }

    func terminateAll() {
        for model in models.values { model.stop() }
        models.removeAll()
        tabs.removeAll()
        activeID = nil
    }
}
