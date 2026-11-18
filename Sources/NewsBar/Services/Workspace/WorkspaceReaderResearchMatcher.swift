import Foundation
import Observation

struct WorkspaceReaderResearchMatch: Equatable, Sendable {
    let entry: ResearchIndexEntry?
    let eventID: String?
    let subjectID: String?

    var recordID: String? { entry?.id }
    var hasPublishedReport: Bool { entry?.hasReport == true }
    var isResearching: Bool { entry?.status.isActive == true }
    var isVisibleToReaders: Bool { hasPublishedReport || isResearching }
}

struct WorkspaceReaderResearchTaskKey: Equatable {
    let enabled: Bool
    let itemID: String
    let urls: [String]
}

struct WorkspaceReaderResearchMatcherMetrics: Equatable, Sendable {
    var fullIndexLoads = 0
    var recordReads = 0
    var processedBatches = 0
    var signalRefreshes = 0
    var signalPublishes = 0
    var signalDeliveryWaits = 0
}

@MainActor
@Observable
final class WorkspaceReaderResearchAssociationSignal {
    private struct Presentation: Equatable {
        let recordID: String?
        let eventID: String?
        let subjectID: String?
        let hasReport: Bool
        let isResearching: Bool

        init(_ match: WorkspaceReaderResearchMatch?) {
            recordID = match?.recordID
            eventID = match?.eventID
            subjectID = match?.subjectID
            hasReport = match?.hasPublishedReport == true
            isResearching = match?.isResearching == true
        }
    }

    let id = UUID()
    private(set) var match: WorkspaceReaderResearchMatch?
    private(set) var revision = 0
    @ObservationIgnored private var presentation = Presentation(nil)

    @discardableResult
    fileprivate func update(_ value: WorkspaceReaderResearchMatch?) -> Bool {
        let nextPresentation = Presentation(value)
        guard nextPresentation != presentation else { return false }
        presentation = nextPresentation
        match = value
        revision &+= 1
        return true
    }
}

protocol WorkspaceReaderResearchRecordProviding: Sendable {
    func index() async -> [ResearchIndexEntry]
    func record(id: String) async -> ResearchRecord?
}

protocol WorkspaceReaderResearchSubjectProviding: Sendable {
    func subjects() async -> [WorkspaceSubject]
}

protocol WorkspaceReaderResearchEventProviding: Sendable {
    func events() async throws -> [NewsEvent]
}

extension ResearchStore: WorkspaceReaderResearchRecordProviding {}
extension WorkspaceSubjectStore: WorkspaceReaderResearchSubjectProviding {}
extension NewsEventStore: WorkspaceReaderResearchEventProviding {}

private struct WorkspaceReaderResearchRecordUpdate: Sendable {
    let id: String
    let entry: ResearchIndexEntry?
}

/// The shared lookup index owns all mapping and ordering work away from the
/// main actor. Queries examine only the small set of buckets addressed by an
/// article; single-record updates do not rescan the full research index.
private actor WorkspaceReaderResearchIndex {
    private struct EntryPresentation: Equatable {
        let id: String
        let itemID: String?
        let canonicalURL: String?
        let hasReport: Bool
        let isResearching: Bool

        init?(_ entry: ResearchIndexEntry?) {
            guard let entry else { return nil }
            id = entry.id
            itemID = entry.seedItemID
            let canonical = entry.seedURL.map(ContentIdentity.canonicalURL) ?? ""
            canonicalURL = canonical.isEmpty ? nil : canonical
            hasReport = entry.hasReport
            isResearching = entry.status.isActive
        }
    }

    private var allEntries: [ResearchIndexEntry] = []
    private var allEntriesByID: [String: ResearchIndexEntry] = [:]
    private var entriesByID: [String: ResearchIndexEntry] = [:]
    private var entriesByItemID: [String: [ResearchIndexEntry]] = [:]
    private var entriesByURL: [String: [ResearchIndexEntry]] = [:]
    private var subjectByRecordID: [String: WorkspaceSubject] = [:]
    private var subjectByEventID: [String: WorkspaceSubject] = [:]
    private var eventByURL: [String: NewsEvent] = [:]

    func replace(
        entries: [ResearchIndexEntry],
        subjects: [WorkspaceSubject],
        events: [NewsEvent]
    ) -> Set<String> {
        let previousKeys = allLookupKeys()
        allEntries = entries
        allEntriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        entriesByID.removeAll(keepingCapacity: true)
        entriesByItemID.removeAll(keepingCapacity: true)
        entriesByURL.removeAll(keepingCapacity: true)
        subjectByRecordID.removeAll(keepingCapacity: true)
        subjectByEventID.removeAll(keepingCapacity: true)
        eventByURL.removeAll(keepingCapacity: true)

        for entry in entries where Self.isReaderVisible(entry) {
            entriesByID[entry.id] = entry
            appendToArticleLookups(entry)
        }
        for key in Array(entriesByItemID.keys) { entriesByItemID[key]?.sort(by: Self.preferred) }
        for key in Array(entriesByURL.keys) { entriesByURL[key]?.sort(by: Self.preferred) }
        _ = replaceSubjects(subjects)
        _ = replaceEvents(events)
        return previousKeys.union(allLookupKeys())
    }

    func apply(
        recordUpdates: [WorkspaceReaderResearchRecordUpdate],
        subjects: [WorkspaceSubject]?,
        events: [NewsEvent]?
    ) -> Set<String> {
        var affected = Set<String>()
        for update in recordUpdates {
            affected.formUnion(updateRecord(id: update.id, entry: update.entry))
        }
        if let subjects { affected.formUnion(replaceSubjects(subjects)) }
        if let events { affected.formUnion(replaceEvents(events)) }
        return affected
    }

    func match(itemID: String?, rawURLs: [String]) -> WorkspaceReaderResearchMatch? {
        let canonicalURLs = Set(rawURLs.compactMap { raw -> String? in
            let canonical = ContentIdentity.canonicalURL(raw)
            return canonical.isEmpty ? nil : canonical
        })

        var directCandidates: [ResearchIndexEntry] = []
        if let itemID, let candidate = entriesByItemID[itemID]?.first {
            directCandidates.append(candidate)
        }
        for url in canonicalURLs {
            if let candidate = entriesByURL[url]?.first {
                directCandidates.append(candidate)
            }
        }
        let direct = directCandidates.min(by: Self.preferred)
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
            .min(by: Self.preferred)
        guard linked != nil else { return nil }
        return WorkspaceReaderResearchMatch(entry: linked, eventID: event.id, subjectID: subject.id)
    }

    func recentEntries(excluding id: String?, limit: Int) -> [ResearchIndexEntry] {
        guard limit > 0 else { return [] }
        return Array(allEntries.lazy.filter { $0.id != id }.prefix(limit))
    }

    private func updateRecord(id: String, entry: ResearchIndexEntry?) -> Set<String> {
        let previousVisible = entriesByID[id]
        let nextVisible = entry.flatMap { Self.isReaderVisible($0) ? $0 : nil }
        let didChangePresentation = EntryPresentation(previousVisible) != EntryPresentation(nextVisible)
        var affected = Set<String>()
        if didChangePresentation {
            if let previousVisible { affected.formUnion(Self.lookupKeys(for: previousVisible)) }
            if let nextVisible { affected.formUnion(Self.lookupKeys(for: nextVisible)) }
        }

        if let previous = allEntriesByID.removeValue(forKey: id) {
            removeFromAllEntries(previous)
        }
        if let previousVisible {
            removeFromArticleLookups(previousVisible)
            entriesByID[id] = nil
        }

        guard let entry else { return affected }
        allEntriesByID[id] = entry
        let insertionIndex = insertionIndex(for: entry)
        allEntries.insert(entry, at: insertionIndex)
        guard Self.isReaderVisible(entry) else { return affected }
        entriesByID[id] = entry
        insertPreferred(entry, into: &entriesByItemID, forKey: entry.seedItemID)
        if let seedURL = entry.seedURL {
            let canonical = ContentIdentity.canonicalURL(seedURL)
            if !canonical.isEmpty {
                insertPreferred(entry, into: &entriesByURL, forKey: canonical)
            }
        }
        return affected
    }

    private func removeFromAllEntries(_ entry: ResearchIndexEntry) {
        var low = 0
        var high = allEntries.count
        while low < high {
            let middle = (low + high) / 2
            if Self.researchIndexOrder(allEntries[middle], entry) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        if low < allEntries.count, allEntries[low].id == entry.id {
            allEntries.remove(at: low)
        }
    }

    private func insertionIndex(for entry: ResearchIndexEntry) -> Int {
        var low = 0
        var high = allEntries.count
        while low < high {
            let middle = (low + high) / 2
            if Self.researchIndexOrder(allEntries[middle], entry) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private func replaceSubjects(_ subjects: [WorkspaceSubject]) -> Set<String> {
        let previousRecordAssociations = subjectByRecordID.mapValues(\.id)
        let previousEventAssociations = subjectByEventID.mapValues(\.id)
        subjectByRecordID.removeAll(keepingCapacity: true)
        subjectByEventID.removeAll(keepingCapacity: true)
        for subject in subjects {
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
        guard previousRecordAssociations != subjectByRecordID.mapValues(\.id)
                || previousEventAssociations != subjectByEventID.mapValues(\.id) else { return [] }
        return allLookupKeys()
    }

    private func replaceEvents(_ events: [NewsEvent]) -> Set<String> {
        let previousEventIDs = eventByURL.mapValues(\.id)
        var nextEventByURL: [String: NewsEvent] = [:]
        for event in events {
            for evidence in event.evidence {
                let canonical = ContentIdentity.canonicalURL(evidence.url)
                guard !canonical.isEmpty else { continue }
                if nextEventByURL[canonical].map({ $0.lastEvidenceAt < event.lastEvidenceAt }) ?? true {
                    nextEventByURL[canonical] = event
                }
            }
        }
        guard previousEventIDs != nextEventByURL.mapValues(\.id) else { return [] }
        let affectedURLs = Set(previousEventIDs.keys).union(nextEventByURL.keys)
        eventByURL = nextEventByURL
        return Set(affectedURLs.map { "url:\($0)" })
    }

    private func appendToArticleLookups(_ entry: ResearchIndexEntry) {
        if let itemID = entry.seedItemID, !itemID.isEmpty {
            entriesByItemID[itemID, default: []].append(entry)
        }
        if let seedURL = entry.seedURL {
            let canonical = ContentIdentity.canonicalURL(seedURL)
            if !canonical.isEmpty { entriesByURL[canonical, default: []].append(entry) }
        }
    }

    private func insertPreferred(
        _ entry: ResearchIndexEntry,
        into table: inout [String: [ResearchIndexEntry]],
        forKey key: String?
    ) {
        guard let key, !key.isEmpty else { return }
        var bucket = table[key, default: []]
        let insertionIndex = bucket.firstIndex { Self.preferred(entry, $0) } ?? bucket.endIndex
        bucket.insert(entry, at: insertionIndex)
        table[key] = bucket
    }

    private func removeFromArticleLookups(_ entry: ResearchIndexEntry) {
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

    private func allLookupKeys() -> Set<String> {
        var keys = Set<String>()
        for entry in entriesByID.values { keys.formUnion(Self.lookupKeys(for: entry)) }
        for url in eventByURL.keys { keys.insert("url:\(url)") }
        return keys
    }

    private static func lookupKeys(for entry: ResearchIndexEntry) -> Set<String> {
        var keys = Set<String>()
        if let itemID = entry.seedItemID, !itemID.isEmpty { keys.insert("item:\(itemID)") }
        if let seedURL = entry.seedURL {
            let canonical = ContentIdentity.canonicalURL(seedURL)
            if !canonical.isEmpty { keys.insert("url:\(canonical)") }
        }
        return keys
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

    private static func researchIndexOrder(_ lhs: ResearchIndexEntry, _ rhs: ResearchIndexEntry) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        if lhs.topic != rhs.topic { return lhs.topic < rhs.topic }
        return lhs.id < rhs.id
    }
}

/// The only NotificationCenter observer for article-to-research matching.
/// Visible readers register precise lookup keys; changes only refresh readers
/// attached to identities whose displayed association can have changed.
@MainActor
final class WorkspaceReaderResearchMatcher {
    static let shared = WorkspaceReaderResearchMatcher()

    private struct PendingChanges {
        var reloadResearch = false
        var recordIDs: Set<String> = []
        var reloadSubjects = false
        var reloadEvents = false

        var isEmpty: Bool {
            !reloadResearch && recordIDs.isEmpty && !reloadSubjects && !reloadEvents
        }

        mutating func merge(_ other: PendingChanges) {
            reloadResearch = reloadResearch || other.reloadResearch
            if reloadResearch {
                recordIDs.removeAll()
            } else {
                recordIDs.formUnion(other.recordIDs)
            }
            reloadSubjects = reloadSubjects || other.reloadSubjects
            reloadEvents = reloadEvents || other.reloadEvents
        }
    }

    private struct Registration {
        let itemID: String
        let urls: [String]
        let keys: Set<String>
        let generation: Int
    }

    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
    }

    private final class WeakSignal {
        weak var value: WorkspaceReaderResearchAssociationSignal?
        init(_ value: WorkspaceReaderResearchAssociationSignal) { self.value = value }
    }

    private let researchStore: any WorkspaceReaderResearchRecordProviding
    private let workspaceStore: any WorkspaceReaderResearchSubjectProviding
    private let eventStore: any WorkspaceReaderResearchEventProviding
    private let lookupIndex = WorkspaceReaderResearchIndex()
    private var sourceRevision = 0
    private var indexedRevision = -1
    private var isLoaded = false
    private var pending = PendingChanges()
    private var pendingAffectedKeys = Set<String>()
    private var batchFlight: Flight?
    private var updateFlight: Flight?
    private var signalDeliveryFlight: Flight?
    private var observers: [NSObjectProtocol] = []
    private var registrations: [UUID: Registration] = [:]
    private var signalReferences: [UUID: WeakSignal] = [:]
    private var registrationsByKey: [String: Set<UUID>] = [:]
    private var metrics = WorkspaceReaderResearchMatcherMetrics()
    private let beforeSignalDelivery: (@Sendable () async -> Void)?

    init(
        researchStore: any WorkspaceReaderResearchRecordProviding = ResearchStore.shared,
        workspaceStore: any WorkspaceReaderResearchSubjectProviding = WorkspaceSubjectStore.shared,
        eventStore: any WorkspaceReaderResearchEventProviding = NewsEventStore.shared,
        beforeSignalDelivery: (@Sendable () async -> Void)? = nil
    ) {
        self.researchStore = researchStore
        self.workspaceStore = workspaceStore
        self.eventStore = eventStore
        self.beforeSignalDelivery = beforeSignalDelivery

        observers.append(NotificationCenter.default.addObserver(
            forName: .researchRecordsChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let recordID = notification.userInfo?[ResearchChangeKey.recordID] as? String
            Task { @MainActor [weak self] in self?.recordDidChange(id: recordID) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .researchWorkspaceChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.workspaceDidChange() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .newsEventsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.eventsDidChange() }
        })
    }

    deinit {
        batchFlight?.task.cancel()
        updateFlight?.task.cancel()
        signalDeliveryFlight?.task.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func taskKey(itemID: String, urls: [String], enabled: Bool) -> WorkspaceReaderResearchTaskKey {
        WorkspaceReaderResearchTaskKey(enabled: enabled, itemID: itemID, urls: urls)
    }

    func observe(
        _ signal: WorkspaceReaderResearchAssociationSignal,
        itemID: String,
        urls: [String],
        enabled: Bool
    ) async {
        guard enabled else {
            removeObserver(signal)
            return
        }

        let nextGeneration = (registrations[signal.id]?.generation ?? 0) &+ 1
        removeRegistration(signal.id, clearSignal: false)
        let keys = Self.lookupKeys(itemID: itemID, urls: urls)
        registrations[signal.id] = Registration(
            itemID: itemID,
            urls: urls,
            keys: keys,
            generation: nextGeneration
        )
        signalReferences[signal.id] = WeakSignal(signal)
        for key in keys { registrationsByKey[key, default: []].insert(signal.id) }
        _ = signal.update(nil)

        await ensureCurrentIndex()
        guard registrations[signal.id]?.generation == nextGeneration else { return }
        guard !Task.isCancelled else {
            removeObserver(signal)
            return
        }
        await refreshRegisteredSignal(signal.id, generation: nextGeneration, respectCancellation: true)
    }

    func removeObserver(_ signal: WorkspaceReaderResearchAssociationSignal) {
        removeRegistration(signal.id, clearSignal: true)
    }

    func match(item: NewsItem?, url: String, enabled: Bool) async -> WorkspaceReaderResearchMatch? {
        guard enabled else { return nil }
        return await match(itemID: item?.id, urls: [item?.url, item?.readerURL, url].compactMap { $0 })
    }

    func match(item: NewsItem?, url: String) async -> WorkspaceReaderResearchMatch? {
        await match(itemID: item?.id, urls: [item?.url, item?.readerURL, url].compactMap { $0 })
    }

    func match(itemID: String?, urls: [String]) async -> WorkspaceReaderResearchMatch? {
        while !Task.isCancelled {
            await ensureCurrentIndex()
            guard !Task.isCancelled else { return nil }
            let expectedRevision = sourceRevision
            let result = await lookupIndex.match(itemID: itemID, rawURLs: urls)
            if expectedRevision == sourceRevision, indexedRevision == expectedRevision {
                return result
            }
        }
        return nil
    }

    func recentEntries(excluding id: String?, limit: Int) async -> [ResearchIndexEntry] {
        while !Task.isCancelled {
            await ensureCurrentIndex()
            guard !Task.isCancelled else { return [] }
            let expectedRevision = sourceRevision
            let result = await lookupIndex.recentEntries(excluding: id, limit: limit)
            if expectedRevision == sourceRevision, indexedRevision == expectedRevision {
                return result
            }
        }
        return []
    }

    func metricsSnapshot() -> WorkspaceReaderResearchMatcherMetrics { metrics }

    /// Deterministic seam used by isolated tests; production notifications call
    /// these same coalescing entry points through the single observer above.
    func recordDidChange(id: String?) {
        var change = PendingChanges()
        if let id { change.recordIDs.insert(id) }
        else { change.reloadResearch = true }
        enqueue(change)
    }

    func workspaceDidChange() {
        var change = PendingChanges()
        change.reloadSubjects = true
        enqueue(change)
    }

    func eventsDidChange() {
        var change = PendingChanges()
        change.reloadEvents = true
        enqueue(change)
    }

    func flushPendingChanges() async {
        await ensureCurrentIndex()
    }

    private func enqueue(_ change: PendingChanges) {
        guard !change.isEmpty else { return }
        pending.merge(change)
        sourceRevision &+= 1
        guard !registrations.isEmpty else { return }
        guard batchFlight == nil else { return }

        let flightID = UUID()
        let task = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            guard !self.registrations.isEmpty else {
                if self.batchFlight?.id == flightID { self.batchFlight = nil }
                return
            }
            await self.ensureCurrentIndex()
            if self.batchFlight?.id == flightID { self.batchFlight = nil }
            if !self.pending.isEmpty, !self.registrations.isEmpty { self.enqueueBatchIfNeeded() }
        }
        batchFlight = Flight(id: flightID, task: task)
    }

    private func enqueueBatchIfNeeded() {
        guard !pending.isEmpty, !registrations.isEmpty, batchFlight == nil else { return }
        let flightID = UUID()
        let task = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            guard !self.registrations.isEmpty else {
                if self.batchFlight?.id == flightID { self.batchFlight = nil }
                return
            }
            await self.ensureCurrentIndex()
            if self.batchFlight?.id == flightID { self.batchFlight = nil }
            if !self.pending.isEmpty, !self.registrations.isEmpty { self.enqueueBatchIfNeeded() }
        }
        batchFlight = Flight(id: flightID, task: task)
    }

    private func ensureCurrentIndex() async {
        while !Task.isCancelled {
            while !Task.isCancelled {
                if let flight = updateFlight {
                    await flight.task.value
                    if updateFlight?.id == flight.id { updateFlight = nil }
                    continue
                }
                if isLoaded, indexedRevision == sourceRevision, pending.isEmpty { break }

                let expectedRevision = sourceRevision
                let changes = pending
                pending = PendingChanges()
                let flightID = UUID()
                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.apply(changes, expectedRevision: expectedRevision)
                }
                updateFlight = Flight(id: flightID, task: task)
                await task.value
                if updateFlight?.id == flightID { updateFlight = nil }
            }

            await deliverAffectedSignals()
            if isLoaded, indexedRevision == sourceRevision, pending.isEmpty, pendingAffectedKeys.isEmpty {
                return
            }
        }
    }

    private func apply(_ changes: PendingChanges, expectedRevision: Int) async {
        metrics.processedBatches += 1
        if !isLoaded || changes.reloadResearch {
            metrics.fullIndexLoads += 1
            async let entries = researchStore.index()
            async let subjects = workspaceStore.subjects()
            async let events = (try? await eventStore.events()) ?? []
            let (resolvedEntries, resolvedSubjects, resolvedEvents) = await (entries, subjects, events)
            guard sourceRevision == expectedRevision, !Task.isCancelled else {
                pending.merge(changes)
                return
            }
            let affected = await lookupIndex.replace(
                entries: resolvedEntries,
                subjects: resolvedSubjects,
                events: resolvedEvents
            )
            if isLoaded { pendingAffectedKeys.formUnion(affected) }
            guard sourceRevision == expectedRevision, !Task.isCancelled else {
                pending.merge(changes)
                return
            }
            isLoaded = true
            indexedRevision = expectedRevision
            return
        }

        var recordUpdates: [WorkspaceReaderResearchRecordUpdate] = []
        for id in changes.recordIDs.sorted() {
            metrics.recordReads += 1
            let record = await researchStore.record(id: id)
            let entry = record.flatMap { $0.loadIssue == nil ? ResearchIndexEntry(record: $0) : nil }
            recordUpdates.append(WorkspaceReaderResearchRecordUpdate(id: id, entry: entry))
        }
        let subjects = changes.reloadSubjects ? await workspaceStore.subjects() : nil
        let events: [NewsEvent]? = if changes.reloadEvents {
            (try? await eventStore.events()) ?? []
        } else {
            nil
        }

        guard sourceRevision == expectedRevision, !Task.isCancelled else {
            pending.merge(changes)
            return
        }
        let affected = await lookupIndex.apply(
            recordUpdates: recordUpdates,
            subjects: subjects,
            events: events
        )
        pendingAffectedKeys.formUnion(affected)
        guard sourceRevision == expectedRevision, !Task.isCancelled else {
            pending.merge(changes)
            return
        }
        indexedRevision = expectedRevision
    }

    private func deliverAffectedSignals() async {
        if let flight = signalDeliveryFlight {
            metrics.signalDeliveryWaits += 1
            await flight.task.value
            if signalDeliveryFlight?.id == flight.id { signalDeliveryFlight = nil }
            if !pendingAffectedKeys.isEmpty { await deliverAffectedSignals() }
            return
        }
        guard !pendingAffectedKeys.isEmpty else { return }
        let changedKeys = pendingAffectedKeys
        pendingAffectedKeys.removeAll(keepingCapacity: true)
        let flightID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.beforeSignalDelivery?()
            let signalIDs = Set(changedKeys.flatMap { self.registrationsByKey[$0] ?? [] })
            for signalID in signalIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let generation = self.registrations[signalID]?.generation else { continue }
                await self.refreshRegisteredSignal(signalID, generation: generation, respectCancellation: false)
            }
        }
        signalDeliveryFlight = Flight(id: flightID, task: task)
        await task.value
        if signalDeliveryFlight?.id == flightID { signalDeliveryFlight = nil }
        if !pendingAffectedKeys.isEmpty { await deliverAffectedSignals() }
    }

    private func refreshRegisteredSignal(
        _ signalID: UUID,
        generation: Int,
        respectCancellation: Bool
    ) async {
        guard let registration = registrations[signalID] else { return }
        guard registration.generation == generation else { return }
        guard let signal = signalReferences[signalID]?.value else {
            removeRegistration(signalID, clearSignal: true)
            return
        }
        guard indexedRevision == sourceRevision else {
            pendingAffectedKeys.formUnion(registration.keys)
            return
        }
        let expectedRevision = sourceRevision
        let result = await lookupIndex.match(itemID: registration.itemID, rawURLs: registration.urls)
        guard (!respectCancellation || !Task.isCancelled),
              registrations[signalID]?.generation == generation,
              sourceRevision == expectedRevision,
              indexedRevision == expectedRevision else {
            if registrations[signalID]?.generation == generation {
                pendingAffectedKeys.formUnion(registration.keys)
            }
            return
        }
        metrics.signalRefreshes += 1
        if signal.update(result) { metrics.signalPublishes += 1 }
    }

    /// Internal seam for asserting stale registration work cannot unregister a newer identity.
    func refreshRegisteredSignalForTesting(_ signalID: UUID, generation: Int) async {
        await refreshRegisteredSignal(signalID, generation: generation, respectCancellation: false)
    }

    private func removeRegistration(_ signalID: UUID, clearSignal: Bool) {
        if let registration = registrations.removeValue(forKey: signalID) {
            for key in registration.keys {
                registrationsByKey[key]?.remove(signalID)
                if registrationsByKey[key]?.isEmpty == true { registrationsByKey[key] = nil }
            }
        }
        let signal = signalReferences.removeValue(forKey: signalID)?.value
        if clearSignal, let signal, signal.update(nil) { metrics.signalPublishes += 1 }
    }

    private static func lookupKeys(itemID: String, urls: [String]) -> Set<String> {
        var keys = Set<String>()
        if !itemID.isEmpty { keys.insert("item:\(itemID)") }
        for rawURL in urls {
            let canonical = ContentIdentity.canonicalURL(rawURL)
            if !canonical.isEmpty { keys.insert("url:\(canonical)") }
        }
        return keys
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
