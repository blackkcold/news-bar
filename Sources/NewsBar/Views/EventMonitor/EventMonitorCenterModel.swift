import Foundation
import Observation
import SwiftUI

enum NewsEventListFilter: String, CaseIterable, Identifiable {
    case all, candidate, tracking, notified, expired, budget, conflict

    var id: String { rawValue }

    var titleKey: String { "event.filter.\(rawValue)" }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .candidate: return "sparkle.magnifyingglass"
        case .tracking: return "dot.radiowaves.left.and.right"
        case .notified: return "bell.badge"
        case .expired: return "clock.arrow.circlepath"
        case .budget: return "hourglass"
        case .conflict: return "exclamationmark.bubble"
        }
    }

    func matches(_ event: NewsEvent) -> Bool {
        switch self {
        case .all: return true
        case .candidate: return event.lifecycle == .queued
        case .tracking: return event.lifecycle == .tracking
        case .notified: return event.wasNotified
        case .expired: return event.lifecycle == .expired
        case .budget: return event.trackingStatus == .budgetDeferred
        case .conflict: return event.hasConflict
        }
    }
}

@MainActor
@Observable
final class EventMonitorCenterModel {
    private static let selectedEventKey = "newsEventMonitor.selectedEventID"

    let controller: NewsEventController
    let settings: AppSettings

    var filter: NewsEventListFilter = .all
    var searchText = ""
    private(set) var selectedEventID: String?
    private(set) var isRefreshing = false
    private(set) var isChecking = false
    private(set) var routeMessage: String?

    @ObservationIgnored private var pendingEventID: String?
    @ObservationIgnored private var hasLoaded = false

    init(controller: NewsEventController, settings: AppSettings, eventID: String? = nil) {
        self.controller = controller
        self.settings = settings
        self.pendingEventID = eventID
    }

    var visibleEvents: [NewsEvent] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return controller.events.filter { event in
            guard filter.matches(event) else { return false }
            guard !query.isEmpty else { return true }
            let evidenceTerms = event.evidence.flatMap { evidence -> [String] in
                [evidence.title, evidence.sourceName, evidence.author ?? ""]
            }
            let searchableFields = [event.title, event.eventDescription, event.location ?? ""]
                + event.subjectAliases + evidenceTerms
            let searchable = searchableFields.joined(separator: " ")
            return searchable.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    func count(for filter: NewsEventListFilter) -> Int {
        controller.events.filter(filter.matches).count
    }

    func event(id: String?) -> NewsEvent? {
        guard let id else { return nil }
        return controller.event(id: id)
    }

    func load() async {
        guard !hasLoaded else { return }
        await InterestController.shared.prepare()
        await reload(preserveSelection: true)
        hasLoaded = true
        restoreSelectionAfterInitialLoad()
    }

    func reload() async {
        await reload(preserveSelection: true)
    }

    private func reload(preserveSelection: Bool) async {
        let previousID = selectedEventID
        var removedSelection = false
        isRefreshing = true
        routeMessage = nil
        await controller.reload(now: Date())
        isRefreshing = false
        if preserveSelection, let previousID {
            if controller.event(id: previousID) != nil {
                selectedEventID = previousID
            } else {
                clearSelection()
                removedSelection = true
                routeMessage = L10n.string("event.selection.removed", language: settings.appLanguage)
            }
        }
        if !removedSelection { reconcileSelectionAfterFilterChange() }
    }

    func checkNow() async {
        guard settings.newsEventMonitoringEnabled else {
            routeMessage = L10n.string("event.check.monitorOff", language: settings.appLanguage)
            return
        }
        isChecking = true
        routeMessage = nil
        await controller.recoverAndTick(now: Date(), sources: settings.activeSources)
        isChecking = false
        if case .failed(let message, _) = controller.state {
            routeMessage = message
        }
        var removedSelection = false
        if let selectedEventID, controller.event(id: selectedEventID) == nil {
            clearSelection()
            removedSelection = true
            routeMessage = L10n.string("event.selection.removed", language: settings.appLanguage)
        }
        if !removedSelection { reconcileSelectionAfterFilterChange() }
    }

    func select(_ id: String) {
        guard visibleEvents.contains(where: { $0.id == id }) else { return }
        selectedEventID = id
        routeMessage = nil
        TestIsolation.defaults.set(id, forKey: Self.selectedEventKey)
    }

    /// Notification links deliberately clear search and filters before lookup.
    /// A missing ID clears detail instead of presenting a different event.
    func openEvent(_ id: String) async {
        filter = .all
        searchText = ""
        pendingEventID = id
        await reload(preserveSelection: false)
        if controller.event(id: id) != nil {
            select(id)
            pendingEventID = nil
        } else {
            clearSelection()
            pendingEventID = nil
            routeMessage = L10n.string("event.selection.notFound", language: settings.appLanguage)
        }
    }

    func reconcileSelectionAfterFilterChange() {
        let visible = visibleEvents
        if let selectedEventID, visible.contains(where: { $0.id == selectedEventID }) { return }
        if let first = visible.first {
            select(first.id)
        } else {
            clearSelection()
        }
    }

    func moveSelection(_ direction: MoveCommandDirection) {
        guard direction == .up || direction == .down else { return }
        let entries = visibleEvents
        guard !entries.isEmpty else { return }
        let current = entries.firstIndex { $0.id == selectedEventID }
        let next = current.map { min(max($0 + (direction == .down ? 1 : -1), 0), entries.count - 1) }
            ?? (direction == .down ? 0 : entries.count - 1)
        select(entries[next].id)
    }

    private func restoreSelectionAfterInitialLoad() {
        if let pendingEventID {
            if controller.event(id: pendingEventID) != nil {
                select(pendingEventID)
            } else {
                clearSelection()
                routeMessage = L10n.string("event.selection.notFound", language: settings.appLanguage)
            }
            self.pendingEventID = nil
            return
        }
        if let saved = TestIsolation.defaults.string(forKey: Self.selectedEventKey),
           visibleEvents.contains(where: { $0.id == saved }) {
            select(saved)
        } else if let first = visibleEvents.first {
            select(first.id)
        }
    }

    private func clearSelection() {
        selectedEventID = nil
        TestIsolation.defaults.removeObject(forKey: Self.selectedEventKey)
    }
}
