import Foundation
@testable import NewsBar

func researchTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("NewsBarResearchTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func researchTestRecord(
    id: UUID = UUID(),
    title: String,
    status: ResearchStatus = .ready,
    origin: ResearchOrigin = .manual,
    updatedAt: Date = Date(),
    lastAccessedAt: Date? = nil,
    lastSeenAt: Date? = nil,
    isPinned: Bool = false,
    isRead: Bool = false,
    seedURL: String? = "https://example.com/article",
    aliases: [String] = [],
    report: BurstResearch? = nil
) -> ResearchRecord {
    var run = ResearchRun()
    run.phase = status.isActive ? .searching : .done
    run.origin = origin
    run.startedAt = updatedAt
    run.finishedAt = status.isActive ? nil : updatedAt

    let seed = ResearchSeed(
        itemID: nil,
        title: title,
        url: seedURL,
        source: .weibo,
        publishedAt: nil,
        initialSummary: ""
    )

    return ResearchRecord(
        id: id.uuidString,
        topicKey: TopicFingerprint.key(for: title),
        origin: origin,
        topic: title,
        aliases: aliases,
        seed: seed,
        createdAt: updatedAt,
        lastSeenAt: lastSeenAt ?? updatedAt,
        updatedAt: updatedAt,
        lastAccessedAt: lastAccessedAt ?? updatedAt,
        isPinned: isPinned,
        isRead: isRead,
        status: status,
        report: report,
        run: run,
        reportVersion: 2
    )
}

/// Thread-safe clock for injectable store timestamps.
final class ResearchTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Date) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func advance(_ seconds: TimeInterval) {
        set(now.addingTimeInterval(seconds))
    }
}

/// In-memory `ResearchPersisting` used by coordinator/model tests. It keeps
/// save order so ordering-sensitive tests do not need a real filesystem.
actor ResearchFakeStore: ResearchPersisting {
    private var recordMap: [String: ResearchRecord]
    private var savedIDs: [String] = []
    private var metaState = ResearchStoreMeta()
    private(set) var didDeleteAll = false

    init(records: [ResearchRecord] = []) {
        self.recordMap = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    func bootstrap() async -> ResearchStoreBootstrap {
        ResearchStoreBootstrap(entries: indexSnapshot())
    }

    func index() async -> [ResearchIndexEntry] {
        indexSnapshot()
    }

    func records() async -> [ResearchRecord] {
        recordMap.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func record(id: String) async -> ResearchRecord? {
        recordMap[id]
    }

    func latestRecord(topicKey: String) async -> ResearchRecord? {
        recordMap.values
            .filter { $0.topicKey == topicKey }
            .max { $0.lastSeenAt < $1.lastSeenAt }
    }

    func burstSummary() async -> ResearchSummary {
        let bursts = recordMap.values.filter { $0.origin == .burst }
        return ResearchSummary(
            burstCount: bursts.count,
            unreadBurstCount: bursts.filter { !$0.isRead }.count
        )
    }

    func touch(id: String, at date: Date) async {
        guard var record = recordMap[id] else { return }
        record.lastAccessedAt = date
        recordMap[id] = record
    }

    func deleteAll() async throws {
        recordMap.removeAll()
        savedIDs.removeAll()
        didDeleteAll = true
    }

    func storageFootprint() async -> Int64 {
        0
    }

    func save(_ record: ResearchRecord) async throws {
        recordMap[record.id] = record
        savedIDs.append(record.id)
    }

    func saveAll(_ records: [ResearchRecord]) async throws {
        for record in records {
            recordMap[record.id] = record
            savedIDs.append(record.id)
        }
    }

    func saveProgress(_ record: ResearchRecord) async {
        recordMap[record.id] = record
    }

    func flushPendingWrites() async {}

    func delete(id: String) async throws {
        recordMap.removeValue(forKey: id)
    }

    func enforceLimits(
        now: Date,
        historyLimit: Int,
        retentionDays: Int,
        excluding: Set<String>
    ) async -> [String] {
        []
    }

    func meta() async -> ResearchStoreMeta {
        metaState
    }

    func updateMeta(_ transform: @Sendable (inout ResearchStoreMeta) -> Void) async -> Bool {
        var next = metaState
        transform(&next)
        metaState = next
        return true
    }

    func savedOrder() -> [String] {
        savedIDs
    }

    func snapshot() -> [String: ResearchRecord] {
        recordMap
    }

    private func indexSnapshot() -> [ResearchIndexEntry] {
        recordMap.values
            .map { ResearchIndexEntry(record: $0) }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id < $1.id
            }
    }
}

