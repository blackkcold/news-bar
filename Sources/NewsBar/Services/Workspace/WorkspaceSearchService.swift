import Foundation

/// Local-first workspace search. `searchLocal` never constructs or calls a
/// search provider; `searchWeb` is only for an explicit user action and uses
/// the shared `ManualSearchGateway`.
@MainActor
final class WorkspaceSearchService {
    private let store: any WorkspacePersisting
    private let index: WorkspaceSearchIndex
    private let researchStore: any ResearchPersisting
    private let eventStore: any NewsEventPersisting
    private let archiveStore: AISearchArchiveStore
    private let gateway: ManualSearchGateway
    private var subjectsByID: [String: WorkspaceSubject] = [:]
    private var didLoadIndex = false
    /// Monotonic dirty counter. A reload captures it and refuses to publish if
    /// anything changed (especially a history clear) while it was reading.
    private var revision = 0
    private var reloadTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(
        store: any WorkspacePersisting = WorkspaceSubjectStore.shared,
        index: WorkspaceSearchIndex = .shared,
        researchStore: any ResearchPersisting = ResearchStore.shared,
        eventStore: any NewsEventPersisting = NewsEventStore.shared,
        archiveStore: AISearchArchiveStore = AISearchArchiveStore(),
        gateway: ManualSearchGateway = ManualSearchGateway()
    ) {
        self.store = store
        self.index = index
        self.researchStore = researchStore
        self.eventStore = eventStore
        self.archiveStore = archiveStore
        self.gateway = gateway
        observeChanges()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func observeChanges() {
        let names: [Notification.Name] = [
            .researchWorkspaceChanged,
            .researchRecordsChanged,
            .newsEventsChanged,
            .aiSearchArchiveChanged,
        ]
        for name in names {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                // Progress snapshots rewrite a record but do not change the
                // searchable report. Final publication, history removal and
                // workspace membership changes arrive through the workspace
                // store notification and rebuild the index there.
                if notification.name == .researchRecordsChanged,
                   notification.userInfo?[ResearchChangeKey.recordID] is String {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.markDirty()
                }
            }
            observers.append(token)
        }
    }

    /// Invalidates immediately and drops the old subject snapshot so a reader
    /// cannot show pre-clear follow state.
    func markDirty() {
        revision += 1
        didLoadIndex = false
        subjectsByID.removeAll()
    }

    func reloadIndex() async {
        markDirty()
        await reloadIfNeeded()
    }

    private func reloadIfNeeded() async {
        if didLoadIndex { return }
        if let existing = reloadTask {
            await existing.value
            reloadTask = nil
            if didLoadIndex { return }
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performReload()
        }
        reloadTask = task
        await task.value
        reloadTask = nil
    }

    private func performReload() async {
        let expectedRevision = revision
        let expectedGeneration = await index.beginRebuild()

        _ = await store.bootstrap()
        let subjects = await store.subjects()
        let records = await researchStore.records()

        let recordSubjects = Dictionary(
            subjects.flatMap { subject in
                subject.researchRecordIDs.map { ($0, subject.id) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        // Lazy first version for a linked historical report. The store refuses
        // records cleared by a history reset, so this cannot resurrect them.
        for record in records where record.report != nil {
            guard revision == expectedRevision else { return }
            guard let subjectID = recordSubjects[record.id] else { continue }
            try? await store.ensureBaselineVersion(
                record: record,
                subjectID: subjectID,
                at: record.updatedAt
            )
        }

        let events = (try? await eventStore.events()) ?? []
        await archiveStore.prepare()
        let answers = await archiveStore.all()

        guard revision == expectedRevision else { return }
        let committed = await index.rebuild(
            subjects: subjects,
            records: records,
            events: events,
            answers: answers,
            now: Date(),
            generation: expectedGeneration
        )
        guard committed, revision == expectedRevision else { return }
        subjectsByID = Dictionary(
            uniqueKeysWithValues: subjects.map { ($0.id, $0) }
        )
        didLoadIndex = true
    }

    func searchLocal(
        _ text: String,
        scopes: WorkspaceSearchScope,
        limit: Int = 20
    ) async -> WorkspaceSearchResponse {
        if !didLoadIndex {
            await reloadIfNeeded()
        }
        guard didLoadIndex else {
            return WorkspaceSearchResponse(results: [], isLocalOnly: true, truncated: false)
        }
        let response = await index.search(text: text, scopes: scopes, limit: limit)
        let enriched = response.results.map { result -> WorkspaceSearchResult in
            guard case let .subject(id, title, snippet, _) = result else { return result }
            return .subject(
                id: id,
                title: title,
                snippet: snippet,
                isFollowed: subjectsByID[id]?.isFollowed ?? false
            )
        }
        return WorkspaceSearchResponse(
            results: enriched,
            isLocalOnly: true,
            truncated: response.truncated
        )
    }

    /// Explicit `在网页中查找` only. Never called by `searchLocal`.
    func searchWeb(
        _ text: String,
        language: AppLanguage,
        settings: AppSettings
    ) async throws -> SearchBatch {
        let keys = await SearchKeyStore.loadAll()
        return try await gateway.search(
            text: text,
            language: language,
            enabledProviders: settings.enabledSearchProviders,
            keys: keys
        )
    }

    /// Stage 3 hook: an explicit web result can become a review lead for the
    /// current subject. It is stored with `origin: .research` and stays
    /// unverified; it never enters a report's evidence array.
    @discardableResult
    func saveWebHitAsCandidate(
        _ hit: SearchHit,
        subjectID: String,
        now: Date = Date()
    ) async -> WorkspaceUpdateCandidate? {
        guard await store.subject(id: subjectID) != nil else { return nil }
        let candidate = WorkspaceUpdateCandidate(
            id: WorkspaceUpdateCandidate.identity(subjectID: subjectID, url: hit.url),
            subjectID: subjectID,
            title: hit.title,
            url: hit.url,
            sourceName: hit.provider.displayName,
            publishedAt: hit.publishedAt,
            discoveredAt: now,
            origin: .research
        )
        let existing = await store.updates(subjectID: subjectID)
        guard !existing.contains(where: { $0.id == candidate.id }) else {
            return candidate
        }
        do {
            try await store.saveUpdates(existing + [candidate], for: subjectID)
            return candidate
        } catch {
            return nil
        }
    }
}
