import Foundation

struct WorkspaceReaderResearchMatch: Equatable, Sendable {
    let entry: ResearchIndexEntry?
    let eventID: String?
    let subjectID: String?

    var recordID: String? { entry?.id }
    var hasPublishedReport: Bool { entry?.hasReport == true }
    var isResearching: Bool { entry?.status.isActive == true }
    var isVisibleToReaders: Bool { hasPublishedReport || isResearching }
}

/// Resolves only explicit article identities or event membership. Similar
/// titles are deliberately excluded from reader facing associations.
@MainActor
final class WorkspaceReaderResearchMatcher {
    static let shared = WorkspaceReaderResearchMatcher()

    private let researchStore: any ResearchPersisting
    private let workspaceStore: any WorkspacePersisting
    private let eventStore: any NewsEventPersisting
    private var revision = 0
    private var loadedRevision = -1
    private var loadTask: Task<Void, Never>?
    private var recordRefreshTasks: [String: Task<Void, Never>] = [:]
    private var entriesByID: [String: ResearchIndexEntry] = [:]
    private var entriesByItemID: [String: [ResearchIndexEntry]] = [:]
    private var entriesByURL: [String: [ResearchIndexEntry]] = [:]
    private var subjectByRecordID: [String: WorkspaceSubject] = [:]
    private var subjectByEventID: [String: WorkspaceSubject] = [:]
    private var eventByURL: [String: NewsEvent] = [:]
    private var observers: [NSObjectProtocol] = []

    init(
        researchStore: any ResearchPersisting = ResearchStore.shared,
        workspaceStore: any WorkspacePersisting = WorkspaceSubjectStore.shared,
        eventStore: any NewsEventPersisting = NewsEventStore.shared
    ) {
        self.researchStore = researchStore
        self.workspaceStore = workspaceStore
        self.eventStore = eventStore

        observers.append(NotificationCenter.default.addObserver(
            forName: .researchRecordsChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let recordID = notification.userInfo?[ResearchChangeKey.recordID] as? String
            Task { @MainActor [weak self] in
                if let recordID { await self?.refreshRecord(recordID) }
                else { self?.invalidate() }
            }
        })
        for name in [Notification.Name.researchWorkspaceChanged, .newsEventsChanged] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.invalidate() }
            })
        }
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func invalidate() {
        revision += 1
        loadedRevision = -1
        loadTask?.cancel()
        loadTask = nil
        for task in recordRefreshTasks.values { task.cancel() }
        recordRefreshTasks.removeAll()
        entriesByID.removeAll()
        entriesByItemID.removeAll()
        entriesByURL.removeAll()
        subjectByRecordID.removeAll()
        subjectByEventID.removeAll()
        eventByURL.removeAll()
    }

    func match(item: NewsItem?, url: String) async -> WorkspaceReaderResearchMatch? {
        await match(itemID: item?.id, urls: [item?.url, item?.readerURL, url].compactMap { $0 })
    }

    func match(itemID: String?, urls rawURLs: [String]) async -> WorkspaceReaderResearchMatch? {
        let expectedRevision = revision
        await loadIfNeeded()
        guard expectedRevision == revision, loadedRevision == expectedRevision else { return nil }

        let canonicalURLs = Set(rawURLs.compactMap { raw -> String? in
            let canonical = ContentIdentity.canonicalURL(raw)
            return canonical.isEmpty ? nil : canonical
        })
        let directCandidates = (itemID.flatMap { entriesByItemID[$0] } ?? [])
            + canonicalURLs.flatMap { entriesByURL[$0] ?? [] }
        let direct = directCandidates.sorted(by: Self.preferred).first
        let event = canonicalURLs.compactMap { eventByURL[$0] }
            .max { $0.lastEvidenceAt < $1.lastEvidenceAt }
        let subject = event.flatMap { subjectByEventID[$0.id] }

        if let direct {
            return WorkspaceReaderResearchMatch(
                entry: direct,
                eventID: event?.id,
                subjectID: subjectByRecordID[direct.id]?.id ?? subject?.id
            )
        }

        guard let event, let subject else { return nil }
        let linked = subject.researchRecordIDs
            .compactMap { entriesByID[$0] }
            .sorted(by: Self.preferred)
            .first
        guard linked != nil else { return nil }
        return WorkspaceReaderResearchMatch(entry: linked, eventID: event.id, subjectID: subject.id)
    }

    private func loadIfNeeded() async {
        guard loadedRevision != revision else { return }
        if let loadTask {
            await loadTask.value
            if loadedRevision == revision { return }
        }
        let expectedRevision = revision
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoad(expectedRevision: expectedRevision)
        }
        loadTask = task
        await task.value
        if revision == expectedRevision, loadedRevision == expectedRevision {
            loadTask = nil
        }
    }

    private func performLoad(expectedRevision: Int) async {
        async let newEntries = researchStore.index()
        async let newSubjects = workspaceStore.subjects()
        async let newEvents = try? eventStore.events()
        let (resolvedEntries, resolvedSubjects, resolvedEvents) = await (newEntries, newSubjects, newEvents)
        guard revision == expectedRevision, !Task.isCancelled else { return }

        entriesByID = Dictionary(uniqueKeysWithValues: resolvedEntries.compactMap { entry in
            guard Self.isReaderVisible(entry) else { return nil }
            return (entry.id, entry)
        })
        for entry in entriesByID.values { addToArticleLookups(entry) }
        for subject in resolvedSubjects {
            for id in subject.researchRecordIDs {
                subjectByRecordID[id] = subject
            }
            for key in subject.lookupKeys where key.hasPrefix("research:") {
                subjectByRecordID[String(key.dropFirst("research:".count))] = subject
            }
            for id in subject.eventIDs {
                subjectByEventID[id] = subject
            }
            for key in subject.lookupKeys where key.hasPrefix("event:") {
                subjectByEventID[String(key.dropFirst("event:".count))] = subject
            }
        }
        for event in resolvedEvents ?? [] {
            for evidence in event.evidence {
                let canonical = ContentIdentity.canonicalURL(evidence.url)
                guard !canonical.isEmpty else { continue }
                if eventByURL[canonical].map({ $0.lastEvidenceAt < event.lastEvidenceAt }) ?? true {
                    eventByURL[canonical] = event
                }
            }
        }
        sortArticleLookups()
        loadedRevision = expectedRevision
    }

    private func refreshRecord(_ id: String) async {
        if let existing = recordRefreshTasks[id] {
            await existing.value
            return
        }
        let expectedRevision = revision
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.loadedRevision != expectedRevision, let loadTask = self.loadTask {
                await loadTask.value
            }
            guard self.revision == expectedRevision,
                  self.loadedRevision == expectedRevision,
                  !Task.isCancelled else { return }
            let record = await self.researchStore.record(id: id)
            guard self.revision == expectedRevision,
                  self.loadedRevision == expectedRevision,
                  !Task.isCancelled else { return }
            self.removeFromArticleLookups(self.entriesByID.removeValue(forKey: id))
            if let record, record.loadIssue == nil {
                let entry = ResearchIndexEntry(record: record)
                if Self.isReaderVisible(entry) {
                    self.entriesByID[id] = entry
                    self.addToArticleLookups(entry)
                    self.sortArticleLookups()
                }
            }
        }
        recordRefreshTasks[id] = task
        await task.value
        if revision == expectedRevision { recordRefreshTasks[id] = nil }
    }

    private func addToArticleLookups(_ entry: ResearchIndexEntry) {
        if let itemID = entry.seedItemID, !itemID.isEmpty {
            entriesByItemID[itemID, default: []].append(entry)
        }
        if let seedURL = entry.seedURL {
            let canonical = ContentIdentity.canonicalURL(seedURL)
            if !canonical.isEmpty { entriesByURL[canonical, default: []].append(entry) }
        }
    }

    private func removeFromArticleLookups(_ entry: ResearchIndexEntry?) {
        guard let entry else { return }
        if let itemID = entry.seedItemID {
            entriesByItemID[itemID]?.removeAll { $0.id == entry.id }
            if entriesByItemID[itemID]?.isEmpty == true { entriesByItemID[itemID] = nil }
        }
        if let seedURL = entry.seedURL {
            let canonical = ContentIdentity.canonicalURL(seedURL)
            entriesByURL[canonical]?.removeAll { $0.id == entry.id }
            if entriesByURL[canonical]?.isEmpty == true { entriesByURL[canonical] = nil }
        }
    }

    private func sortArticleLookups() {
        for key in Array(entriesByItemID.keys) { entriesByItemID[key]?.sort(by: Self.preferred) }
        for key in Array(entriesByURL.keys) { entriesByURL[key]?.sort(by: Self.preferred) }
    }

    private static func isReaderVisible(_ entry: ResearchIndexEntry) -> Bool {
        entry.issue == nil && entry.status != .corrupt && (entry.hasReport || entry.status.isActive)
    }

    private static func preferred(_ lhs: ResearchIndexEntry, _ rhs: ResearchIndexEntry) -> Bool {
        if lhs.hasReport != rhs.hasReport { return lhs.hasReport }
        if lhs.status.isActive != rhs.status.isActive { return lhs.status.isActive }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }
}

@MainActor
enum ResearchReadingContextRegistry {
    private struct Target: Equatable {
        let eventID: String?
        let recordID: String?
    }

    private static var targets: [UUID: Target] = [:]

    static func update(token: UUID, eventID: String?, recordID: String?, isVisible: Bool) {
        guard isVisible, eventID != nil || recordID != nil else {
            targets.removeValue(forKey: token)
            return
        }
        targets[token] = Target(eventID: eventID, recordID: recordID)
    }

    static func remove(token: UUID) {
        targets.removeValue(forKey: token)
    }

    static func contains(eventID: String?, recordID: String?) -> Bool {
        targets.values.contains { target in
            (eventID != nil && target.eventID == eventID)
                || (recordID != nil && target.recordID == recordID)
        }
    }
}
