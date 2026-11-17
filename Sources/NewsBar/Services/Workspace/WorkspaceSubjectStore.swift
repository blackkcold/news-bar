import Foundation

extension Notification.Name {
    /// Posted after a durable workspace write. `userInfo["subjectID"]` is
    /// present when exactly one subject changed.
    static let researchWorkspaceChanged = Notification.Name("researchWorkspaceChanged")
}

enum WorkspaceStoreError: Error, Equatable {
    case invalidSubjectID
    case emptyTitle
    /// The file was written by a newer build or cannot be read safely. Writes
    /// would destroy bytes this build does not understand.
    case readOnlyStore
    /// A clear could not delete every version/state/index file. The durable
    /// clear intent must remain so the operation is retried.
    case clearIncomplete
    case recordCleared
}

protocol WorkspacePersisting: Sendable {
    func bootstrap() async -> WorkspaceBootstrap
    func subjects() async -> [WorkspaceSubject]
    func subject(id: String) async -> WorkspaceSubject?
    func subject(containingResearchID id: String) async -> WorkspaceSubject?
    func subject(containingEventID id: String) async -> WorkspaceSubject?
    func createSubject(title: String, aliases: [String], isFollowed: Bool,
                       now: Date) async throws -> WorkspaceSubject
    func save(_ subject: WorkspaceSubject) async throws
    func saveAll(_ subjects: [WorkspaceSubject]) async throws
    @discardableResult
    func updateSubject(
        id: String,
        mutation: @Sendable (inout WorkspaceSubject) -> Void
    ) async throws -> WorkspaceSubject
    func updates(subjectID: String) async -> [WorkspaceUpdateCandidate]
    func saveUpdates(_ updates: [WorkspaceUpdateCandidate], for subjectID: String) async throws
    func versions(recordID: String) async -> [WorkspaceReportVersion]
    func appendVersion(_ version: WorkspaceReportVersion) async throws
    func dataEpoch() async -> Int

    // Stage-2 extensions (defaulted for test doubles).
    func reportState(recordID: String) async -> WorkspaceReportState?
    func saveReportState(_ state: WorkspaceReportState) async throws
    func ensureBaselineVersion(record: ResearchRecord, subjectID: String, at: Date) async throws
    func applyHistoryClear(now: Date) async throws -> Int
}

extension WorkspacePersisting {
    func reportState(recordID: String) async -> WorkspaceReportState? { nil }
    func saveReportState(_ state: WorkspaceReportState) async throws {}
    func applyHistoryClear(now: Date) async throws -> Int { 0 }

    @discardableResult
    func updateSubject(
        id: String,
        mutation: @Sendable (inout WorkspaceSubject) -> Void
    ) async throws -> WorkspaceSubject {
        guard var subject = await subject(id: id) else {
            throw WorkspaceStoreError.invalidSubjectID
        }
        mutation(&subject)
        try await save(subject)
        return subject
    }

    func ensureBaselineVersion(record: ResearchRecord, subjectID: String, at: Date) async throws {
        guard let report = record.report else { return }
        let existing = await versions(recordID: record.id)
        guard existing.isEmpty else { return }
        try await appendVersion(
            WorkspaceReportVersion(
                id: "\(record.id)#1",
                recordID: record.id,
                subjectID: subjectID,
                sequence: 1,
                createdAt: report.generatedAt ?? at,
                trigger: record.run.origin,
                report: report,
                digest: WorkspaceReportDigest.make(report)
            )
        )
    }
}

/// Actor store for the link/version layer. `workspace-v1.json` is the index;
/// report versions and analysis state are one file per record. None of these
/// writes touches `ResearchRecord`, `ResearchStore` or event files.
actor WorkspaceSubjectStore: WorkspacePersisting {
    static let shared = WorkspaceSubjectStore()

    private struct IndexDocument: Codable {
        var version = 1
        var updatedAt: Date
        var clearGeneration: Int
        var subjects: [WorkspaceSubject]
        var updates: [String: [WorkspaceUpdateCandidate]]

        init(
            version: Int = 1,
            updatedAt: Date,
            clearGeneration: Int,
            subjects: [WorkspaceSubject],
            updates: [String: [WorkspaceUpdateCandidate]]
        ) {
            self.version = version
            self.updatedAt = updatedAt
            self.clearGeneration = clearGeneration
            self.subjects = subjects
            self.updates = updates
        }

        enum CodingKeys: String, CodingKey {
            case version, updatedAt, clearGeneration, subjects, updates
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
            clearGeneration = try container.decodeIfPresent(Int.self, forKey: .clearGeneration) ?? 0
            subjects = try container.decodeIfPresent([WorkspaceSubject].self, forKey: .subjects) ?? []
            updates = try container.decodeIfPresent(
                [String: [WorkspaceUpdateCandidate]].self,
                forKey: .updates
            ) ?? [:]
        }
    }

    private struct VersionProbe: Codable {
        var version: Int?
    }

    static let updateRetention: TimeInterval = 90 * 86_400
    static let versionLimit = 20

    private let directoryURL: URL
    private let indexURL: URL
    private let versionsURL: URL
    private let statesURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    private var subjectsByID: [String: WorkspaceSubject] = [:]
    private var updatesBySubject: [String: [WorkspaceUpdateCandidate]] = [:]
    private var versionCache: [String: [WorkspaceReportVersion]] = [:]
    private var stateCache: [String: WorkspaceReportState] = [:]
    private var clearGeneration = 0
    /// IDs merged into a canonical subject. Persisted as `subject:<retiredID>`
    /// lookup keys on the survivor, so old deep links still resolve.
    private var retiredSubjectIDs: Set<String> = []
    /// Records/leads removed by a clear. A late snapshot must not re-link them.
    private var clearedResearchRecordIDs: Set<String> = []
    private var clearedAt: Date?
    private var epoch = 0
    private var didBootstrap = false
    private var readOnly = false
    private var issue: WorkspaceStoreIssue?
    private var rebuilt = false
    private var corruptFile = false

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let directory = directoryURL ?? ResearchPaths.workspaceDirectory
        self.directoryURL = directory
        self.indexURL = directory.appendingPathComponent("workspace-v1.json")
        self.versionsURL = directory.appendingPathComponent("report-versions", isDirectory: true)
        self.statesURL = directory.appendingPathComponent("report-state", isDirectory: true)
        self.fileManager = fileManager
        self.now = now
    }

    // MARK: - Bootstrap

    func bootstrap() async -> WorkspaceBootstrap {
        if didBootstrap {
            return WorkspaceBootstrap(
                subjects: sortedSubjects(),
                rebuilt: false,
                corruptFile: corruptFile,
                readOnly: readOnly,
                issue: issue
            )
        }
        ensureDirectories()
        loadDocument()
        didBootstrap = true
        if !readOnly {
            _ = try? await applyHistoryClear(now: now())
        }
        return WorkspaceBootstrap(
            subjects: sortedSubjects(),
            rebuilt: rebuilt,
            corruptFile: corruptFile,
            readOnly: readOnly,
            issue: issue
        )
    }

    private func loadDocument() {
        guard fileManager.fileExists(atPath: indexURL.path) else {
            rebuilt = true
            return
        }
        guard let data = try? Data(contentsOf: indexURL) else {
            issue = .ioUnavailable
            readOnly = true
            return
        }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
              let version = probe.version else {
            // An old file always states its version. Without one the shape is
            // unknown; isolate the bytes instead of overwriting them.
            isolateCorruptFile()
            return
        }
        guard version == 1 else {
            issue = .unsupportedVersion
            readOnly = true
            return
        }
        guard let document = try? JSONDecoder().decode(IndexDocument.self, from: data),
              document.version == 1 else {
            isolateCorruptFile()
            return
        }
        if document.subjects.contains(where: {
            $0.schemaVersion > WorkspaceSubject.currentSchemaVersion
        }) {
            // A future subject shape would be silently downgraded on write.
            issue = .unsupportedVersion
            readOnly = true
            return
        }
        clearGeneration = document.clearGeneration
        subjectsByID = Dictionary(
            document.subjects.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        retiredSubjectIDs = Self.redirectedIDs(in: subjectsByID.values)
        updatesBySubject = document.updates.mapValues { Self.prunedUpdates($0, now: now()) }
    }

    private func isolateCorruptFile() {
        let stamp = Int(now().timeIntervalSince1970)
        let base = "workspace-v1.corrupt-\(stamp)"
        var target = directoryURL.appendingPathComponent("\(base).json")
        if fileManager.fileExists(atPath: target.path) {
            target = directoryURL.appendingPathComponent("\(base)-\(UUID().uuidString).json")
        }
        do {
            try fileManager.moveItem(at: indexURL, to: target)
            rebuilt = true
            corruptFile = true
            issue = .corruptFile
        } catch {
            // Keeping the bad file is more important than rebuilding. Surface
            // read-only instead of pretending the data was recovered.
            issue = .corruptFile
            readOnly = true
        }
    }

    // MARK: - Reads

    func subjects() async -> [WorkspaceSubject] {
        await ensureLoaded()
        return sortedSubjects()
    }

    func subject(id: String) async -> WorkspaceSubject? {
        await ensureLoaded()
        if let subject = subjectsByID[id] { return subject }
        return subjectsByID.values.first {
            $0.lookupKeys.contains("subject:\(id)")
        }
    }

    func subject(containingResearchID id: String) async -> WorkspaceSubject? {
        await ensureLoaded()
        let key = "research:\(id)"
        return sortedSubjects().first {
            $0.researchRecordIDs.contains(id) || $0.lookupKeys.contains(key)
        }
    }

    func subject(containingEventID id: String) async -> WorkspaceSubject? {
        await ensureLoaded()
        let key = "event:\(id)"
        return sortedSubjects().first {
            $0.eventIDs.contains(id) || $0.lookupKeys.contains(key)
        }
    }

    func updates(subjectID: String) async -> [WorkspaceUpdateCandidate] {
        await ensureLoaded()
        return Self.sortedUpdates(updatesBySubject[subjectID] ?? [])
    }

    func versions(recordID: String) async -> [WorkspaceReportVersion] {
        await ensureLoaded()
        return loadVersions(recordID: recordID)
    }

    func reportState(recordID: String) async -> WorkspaceReportState? {
        await ensureLoaded()
        return loadReportState(recordID: recordID)
    }

    func dataEpoch() async -> Int {
        await ensureLoaded()
        return epoch
    }

    /// Atomic field intent. The mutation sees the latest stored subject, not a
    /// caller snapshot, so a checker/observer/notification update cannot roll
    /// back a user toggle that happened in between.
    @discardableResult
    func updateSubject(
        id: String,
        mutation: @Sendable (inout WorkspaceSubject) -> Void
    ) async throws -> WorkspaceSubject {
        await ensureLoaded()
        try ensureWritable()
        let resolvedID = canonicalID(for: id) ?? id
        guard var subject = subjectsByID[resolvedID] else {
            throw WorkspaceStoreError.invalidSubjectID
        }
        let before = subject
        mutation(&subject)
        subject.schemaVersion = WorkspaceSubject.currentSchemaVersion
        subject.kind = subject.recomputedKind
        if (subject.lastCheckedAt ?? .distantPast) < (before.lastCheckedAt ?? .distantPast) {
            subject.lastCheckedAt = before.lastCheckedAt
            subject.lastCheckOutcome = before.lastCheckOutcome
        }
        if (subject.lastNotifiedAt ?? .distantPast) < (before.lastNotifiedAt ?? .distantPast) {
            subject.lastNotifiedAt = before.lastNotifiedAt
            subject.lastNotificationKind = before.lastNotificationKind
            subject.lastNotifiedReference = before.lastNotifiedReference
        }
        if subject.updatedAt < before.updatedAt { subject.updatedAt = before.updatedAt }
        if subject.lastActivityAt < before.lastActivityAt {
            subject.lastActivityAt = before.lastActivityAt
        }

        var nextSubjects = subjectsByID
        nextSubjects[id] = subject
        try writeIndex(
            subjects: nextSubjects,
            updates: updatesBySubject,
            clearGeneration: clearGeneration
        )
        subjectsByID = nextSubjects
        epoch += 1
        postChanged(subjectID: id)
        return subject
    }

    // MARK: - Subject writes

    func createSubject(
        title: String,
        aliases: [String],
        isFollowed: Bool,
        now date: Date
    ) async throws -> WorkspaceSubject {
        await ensureLoaded()
        try ensureWritable()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkspaceStoreError.emptyTitle }
        let normalizedTitle = TopicFingerprint.normalized(trimmed)
        guard !normalizedTitle.isEmpty else { throw WorkspaceStoreError.emptyTitle }

        var subject = WorkspaceSubject(
            title: trimmed,
            aliases: [],
            kind: .topic,
            createdAt: date,
            updatedAt: date,
            lastActivityAt: date,
            isFollowed: isFollowed,
            isArchived: false,
            archivedAt: nil,
            updateState: .current,
            lastCheckedAt: nil,
            lastCheckOutcome: .notConfigured,
            pendingUpdateIDs: [],
            researchRecordIDs: [],
            eventIDs: [],
            lookupKeys: ["topic:\(TopicFingerprint.key(for: trimmed))"],
            schemaVersion: WorkspaceSubject.currentSchemaVersion
        )
        subject.aliases = Self.uniqueAliases(aliases, title: trimmed)
        var nextSubjects = subjectsByID
        nextSubjects[subject.id] = subject
        try writeIndex(
            subjects: nextSubjects,
            updates: updatesBySubject,
            clearGeneration: clearGeneration
        )
        subjectsByID = nextSubjects
        epoch += 1
        postChanged(subjectID: subject.id)
        return subject
    }

    func save(_ subject: WorkspaceSubject) async throws {
        await ensureLoaded()
        try ensureWritable()
        guard isValidID(subject.id) else { throw WorkspaceStoreError.invalidSubjectID }
        // A stale deep link/observer snapshot for a merged subject must not
        // resurrect it as a second row.
        guard !retiredSubjectIDs.contains(subject.id) else { return }
        var next = subject
        next.schemaVersion = WorkspaceSubject.currentSchemaVersion
        if let current = subjectsByID[subject.id] {
            next = mergeSnapshot(
                current: current,
                incoming: next,
                allowUserIntent: next.userRevision > current.userRevision
            )
        }
        var nextRetired = retiredSubjectIDs
        for key in next.lookupKeys where key.hasPrefix("subject:") {
            let id = String(key.dropFirst("subject:".count))
            if !id.isEmpty { nextRetired.insert(id) }
        }
        var nextSubjects = subjectsByID
        for id in nextRetired where id != next.id {
            nextSubjects.removeValue(forKey: id)
        }
        nextSubjects[next.id] = next
        try writeIndex(
            subjects: nextSubjects,
            updates: updatesBySubject,
            clearGeneration: clearGeneration
        )
        subjectsByID = nextSubjects
        retiredSubjectIDs = nextRetired
        epoch += 1
        postChanged(subjectID: next.id)
    }

    /// Bulk path used by reconcile/auto-discovery. A reconcile snapshot may be
    /// older than a user toggle that happened while it was running, so stored
    /// user state always wins.
    func saveAll(_ subjects: [WorkspaceSubject]) async throws {
        await ensureLoaded()
        try ensureWritable()
        guard !subjects.isEmpty else { return }
        var nextRetired = retiredSubjectIDs
        for incoming in subjects {
            for key in incoming.lookupKeys where key.hasPrefix("subject:") {
                let id = String(key.dropFirst("subject:".count))
                if !id.isEmpty { nextRetired.insert(id) }
            }
        }
        var nextSubjects = subjectsByID
        for id in nextRetired {
            nextSubjects.removeValue(forKey: id)
        }
        for incoming in subjects {
            guard isValidID(incoming.id) else { throw WorkspaceStoreError.invalidSubjectID }
            guard !nextRetired.contains(incoming.id) else { continue }
            var next = incoming
            next.schemaVersion = WorkspaceSubject.currentSchemaVersion
            if let current = subjectsByID[incoming.id] {
                next = mergeSnapshot(
                    current: current,
                    incoming: next,
                    allowUserIntent: false
                )
            }
            nextSubjects[next.id] = next
        }
        if nextSubjects == subjectsByID, nextRetired == retiredSubjectIDs {
            return
        }
        try writeIndex(
            subjects: nextSubjects,
            updates: updatesBySubject,
            clearGeneration: clearGeneration
        )
        subjectsByID = nextSubjects
        retiredSubjectIDs = nextRetired
        epoch += 1
        NotificationCenter.default.post(name: .researchWorkspaceChanged, object: nil)
    }

    func saveUpdates(
        _ updates: [WorkspaceUpdateCandidate],
        for subjectID: String
    ) async throws {
        await ensureLoaded()
        try ensureWritable()
        let incoming = updates.filter { candidate in
            guard candidate.origin == .research, let clearedAt else { return true }
            return candidate.discoveredAt > clearedAt
        }
        let existing = updatesBySubject[subjectID] ?? []
        let canonicalExisting = existing.map { $0.canonicalized() }
        let canonicalIncoming = incoming.map { $0.canonicalized() }
        let oldIDsToNew = Dictionary(
            uniqueKeysWithValues: existing.map { ($0.id, $0.canonicalized().id) }
        )

        var merged: [String: WorkspaceUpdateCandidate] = [:]
        for candidate in Self.prunedUpdates(
            canonicalExisting + canonicalIncoming,
            now: now()
        ) {
            if let current = merged[candidate.id] {
                // The same subject + canonical URL is one lead. Keep the
                // earliest discovery so a later check cannot reset it and keep
                // re-triggering needsReview.
                if candidate.discoveredAt < current.discoveredAt {
                    merged[candidate.id] = candidate
                }
            } else {
                merged[candidate.id] = candidate
            }
        }
        var nextUpdates = updatesBySubject
        nextUpdates[subjectID] = Array(merged.values)
        var nextSubjects = subjectsByID

        if var subject = nextSubjects[subjectID] {
            let mappedPending = subject.pendingUpdateIDs.map { oldIDsToNew[$0] ?? $0 }
            if mappedPending != subject.pendingUpdateIDs {
                subject.pendingUpdateIDs = mappedPending
                nextSubjects[subjectID] = subject
            }
            let report = linkedReportState(subjectID: subjectID)
            let analysisDate = report?.recordedAt ?? subject.lastCheckedAt
            let fresh = Self.sortedUpdates(Array(merged.values)).filter { candidate in
                guard let analysisDate else { return true }
                return candidate.discoveredAt > analysisDate
                    || (candidate.publishedAt ?? .distantPast) > analysisDate
            }
            if !fresh.isEmpty {
                if subject.updateState != .needsReview {
                    subject.updateState = .hasUpdates
                }
                if report?.status == .analyzed, report?.analyzedFingerprint != nil {
                    subject.updateState = .needsReview
                    subject.pendingUpdateIDs = Array(
                        Set(subject.pendingUpdateIDs + fresh.map(\.id))
                    ).sorted()
                }
                if fresh.contains(where: { $0.discoveredAt > (analysisDate ?? .distantPast) }) {
                    subject.markActivity(at: fresh.map(\.discoveredAt).max() ?? now())
                }
                nextSubjects[subjectID] = subject
            }
        }
        try writeIndex(
            subjects: nextSubjects,
            updates: nextUpdates,
            clearGeneration: clearGeneration
        )
        updatesBySubject = nextUpdates
        subjectsByID = nextSubjects
        epoch += 1
        postChanged(subjectID: subjectID)
    }

    // MARK: - Report versions

    func ensureBaselineVersion(
        record: ResearchRecord,
        subjectID: String,
        at date: Date
    ) async throws {
        await ensureLoaded()
        guard !clearedResearchRecordIDs.contains(record.id) else { return }
        guard let report = record.report else { return }
        guard loadVersions(recordID: record.id).isEmpty else { return }
        try await appendVersion(
            WorkspaceReportVersion(
                id: "\(record.id)#1",
                recordID: record.id,
                subjectID: subjectID,
                sequence: 1,
                createdAt: report.generatedAt ?? date,
                trigger: record.run.origin,
                report: report,
                digest: WorkspaceReportDigest.make(report)
            )
        )
    }

    func appendVersion(_ version: WorkspaceReportVersion) async throws {
        await ensureLoaded()
        try ensureWritable()
        guard isValidID(version.recordID) else { throw WorkspaceStoreError.invalidSubjectID }
        // A post-clear observer/reload must not resurrect a version for a
        // record whose history was deleted. Report the failure to the caller
        // so the coordinator does not silently overwrite the old report.
        guard !clearedResearchRecordIDs.contains(version.recordID) else {
            throw WorkspaceStoreError.recordCleared
        }
        var list = loadVersions(recordID: version.recordID)
        // `loadVersions` may isolate a corrupt file and switch to read-only.
        try ensureWritable()
        let digest = version.digest.isEmpty
            ? WorkspaceReportDigest.make(version.report)
            : version.digest
        // A re-run with an identical report must not create a second version.
        guard !list.contains(where: { $0.digest == digest }) else { return }

        let sequence = (list.map(\.sequence).max() ?? 0) + 1
        let canonical = WorkspaceReportVersion(
            id: "\(version.recordID)#\(sequence)",
            recordID: version.recordID,
            subjectID: version.subjectID,
            sequence: sequence,
            createdAt: version.createdAt,
            trigger: version.trigger,
            report: version.report,
            digest: digest,
            evidenceFingerprint: version.evidenceFingerprint,
            analysisSignature: version.analysisSignature
        )
        list.append(canonical)
        list.sort { $0.sequence < $1.sequence }
        if list.count > Self.versionLimit {
            list.removeFirst(list.count - Self.versionLimit)
        }
        // Durable first. A failed write must not leave a cached digest that
        // makes the next attempt skip the old-report archive.
        try writeVersions(list, recordID: version.recordID)
        versionCache[version.recordID] = list
        epoch += 1
    }

    func saveReportState(_ state: WorkspaceReportState) async throws {
        await ensureLoaded()
        try ensureWritable()
        guard isValidID(state.recordID) else { throw WorkspaceStoreError.invalidSubjectID }
        guard !clearedResearchRecordIDs.contains(state.recordID) else { return }
        let data = try JSONEncoder().encode(state)
        try ensureDirectory(statesURL)
        try PrivateFile.write(
            data,
            to: statesURL.appendingPathComponent("\(state.recordID).json"),
            durable: true
        )
        stateCache[state.recordID] = state
        epoch += 1
    }

    // MARK: - Clear history

    /// Drops research links, all report versions and analysis state, then
    /// deletes the rebuildable search index so cleared content cannot leak
    /// through local search. Event links and event evidence are untouched.
    @discardableResult
    func applyHistoryClear(now date: Date) async throws -> Int {
        await ensureLoaded()
        guard !readOnly else { throw WorkspaceStoreError.readOnlyStore }
        let load = ResearchClearIntentStore().load()
        let intentGeneration: Int?
        switch load {
        case .none:
            intentGeneration = nil
        case let .pending(intent):
            if intent.generation > clearGeneration {
                intentGeneration = intent.generation
            } else if intent.generation == 0, clearGeneration == 0 {
                // A damaged intent is still an intent; replay once.
                intentGeneration = 1
            } else {
                intentGeneration = nil
            }
        case .unsupportedVersion:
            // A newer build is clearing. Prune once conservatively and do not
            // pretend nothing happened.
            intentGeneration = clearGeneration == 0 ? 1 : nil
        }
        guard let intentGeneration, intentGeneration > clearGeneration else { return 0 }

        var nextSubjects = subjectsByID
        var nextUpdates = updatesBySubject
        var nextClearedIDs = clearedResearchRecordIDs
        for subject in subjectsByID.values {
            nextClearedIDs.formUnion(subject.researchRecordIDs)
        }

        for (id, var subject) in subjectsByID {
            subject.researchRecordIDs = []
            subject.lookupKeys = subject.lookupKeys.filter {
                !$0.hasPrefix("research:") && !$0.hasPrefix("topic:")
            }
            subject.pendingUpdateIDs = subject.pendingUpdateIDs.filter { updateID in
                (updatesBySubject[id] ?? []).contains { $0.id == updateID }
            }
            if subject.updateState == .needsReview,
               subject.pendingUpdateIDs.isEmpty {
                subject.updateState = .current
            }
            subject.kind = subject.recomputedKind
            subject.markActivity(at: date)
            nextSubjects[id] = subject
        }

        for (subjectID, candidates) in updatesBySubject {
            nextUpdates[subjectID] = candidates.filter { $0.origin != .research }
        }

        // Deletion is part of the operation: a failure must abort before the
        // clear generation/index is published, so the intent stays pending.
        versionCache.removeAll()
        stateCache.removeAll()
        var removed = 0
        removed += try removeAllFiles(in: versionsURL)
        removed += try removeAllFiles(in: statesURL)

        if fileManager.fileExists(atPath: ResearchPaths.workspaceSearchIndexFile.path) {
            do {
                try fileManager.removeItem(at: ResearchPaths.workspaceSearchIndexFile)
            } catch {
                throw WorkspaceStoreError.clearIncomplete
            }
        }
        // Prevent a concurrent baseline/observer from recreating versions even
        // if the final index write fails and the clear intent is retried.
        clearedResearchRecordIDs = nextClearedIDs
        clearedAt = date
        try writeIndex(
            subjects: nextSubjects,
            updates: nextUpdates,
            clearGeneration: intentGeneration
        )

        subjectsByID = nextSubjects
        updatesBySubject = nextUpdates
        clearGeneration = intentGeneration
        epoch += 1
        await WorkspaceSearchIndex.shared.reset()
        NotificationCenter.default.post(name: .researchWorkspaceChanged, object: nil)
        return removed
    }

    // MARK: - Index writes

    private func writeIndex() throws {
        try writeIndex(
            subjects: subjectsByID,
            updates: updatesBySubject,
            clearGeneration: clearGeneration
        )
    }

    /// Candidate-first durable write. Memory is published by the caller only
    /// after this returns.
    private func writeIndex(
        subjects: [String: WorkspaceSubject],
        updates: [String: [WorkspaceUpdateCandidate]],
        clearGeneration: Int
    ) throws {
        let document = IndexDocument(
            updatedAt: now(),
            clearGeneration: clearGeneration,
            subjects: subjects.values.sorted(by: Self.subjectOrder),
            updates: updates.mapValues { Self.sortedUpdates($0) }
        )
        let data = try JSONEncoder().encode(document)
        try ensureDirectory(directoryURL)
        try PrivateFile.write(data, to: indexURL, durable: true)
    }

    private func writeVersions(_ versions: [WorkspaceReportVersion], recordID: String) throws {
        try ensureDirectory(versionsURL)
        let data = try JSONEncoder().encode(versions)
        try PrivateFile.write(
            data,
            to: versionsURL.appendingPathComponent("\(recordID).json"),
            durable: true
        )
    }

    private func loadVersions(recordID: String) -> [WorkspaceReportVersion] {
        if let cached = versionCache[recordID] { return cached }
        let url = versionsURL.appendingPathComponent("\(recordID).json")
        guard fileManager.fileExists(atPath: url.path) else {
            versionCache[recordID] = []
            return []
        }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([WorkspaceReportVersion].self, from: data) else {
            isolateFile(url, prefix: "report-versions")
            versionCache[recordID] = []
            return []
        }
        let sorted = decoded.sorted { $0.sequence < $1.sequence }
        versionCache[recordID] = sorted
        return sorted
    }

    private func loadReportState(recordID: String) -> WorkspaceReportState? {
        if let cached = stateCache[recordID] { return cached }
        let url = statesURL.appendingPathComponent("\(recordID).json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(WorkspaceReportState.self, from: data) else {
            isolateFile(url, prefix: "report-state")
            return nil
        }
        stateCache[recordID] = decoded
        return decoded
    }

    private func linkedReportState(subjectID: String) -> WorkspaceReportState? {
        guard let subject = subjectsByID[subjectID] else { return nil }
        return subject.researchRecordIDs
            .compactMap { loadReportState(recordID: $0) }
            .max { ($0.recordedAt ?? .distantPast) < ($1.recordedAt ?? .distantPast) }
    }

    private func isolateFile(_ url: URL, prefix: String) {
        let stamp = Int(now().timeIntervalSince1970)
        let base = "\(url.deletingPathExtension().lastPathComponent).\(prefix)-corrupt-\(stamp)"
        var target = url.deletingLastPathComponent().appendingPathComponent("\(base).json")
        if fileManager.fileExists(atPath: target.path) {
            target = url.deletingLastPathComponent()
                .appendingPathComponent("\(base)-\(UUID().uuidString).json")
        }
        do {
            try fileManager.moveItem(at: url, to: target)
        } catch {
            // Never let a later write replace bytes that could not be isolated.
            issue = .ioUnavailable
            readOnly = true
        }
    }

    private func removeAllFiles(in directory: URL) throws -> Int {
        guard fileManager.fileExists(atPath: directory.path) else { return 0 }
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw WorkspaceStoreError.clearIncomplete
        }
        var removed = 0
        for url in urls where url.pathExtension.lowercased() == "json"
            && !url.lastPathComponent.contains("-corrupt-") {
            do {
                try fileManager.removeItem(at: url)
                removed += 1
            } catch {
                throw WorkspaceStoreError.clearIncomplete
            }
        }
        return removed
    }

    // MARK: - Helpers

    private func ensureLoaded() async {
        if !didBootstrap { _ = await bootstrap() }
    }

    private func ensureWritable() throws {
        guard !readOnly else { throw WorkspaceStoreError.readOnlyStore }
    }

    private func ensureDirectories() {
        for directory in [directoryURL, versionsURL, statesURL] {
            try? PrivateFile.ensureDirectory(directory)
        }
    }

    private func ensureDirectory(_ directory: URL) throws {
        try PrivateFile.ensureDirectory(directory)
    }

    private func sortedSubjects() -> [WorkspaceSubject] {
        subjectsByID.values.sorted(by: Self.subjectOrder)
    }

    private static func subjectOrder(_ lhs: WorkspaceSubject, _ rhs: WorkspaceSubject) -> Bool {
        if lhs.lastActivityAt != rhs.lastActivityAt {
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
        if lhs.title != rhs.title { return lhs.title < rhs.title }
        return lhs.id < rhs.id
    }

    private func postChanged(subjectID: String?) {
        let info = subjectID.map { ["subjectID": $0] }
        NotificationCenter.default.post(
            name: .researchWorkspaceChanged,
            object: nil,
            userInfo: info
        )
    }

    private func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".." && !id.contains("/") && !id.contains("\\")
    }

    private func canonicalID(for id: String) -> String? {
        if subjectsByID[id] != nil { return id }
        return subjectsByID.values.first {
            $0.lookupKeys.contains("subject:\(id)")
        }?.id
    }

    private static func redirectedIDs(
        in subjects: Dictionary<String, WorkspaceSubject>.Values
    ) -> Set<String> {
        var output: Set<String> = []
        for subject in subjects {
            for key in subject.lookupKeys where key.hasPrefix("subject:") {
                let id = String(key.dropFirst("subject:".count))
                if !id.isEmpty { output.insert(id) }
            }
        }
        return output
    }

    private static func strongest(
        _ lhs: WorkspaceUpdateState,
        _ rhs: WorkspaceUpdateState
    ) -> WorkspaceUpdateState {
        func rank(_ value: WorkspaceUpdateState) -> Int {
            switch value {
            case .current: return 0
            case .hasUpdates: return 1
            case .needsReview: return 2
            }
        }
        return rank(lhs) >= rank(rhs) ? lhs : rhs
    }

    private func mergeSnapshot(
        current: WorkspaceSubject,
        incoming: WorkspaceSubject,
        allowUserIntent: Bool
    ) -> WorkspaceSubject {
        var next = incoming
        next.schemaVersion = WorkspaceSubject.currentSchemaVersion
        next.researchRecordIDs = Self.orderedUnion(
            current.researchRecordIDs,
            next.researchRecordIDs
        )
        next.eventIDs = Self.orderedUnion(current.eventIDs, next.eventIDs)
        next.lookupKeys = Self.orderedUnion(current.lookupKeys, next.lookupKeys)
        next.researchRecordIDs.removeAll { clearedResearchRecordIDs.contains($0) }
        next.lookupKeys.removeAll { key in
            guard key.hasPrefix("research:") else { return false }
            return clearedResearchRecordIDs.contains(String(key.dropFirst("research:".count)))
        }
        next.aliases = Self.uniqueAliases(
            current.aliases + next.aliases,
            title: next.title
        )
        next.kind = next.recomputedKind

        if allowUserIntent {
            next.userRevision = max(next.userRevision, current.userRevision)
        } else {
            next.isFollowed = current.isFollowed
            next.isArchived = current.isArchived
            next.archivedAt = current.archivedAt
            next.seedURL = current.seedURL
            next.userRevision = current.userRevision
        }

        // A stale snapshot can never drop a lead acknowledged/saved by another
        // task; explicit acknowledgement goes through `updateSubject`.
        next.pendingUpdateIDs = Self.orderedUnion(
            current.pendingUpdateIDs,
            next.pendingUpdateIDs
        )
        next.updateState = Self.strongest(current.updateState, next.updateState)
        if !next.pendingUpdateIDs.isEmpty, next.updateState == .current {
            next.updateState = .hasUpdates
        }
        if current.updatedAt > incoming.updatedAt {
            // A reconcile snapshot taken before an observer/checker commit must
            // not re-promote an already acknowledged subject.
            next.pendingUpdateIDs = current.pendingUpdateIDs
            next.updateState = current.updateState
        }

        if (next.lastCheckedAt ?? .distantPast) < (current.lastCheckedAt ?? .distantPast) {
            next.lastCheckedAt = current.lastCheckedAt
            next.lastCheckOutcome = current.lastCheckOutcome
        }
        if (next.lastNotifiedAt ?? .distantPast) < (current.lastNotifiedAt ?? .distantPast) {
            next.lastNotifiedAt = current.lastNotifiedAt
            next.lastNotificationKind = current.lastNotificationKind
            next.lastNotifiedReference = current.lastNotifiedReference
        }
        if next.updatedAt < current.updatedAt {
            next.updatedAt = current.updatedAt
        }
        if next.lastActivityAt < current.lastActivityAt {
            next.lastActivityAt = current.lastActivityAt
        }
        return next
    }

    private static func userStateChanged(
        _ lhs: WorkspaceSubject,
        _ rhs: WorkspaceSubject
    ) -> Bool {
        lhs.isFollowed != rhs.isFollowed
            || lhs.isArchived != rhs.isArchived
            || lhs.archivedAt != rhs.archivedAt
            || lhs.lastCheckedAt != rhs.lastCheckedAt
            || lhs.lastCheckOutcome != rhs.lastCheckOutcome
            || lhs.pendingUpdateIDs != rhs.pendingUpdateIDs
            || lhs.lastNotifiedAt != rhs.lastNotifiedAt
            || lhs.lastNotificationKind != rhs.lastNotificationKind
            || lhs.lastNotifiedReference != rhs.lastNotifiedReference
    }

    private static func orderedUnion(_ lhs: [String], _ rhs: [String]) -> [String] {
        var seen = Set(lhs)
        var output = lhs
        for value in rhs where seen.insert(value).inserted {
            output.append(value)
        }
        return output
    }

    private static func uniqueAliases(_ aliases: [String], title: String) -> [String] {        let titleKey = TopicFingerprint.normalized(title)
        var seen: Set<String> = []
        var output: [String] = []
        for alias in aliases {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = TopicFingerprint.normalized(trimmed)
            guard !trimmed.isEmpty, !key.isEmpty, key != titleKey,
                  seen.insert(key).inserted else { continue }
            output.append(trimmed)
        }
        return output
    }

    private static func prunedUpdates(
        _ updates: [WorkspaceUpdateCandidate],
        now: Date
    ) -> [WorkspaceUpdateCandidate] {
        let cutoff = now.addingTimeInterval(-updateRetention)
        return sortedUpdates(updates.filter { $0.discoveredAt >= cutoff })
    }

    private static func sortedUpdates(
        _ updates: [WorkspaceUpdateCandidate]
    ) -> [WorkspaceUpdateCandidate] {
        updates.sorted { lhs, rhs in
            if lhs.discoveredAt != rhs.discoveredAt {
                return lhs.discoveredAt > rhs.discoveredAt
            }
            return lhs.id < rhs.id
        }
    }
}
