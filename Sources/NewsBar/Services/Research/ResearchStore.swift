import Foundation

enum ResearchPaths {
    static var applicationSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.newsbar.app", isDirectory: true)
    }

    static var researchDirectory: URL {
        applicationSupportRoot.appendingPathComponent("Research", isDirectory: true)
    }

    static var researchCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.newsbar.app/ResearchCache", isDirectory: true)
    }

    static var ledgerFile: URL {
        researchDirectory.appendingPathComponent("ledger.json")
    }

    static var clearIntentFile: URL {
        researchDirectory.appendingPathComponent("clear-intent.json")
    }
}

/// Lightweight projection of a record for list rendering and index rebuilds.
struct ResearchIndexEntry: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let topicKey: String
    let origin: ResearchOrigin
    let topic: String
    let status: ResearchStatus
    let source: NewsSource
    let createdAt: Date
    let lastSeenAt: Date
    let updatedAt: Date
    let lastAccessedAt: Date
    let isPinned: Bool
    let isRead: Bool
    let reportVersion: Int
    let strength: Int
    let verdict: VerificationReport.Verdict?
    let hasReport: Bool
    let aliasCount: Int
    var issue: ResearchEntryIssue?
    /// Version recorded when the projection was written. `nil` means the index
    /// predates the field, so the bootstrap probes that file once.
    var schemaVersion: Int?

    init(record: ResearchRecord, issue: ResearchEntryIssue? = nil) {
        id = record.id
        topicKey = record.topicKey
        origin = record.origin
        topic = record.topic
        status = record.status
        source = record.seed.source
        createdAt = record.createdAt
        lastSeenAt = record.lastSeenAt
        updatedAt = record.updatedAt
        lastAccessedAt = record.lastAccessedAt
        isPinned = record.isPinned
        isRead = record.isRead
        reportVersion = record.reportVersion
        strength = record.strength
        verdict = record.report?.verification?.verdict
        hasReport = record.report != nil
        aliasCount = record.aliases.count
        self.issue = issue
        schemaVersion = record.schemaVersion
    }
}

struct ResearchStoreMeta: Codable, Hashable, Sendable {
    var version = 1
    var legacyImportVersion = 0
    var ledgerMigrationVersion = 0
    /// 1 once the one-time owner-only tightening and temporary-file sweep has
    /// completed. Without it, every launch would lstat every record.
    var permissionsVersion = 0
    var lastMaintenanceAt: Date?
    var updatedAt: Date?

    init() {}

    enum CodingKeys: String, CodingKey {
        case version, legacyImportVersion, ledgerMigrationVersion, permissionsVersion
        case lastMaintenanceAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        legacyImportVersion = try container.decodeIfPresent(Int.self, forKey: .legacyImportVersion) ?? 0
        ledgerMigrationVersion = try container.decodeIfPresent(Int.self, forKey: .ledgerMigrationVersion) ?? 0
        permissionsVersion = try container.decodeIfPresent(Int.self, forKey: .permissionsVersion) ?? 0
        lastMaintenanceAt = try container.decodeIfPresent(Date.self, forKey: .lastMaintenanceAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

struct ResearchStoreBootstrap: Sendable, Equatable {
    var entries: [ResearchIndexEntry] = []
    var interruptedIDs: [String] = []
    var corruptIDs: [String] = []
    var unsupportedVersionIDs: [String] = []
    var rebuiltIndex = false
}

enum ResearchMetaAvailability: Sendable, Equatable {
    case available
    case corrupt
    case ioUnavailable
    case unsupportedVersion

    var isWritable: Bool { self == .available }
}

enum ResearchStoreError: Error, Equatable {
    case invalidRecordID
    /// The record file was written by a newer build, or could not be read
    /// reliably. Writing would destroy bytes this build does not understand.
    case readOnlyRecord
    case readOnlyMeta
}

protocol ResearchPersisting: Sendable {
    func bootstrap() async -> ResearchStoreBootstrap
    func index() async -> [ResearchIndexEntry]
    func records() async -> [ResearchRecord]
    func record(id: String) async -> ResearchRecord?
    func latestRecord(topicKey: String) async -> ResearchRecord?
    func burstSummary() async -> ResearchSummary
    func touch(id: String, at date: Date) async
    func deleteAll() async throws
    func storageFootprint() async -> Int64
    func save(_ record: ResearchRecord) async throws
    /// Batch write used by the one-time legacy import: records first, index once.
    func saveAll(_ records: [ResearchRecord]) async throws
    func saveProgress(_ record: ResearchRecord) async
    func flushPendingWrites() async
    func delete(id: String) async throws
    @discardableResult
    func enforceLimits(
        now: Date,
        historyLimit: Int,
        retentionDays: Int,
        excluding: Set<String>
    ) async -> [String]
    func meta() async -> ResearchStoreMeta
    func metaAvailability() async -> ResearchMetaAvailability
    /// Bumped by `deleteAll`. A stale import that finishes afterwards can
    /// notice the change and remove what it just wrote.
    func dataEpoch() async -> Int
    @discardableResult
    func updateMeta(_ transform: @Sendable (inout ResearchStoreMeta) -> Void) async -> Bool
    /// Dry run for the settings confirmation: number of records the proposed
    /// limits would remove. Pinned, active and corrupt records are exempt.
    func previewEnforcement(now: Date, historyLimit: Int, retentionDays: Int) async -> Int
}

extension ResearchPersisting {
    func saveAll(_ records: [ResearchRecord]) async throws {
        for record in records {
            try await save(record)
        }
    }

    func latestRecord(topicKey: String) async -> ResearchRecord? { nil }
    func burstSummary() async -> ResearchSummary { .zero }
    func touch(id: String, at date: Date) async {}
    func deleteAll() async throws {}
    func storageFootprint() async -> Int64 { 0 }

    @discardableResult
    func enforceLimits(
        now: Date,
        historyLimit: Int,
        retentionDays: Int,
        excluding: Set<String>
    ) async -> [String] {
        []
    }

    func meta() async -> ResearchStoreMeta { ResearchStoreMeta() }

    func metaAvailability() async -> ResearchMetaAvailability { .available }

    func dataEpoch() async -> Int { 0 }

    @discardableResult
    func updateMeta(_ transform: @Sendable (inout ResearchStoreMeta) -> Void) async -> Bool {
        false
    }

    func previewEnforcement(now: Date, historyLimit: Int, retentionDays: Int) async -> Int {
        0
    }
}

/// Record-per-file store. `records/<id>.json` is authoritative; `index.json` is
/// a derived list projection that can always be rebuilt. Writes are atomic and
/// progress updates are throttled to at most one per second per record.
actor ResearchStore: ResearchPersisting {
    static let shared = ResearchStore()

    private struct IndexDocument: Codable {
        var version = 1
        var updatedAt: Date
        var entries: [ResearchIndexEntry]
    }

    private let directoryURL: URL
    private let recordsURL: URL
    private let indexURL: URL
    private let metaURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    private var entries: [String: ResearchIndexEntry] = [:]
    private var metaState = ResearchStoreMeta()
    private var metaLoaded = false
    private var pending: [String: ResearchRecord] = [:]
    private var lastProgressWrite: [String: Date] = [:]
    private var flushTask: Task<Void, Never>?
    private var didBootstrap = false
    /// IDs removed by the user. A late progress callback or `touch` must not
    /// resurrect a record after deletion.
    private var deletedIDs: Set<String> = []
    /// IDs whose file must not be written back: a newer schema, corrupt JSON,
    /// or an unreadable file. Reading keeps working for corrupt files via a
    /// placeholder; writing never silently replaces the original bytes.
    private var readOnlyIDs: Set<String> = []
    private var issues: [String: ResearchEntryIssue] = [:]
    private var metaAvailabilityState: ResearchMetaAvailability = .available
    private var epoch = 0
    private var lastIndexWrite: Date = .distantPast

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let directory = directoryURL ?? ResearchPaths.researchDirectory
        self.directoryURL = directory
        self.recordsURL = directory.appendingPathComponent("records", isDirectory: true)
        self.indexURL = directory.appendingPathComponent("index.json")
        self.metaURL = directory.appendingPathComponent("meta.json")
        self.fileManager = fileManager
        self.now = now
    }

    deinit {
        flushTask?.cancel()
    }

    func bootstrap() async -> ResearchStoreBootstrap {
        if didBootstrap {
            return ResearchStoreBootstrap(entries: sortedEntries())
        }

        ensureDirectories()
        loadMeta()
        tightenExistingFilesIfNeeded()

        var result = ResearchStoreBootstrap()
        let files = recordFileURLs()
        var indexUpdatedAt = now()

        if let data = try? Data(contentsOf: indexURL),
           let document = try? JSONDecoder().decode(IndexDocument.self, from: data),
           document.version == 1,
           Set(document.entries.map(\.id)) == Set(files.keys),
           Set(document.entries.map(\.id)).count == document.entries.count {
            entries = Dictionary(uniqueKeysWithValues: document.entries.map { ($0.id, $0) })
            indexUpdatedAt = document.updatedAt
        } else {
            result.rebuiltIndex = true
            rebuildIndex(into: &result)
        }

        // Probe after the index is available: a trusted projection carries
        // each record's schema version, so a normal launch reads no record
        // files at all.
        probeFileIssues(files, newerThan: indexUpdatedAt)
        if !issues.isEmpty {
            for id in entries.keys {
                entries[id]?.issue = issues[id]
            }
        }

        let activeIDs = entries.values.filter { $0.status.isActive }.map(\.id)
        var healedIndex = false
        for id in activeIDs {
            if readOnlyIDs.contains(id) {
                let date = modificationDate(of: recordURL(for: id)) ?? now()
                entries[id] = ResearchIndexEntry(
                    record: placeholder(id: id, date: date, issue: issues[id] ?? .corrupt),
                    issue: issues[id] ?? .corrupt
                )
                healedIndex = true
                continue
            }
            guard var record = decodeRecord(id: id) else {
                let date = modificationDate(of: recordURL(for: id)) ?? now()
                let issue = issues[id] ?? .corrupt
                entries[id] = ResearchIndexEntry(
                    record: placeholder(id: id, date: date, issue: issue),
                    issue: issue
                )
                healedIndex = true
                continue
            }
            // The index is only a projection. A record that finished after the
            // last index write must not be rewritten as "interrupted"; heal the
            // stale entry from the authoritative file instead.
            guard record.status.isActive else {
                entries[id] = ResearchIndexEntry(record: record)
                healedIndex = true
                continue
            }
            record.status = .interrupted
            record.run.phase = .done
            record.run.lastError = "App 退出中断"
            if record.run.finishedAt == nil { record.run.finishedAt = now() }
            do {
                try writeRecord(record)
                entries[id] = ResearchIndexEntry(record: record)
                result.interruptedIDs.append(id)
            } catch {
                // Keep the previous entry; a later save or rebuild will retry.
            }
        }

        var corrupt: [String] = []
        var unsupported: [String] = []
        for entry in entries.values {
            switch entry.issue {
            case .corrupt, .ioUnavailable:
                corrupt.append(entry.id)
            case .unsupportedVersion:
                unsupported.append(entry.id)
            case nil:
                break
            }
        }
        result.corruptIDs = corrupt.sorted()
        result.unsupportedVersionIDs = unsupported.sorted()
        result.entries = sortedEntries()

        if result.rebuiltIndex || healedIndex || !result.interruptedIDs.isEmpty {
            writeIndexBestEffort()
        }
        didBootstrap = true
        return result
    }

    func index() async -> [ResearchIndexEntry] {
        if !didBootstrap { _ = await bootstrap() }
        return sortedEntries()
    }

    func records() async -> [ResearchRecord] {
        if !didBootstrap { _ = await bootstrap() }
        return sortedEntries().map { entry in
            if let pending = pending[entry.id] { return pending }
            if let record = decodeRecord(id: entry.id) { return record }
            return placeholder(
                id: entry.id,
                date: entry.updatedAt,
                issue: entry.issue ?? issues[entry.id] ?? .corrupt
            )
        }
    }

    func record(id: String) async -> ResearchRecord? {
        if !didBootstrap { _ = await bootstrap() }
        guard isSafeID(id) else { return nil }
        if let pending = pending[id] { return pending }
        if let record = decodeRecord(id: id) { return record }
        guard let entry = entries[id] else { return nil }
        return placeholder(
            id: id,
            date: entry.updatedAt,
            issue: entry.issue ?? issues[id] ?? .corrupt
        )
    }

    /// Latest record for an exact topic key. Used by auto-detection and the
    /// legacy burst shim; fuzzy matching is a separate, stricter policy.
    func latestRecord(topicKey: String) async -> ResearchRecord? {
        if !didBootstrap { _ = await bootstrap() }
        let candidates = entries.values
            .filter { $0.topicKey == topicKey }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
        for entry in candidates {
            if let record = decodeRecord(id: entry.id) { return record }
        }
        return nil
    }

    func burstSummary() async -> ResearchSummary {
        if !didBootstrap { _ = await bootstrap() }
        let bursts = entries.values.filter { $0.origin == .burst }
        return ResearchSummary(
            burstCount: bursts.count,
            unreadBurstCount: bursts.filter { !$0.isRead }.count
        )
    }

    /// Selection-side access bump. Writes at most once per 10 minutes.
    func touch(id: String, at date: Date = Date()) async {
        guard var record = await record(id: id), record.status != .corrupt else { return }
        guard date.timeIntervalSince(record.lastAccessedAt) > 600 else { return }
        record.lastAccessedAt = date
        try? await save(record)
    }

    /// Removes every authoritative record. Cache files are intentionally left
    /// to `ResearchCacheStore`, which owns their TTL and byte budget.
    func deleteAll() async throws {
        if !didBootstrap { _ = await bootstrap() }
        epoch += 1
        flushTask?.cancel()
        flushTask = nil
        pending.removeAll()
        let fileIDs = Set(recordFileURLs().keys)
        deletedIDs.formUnion(entries.keys)
        deletedIDs.formUnion(fileIDs)
        trimTombstones()
        for url in recordFileURLs().values {
            try fileManager.removeItem(at: url)
        }
        entries.removeAll()
        lastProgressWrite.removeAll()
        writeIndexBestEffort()
    }

    func save(_ record: ResearchRecord) async throws {
        if !didBootstrap { _ = await bootstrap() }
        guard isSafeID(record.id) else { throw ResearchStoreError.invalidRecordID }
        guard !isReadOnly(record.id) else { throw ResearchStoreError.readOnlyRecord }
        guard !deletedIDs.contains(record.id) else { return }
        try ensureDirectoriesThrowing()
        try writeRecord(record)
        entries[record.id] = ResearchIndexEntry(record: record)
        pending.removeValue(forKey: record.id)
        lastProgressWrite[record.id] = now()
        writeIndexBestEffort()
    }

    /// Writes record files first and refreshes the derived index once. Used by
    /// the legacy import so 500 records do not produce 500 index rewrites.
    func saveAll(_ records: [ResearchRecord]) async throws {
        guard !records.isEmpty else { return }
        if !didBootstrap { _ = await bootstrap() }
        for record in records {
            guard isSafeID(record.id) else { throw ResearchStoreError.invalidRecordID }
        }
        guard records.allSatisfy({ !isReadOnly($0.id) }) else {
            throw ResearchStoreError.readOnlyRecord
        }
        try ensureDirectoriesThrowing()
        for record in records {
            guard !deletedIDs.contains(record.id) else { continue }
            try writeRecord(record)
            entries[record.id] = ResearchIndexEntry(record: record)
            pending.removeValue(forKey: record.id)
            lastProgressWrite[record.id] = now()
        }
        writeIndexBestEffort()
    }

    func saveProgress(_ record: ResearchRecord) async {
        if !didBootstrap { _ = await bootstrap() }
        guard isSafeID(record.id),
              !deletedIDs.contains(record.id),
              !isReadOnly(record.id) else { return }

        let terminal = record.status != .running || record.run.finishedAt != nil
        if terminal {
            try? await save(record)
            await flushPendingWrites()
            return
        }

        let current = now()
        let last = lastProgressWrite[record.id] ?? .distantPast
        if current.timeIntervalSince(last) >= 1 {
            pending.removeValue(forKey: record.id)
            do {
                // Progress rewrites only the record file. The derived index is
                // refreshed at most every 10 seconds, so a long run no longer
                // re-encodes every entry once per tick.
                try writeRecord(record)
                entries[record.id] = ResearchIndexEntry(record: record)
                lastProgressWrite[record.id] = current
                writeIndexThrottled()
            } catch {
                pending[record.id] = record
                scheduleFlush()
            }
        } else {
            pending[record.id] = record
            scheduleFlush()
        }
    }

    func flushPendingWrites() async {
        flushTask?.cancel()
        flushTask = nil
        guard !pending.isEmpty else { return }
        let records = pending.values.sorted { $0.id < $1.id }
        pending.removeAll()
        for record in records {
            try? await save(record)
        }
    }

    func delete(id: String) async throws {
        if !didBootstrap { _ = await bootstrap() }
        guard isSafeID(id) else { throw ResearchStoreError.invalidRecordID }
        deletedIDs.insert(id)
        readOnlyIDs.remove(id)
        issues.removeValue(forKey: id)
        trimTombstones()
        let url = recordURL(for: id)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        entries.removeValue(forKey: id)
        pending.removeValue(forKey: id)
        lastProgressWrite.removeValue(forKey: id)
        writeIndexBestEffort()
    }

    @discardableResult
    func enforceLimits(
        now date: Date,
        historyLimit: Int,
        retentionDays: Int,
        excluding: Set<String> = []
    ) async -> [String] {
        if !didBootstrap { _ = await bootstrap() }

        var removed: [String] = []

        func isProtected(_ entry: ResearchIndexEntry) -> Bool {
            entry.isPinned
                || excluding.contains(entry.id)
                || entry.status.isActive
                || entry.status == .corrupt
                || entry.issue != nil
        }

        if retentionDays > 0 {
            let cutoff = date.addingTimeInterval(-Double(retentionDays) * 86_400)
            for entry in sortedEntries() where entry.updatedAt < cutoff && !isProtected(entry) {
                if removeRecord(id: entry.id) { removed.append(entry.id) }
            }
        }

        if historyLimit >= 0 {
            while entries.count > historyLimit {
                let candidates = entries.values.filter { !isProtected($0) }
                guard let victim = candidates.min(by: evictionOrder) else {
                    break
                }
                if removeRecord(id: victim.id) {
                    removed.append(victim.id)
                } else {
                    break
                }
            }
        }

        // Safety net only; normal limits are count- and age-based.
        let byteCap: Int64 = 200 * 1024 * 1024
        var total = storageBytes()
        if total > byteCap {
            let candidates = entries.values
                .filter { !isProtected($0) }
                .sorted(by: evictionOrder)
            for victim in candidates {
                guard total > byteCap else { break }
                let size = fileSize(recordURL(for: victim.id))
                if removeRecord(id: victim.id) {
                    total -= size
                    removed.append(victim.id)
                }
            }
        }

        if metaAvailabilityState.isWritable {
            metaState.lastMaintenanceAt = date
            metaState.updatedAt = date
            if (try? writeMeta(metaState)) == nil {
                metaAvailabilityState = .ioUnavailable
            }
        }
        if !removed.isEmpty { writeIndexBestEffort() }
        return removed
    }

    /// Counts what `enforceLimits` would delete at the proposed limits without
    /// touching disk. Uses the same protection rules so the confirmation shown
    /// to the user matches the subsequent enforcement pass.
    func previewEnforcement(now date: Date, historyLimit: Int, retentionDays: Int) async -> Int {
        if !didBootstrap { _ = await bootstrap() }

        func isProtected(_ entry: ResearchIndexEntry) -> Bool {
            entry.isPinned
                || entry.status.isActive
                || entry.status == .corrupt
                || entry.issue != nil
        }

        var remainingIDs = Set(entries.keys)
        var removed = 0

        if retentionDays > 0 {
            let cutoff = date.addingTimeInterval(-Double(retentionDays) * 86_400)
            for entry in entries.values where entry.updatedAt < cutoff && !isProtected(entry) {
                guard remainingIDs.remove(entry.id) != nil else { continue }
                removed += 1
            }
        }

        if historyLimit >= 0, remainingIDs.count > historyLimit {
            let candidates = entries.values.filter {
                remainingIDs.contains($0.id) && !isProtected($0)
            }
            removed += min(remainingIDs.count - historyLimit, candidates.count)
        }

        return removed
    }

    func meta() async -> ResearchStoreMeta {
        reloadMetaAfterTransientFailure()
        loadMeta()
        return metaState
    }

    func metaAvailability() async -> ResearchMetaAvailability {
        reloadMetaAfterTransientFailure()
        loadMeta()
        return metaAvailabilityState
    }

    func dataEpoch() async -> Int {
        epoch
    }

    @discardableResult
    func updateMeta(_ transform: @Sendable (inout ResearchStoreMeta) -> Void) async -> Bool {
        reloadMetaAfterTransientFailure()
        loadMeta()
        var next = metaState
        transform(&next)
        next.updatedAt = now()
        guard metaAvailabilityState.isWritable else { return false }
        do {
            try ensureDirectoriesThrowing()
            try writeMeta(next)
            metaState = next
            return true
        } catch ResearchStoreError.readOnlyMeta {
            metaAvailabilityState = .unsupportedVersion
            return false
        } catch {
            metaAvailabilityState = .ioUnavailable
            return false
        }
    }

    /// Total bytes of authoritative record files. Cache files are accounted for
    /// separately by `ResearchCacheStore`.
    func storageBytes() -> Int64 {
        recordFileURLs().values.reduce(Int64(0)) { $0 + fileSize($1) }
    }

    func storageFootprint() async -> Int64 {
        storageBytes()
    }

    // MARK: - Index

    private func rebuildIndex(into result: inout ResearchStoreBootstrap) {
        entries = [:]
        var scanned: [ResearchIndexEntry] = []
        for (id, url) in recordFileURLs() {
            if let record = decodeRecord(at: url), record.id == id {
                scanned.append(ResearchIndexEntry(record: record))
            } else {
                let date = modificationDate(of: url) ?? now()
                let issue = issues[id] ?? .corrupt
                scanned.append(
                    ResearchIndexEntry(
                        record: placeholder(id: id, date: date, issue: issue),
                        issue: issue
                    )
                )
            }
        }
        // Every record file is visible. A truncated index used to hide files
        // beyond the first 1000, which made them impossible to delete or evict.
        entries = Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, $0) })
        result.rebuiltIndex = true
    }

    private func sortedEntries() -> [ResearchIndexEntry] {
        entries.values.sorted(by: indexOrder)
    }

    private func indexOrder(_ lhs: ResearchIndexEntry, _ rhs: ResearchIndexEntry) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        if lhs.topic != rhs.topic { return lhs.topic < rhs.topic }
        return lhs.id < rhs.id
    }

    /// Deterministic eviction order. Dictionary iteration order is not stable,
    /// so ties must fall back to durable fields or the same run deletes a
    /// different record every time.
    private func evictionOrder(_ lhs: ResearchIndexEntry, _ rhs: ResearchIndexEntry) -> Bool {
        if lhs.lastAccessedAt != rhs.lastAccessedAt { return lhs.lastAccessedAt < rhs.lastAccessedAt }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
        return lhs.id < rhs.id
    }

    private func writeIndexBestEffort() {
        do {
            try writeIndex()
            lastIndexWrite = now()
        } catch {
            // The record is authoritative; the next bootstrap rebuilds the index.
        }
    }

    private func writeIndexThrottled() {
        let current = now()
        guard current.timeIntervalSince(lastIndexWrite) >= 10 else { return }
        lastIndexWrite = current
        writeIndexBestEffort()
    }

    private func trimTombstones() {
        if deletedIDs.count > 2_000 {
            deletedIDs = Set(Array(deletedIDs).suffix(1_000))
        }
    }

    private func writeIndex() throws {
        try ensureDirectoriesThrowing()
        let document = IndexDocument(updatedAt: now(), entries: sortedEntries())
        let data = try JSONEncoder().encode(document)
        try PrivateFile.write(data, to: indexURL, durable: false)
    }

    // MARK: - Files

    private func ensureDirectories() {
        try? ensureDirectoriesThrowing()
    }

    private func ensureDirectoriesThrowing() throws {
        try PrivateFile.ensureDirectory(directoryURL)
        try PrivateFile.ensureDirectory(recordsURL)
    }

    /// Owner-only tightening for files written before the atomic private
    /// writer existed, plus a sweep of crash-left temporary files. Runs once
    /// per store version; the marker keeps normal launches free of 1000-document
    /// `lstat` walks.
    private func tightenExistingFilesIfNeeded() {
        guard metaState.permissionsVersion < 1 else { return }
        var failures = 0
        for url in [indexURL, metaURL] + recordFileURLs().values {
            if !PrivateFile.tightenExistingFile(url) {
                failures += 1
            }
        }
        if failures > 0 {
            NSLog(
                "[ResearchStore] could not tighten %ld research file(s)",
                failures
            )
        }
        _ = PrivateFile.removeStaleTemporaries(
            in: recordsURL,
            olderThan: now().addingTimeInterval(-3_600),
            now: now(),
            fileManager: fileManager
        )
        // Ledger and clear-intent temporaries live in the research root.
        _ = PrivateFile.removeStaleTemporaries(
            in: directoryURL,
            olderThan: now().addingTimeInterval(-3_600),
            now: now(),
            fileManager: fileManager
        )
        guard metaAvailabilityState.isWritable else { return }
        var next = metaState
        next.permissionsVersion = 1
        next.updatedAt = now()
        if (try? writeMeta(next)) != nil {
            metaState = next
        }
    }

    private func recordFileURLs() -> [String: URL] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: recordsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var result: [String: URL] = [:]
        for url in urls where url.pathExtension.lowercased() == "json" {
            let id = url.deletingPathExtension().lastPathComponent
            guard isSafeID(id) else { continue }
            result[id] = url
        }
        return result
    }

    private func recordURL(for id: String) -> URL {
        recordsURL.appendingPathComponent("\(id).json")
    }

    private func writeRecord(_ record: ResearchRecord) throws {
        let data = try JSONEncoder().encode(record)
        try PrivateFile.write(data, to: recordURL(for: record.id), durable: false)
    }

    private func decodeRecord(id: String) -> ResearchRecord? {
        decodeRecord(at: recordURL(for: id))
    }

    private func decodeRecord(at url: URL) -> ResearchRecord? {
        let id = url.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            issues[id] = .ioUnavailable
            readOnlyIDs.insert(id)
            return nil
        }
        guard let version = Self.probeRecordSchemaVersion(data) else {
            issues[id] = .corrupt
            readOnlyIDs.insert(id)
            return nil
        }
        guard version <= ResearchRecord.currentSchemaVersion else {
            issues[id] = .unsupportedVersion
            readOnlyIDs.insert(id)
            return nil
        }
        guard let record = try? JSONDecoder().decode(ResearchRecord.self, from: data) else {
            issues[id] = .corrupt
            readOnlyIDs.insert(id)
            return nil
        }
        issues.removeValue(forKey: id)
        readOnlyIDs.remove(id)
        return record.normalizedForRead()
    }

    private func isReadOnly(_ id: String) -> Bool {
        readOnlyIDs.contains(id) || issues[id] != nil
    }

    private func placeholder(
        id: String,
        date: Date,
        issue: ResearchEntryIssue
    ) -> ResearchRecord {
        var record = ResearchRecord.corruptPlaceholder(id: id, date: date)
        record.loadIssue = issue
        switch issue {
        case .unsupportedVersion:
            record.run.lastError = "Record was written by a newer app version"
            record.isRead = true
        case .ioUnavailable:
            record.run.lastError = "Record file is temporarily unreadable"
        case .corrupt:
            break
        }
        return record
    }

    /// Eager, prefix-free version probe. Records are small; a full read keeps
    /// the check exact instead of guessing from a truncated JSON prefix.
    private func probeFileIssues(_ files: [String: URL], newerThan: Date) {
        for (id, url) in files {
            // A projection may already carry a read-only issue (for example
            // after a rebuild). Restore the write gate before the fast path,
            // otherwise a skipped probe would make the record writable again.
            if let existingIssue = entries[id]?.issue {
                issues[id] = existingIssue
                readOnlyIDs.insert(id)
            }

            // The projection carries the version, so a normal launch does not
            // re-read all record files. A file modified after the index was
            // written (for example a newer build crashed before updating the
            // projection) is always probed. A missing value is probed once and
            // then written back by the next index update.
            let modifiedAfterIndex = (modificationDate(of: url) ?? .distantPast) > newerThan
            if let projected = entries[id]?.schemaVersion, !modifiedAfterIndex {
                if projected > ResearchRecord.currentSchemaVersion {
                    issues[id] = .unsupportedVersion
                    readOnlyIDs.insert(id)
                } else {
                    issues.removeValue(forKey: id)
                    readOnlyIDs.remove(id)
                }
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                issues[id] = .ioUnavailable
                readOnlyIDs.insert(id)
                continue
            }
            guard let version = Self.probeRecordSchemaVersion(data) else {
                issues[id] = .corrupt
                readOnlyIDs.insert(id)
                continue
            }
            if version > ResearchRecord.currentSchemaVersion {
                issues[id] = .unsupportedVersion
                readOnlyIDs.insert(id)
            } else {
                issues.removeValue(forKey: id)
                readOnlyIDs.remove(id)
            }
        }
    }

    private static func probeRecordSchemaVersion(_ data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let version = object["schemaVersion"] as? Int { return version }
        // Files written before the field existed are v1 only when their
        // authoritative identity is present.
        return object["id"] != nil && object["topicKey"] != nil
            ? ResearchRecord.currentSchemaVersion
            : nil
    }

    private static func probeMetaVersion(_ data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let version = object["version"] as? Int { return version }
        return ResearchStoreMeta().version
    }

    private func removeRecord(id: String) -> Bool {
        let url = recordURL(for: id)
        if fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                return false
            }
        }
        entries.removeValue(forKey: id)
        pending.removeValue(forKey: id)
        lastProgressWrite.removeValue(forKey: id)
        return true
    }

    private func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func fileSize(_ url: URL) -> Int64 {
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return Int64(size ?? 0)
    }

    private func isSafeID(_ id: String) -> Bool {
        !id.isEmpty
            && id != "."
            && id != ".."
            && !id.contains("/")
            && !id.contains("\\")
            && !id.contains("..")
    }

    // MARK: - Meta

    /// A missing or unreadable file may become readable later (permissions
    /// repair, external volume). Corrupt or newer-version files are stable and
    /// must not be re-read on every call.
    private func reloadMetaAfterTransientFailure() {
        guard metaAvailabilityState == .ioUnavailable else { return }
        metaLoaded = false
    }

    private func loadMeta() {
        guard !metaLoaded else { return }
        metaLoaded = true
        guard fileManager.fileExists(atPath: metaURL.path) else {
            metaAvailabilityState = .available
            return
        }
        _ = PrivateFile.tightenExistingFile(metaURL)
        guard let data = try? Data(contentsOf: metaURL) else {
            metaAvailabilityState = .ioUnavailable
            return
        }
        guard let version = Self.probeMetaVersion(data) else {
            metaAvailabilityState = .corrupt
            return
        }
        guard version <= ResearchStoreMeta().version else {
            metaAvailabilityState = .unsupportedVersion
            return
        }
        guard let meta = try? JSONDecoder().decode(ResearchStoreMeta.self, from: data) else {
            metaAvailabilityState = .corrupt
            return
        }
        metaState = meta
        metaAvailabilityState = .available
    }

    private func writeMeta(_ meta: ResearchStoreMeta) throws {
        guard metaAvailabilityState.isWritable else {
            throw ResearchStoreError.readOnlyMeta
        }
        let data = try JSONEncoder().encode(meta)
        try PrivateFile.write(data, to: metaURL, durable: false)
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await self?.flushPendingWrites()
        }
    }
}
