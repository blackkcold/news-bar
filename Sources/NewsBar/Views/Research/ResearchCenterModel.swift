import Foundation
import Observation

enum ResearchCenterFilter: String, CaseIterable, Identifiable, Sendable {
    case all, unread, burst, keyword, manual, failed, pinned

    var id: String { rawValue }
    var titleKey: String { "research.filter.\(rawValue)" }

    var symbol: String {
        switch self {
        case .all: return "tray.full"
        case .unread: return "circle.fill"
        case .burst: return "flame"
        case .keyword: return "text.magnifyingglass"
        case .manual: return "checkmark.seal"
        case .failed: return "exclamationmark.triangle"
        case .pinned: return "pin"
        }
    }

    func matches(_ entry: ResearchIndexEntry) -> Bool {
        switch self {
        case .all:
            return true
        case .unread:
            return !entry.isRead
        case .burst:
            return entry.origin == .burst
        case .keyword:
            return entry.origin == .keyword
        case .manual:
            return entry.origin == .manual
        case .failed:
            return entry.status == .failed || entry.status == .partial || entry.status == .interrupted
        case .pinned:
            return entry.isPinned
        }
    }
}

enum ResearchSort: String, CaseIterable, Identifiable, Sendable {
    case updated, created, accessed

    var id: String { rawValue }
    var titleKey: String { "research.sort.\(rawValue)" }
}

@MainActor
final class ResearchSelectionTracker {
    static let shared = ResearchSelectionTracker()
    private(set) var selectedID: String?

    func set(_ id: String?) {
        selectedID = id
    }
}

@MainActor
@Observable
final class ResearchCenterModel {
    private let store: any ResearchPersisting
    private let coordinator: ResearchCoordinator
    private let orchestrator: NewsOrchestrator
    private let settings: AppSettings

    var entries: [ResearchIndexEntry] = []
    var selectedID: String? {
        didSet { ResearchSelectionTracker.shared.set(selectedID) }
    }
    var selectedRecord: ResearchRecord?
    var filter: ResearchCenterFilter = .all
    var sort: ResearchSort = .updated
    var searchText = ""
    var onlyUnread = false
    var storageBytes: Int64 = 0
    var isLoading = false
    var errorMessage: String?

    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var hasLoaded = false

    init(
        orchestrator: NewsOrchestrator,
        settings: AppSettings,
        store: any ResearchPersisting = ResearchStore.shared,
        coordinator: ResearchCoordinator = .shared
    ) {
        self.orchestrator = orchestrator
        self.settings = settings
        self.store = store
        self.coordinator = coordinator

        observer = NotificationCenter.default.addObserver(
            forName: .researchRecordsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.hasLoaded else { return }
                await self.refresh()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var summary: ResearchSummary {
        let bursts = entries.filter { $0.origin == .burst }
        return ResearchSummary(
            burstCount: bursts.count,
            unreadBurstCount: bursts.filter { !$0.isRead }.count
        )
    }

    var visibleEntries: [ResearchIndexEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = entries.filter { entry in
            guard filter.matches(entry) else { return false }
            guard !onlyUnread || !entry.isRead else { return false }
            guard !query.isEmpty else { return true }
            return entry.topic.localizedCaseInsensitiveContains(query)
        }

        switch sort {
        case .updated:
            return filtered.sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id < $1.id
            }
        case .created:
            return filtered.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id < $1.id
            }
        case .accessed:
            return filtered.sorted {
                if $0.lastAccessedAt != $1.lastAccessedAt { return $0.lastAccessedAt > $1.lastAccessedAt }
                return $0.id < $1.id
            }
        }
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        await reloadEntries()
        hasLoaded = true
        if let selectedID, entries.contains(where: { $0.id == selectedID }) {
            selectedRecord = await store.record(id: selectedID)
        } else if let first = visibleEntries.first {
            selectedID = first.id
            selectedRecord = await store.record(id: first.id)
        } else {
            selectedID = nil
            selectedRecord = nil
        }
    }

    func refresh() async {
        await reloadEntries()
        if let selectedID {
            if entries.contains(where: { $0.id == selectedID }) {
                selectedRecord = await store.record(id: selectedID)
            } else {
                self.selectedID = nil
                selectedRecord = nil
            }
        }
        if selectedID == nil, let first = visibleEntries.first {
            selectedID = first.id
            selectedRecord = await store.record(id: first.id)
        }
    }

    func select(_ id: String?) async {
        selectedID = id
        guard let id else {
            selectedRecord = nil
            return
        }
        guard let record = await store.record(id: id) else {
            selectedRecord = nil
            return
        }
        selectedRecord = record
        await store.touch(id: id, at: Date())
        if let touched = await store.record(id: id) {
            selectedRecord = touched
        }
        await reloadEntries()
    }

    @discardableResult
    func createManual(item: NewsItem) async -> String? {
        guard ResearchConsent.presentIfNeeded(settings: settings) else { return nil }
        guard let record = await ResearchRecordProvisioner.ensureRecord(
            for: item,
            origin: .manual,
            store: store
        ) else {
            errorMessage = L10n.string("research.error.create", language: settings.appLanguage)
            return nil
        }

        if record.run.startedAt == nil || !record.status.isActive {
            await schedule(record)
        }
        await refresh()
        await select(record.id)
        return record.id
    }

    func retry(id: String) async {
        guard let record = await store.record(id: id), record.status != .corrupt else { return }
        guard !record.status.isActive else { return }
        await schedule(record)
        await refresh()
    }

    func cancel(id: String) async {
        coordinator.cancel(recordID: id)
        try? await Task.sleep(nanoseconds: 60_000_000)
        await refresh()
    }

    func delete(id: String) async {
        do {
            try await store.delete(id: id)
        } catch {
            errorMessage = L10n.string("research.error.delete", language: settings.appLanguage)
            return
        }
        if selectedID == id {
            selectedID = nil
            selectedRecord = nil
        }
        await refresh()
    }

    func togglePin(id: String) async {
        guard var record = await store.record(id: id), record.status != .corrupt else { return }
        record.isPinned.toggle()
        try? await store.save(record)
        await refresh()
    }

    func markRead(id: String, read: Bool = true) async {
        guard var record = await store.record(id: id), record.status != .corrupt else { return }
        guard record.isRead != read else { return }
        record.isRead = read
        try? await store.save(record)
        await refresh()
    }

    func clearHistory() async {
        coordinator.cancelAll()
        do {
            try await store.deleteAll()
        } catch {
            errorMessage = L10n.string("research.error.delete", language: settings.appLanguage)
        }
        selectedID = nil
        selectedRecord = nil
        await refresh()
    }

    func markdown(for record: ResearchRecord) -> String {
        guard let report = record.report else { return "" }
        let language = settings.appLanguage
        var lines: [String] = ["# \(record.topic)", ""]

        if !report.summary.isEmpty {
            lines += ["## \(L10n.string("burst.summary", language: language))", "", report.summary, ""]
        }
        if !report.overview.isEmpty {
            lines += ["## \(L10n.string("burst.overview", language: language))", "", report.overview, ""]
        }
        if !report.timeline.isEmpty {
            lines += ["## \(L10n.string("burst.timeline", language: language))", ""]
            for node in report.timeline {
                let date = node.date.isEmpty ? "" : "\(node.date) "
                lines.append("- \(date)\(node.title)：\(node.detail)")
            }
            lines.append("")
        }
        if let verification = report.verification {
            lines += [
                "## \(L10n.string("research.section.verification", language: language))",
                "",
                L10n.string("research.strength", language: language, verification.strength),
                L10n.string("research.independentSources", language: language, verification.independentSources),
                "",
            ]
        }
        if !report.evidence.isEmpty {
            lines += ["## \(L10n.string("research.section.evidence", language: language))", ""]
            for item in report.evidence {
                lines.append("- [\(item.id)] \(item.title) — \(item.url)")
                if !item.quote.isEmpty {
                    lines.append("  > \(item.quote)")
                }
            }
            lines.append("")
        }
        if !report.limitations.isEmpty {
            lines += ["## \(L10n.string("research.section.limitations", language: language))", "", report.limitations, ""]
        }
        if !report.sources.isEmpty {
            lines += ["## \(L10n.string("burst.sources", language: language))", ""]
            for source in report.sources {
                lines.append("- \(source)")
            }
            lines.append("")
        }
        lines.append(L10n.string("research.disclaimer", language: language))
        return lines.joined(separator: "\n")
    }

    private func schedule(_ record: ResearchRecord) async {
        await coordinator.schedule(recordID: record.id) { [orchestrator, settings] record, progress in
            await orchestrator.executeResearch(record: record, settings: settings, progress: progress)
        }
    }

    private func reloadEntries() async {
        entries = await store.index()
        storageBytes = await store.storageFootprint()
        orchestrator.researchSummary = summary
    }
}
