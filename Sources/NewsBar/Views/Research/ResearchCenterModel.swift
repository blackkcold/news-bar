import Foundation
import Observation

enum ResearchCenterFilter: String, CaseIterable, Identifiable, Sendable {
    case all, unread, burst, keyword, interest, manual, failed, pinned

    var id: String { rawValue }
    var titleKey: String { "research.filter.\(rawValue)" }

    var symbol: String {
        switch self {
        case .all: return "tray.full"
        case .unread: return "circle.fill"
        case .burst: return "flame"
        case .keyword: return "text.magnifyingglass"
        case .interest: return "sparkles"
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
        case .interest:
            return entry.origin == .interest
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

/// Presentation-only retry state. It is never written to the record: the
/// coordinator owns the real `.queued` transition and posts it back.
struct ResearchRetryOverlay: Equatable {
    var status: ResearchStatus = .queued
    var phase: ResearchRun.Phase = .idle
}

/// Transient, non-modal feedback for a user action. Auto-dismissed by the model
/// so the view does not need its own timer.
struct ResearchActionNotice: Identifiable, Equatable {
    enum Tone: Equatable { case info, error }

    let id = UUID()
    let message: String
    let tone: Tone
    /// Scopes the banner to the record the action belonged to. Switching rows
    /// must not show the previous record's error.
    let recordID: String
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
    typealias ResearchExecutor = @MainActor (
        ResearchRecord,
        @escaping @Sendable (ResearchRun) async -> Void
    ) async -> ResearchExecution

    private let store: any ResearchPersisting
    private let coordinator: ResearchCoordinator
    private let orchestrator: NewsOrchestrator
    private let settings: AppSettings
    private let clearHistoryAction: @MainActor () async -> ResearchClearResult
    /// Injectable only so tests can hold a run open and observe the queued
    /// overlay. Production uses the orchestrator pipeline.
    private let executorOverride: ResearchExecutor?

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
    /// Records whose retry was accepted locally and whose store transition has
    /// not arrived yet. Keyed by record id.
    var retryOverlay: [String: ResearchRetryOverlay] = [:]
    var actionNotice: ResearchActionNotice?

    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var retryTimeouts: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingReadTask: Task<Void, Never>?

    init(
        orchestrator: NewsOrchestrator,
        settings: AppSettings,
        store: any ResearchPersisting = ResearchStore.shared,
        coordinator: ResearchCoordinator = .shared,
        clearHistoryAction: (@MainActor () async -> ResearchClearResult)? = nil,
        executor: ResearchExecutor? = nil
    ) {
        self.orchestrator = orchestrator
        self.settings = settings
        self.store = store
        self.coordinator = coordinator
        self.executorOverride = executor
        self.clearHistoryAction = clearHistoryAction ?? { [orchestrator] in
            await orchestrator.clearResearchHistory()
        }

        observer = NotificationCenter.default.addObserver(
            forName: .researchRecordsChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let recordID = note.userInfo?[ResearchChangeKey.recordID] as? String
            Task { @MainActor in
                guard let self, self.hasLoaded else { return }
                if let recordID {
                    await self.applyRecordChange(id: recordID)
                } else {
                    await self.refresh()
                }
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
        await reloadStorage()
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
        pendingReadTask?.cancel()
        pendingReadTask = nil
        selectedID = id
        guard let id else {
            selectedRecord = nil
            return
        }
        let loaded = await store.record(id: id)
        guard selectedID == id else { return }
        guard let record = loaded else {
            selectedRecord = nil
            return
        }
        selectedRecord = record
        if record.status.marksReadOnOpen {
            // Give keyboard navigation a short dwell so arrowing through the
            // list does not mark every visited record read.
            scheduleOpenedRead(id: id)
        } else {
            // Active runs keep the LRU access bump; they never clear unread.
            await store.touch(id: id, at: Date())
            guard selectedID == id else { return }
            let touched = await store.record(id: id)
            guard selectedID == id else { return }
            if let touched {
                selectedRecord = touched
            }
        }
        await reloadEntries()
    }

    func retry(id: String) async {
        guard let record = await store.record(id: id) else {
            presentNotice(retryMessage(.unavailable), tone: .error, recordID: id)
            return
        }
        guard record.status != .corrupt, record.loadIssue == nil else {
            presentNotice(retryMessage(.unavailable), tone: .error, recordID: id)
            return
        }
        guard !record.status.isActive else {
            presentNotice(retryMessage(.alreadyActive), tone: .info, recordID: id)
            return
        }

        retryOverlay[id] = ResearchRetryOverlay()
        armRetryTimeout(id: id)
        let executor = executorOverride ?? { [orchestrator, settings] record, progress in
            await orchestrator.executeResearch(record: record, settings: settings, progress: progress)
        }
        let outcome = await coordinator.schedule(recordID: id, notify: false, trigger: .manual, executor: executor)
        switch outcome {
        case .accepted:
            break
        case .alreadyActive:
            retryOverlay[id] = nil
            presentNotice(retryMessage(.alreadyActive), tone: .info, recordID: id)
        case .unavailable:
            retryOverlay[id] = nil
            presentNotice(retryMessage(.unavailable), tone: .error, recordID: id)
        case .admissionDenied:
            retryOverlay[id] = nil
            presentNotice(retryMessage(.admissionDenied), tone: .error, recordID: id)
        case .queueFull:
            retryOverlay[id] = nil
            presentNotice(retryMessage(.queueFull), tone: .error, recordID: id)
        case .persistenceFailed:
            retryOverlay[id] = nil
            presentNotice(retryMessage(.persistenceFailed), tone: .error, recordID: id)
        }
    }

    func cancel(id: String) async {
        coordinator.cancel(recordID: id)
    }

    func delete(id: String) async {
        do {
            try await store.delete(id: id)
        } catch {
            errorMessage = L10n.string("research.error.delete", language: settings.appLanguage)
            return
        }
        retryTimeouts[id]?.cancel()
        retryTimeouts[id] = nil
        retryOverlay[id] = nil
        if selectedID == id {
            pendingReadTask?.cancel()
            pendingReadTask = nil
            selectedID = nil
            selectedRecord = nil
        }
        await refresh()
        await reloadStorage()
    }

    func togglePin(id: String) async {
        guard var record = await store.record(id: id), record.status != .corrupt else { return }
        record.isPinned.toggle()
        do {
            try await store.save(record)
            if let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index] = ResearchIndexEntry(record: record, issue: entries[index].issue)
            }
            if selectedID == id { selectedRecord = record }
            postRecordChange(id: id)
        } catch {
            presentNotice(L10n.string("research.error.write", language: settings.appLanguage), tone: .error, recordID: id)
        }
    }

    func markRead(id: String, read: Bool = true) async {
        if selectedID == id {
            pendingReadTask?.cancel()
            pendingReadTask = nil
        }
        guard var record = await store.record(id: id), record.status != .corrupt else { return }
        guard record.isRead != read else { return }
        record.isRead = read
        do {
            try await store.save(record)
            if let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index].isRead = read
            }
            if selectedID == id, var current = selectedRecord, current.id == id {
                current.isRead = read
                selectedRecord = current
            }
            orchestrator.researchSummary = summary
            postRecordChange(id: id)
        } catch {
            presentNotice(L10n.string("research.error.write", language: settings.appLanguage), tone: .error, recordID: id)
        }
    }

    func clearHistory() async {
        let result = await clearHistoryAction()
        if !result.isComplete {
            errorMessage = L10n.string("research.error.delete", language: settings.appLanguage)
        }
        for task in retryTimeouts.values { task.cancel() }
        retryTimeouts.removeAll()
        retryOverlay.removeAll()
        pendingReadTask?.cancel()
        pendingReadTask = nil
        selectedID = nil
        selectedRecord = nil
        await refresh()
        await reloadStorage()
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
            let presentation = ReportPresentation(
                report: report,
                isLegacy: record.reportVersion == 0
            )
            if presentation.isLegacy {
                lines += [L10n.string("research.timeline.legacy", language: language), ""]
            }
            for item in presentation.nodes {
                let date = item.node.date.isEmpty ? "" : "\(item.node.date) "
                let ids = item.node.evidenceIDs.isEmpty
                    ? ""
                    : " [\(item.node.evidenceIDs.joined(separator: ", "))]"
                let state: String
                if presentation.isLegacy || item.state == .verified {
                    state = ""
                } else if item.state == .citedUnverified {
                    state = "（\(L10n.string("research.node.unverified", language: language))）"
                } else {
                    state = "（\(L10n.string("research.node.unsourced", language: language))）"
                }
                lines.append("- \(date)\(item.node.title)：\(item.node.detail)\(ids)\(state)")
            }
            lines.append("")
        }
        if let verification = report.verification, !report.evidence.isEmpty {
            lines += [
                "## \(L10n.string("research.section.verification", language: language))",
                "",
                L10n.string("research.strength", language: language, verification.strength),
                L10n.string("research.independentSources", language: language, verification.independentSources),
                "",
            ]
            if !verification.claims.isEmpty {
                for claim in verification.claims {
                    let status = claim.status.map {
                        L10n.string("research.stance.\($0.rawValue)", language: language)
                    } ?? L10n.string("research.node.unverified", language: language)
                    let ids = claim.evidenceIDs.isEmpty
                        ? ""
                        : " [\(claim.evidenceIDs.joined(separator: ", "))]"
                    lines.append("- [\(status)] \(claim.claim)\(ids)")
                    if !claim.note.isEmpty {
                        lines.append("  \(claim.note)")
                    }
                }
                lines.append("")
            }
            if !verification.conflicts.isEmpty {
                lines += ["### \(L10n.string("research.conflicts", language: language))", ""]
                lines += verification.conflicts.map { "- \($0)" }
                lines.append("")
            }
            if !verification.missing.isEmpty {
                lines += ["### \(L10n.string("research.missing", language: language))", ""]
                lines += verification.missing.map { "- \($0)" }
                lines.append("")
            }
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

    // MARK: - Status propagation

    /// One record changed. The store index is an in-memory projection, so this
    /// skips the directory scan that `storageFootprint` performs.
    private func applyRecordChange(id: String) async {
        retryTimeouts[id]?.cancel()
        retryTimeouts[id] = nil
        retryOverlay[id] = nil
        entries = await store.index()
        orchestrator.researchSummary = summary
        if selectedID == id {
            selectedRecord = await store.record(id: id)
        }
        if !entries.contains(where: { $0.id == id }) {
            await refresh()
        }
    }

    /// Fallback for a lost notification: only active records are polled, and
    /// the loop exits as soon as the record reaches a terminal state.
    func poll(id: String) async {
        // Terminal records do not need a poll: the task would only add one
        // redundant file read right after `select`.
        guard let presented = selectedRecord.map({ presentedRecord($0) }),
              presented.id == id,
              presented.status.isActive else { return }
        while !Task.isCancelled {
            guard let record = await store.record(id: id) else { return }
            // A retry overlay precedes the queued write. The old terminal
            // record is not evidence that this new attempt has finished.
            if !record.status.isActive, retryOverlay[id] != nil {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            if selectedID == id, selectedRecord != record {
                selectedRecord = record
            }
            if let index = entries.firstIndex(where: { $0.id == id }) {
                let updated = ResearchIndexEntry(record: record, issue: entries[index].issue)
                if entries[index] != updated { entries[index] = updated }
            }
            if !record.status.isActive {
                retryOverlay[id] = nil
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    func presentedRecord(_ record: ResearchRecord) -> ResearchRecord {
        guard let overlay = retryOverlay[record.id] else { return record }
        var presented = record
        presented.status = overlay.status
        presented.run.phase = overlay.phase
        presented.run.lastError = nil
        presented.run.startedAt = nil
        presented.run.finishedAt = nil
        return presented
    }

    func presentedStatus(for id: String) -> ResearchStatus? {
        retryOverlay[id]?.status
    }

    func notice(for id: String) -> ResearchActionNotice? {
        guard actionNotice?.recordID == id else { return nil }
        return actionNotice
    }

    // MARK: - Opened-read state

    private func scheduleOpenedRead(id: String) {
        pendingReadTask?.cancel()
        pendingReadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self, self.selectedID == id else { return }
            await self.markOpenedRead(id: id)
        }
    }

    private func markOpenedRead(id: String) async {
        guard settings.researchMarkReadOnOpen else {
            // The switch only disables the read flag; the LRU access bump is
            // still useful and stays separate.
            await store.touch(id: id, at: Date())
            return
        }
        guard let record = await store.record(id: id),
              !Task.isCancelled,
              selectedID == id,
              record.status.marksReadOnOpen,
              record.loadIssue == nil else { return }

        if record.isRead {
            if case .updated = await store.markReadOnOpen(id: id, at: Date()) {
                postRecordChange(id: id)
            }
            return
        }

        let previousEntries = entries
        let previousSelected = selectedRecord
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].isRead = true
        }
        if selectedID == id, var current = selectedRecord, current.id == id {
            current.isRead = true
            selectedRecord = current
        }
        orchestrator.researchSummary = summary

        switch await store.markReadOnOpen(id: id, at: Date()) {
        case .updated:
            postRecordChange(id: id)
        case .unchanged:
            break
        case .failed:
            entries = previousEntries
            if selectedID == id { selectedRecord = previousSelected }
            orchestrator.researchSummary = summary
            presentNotice(L10n.string("research.error.read", language: settings.appLanguage), tone: .error, recordID: id)
        }
    }

    // MARK: - Feedback

    private func postRecordChange(id: String) {
        NotificationCenter.default.post(
            name: .researchRecordsChanged,
            object: nil,
            userInfo: [ResearchChangeKey.recordID: id]
        )
    }

    private enum RetryFailure {
        case alreadyActive, unavailable, admissionDenied, queueFull, persistenceFailed
    }

    private func retryMessage(_ failure: RetryFailure) -> String {
        let key: String
        switch failure {
        case .alreadyActive: key = "research.retry.alreadyActive"
        case .unavailable: key = "research.retry.unavailable"
        case .admissionDenied: key = "research.retry.admissionDenied"
        case .queueFull: key = "research.retry.queueFull"
        case .persistenceFailed: key = "research.retry.persistenceFailed"
        }
        return L10n.string(key, language: settings.appLanguage)
    }

    private func presentNotice(_ message: String, tone: ResearchActionNotice.Tone, recordID: String) {
        let notice = ResearchActionNotice(message: message, tone: tone, recordID: recordID)
        actionNotice = notice
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self, self.actionNotice?.id == notice.id else { return }
            self.actionNotice = nil
        }
    }

    /// Clears a retry overlay if the store never acknowledges it. A store that
    /// already reached `.queued` is accepted; anything still terminal is a
    /// silent no-start and must be reported.
    private func armRetryTimeout(id: String) {
        retryTimeouts[id]?.cancel()
        retryTimeouts[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, self.retryOverlay[id] != nil else { return }
            await self.applyRecordChange(id: id)
            if let record = await self.store.record(id: id), !record.status.isActive {
                self.presentNotice(L10n.string("research.retry.noStart", language: self.settings.appLanguage), tone: .error, recordID: id)
            }
        }
    }

    private func reloadEntries() async {
        entries = await store.index()
        orchestrator.researchSummary = summary
    }

    private func reloadStorage() async {
        storageBytes = await store.storageFootprint()
    }
}
