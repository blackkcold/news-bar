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

    init(record: ResearchRecord) {
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
    }
}

struct ResearchStoreMeta: Codable, Hashable, Sendable {
    var version = 1
    var legacyImportVersion = 0
    var ledgerMigrationVersion = 0
    var lastMaintenanceAt: Date?
    var updatedAt: Date?

    init() {}

    enum CodingKeys: String, CodingKey {
        case version, legacyImportVersion, ledgerMigrationVersion, lastMaintenanceAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        legacyImportVersion = try container.decodeIfPresent(Int.self, forKey: .legacyImportVersion) ?? 0
        ledgerMigrationVersion = try container.decodeIfPresent(Int.self, forKey: .ledgerMigrationVersion) ?? 0
        lastMaintenanceAt = try container.decodeIfPresent(Date.self, forKey: .lastMaintenanceAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

struct ResearchStoreBootstrap: Sendable, Equatable {
    var entries: [ResearchIndexEntry] = []
    var interruptedIDs: [String] = []
    var corruptIDs: [String] = []
    var rebuiltIndex = false
}

enum ResearchStoreError: Error, Equatable {
    case invalidRecordID
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

        var result = ResearchStoreBootstrap()
        let files = recordFileURLs()

        if let data = try? Data(contentsOf: indexURL),
           let document = try? JSONDecoder().decode(IndexDocument.self, from: data),
           document.version == 1,
           Set(document.entries.map(\.id)) == Set(files.keys),
           Set(document.entries.map(\.id)).count == document.entries.count {
            entries = Dictionary(uniqueKeysWithValues: document.entries.map { ($0.id, $0) })
        } else {
            result.rebuiltIndex = true
            rebuildIndex(into: &result)
        }

        let activeIDs = entries.values.filter { $0.status.isActive }.map(\.id)
        for id in activeIDs {
            guard var record = decodeRecord(id: id) else {
                let date = modificationDate(of: recordURL(for: id)) ?? now()
                entries[id] = ResearchIndexEntry(record: .corruptPlaceholder(id: id, date: date))
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

        result.corruptIDs = entries.values
            .filter { $0.status == .corrupt }
            .map(\.id)
            .sorted()
        result.entries = sortedEntries()

        if result.rebuiltIndex || !result.interruptedIDs.isEmpty {
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
            return decodeRecord(id: entry.id)
                ?? .corruptPlaceholder(id: entry.id, date: entry.updatedAt)
        }
    }

    func record(id: String) async -> ResearchRecord? {
        if !didBootstrap { _ = await bootstrap() }
        guard isSafeID(id) else { return nil }
        if let pending = pending[id] { return pending }
        if let record = decodeRecord(id: id) { return record }
        guard let entry = entries[id] else { return nil }
        return .corruptPlaceholder(id: id, date: entry.updatedAt)
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
        flushTask?.cancel()
        flushTask = nil
        pending.removeAll()
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
        try ensureDirectoriesThrowing()
        for record in records {
            try writeRecord(record)
            entries[record.id] = ResearchIndexEntry(record: record)
            pending.removeValue(forKey: record.id)
            lastProgressWrite[record.id] = now()
        }
        writeIndexBestEffort()
    }

    func saveProgress(_ record: ResearchRecord) async {
        if !didBootstrap { _ = await bootstrap() }
        guard isSafeID(record.id) else { return }

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
                try await save(record)
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
                guard let victim = candidates.min(by: { $0.lastAccessedAt < $1.lastAccessedAt }) else {
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
                .sorted { $0.lastAccessedAt < $1.lastAccessedAt }
            for victim in candidates {
                guard total > byteCap else { break }
                let size = fileSize(recordURL(for: victim.id))
                if removeRecord(id: victim.id) {
                    total -= size
                    removed.append(victim.id)
                }
            }
        }

        metaState.lastMaintenanceAt = date
        metaState.updatedAt = date
        try? writeMeta(metaState)
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
        loadMeta()
        return metaState
    }

    @discardableResult
    func updateMeta(_ transform: @Sendable (inout ResearchStoreMeta) -> Void) async -> Bool {
        loadMeta()
        var next = metaState
        transform(&next)
        next.updatedAt = now()
        do {
            try ensureDirectoriesThrowing()
            try writeMeta(next)
            metaState = next
            return true
        } catch {
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
                scanned.append(ResearchIndexEntry(record: .corruptPlaceholder(id: id, date: date)))
            }
        }
        // Cap the derived index, not the files. The newest entries stay visible;
        // the age/size enforcement pass owns actual deletion.
        let kept = scanned.sorted(by: indexOrder).prefix(1000)
        entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.id, $0) })
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

    private func writeIndexBestEffort() {
        do {
            try writeIndex()
        } catch {
            // The record is authoritative; the next bootstrap rebuilds the index.
        }
    }

    private func writeIndex() throws {
        try ensureDirectoriesThrowing()
        let document = IndexDocument(updatedAt: now(), entries: sortedEntries())
        let data = try JSONEncoder().encode(document)
        try data.write(to: indexURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }

    // MARK: - Files

    private func ensureDirectories() {
        try? ensureDirectoriesThrowing()
    }

    private func ensureDirectoriesThrowing() throws {
        try fileManager.createDirectory(
            at: recordsURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recordsURL.path)
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
        let url = recordURL(for: record.id)
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func decodeRecord(id: String) -> ResearchRecord? {
        decodeRecord(at: recordURL(for: id))
    }

    private func decodeRecord(at url: URL) -> ResearchRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ResearchRecord.self, from: data)
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

    private func loadMeta() {
        guard !metaLoaded else { return }
        metaLoaded = true
        if let data = try? Data(contentsOf: metaURL),
           let meta = try? JSONDecoder().decode(ResearchStoreMeta.self, from: data) {
            metaState = meta
        }
    }

    private func writeMeta(_ meta: ResearchStoreMeta) throws {
        let data = try JSONEncoder().encode(meta)
        try data.write(to: metaURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metaURL.path)
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await self?.flushPendingWrites()
        }
    }
}
