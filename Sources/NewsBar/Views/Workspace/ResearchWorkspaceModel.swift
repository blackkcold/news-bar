import Foundation
import Observation

// MARK: - Filters and presentation types

enum WorkspaceFilter: String, CaseIterable, Identifiable, Sendable {
    case all, following, updated, review, archived

    var id: String { rawValue }
    var titleKey: String { "workspace.sidebar.\(rawValue)" }

    var symbol: String {
        switch self {
        case .all: return "square.stack.3d.up"
        case .following: return "pin"
        case .updated: return "arrow.triangle.2.circlepath"
        case .review: return "exclamationmark.magnifyingglass"
        case .archived: return "archivebox"
        }
    }

    func matches(_ subject: WorkspaceSubject) -> Bool {
        switch self {
        case .all: return !subject.isArchived
        case .following: return subject.isFollowed && !subject.isArchived
        case .updated: return subject.updateState == .hasUpdates && !subject.isArchived
        case .review: return subject.updateState == .needsReview && !subject.isArchived
        case .archived: return subject.isArchived
        }
    }
}

enum WorkspaceSort: String, CaseIterable, Identifiable, Sendable {
    case activity, created, title

    var id: String { rawValue }
    var titleKey: String { "workspace.sort.\(rawValue)" }
}

enum WorkspaceSegment: String, CaseIterable, Identifiable, Sendable {
    case overview, timeline, evidence, research

    var id: String { rawValue }
    var titleKey: String { "workspace.detail.\(rawValue)" }

    var symbol: String {
        switch self {
        case .overview: return "rectangle.grid.1x2"
        case .timeline: return "clock.arrow.circlepath"
        case .evidence: return "quote.bubble"
        case .research: return "doc.text.magnifyingglass"
        }
    }
}

struct WorkspaceSegmentRequest: Equatable, Sendable {
    let id: UUID
    let segment: WorkspaceSegment

    init(segment: WorkspaceSegment) {
        self.id = UUID()
        self.segment = segment
    }
}

enum WorkspaceUpdateCheckAvailability: Equatable, Sendable {
    case ready
    case noSources
    case pendingChecker
}

enum WorkspacePrimaryAction: Equatable, Sendable {
    case none
    case start
    case active
    case update
    case view
}

enum WorkspaceNoticeAction: Equatable, Sendable {
    case configureAI
    case configureRSS
    case undoArchive(String)
    case openSubject(String)
}

struct WorkspaceActionNotice: Identifiable, Equatable, Sendable {
    enum Tone: Equatable, Sendable { case info, error }

    let id = UUID()
    let message: String
    let tone: Tone
    let subjectID: String?
    var action: WorkspaceNoticeAction? = nil
}

/// A search hit that must be located inside the evidence pane. It carries the
/// canonical URL and the stored snippet/quote so the pane matches the real row
/// instead of arbitrary evidence. `id` is a nonce for repeated searches.
struct WorkspaceEvidenceFocus: Identifiable, Equatable, Sendable {
    let id: UUID
    let resultID: String
    let canonicalURL: String
    let quoteHint: String
    let title: String

    init(
        id: UUID = UUID(),
        resultID: String,
        canonicalURL: String,
        quoteHint: String,
        title: String
    ) {
        self.id = id
        self.resultID = resultID
        self.canonicalURL = canonicalURL
        self.quoteHint = quoteHint
        self.title = title
    }
}

// MARK: - Model

@MainActor
@Observable
final class ResearchWorkspaceModel {
    private static let selectionKey = "researchWorkspace.selectedSubjectID"

    private let orchestrator: NewsOrchestrator
    private let settings: AppSettings
    private let store: any WorkspacePersisting
    private let researchStore: any ResearchPersisting
    private let eventStore: any NewsEventPersisting
    private let coordinator: ResearchCoordinator
    private let launcher: WorkspaceResearchLauncher
    private let searchService: WorkspaceSearchService
    private let archiveStore = AISearchArchiveStore()
    private let reconciler = WorkspaceReconciler()
    private let detailBuilder = WorkspaceDetailBuilder()
    /// Stage 4 injects the real RSS checker here. Nil is a visible "pending"
    /// state, never a fake successful check.
    private let updateChecker: (any WorkspaceUpdateChecking)?
    private let eventController: NewsEventController?
    /// Session-only tab/version/depth/scroll memory keyed by canonical subject.
    @ObservationIgnored let presentation = WorkspacePresentationStore()

    // Observable state
    var subjects: [WorkspaceSubject] = []
    var selectedSubjectID: String?
    var detail: WorkspaceDetail?
    var filter: WorkspaceFilter = .all
    var sort: WorkspaceSort = .activity
    var searchText = ""
    var searchResults: [WorkspaceSearchResult] = []
    var webResults: [SearchHit] = []
    var isSearchingWeb = false
    var isLoading = false
    var isLoadingDetail = false
    var isCheckingUpdates = false
    var isStartingResearch = false
    var isRefreshing = false
    var errorMessage: String?
    var actionNotice: WorkspaceActionNotice?
    var bootstrap: WorkspaceBootstrap?
    var lastDataRefreshAt: Date?
    var activeSubjectIDs: Set<String> = []
    var reusePreview: WorkspaceReusePreview?
    var archiveReplay: AISearchArchiveEntry?
    var segmentRequest: WorkspaceSegmentRequest?
    var evidenceFocus: WorkspaceEvidenceFocus?
    /// Last check's coverage/budget, shown until the next check. It is not
    /// persisted: the durable subject keeps the outcome and checked time.
    var lastCheckCoverage: WorkspaceCheckCoverage?
    var lastCheckCoverageSubjectID: String?
    /// Subject whose archive confirmation is open; owned by the window so the
    /// keyboard shortcut and the overflow menu ask the same question.
    var archiveConfirmationSubjectID: String?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var webTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var selectionRevision = 0
    @ObservationIgnored private var searchRevision = 0
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var isRefreshingStores = false

    init(
        orchestrator: NewsOrchestrator,
        settings: AppSettings,
        store: any WorkspacePersisting = WorkspaceSubjectStore.shared,
        coordinator: ResearchCoordinator? = nil,
        eventController: NewsEventController? = nil,
        updateChecker: (any WorkspaceUpdateChecking)? = nil,
        launcher: WorkspaceResearchLauncher? = nil,
        search: WorkspaceSearchService? = nil,
        researchStore: any ResearchPersisting = ResearchStore.shared,
        eventStore: any NewsEventPersisting = NewsEventStore.shared
    ) {
        self.orchestrator = orchestrator
        self.settings = settings
        self.store = store
        self.researchStore = researchStore
        self.eventStore = eventStore
        let resolvedCoordinator = coordinator ?? .shared
        self.coordinator = resolvedCoordinator
        self.eventController = eventController
        self.updateChecker = updateChecker
        self.searchService = search ?? WorkspaceSearchService(
            store: store,
            researchStore: researchStore,
            eventStore: eventStore
        )
        self.launcher = launcher ?? WorkspaceResearchLauncher(
            settings: settings,
            store: store,
            researchStore: researchStore,
            eventStore: eventStore,
            coordinator: resolvedCoordinator,
            executor: WorkspaceResearchLauncher.productionExecutor(
                orchestrator: orchestrator,
                settings: settings
            )
        )
        installObservers()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        refreshTask?.cancel()
        searchTask?.cancel()
        webTask?.cancel()
        noticeTask?.cancel()
    }

    // MARK: - Derived state

    var visibleSubjects: [WorkspaceSubject] {
        let filtered = subjects.filter { filter.matches($0) }
        switch sort {
        case .activity:
            return filtered.sorted { lhs, rhs in
                if lhs.lastActivityAt != rhs.lastActivityAt {
                    return lhs.lastActivityAt > rhs.lastActivityAt
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        case .created:
            return filtered.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        case .title:
            return filtered.sorted { lhs, rhs in
                let order = lhs.title.localizedStandardCompare(rhs.title)
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.id < rhs.id
            }
        }
    }

    func count(for filter: WorkspaceFilter) -> Int {
        subjects.filter { filter.matches($0) }.count
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isReadOnly: Bool { bootstrap?.readOnly == true }

    var readOnlyMessage: String? {
        guard let bootstrap else { return nil }
        guard bootstrap.readOnly else { return nil }
        switch bootstrap.issue {
        case .unsupportedVersion:
            return L10n.string("workspace.readOnly.unsupported", language: settings.appLanguage)
        case .ioUnavailable:
            return L10n.string("workspace.readOnly.io", language: settings.appLanguage)
        case .corruptFile:
            return L10n.string("workspace.readOnly.corrupt", language: settings.appLanguage)
        case nil:
            return L10n.string("workspace.readOnly.generic", language: settings.appLanguage)
        }
    }

    var updateCheckAvailability: WorkspaceUpdateCheckAvailability {
        if activeRSSSources.isEmpty { return .noSources }
        if updateChecker == nil { return .pendingChecker }
        return .ready
    }

    /// Only RSS feeds the user has enabled in Settings. `settings.rssSources`
    /// also contains disabled rows; those must never be fetched.
    var activeRSSSources: [NewsSource] {
        settings.activeSources.filter { source in
            if case .rss = source { return true }
            return false
        }
    }

    var canCheckUpdates: Bool {
        selectedSubjectID != nil
            && updateCheckAvailability == .ready
            && !isCheckingUpdates
            && !isReadOnly
    }

    var checkUpdatesHelp: String {
        switch updateCheckAvailability {
        case .ready: return L10n.string("workspace.action.checkUpdates", language: settings.appLanguage)
        case .noSources: return L10n.string("workspace.check.rssOnly", language: settings.appLanguage)
        case .pendingChecker:
            return L10n.string("workspace.check.pending", language: settings.appLanguage)
        }
    }

    var primaryAction: WorkspacePrimaryAction {
        guard let detail else { return .none }
        guard let record = detail.research else { return .start }
        if record.status.isActive { return .active }
        guard record.report != nil else { return .start }
        if detail.subject.updateState == .needsReview
            || detail.subject.updateState == .hasUpdates {
            return .update
        }
        return .view
    }

    var hasUnreadUpdates: Bool {
        detail?.subject.updateState == .hasUpdates
            || detail?.subject.updateState == .needsReview
    }

    var canStartResearch: Bool {
        !isStartingResearch && !isReadOnly
    }

    var selectedSubject: WorkspaceSubject? {
        guard let selectedSubjectID else { return nil }
        return subjects.first { $0.id == selectedSubjectID }
    }

    var readerURL: URL? {
        guard let detail else { return nil }
        let candidates = (detail.research?.report?.evidence ?? []).compactMap(\.url)
            + (detail.event?.evidence.map(\.url) ?? [])
            + [detail.research?.seed.url, detail.subject.seedURL].compactMap { $0 }
        for candidate in candidates {
            if let url = ReaderNavigationPolicy.allowedURL(candidate) { return url }
        }
        return nil
    }

    var activeResearchIsCancellable: Bool {
        guard let record = detail?.research else { return false }
        return record.status.isActive && !isReadOnly
    }

    var defaultDepth: ResearchDepth { settings.researchDepth }

    func depth(for subjectID: String) -> ResearchDepth {
        presentation.depth(for: subjectID) ?? settings.researchDepth
    }

    var reuseHint: String? {
        guard let preview = reusePreview, let detail,
              detail.research?.id == preview.recordID else { return nil }
        return L10n.string(
            "workspace.research.reuseHint",
            language: settings.appLanguage,
            relativeAge(preview.age)
        )
    }

    // MARK: - Loading

    func load() async {
        guard !isLoading, !hasLoaded else { return }
        isLoading = true
        defer { isLoading = false }

        bootstrap = await store.bootstrap()
        await searchService.reloadIndex()
        await refreshFromStores(reconcile: true, initial: true)
        hasLoaded = true

        let remembered = UserDefaults.standard.string(forKey: Self.selectionKey)
        var target = visibleSubjects.first(where: { $0.id == remembered })
            ?? visibleSubjects.first
        if let remembered,
           target?.id != remembered,
           let redirected = await store.subject(id: remembered),
           let canonical = visibleSubjects.first(where: { $0.id == redirected.id }) {
            presentation.migrate(from: remembered, to: canonical.id)
            target = canonical
        }
        if let target {
            await select(target.id)
        }
    }

    /// Full reconcile from the authoritative stores. `saveAll` runs only when
    /// the reconciler changed something, so a store notification cannot feed
    /// itself through this path.
    func refresh() async {
        await refreshFromStores(reconcile: true)
    }

    private func refreshFromStores(
        reconcile: Bool,
        initial: Bool = false,
        reloadSearchIndex: Bool = true
    ) async {
        guard !isRefreshingStores else { return }
        isRefreshingStores = true
        defer { isRefreshingStores = false }

        if bootstrap == nil {
            bootstrap = await store.bootstrap()
        }
        let research = await researchStore.index()
        let events = (try? await eventStore.events()) ?? []
        let existing = await store.subjects()

        if reconcile, !isReadOnly {
            let result = reconciler.reconcile(
                research: research,
                events: events,
                existing: existing,
                now: Date()
            )
            let changed = !result.changedIDs.isEmpty
                || !result.createdIDs.isEmpty
                || result.subjects.count != existing.count
            if changed {
                do {
                    try await store.saveAll(result.subjects)
                    bootstrap = await store.bootstrap()
                } catch {
                    errorMessage = L10n.string("workspace.error.save", language: settings.appLanguage)
                }
            }
        }

        subjects = await store.subjects()
        lastDataRefreshAt = Date()

        let activeRecordIDs = Set(research.filter { $0.status.isActive }.map(\.id))
        activeSubjectIDs = Set(
            subjects
                .filter { subject in
                    !Set(subject.researchRecordIDs).isDisjoint(with: activeRecordIDs)
                }
                .map(\.id)
        )

        if reloadSearchIndex {
            await searchService.reloadIndex()
        }

        guard !initial else { return }

        if let selectedSubjectID,
           !subjects.contains(where: { $0.id == selectedSubjectID }) {
            // The domain merge retired the selected ID. Follow the redirect and
            // keep the same detail/record before falling back to the first row.
            if let redirected = await store.subject(id: selectedSubjectID),
               subjects.contains(where: { $0.id == redirected.id }) {
                presentation.migrate(from: selectedSubjectID, to: redirected.id)
                await select(redirected.id, preferringRecordID: detail?.research?.id)
            } else {
                await select(visibleSubjects.first?.id)
            }
        } else if selectedSubjectID != nil {
            await reloadSelectedDetail()
        } else if let first = visibleSubjects.first {
            await select(first.id)
        }
    }

    private func reloadSelectedDetail() async {
        guard let selectedSubjectID,
              let subject = subjects.first(where: { $0.id == selectedSubjectID }) else {
            detail = nil
            return
        }
        await loadDetail(for: subject, preferringRecordID: detail?.research?.id)
    }

    func select(_ id: String?) async {
        await select(id, preferringRecordID: nil)
    }

    func select(_ id: String?, preferringRecordID recordID: String?) async {
        selectionRevision += 1
        guard let id else {
            selectedSubjectID = nil
            detail = nil
            reusePreview = nil
            UserDefaults.standard.removeObject(forKey: Self.selectionKey)
            return
        }
        guard let subject = await resolvedSubject(id: id) else {
            selectedSubjectID = nil
            detail = nil
            return
        }
        // `store.subject(id:)` follows retired IDs. Keep one canonical key for
        // presentation/selection and carry the old subject's state across.
        if id != subject.id {
            presentation.migrate(from: id, to: subject.id)
        }
        selectedSubjectID = subject.id
        UserDefaults.standard.set(subject.id, forKey: Self.selectionKey)
        await loadDetail(for: subject, preferringRecordID: recordID)
    }

    private func loadDetail(for subject: WorkspaceSubject, preferringRecordID: String?) async {
        let revision = selectionRevision
        isLoadingDetail = true
        defer {
            if revision == selectionRevision { isLoadingDetail = false }
        }

        let events = (try? await eventStore.events()) ?? []
        let event = events
            .filter { subject.eventIDs.contains($0.id) }
            .max { $0.lastEvidenceAt < $1.lastEvidenceAt }

        var records: [ResearchRecord] = []
        for id in subject.researchRecordIDs {
            if let record = await researchStore.record(id: id),
               record.loadIssue == nil,
               record.status != .corrupt {
                records.append(record.normalizedForRead())
            }
        }
        let record = records.first(where: { $0.id == preferringRecordID })
            ?? records.max { $0.updatedAt < $1.updatedAt }
        let versions: [WorkspaceReportVersion]
        if let record {
            try? await store.ensureBaselineVersion(
                record: record,
                subjectID: subject.id,
                at: record.updatedAt
            )
            versions = await store.versions(recordID: record.id)
        } else {
            versions = []
        }
        let updates = await store.updates(subjectID: subject.id)

        guard revision == selectionRevision, selectedSubjectID == subject.id else { return }

        detail = detailBuilder.build(
            subject: subject,
            event: event,
            research: record,
            versions: versions,
            updates: updates
        )

        if let record {
            reusePreview = await launcher.reusePreview(
                subjectID: subject.id,
                depth: depth(for: subject.id)
            )
            guard revision == selectionRevision, selectedSubjectID == subject.id else { return }
            if settings.researchMarkReadOnOpen, record.status.marksReadOnOpen {
                _ = await researchStore.markReadOnOpen(id: record.id, at: Date())
            }
        } else {
            reusePreview = nil
        }
    }

    // MARK: - Search (local first, web only on explicit action)

    func scheduleSearch() {
        searchTask?.cancel()
        searchRevision += 1
        let revision = searchRevision
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            isSearchingWeb = false
            webResults = []
            return
        }
        searchTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            let response = await self.searchService.searchLocal(query, scopes: .all, limit: 30)
            guard !Task.isCancelled,
                  self.searchRevision == revision,
                  self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query
            else { return }
            self.searchResults = response.results
        }
    }

    func searchAll() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        searchRevision += 1
        let revision = searchRevision
        let response = await searchService.searchLocal(query, scopes: .all, limit: 30)
        guard searchRevision == revision,
              searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query
        else { return }
        searchResults = response.results
    }

    func searchWeb() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        webTask?.cancel()
        isSearchingWeb = true
        webResults = []
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let batch = try await self.searchService.searchWeb(
                    query,
                    language: self.settings.appLanguage,
                    settings: self.settings
                )
                guard !Task.isCancelled,
                      self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query
                else { return }
                self.webResults = batch.hits
                self.isSearchingWeb = false
            } catch is CancellationError {
                self.isSearchingWeb = false
            } catch {
                guard !Task.isCancelled else { return }
                self.isSearchingWeb = false
                self.errorMessage = error.localizedDescription
                self.presentNotice(
                    L10n.string("workspace.search.webFailed", language: self.settings.appLanguage),
                    tone: .error
                )
            }
        }
        webTask = task
        await task.value
    }

    func cancelWebSearch() {
        webTask?.cancel()
        isSearchingWeb = false
    }

    func openSearchResult(_ result: WorkspaceSearchResult) async {
        switch result {
        case let .subject(id, _, _, _):
            await select(id)
        case let .report(recordID, subjectID, _, _, _):
            await openRecord(id: recordID, fallbackSubjectID: subjectID)
        case let .evidence(resultID, subjectID, title, snippet, url):
            guard !subjectID.isEmpty else {
                presentNotice(L10n.string(
                    "workspace.search.evidenceSubjectMissing",
                    language: settings.appLanguage
                ), tone: .info)
                return
            }
            await select(subjectID)
            guard let detail else {
                presentNotice(L10n.string(
                    "workspace.search.evidenceSubjectMissing",
                    language: settings.appLanguage
                ), tone: .info)
                return
            }
            evidenceFocus = WorkspaceEvidenceFocus(
                resultID: resultID,
                canonicalURL: ContentIdentity.canonicalURL(url),
                quoteHint: snippet,
                title: title
            )
            presentation.setSegment(.evidence, for: detail.subject.id)
            requestSegment(.evidence)
        case let .answer(id, _, _, _):
            await replayAnswer(id: id)
        }
    }

    func saveWebHit(_ hit: SearchHit, to subjectID: String?) async {
        let targetID: String
        if let subjectID {
            targetID = subjectID
        } else {
            guard let created = await createSubject(
                title: hit.title,
                aliases: [],
                seedURL: hit.url
            ) else { return }
            targetID = created
        }
        let saved = await searchService.saveWebHitAsCandidate(hit, subjectID: targetID)
        if saved == nil {
            presentNotice(
                L10n.string("workspace.search.leadFailed", language: settings.appLanguage),
                tone: .error
            )
            return
        }
        presentNotice(
            L10n.string("workspace.search.leadSaved", language: settings.appLanguage),
            tone: .info,
            subjectID: targetID
        )
        if selectedSubjectID == targetID {
            await reloadSelectedDetail()
        }
        scheduleDataRefresh()
    }

    func replayAnswer(id: String) async {
        let raw = id.hasPrefix("answer:") ? String(id.dropFirst("answer:".count)) : id
        await archiveStore.prepare()
        guard let entry = await archiveStore.all().first(where: { $0.id.uuidString == raw }) else {
            presentNotice(
                L10n.string("workspace.search.answerMissing", language: settings.appLanguage),
                tone: .error
            )
            return
        }
        archiveReplay = entry
    }

    // MARK: - Subject actions

    @discardableResult
    func createSubject(title: String, aliases: [String], seedURL: String?) async -> String? {
        guard !isReadOnly else {
            presentNotice(readOnlyMessage ?? L10n.string("workspace.error.readOnly", language: settings.appLanguage), tone: .error)
            return nil
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            presentNotice(L10n.string("workspace.new.titleRequired", language: settings.appLanguage), tone: .error)
            return nil
        }
        var normalizedSeed: String?
        if let seedURL, !seedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let allowed = ReaderNavigationPolicy.allowedURL(
                seedURL.trimmingCharacters(in: .whitespacesAndNewlines)
            ) else {
                presentNotice(L10n.string("workspace.new.urlInvalid", language: settings.appLanguage), tone: .error)
                return nil
            }
            normalizedSeed = allowed.absoluteString
        }

        do {
            var subject = try await store.createSubject(
                title: trimmed,
                aliases: aliases,
                isFollowed: true,
                now: Date()
            )
            if let normalizedSeed {
                subject = try await store.updateSubject(id: subject.id) { latest in
                    latest.seedURL = normalizedSeed
                    latest.markUserStateChanged(at: Date())
                }
            }
            subjects = await store.subjects()
            await select(subject.id)
            presentNotice(L10n.string("workspace.new.created", language: settings.appLanguage), tone: .info, subjectID: subject.id)
            Task { @MainActor [weak self] in
                await self?.searchService.reloadIndex()
            }
            return subject.id
        } catch {
            presentNotice(
                L10n.string("workspace.error.save", language: settings.appLanguage),
                tone: .error
            )
            return nil
        }
    }

    private func resolvedSubject(id: String) async -> WorkspaceSubject? {
        if let subject = subjects.first(where: { $0.id == id }) { return subject }
        return await store.subject(id: id)
    }

    func toggleFollow(id: String) async {
        guard !isReadOnly else { return }
        do {
            let subject = try await store.updateSubject(id: id) { latest in
                latest.isFollowed.toggle()
                latest.markUserStateChanged(at: Date())
            }
            subjects = await store.subjects()
            if selectedSubjectID == id, var detail {
                detail.subject = subject
                self.detail = detail
            }
        } catch {
            presentNotice(L10n.string("workspace.error.save", language: settings.appLanguage), tone: .error)
        }
    }

    func setArchived(id: String, archived: Bool) async {
        guard !isReadOnly else { return }
        do {
            let subject = try await store.updateSubject(id: id) { latest in
                latest.markArchived(archived, at: Date())
                latest.markUserStateChanged(at: Date())
            }
            subjects = await store.subjects()
            if archived, selectedSubjectID == id, !filter.matches(subject) {
                await select(visibleSubjects.first?.id)
            } else if selectedSubjectID == id, var detail {
                detail.subject = subject
                self.detail = detail
            }
            if archived {
                presentNotice(
                    L10n.string("workspace.action.archived", language: settings.appLanguage),
                    tone: .info,
                    subjectID: id,
                    action: .undoArchive(id)
                )
            }
        } catch {
            presentNotice(L10n.string("workspace.error.save", language: settings.appLanguage), tone: .error)
        }
    }

    func checkUpdates(id: String) async {
        guard let subject = await resolvedSubject(id: id) else { return }
        guard !isReadOnly else { return }
        let sources = activeRSSSources
        if sources.isEmpty {
            await markCheckOutcome(.notConfigured, subject: subject)
            presentNotice(
                L10n.string("workspace.check.rssOnly", language: settings.appLanguage),
                tone: .info,
                subjectID: id,
                action: .configureRSS
            )
            return
        }
        guard let updateChecker else {
            presentNotice(
                L10n.string("workspace.check.pending", language: settings.appLanguage),
                tone: .info,
                subjectID: id
            )
            return
        }
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }

        let result = await updateChecker.check(
            subjectID: id,
            sources: sources,
            now: Date()
        )
        lastCheckCoverage = result.coverage
        lastCheckCoverageSubjectID = id

        // The checker persists leads before committing the shared cursor. A
        // different injected checker may not, so this is a safe idempotent
        // fallback, not the primary write.
        let stored = await store.updates(subjectID: id)
        let storedIDs = Set(stored.map(\.id))
        if !result.added.allSatisfy({ storedIDs.contains($0.id) }) {
            try? await store.saveUpdates(result.added, for: id)
        }

        // Only copy the check outcome onto the freshest stored subject so a
        // stale checker snapshot cannot revert `needsReview` back to `current`.
        _ = try? await store.updateSubject(id: id) { latest in
            latest.lastCheckOutcome = result.subject.lastCheckOutcome
            if case .checked = result.outcome {
                latest.lastCheckedAt = result.subject.lastCheckedAt
            }
        }
        subjects = await store.subjects()
        if selectedSubjectID == id {
            await reloadSelectedDetail()
        }
        switch result.outcome {
        case let .checked(added, _):
            presentNotice(
                checkNotice(added: added, coverage: result.coverage),
                tone: .info,
                subjectID: id
            )
        case .notConfigured:
            presentNotice(
                L10n.string("workspace.check.rssOnly", language: settings.appLanguage),
                tone: .info,
                subjectID: id,
                action: .configureRSS
            )
        case let .throttled(until):
            presentNotice(
                throttledNotice(until: until, coverage: result.coverage),
                tone: .info,
                subjectID: id
            )
        case let .failed(message, _):
            presentNotice(
                failedNotice(message: message, coverage: result.coverage),
                tone: .error,
                subjectID: id
            )
        }
    }

    private func checkNotice(
        added: Int,
        coverage: WorkspaceCheckCoverage
    ) -> String {
        let budget = budgetText(coverage)
        let next = coverage.nextEligibleAt.map(timeText) ?? "—"
        let base: String
        if coverage.reusedSharedCheck {
            base = L10n.string(
                "workspace.check.reusedCoverage",
                language: settings.appLanguage,
                coverage.eligibleSourceCount,
                budget,
                next
            )
        } else {
            base = L10n.string(
                "workspace.check.covered",
                language: settings.appLanguage,
                coverage.checkedSourceNames.count,
                coverage.eligibleSourceCount,
                added,
                budget,
                next
            )
        }
        guard coverage.deferredSourceCount > 0 else { return base }
        return base + " " + L10n.string(
            "workspace.check.deferred",
            language: settings.appLanguage,
            coverage.deferredSourceCount
        )
    }

    private func throttledNotice(
        until: Date,
        coverage: WorkspaceCheckCoverage
    ) -> String {
        let retry = coverage.retryAt ?? until
        let budget = budgetText(coverage)
        return L10n.string(
            "workspace.check.throttledCoverage",
            language: settings.appLanguage,
            timeText(retry),
            budget
        )
    }

    private func failedNotice(
        message: String,
        coverage: WorkspaceCheckCoverage
    ) -> String {
        let base = L10n.string(
            "workspace.check.failed",
            language: settings.appLanguage,
            message
        )
        var parts = [base]
        if let retry = coverage.retryAt {
            parts.append(L10n.string(
                "workspace.check.retryAt",
                language: settings.appLanguage,
                timeText(retry)
            ))
        }
        if coverage.addedCount > 0 {
            parts.append(L10n.string(
                "workspace.check.leadsKept",
                language: settings.appLanguage,
                coverage.addedCount
            ))
        }
        return parts.joined(separator: " ")
    }

    private func budgetText(_ coverage: WorkspaceCheckCoverage) -> String {
        guard let used = coverage.budgetUsed, let limit = coverage.budgetLimit else {
            return L10n.string("workspace.check.budgetUnknown", language: settings.appLanguage)
        }
        return L10n.string(
            "workspace.check.budget",
            language: settings.appLanguage,
            used,
            limit
        )
    }

    private func markCheckOutcome(_ outcome: WorkspaceCheckOutcome, subject: WorkspaceSubject) async {
        do {
            _ = try await store.updateSubject(id: subject.id) { latest in
                latest.lastCheckOutcome = outcome
                latest.lastCheckedAt = outcome.checkedAt
            }
            subjects = await store.subjects()
        } catch {
            // The check hint is more important than the persisted marker.
        }
    }

    func startResearch(id: String, forceRefresh: Bool = false, depth: ResearchDepth? = nil) async {
        guard let subject = await resolvedSubject(id: id) else {
            presentNotice(L10n.string("workspace.error.subjectMissing", language: settings.appLanguage), tone: .error)
            return
        }
        guard !isReadOnly else {
            presentNotice(readOnlyMessage ?? L10n.string("workspace.error.readOnly", language: settings.appLanguage), tone: .error)
            return
        }
        guard !isStartingResearch else { return }
        guard settings.usableCachedAPIKey != nil else {
            presentNotice(
                L10n.string("workspace.research.noKey", language: settings.appLanguage),
                tone: .info,
                subjectID: id,
                action: .configureAI
            )
            return
        }
        guard ResearchConsent.presentIfNeeded(settings: settings) else { return }

        let chosenDepth = depth ?? settings.researchDepth
        isStartingResearch = true
        defer { isStartingResearch = false }

        let request = WorkspaceResearchRequest(
            subjectID: subject.id,
            depth: chosenDepth,
            trigger: .manual,
            forceRefresh: forceRefresh
        )
        let action = await launcher.start(request)
        switch action {
        case let .started(recordID):
            presentNotice(
                forceRefresh
                    ? L10n.string("workspace.research.restarted", language: settings.appLanguage)
                    : L10n.string("workspace.research.started", language: settings.appLanguage),
                tone: .info,
                subjectID: subject.id
            )
            await select(subject.id, preferringRecordID: recordID)
            requestSegment(.research)
        case let .focusedRunning(recordID):
            presentNotice(
                L10n.string("workspace.research.alreadyRunning", language: settings.appLanguage),
                tone: .info,
                subjectID: subject.id
            )
            await select(subject.id, preferringRecordID: recordID)
            requestSegment(.research)
        case let .reused(recordID, _):
            presentNotice(
                L10n.string("workspace.research.reused", language: settings.appLanguage),
                tone: .info,
                subjectID: subject.id
            )
            await select(subject.id, preferringRecordID: recordID)
            requestSegment(.research)
        case let .failed(failure):
            presentNotice(
                failureMessage(failure),
                tone: .error,
                subjectID: subject.id,
                action: failure == .noAIKey ? .configureAI : nil
            )
        }
        scheduleDataRefresh()
    }

    func cancelActiveResearch() async {
        guard let record = detail?.research, record.status.isActive else { return }
        coordinator.cancel(recordID: record.id)
        presentNotice(
            L10n.string("workspace.research.cancelRequested", language: settings.appLanguage),
            tone: .info,
            subjectID: selectedSubjectID
        )
        try? await Task.sleep(for: .milliseconds(500))
        await reloadSelectedDetail()
    }

    func openRecord(id: String, fallbackSubjectID: String? = nil) async {
        if let subject = await store.subject(containingResearchID: id) {
            presentation.resetVersion(for: subject.id)
            await select(subject.id, preferringRecordID: id)
            requestSegment(.research)
            return
        }
        if let fallbackSubjectID, !fallbackSubjectID.isEmpty {
            let canonical = await store.subject(id: fallbackSubjectID)?.id ?? fallbackSubjectID
            presentation.resetVersion(for: canonical)
            await select(canonical, preferringRecordID: id)
            requestSegment(.research)
            return
        }
        await refreshFromStores(reconcile: true)
        if let subject = await store.subject(containingResearchID: id) {
            presentation.resetVersion(for: subject.id)
            await select(subject.id, preferringRecordID: id)
            requestSegment(.research)
        } else {
            presentNotice(L10n.string("workspace.error.recordMissing", language: settings.appLanguage), tone: .error)
        }
    }

    func openEvent(id: String) async {
        if let subject = await store.subject(containingEventID: id) {
            await select(subject.id)
            requestSegment(.timeline)
            return
        }
        await refreshFromStores(reconcile: true)
        if let subject = await store.subject(containingEventID: id) {
            await select(subject.id)
            requestSegment(.timeline)
        } else {
            presentNotice(L10n.string("workspace.error.eventMissing", language: settings.appLanguage), tone: .error)
        }
    }

    /// Legacy notification/entry payloads. A record/event ID is resolved before
    /// opening; an unresolved payload reconciles once instead of showing empty.
    func handleNotification(
        subjectID: String?,
        recordID: String?,
        eventID: String?,
        answerID: String? = nil,
        evidenceHint: WorkspaceEvidenceFocus? = nil
    ) async {
        if let answerID {
            await replayAnswer(id: answerID)
            return
        }
        var resolved: String?
        if let subjectID, let subject = await store.subject(id: subjectID) {
            resolved = subject.id
        }
        if resolved == nil, let recordID {
            resolved = await store.subject(containingResearchID: recordID)?.id
        }
        if resolved == nil, let eventID {
            resolved = await store.subject(containingEventID: eventID)?.id
        }
        if resolved == nil, recordID != nil || eventID != nil {
            await refreshFromStores(reconcile: true)
            if let recordID {
                resolved = await store.subject(containingResearchID: recordID)?.id
            }
            if resolved == nil, let eventID {
                resolved = await store.subject(containingEventID: eventID)?.id
            }
        }
        guard let resolved else {
            presentNotice(L10n.string("workspace.error.notFound", language: settings.appLanguage), tone: .error)
            return
        }
        if recordID != nil {
            presentation.resetVersion(for: resolved)
        }
        await select(resolved, preferringRecordID: recordID)
        if let evidenceHint, let detail {
            evidenceFocus = evidenceHint
            presentation.setSegment(.evidence, for: detail.subject.id)
            requestSegment(.evidence)
        } else if recordID != nil {
            requestSegment(.research)
        } else if eventID != nil {
            requestSegment(.timeline)
        }
        if subjects.isEmpty {
            await refreshFromStores(reconcile: true)
            if !subjects.contains(where: { $0.id == resolved }) {
                await select(resolved, preferringRecordID: recordID)
            }
        }
    }

    func openInReader() {
        guard let url = readerURL else {
            presentNotice(L10n.string("workspace.error.noReaderURL", language: settings.appLanguage), tone: .info)
            return
        }
        NewsNavigationRouter.shared.open(
            url: url.absoluteString,
            title: selectedSubject?.title ?? "",
            surface: "workspace"
        )
    }

    func openEvidenceURL(_ rawURL: String, title: String) {
        guard let url = ReaderNavigationPolicy.allowedURL(rawURL) else {
            presentNotice(
                L10n.string("workspace.error.blockedURL", language: settings.appLanguage),
                tone: .info
            )
            return
        }
        NewsNavigationRouter.shared.open(
            url: url.absoluteString,
            title: title,
            surface: "workspace"
        )
    }

    func requestSegment(_ segment: WorkspaceSegment) {
        segmentRequest = WorkspaceSegmentRequest(segment: segment)
    }

    /// The reuse gate depends on depth, so the footer hint must be recomputed
    /// when the user changes the depth menu.
    func refreshReusePreview(depth: ResearchDepth) async {
        guard let subjectID = selectedSubjectID else {
            reusePreview = nil
            return
        }
        reusePreview = await launcher.reusePreview(
            subjectID: subjectID,
            depth: depth
        )
    }

    func dismissNotice() {
        noticeTask?.cancel()
        actionNotice = nil
    }

    func presentNotice(
        _ message: String,
        tone: WorkspaceActionNotice.Tone,
        subjectID: String? = nil,
        action: WorkspaceNoticeAction? = nil
    ) {
        noticeTask?.cancel()
        let resolvedSubjectID = subjectID ?? selectedSubjectID
        actionNotice = WorkspaceActionNotice(
            message: message,
            tone: tone,
            subjectID: resolvedSubjectID,
            action: action
        )
        let noticeID = actionNotice?.id
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(tone == .error ? 8 : 5))
            guard let self, !Task.isCancelled, self.actionNotice?.id == noticeID else { return }
            self.actionNotice = nil
        }
    }

    func performNoticeAction(_ action: WorkspaceNoticeAction) async {
        switch action {
        case .configureAI:
            NotificationCenter.default.post(name: .openAISettingsRequested, object: nil)
        case .configureRSS:
            NotificationCenter.default.post(name: .openRSSSettingsRequested, object: nil)
        case let .undoArchive(subjectID):
            await setArchived(id: subjectID, archived: false)
            if selectedSubjectID == nil {
                await select(subjectID)
            }
            dismissNotice()
            return
        case let .openSubject(subjectID):
            await select(subjectID)
        }
        dismissNotice()
    }

    // MARK: - Notification plumbing

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: .researchWorkspaceChanged,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let subjectID = note.userInfo?["subjectID"] as? String
                Task { @MainActor [weak self] in
                    await self?.applyWorkspaceChange(subjectID: subjectID)
                }
            }
        )
        observers.append(
            center.addObserver(
                forName: .researchRecordsChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleDataRefresh()
                }
            }
        )
        observers.append(
            center.addObserver(
                forName: .newsEventsChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleDataRefresh()
                }
            }
        )
    }

    private func applyWorkspaceChange(subjectID: String?) async {
        guard hasLoaded else { return }
        subjects = await store.subjects()
        guard let selectedSubjectID else { return }
        if let subjectID, subjectID != selectedSubjectID { return }
        if var detail, let updated = subjects.first(where: { $0.id == selectedSubjectID }) {
            detail.subject = updated
            self.detail = detail
        } else if !subjects.contains(where: { $0.id == selectedSubjectID }) {
            await select(visibleSubjects.first?.id)
        }
    }

    /// One pending task, no polling. Coalesces bursts of record/event writes
    /// into one reconcile and one index refresh.
    private func scheduleDataRefresh() {
        guard hasLoaded else { return }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await self.refreshFromStores(reconcile: true)
        }
    }

    // MARK: - Formatting helpers

    func relativeAge(_ interval: TimeInterval) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(
            for: Date().addingTimeInterval(-max(0, interval)),
            relativeTo: Date()
        )
    }

    func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    func timeText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func failureMessage(_ failure: WorkspaceResearchFailure) -> String {
        switch failure {
        case .subjectMissing:
            return L10n.string("workspace.error.subjectMissing", language: settings.appLanguage)
        case .noAIKey:
            return L10n.string("workspace.research.noKey", language: settings.appLanguage)
        case .alreadyActive:
            return L10n.string("workspace.research.alreadyRunning", language: settings.appLanguage)
        case .unavailable:
            return L10n.string("workspace.research.unavailable", language: settings.appLanguage)
        case .persistenceFailed:
            return L10n.string("workspace.error.save", language: settings.appLanguage)
        }
    }
}
