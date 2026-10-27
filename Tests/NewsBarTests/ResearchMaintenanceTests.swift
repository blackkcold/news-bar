import XCTest
@testable import NewsBar

@MainActor
final class ResearchMaintenanceTests: XCTestCase {
    private var directory: URL!
    private var store: ResearchStore!
    private var cache: ResearchCacheStore!
    private var ledger: ResearchLedger!
    private var maintenance: ResearchMaintenance!

    override func setUp() async throws {
        try await super.setUp()
        directory = try researchTestDirectory()
        store = ResearchStore(directoryURL: directory.appendingPathComponent("research", isDirectory: true))
        cache = ResearchCacheStore(directoryURL: directory.appendingPathComponent("cache", isDirectory: true))
        ledger = ResearchLedger(fileURL: directory.appendingPathComponent("ledger.json"))
        maintenance = ResearchMaintenance(store: store, cache: cache, ledger: ledger)
    }

    override func tearDown() async throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try await super.tearDown()
    }

    func testLedgerMigrationCopiesLegacyBurstCountOnce() async throws {
        let settings = AppSettings()
        let previousDay = settings.statsDayTimestamp
        let previousCount = settings.todayBurstResearchCount
        defer {
            settings.statsDayTimestamp = previousDay
            settings.todayBurstResearchCount = previousCount
        }

        settings.statsDayTimestamp = Date().timeIntervalSince1970
        settings.todayBurstResearchCount = 7

        let firstMigration = await maintenance.migrateLedgerIfNeeded(settings: settings)
        XCTAssertTrue(firstMigration)
        XCTAssertEqual(ledger.snapshot().ai.burst, 7)
        let meta = await store.meta()
        XCTAssertEqual(meta.ledgerMigrationVersion, 1)

        settings.todayBurstResearchCount = 9
        let secondMigration = await maintenance.migrateLedgerIfNeeded(settings: settings)
        XCTAssertFalse(secondMigration)
        XCTAssertEqual(ledger.snapshot().ai.burst, 7)
    }

    func testMigrationRetriesWhenMarkerWriteFails() async throws {
        let settings = AppSettings()
        let previousDay = settings.statsDayTimestamp
        let previousCount = settings.todayBurstResearchCount
        defer {
            settings.statsDayTimestamp = previousDay
            settings.todayBurstResearchCount = previousCount
        }

        settings.statsDayTimestamp = Date().timeIntervalSince1970
        settings.todayBurstResearchCount = 3

        // Make the marker path unwritable (a directory cannot be replaced by an
        // atomic file write) so the migration must not claim success.
        let metaURL = directory
            .appendingPathComponent("research", isDirectory: true)
            .appendingPathComponent("meta.json")
        try FileManager.default.createDirectory(
            at: metaURL,
            withIntermediateDirectories: true
        )

        let firstAttempt = await maintenance.migrateLedgerIfNeeded(settings: settings)
        XCTAssertFalse(firstAttempt)
        XCTAssertEqual(ledger.snapshot().ai.burst, 3)
        let secondAttempt = await maintenance.migrateLedgerIfNeeded(settings: settings)
        XCTAssertFalse(secondAttempt)
        XCTAssertEqual(ledger.snapshot().ai.burst, 3)
    }

    func testPreviewMatchesRetentionEnforcement() async throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = Date()
        let records = [
            researchTestRecord(title: "旧记录", status: .ready, updatedAt: old, lastAccessedAt: old),
            researchTestRecord(title: "置顶旧记录", status: .ready, updatedAt: old, lastAccessedAt: old, isPinned: true),
            researchTestRecord(title: "运行中旧记录", status: .running, updatedAt: old, lastAccessedAt: old),
            researchTestRecord(title: "新记录", status: .ready, updatedAt: recent, lastAccessedAt: recent),
        ]
        try await store.saveAll(records)

        let preview = await store.previewEnforcement(
            now: recent,
            historyLimit: 200,
            retentionDays: 30
        )
        XCTAssertEqual(preview, 1)

        let removed = await store.enforceLimits(
            now: recent,
            historyLimit: 200,
            retentionDays: 30
        )
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed.first, records[0].id)

        let pinned = await store.record(id: records[1].id)
        XCTAssertNotNil(pinned)
        let active = await store.record(id: records[2].id)
        XCTAssertNotNil(active)
        let kept = await store.record(id: records[3].id)
        XCTAssertNotNil(kept)
    }

    func testPreviewHistoryLimitCountsLeastRecentlyAccessed() async throws {
        let base = Date()
        var records: [ResearchRecord] = []
        for index in 0..<5 {
            records.append(
                researchTestRecord(
                    title: "记录\(index)",
                    status: .ready,
                    updatedAt: base,
                    lastAccessedAt: base.addingTimeInterval(TimeInterval(index))
                )
            )
        }
        try await store.saveAll(records)

        let preview = await store.previewEnforcement(
            now: base,
            historyLimit: 2,
            retentionDays: 0
        )
        XCTAssertEqual(preview, 3)

        let removed = await store.enforceLimits(
            now: base,
            historyLimit: 2,
            retentionDays: 0
        )
        XCTAssertEqual(removed.count, 3)
        let remaining = await store.index()
        XCTAssertEqual(remaining.count, 2)
        XCTAssertEqual(Set(remaining.map(\.topic)), Set(["记录3", "记录4"]))
    }

    func testCachePreviewCountsExpiredFilesWithoutDeleting() async throws {
        let now = Date()
        await cache.store(
            Data("old".utf8),
            kind: .search,
            key: "old",
            now: now.addingTimeInterval(-ResearchCacheStore.searchTTL - 60)
        )
        await cache.store(Data("fresh".utf8), kind: .search, key: "fresh", now: now)

        let preview = await cache.previewEnforcement(now: now, maxBytes: 10_000_000)
        XCTAssertEqual(preview.removedFiles, 1)
        XCTAssertGreaterThan(preview.removedBytes, 0)

        let oldExists = await cache.hasFile(kind: .search, key: "old")
        let freshExists = await cache.hasFile(kind: .search, key: "fresh")
        XCTAssertTrue(oldExists)
        XCTAssertTrue(freshExists)
    }

    func testPageTTLSettingChangesExpiry() async throws {
        let now = Date()
        await cache.store(
            Data("page".utf8),
            kind: .pages,
            key: "p",
            now: now.addingTimeInterval(-2 * 3600)
        )
        await cache.setPagesTTL(hours: 1)
        let expired = await cache.load(kind: .pages, key: "p", now: now)
        XCTAssertNil(expired)
    }
}
