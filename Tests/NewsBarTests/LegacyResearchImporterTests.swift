import XCTest
@testable import NewsBar

private enum SpyStoreError: Error {
    case saveFailed
}

private actor SpyResearchStore: ResearchPersisting {
    private let existingEntries: [ResearchIndexEntry]
    private var savedRecords: [ResearchRecord] = []
    private var storedMeta = ResearchStoreMeta()
    private var shouldFail = false

    init(existingEntries: [ResearchIndexEntry] = []) {
        self.existingEntries = existingEntries
    }

    func setShouldFail(_ value: Bool) {
        shouldFail = value
    }

    func snapshotSaved() -> [ResearchRecord] {
        savedRecords
    }

    func metaValue() -> ResearchStoreMeta {
        storedMeta
    }

    func bootstrap() async -> ResearchStoreBootstrap {
        ResearchStoreBootstrap(entries: existingEntries)
    }

    func index() async -> [ResearchIndexEntry] {
        existingEntries
    }

    func records() async -> [ResearchRecord] {
        savedRecords
    }

    func record(id: String) async -> ResearchRecord? {
        savedRecords.first { $0.id == id }
    }

    func save(_ record: ResearchRecord) async throws {
        if shouldFail { throw SpyStoreError.saveFailed }
        savedRecords.append(record)
    }

    func saveAll(_ records: [ResearchRecord]) async throws {
        if shouldFail { throw SpyStoreError.saveFailed }
        savedRecords.append(contentsOf: records)
    }

    func saveProgress(_ record: ResearchRecord) async {}

    func flushPendingWrites() async {}

    func delete(id: String) async throws {}

    func enforceLimits(
        now: Date,
        historyLimit: Int,
        retentionDays: Int,
        excluding: Set<String>
    ) async -> [String] {
        []
    }

    func meta() async -> ResearchStoreMeta {
        storedMeta
    }

    func updateMeta(_ transform: @Sendable (inout ResearchStoreMeta) -> Void) async -> Bool {
        var next = storedMeta
        transform(&next)
        storedMeta = next
        return true
    }
}

final class LegacyResearchImporterTests: XCTestCase {
    private let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testImportsFiveHundredArtifactsAndWritesMarkerOnce() async {
        let store = SpyResearchStore()
        let artifacts = Dictionary(uniqueKeysWithValues: (0..<500).map { index in
            (
                "爆款事件 \(index)",
                BurstResearch(
                    summary: "摘要 \(index)",
                    sources: ["https://example.com/\(index)"]
                )
            )
        })

        let first = await LegacyResearchImporter.importArtifacts(
            artifacts,
            stateUpdatedAt: updatedAt,
            currentItems: [],
            store: store
        )

        XCTAssertFalse(first.failed)
        XCTAssertEqual(first.imported, 500)
        XCTAssertEqual(first.skipped, 0)

        let saved = await store.snapshotSaved()
        XCTAssertEqual(saved.count, 500)
        XCTAssertTrue(saved.allSatisfy {
            $0.origin == .burst
                && $0.status == .ready
                && $0.isRead
                && $0.reportVersion == 0
                && $0.createdAt == updatedAt
                && $0.updatedAt == updatedAt
                && $0.lastAccessedAt == updatedAt
                && $0.report != nil
        })

        let meta = await store.metaValue()
        XCTAssertEqual(meta.legacyImportVersion, 1)

        let second = await LegacyResearchImporter.importArtifacts(
            artifacts,
            stateUpdatedAt: updatedAt,
            currentItems: [],
            store: store
        )
        XCTAssertFalse(second.failed)
        XCTAssertEqual(second.imported, 0)
        XCTAssertEqual(second.skipped, 500)

        let countAfterSecondRun = await store.snapshotSaved().count
        XCTAssertEqual(countAfterSecondRun, 500)
    }

    func testFiveHundredArtifactsImportIntoRealStoreIsIdempotent() async throws {
        let directory = try researchTestDirectory()
        let store = ResearchStore(directoryURL: directory)
        let artifacts = Dictionary(uniqueKeysWithValues: (0..<500).map { index in
            (
                "迁移事件 \(index)",
                BurstResearch(summary: "摘要 \(index)")
            )
        })

        let first = await LegacyResearchImporter.importArtifacts(
            artifacts,
            stateUpdatedAt: updatedAt,
            currentItems: [],
            store: store
        )
        XCTAssertFalse(first.failed)
        XCTAssertEqual(first.imported, 500)

        let firstCount = await store.index().count
        XCTAssertEqual(firstCount, 500)
        let meta = await store.meta()
        XCTAssertEqual(meta.legacyImportVersion, 1)

        let second = await LegacyResearchImporter.importArtifacts(
            artifacts,
            stateUpdatedAt: updatedAt,
            currentItems: [],
            store: store
        )
        XCTAssertFalse(second.failed)
        XCTAssertEqual(second.imported, 0)
        XCTAssertEqual(second.skipped, 500)

        let secondCount = await store.index().count
        XCTAssertEqual(secondCount, 500)
    }

    func testDeduplicatesByTopicKeyAndTimestampEvenWithoutMarker() async {
        let existing = researchTestRecord(
            title: "事件",
            origin: .burst,
            updatedAt: updatedAt
        )
        let store = SpyResearchStore(existingEntries: [ResearchIndexEntry(record: existing)])

        let outcome = await LegacyResearchImporter.importArtifacts(
            ["事件": BurstResearch(summary: "摘要")],
            stateUpdatedAt: updatedAt,
            currentItems: [],
            store: store
        )

        XCTAssertFalse(outcome.failed)
        XCTAssertEqual(outcome.imported, 0)
        XCTAssertEqual(outcome.skipped, 1)
        let saved = await store.snapshotSaved()
        XCTAssertTrue(saved.isEmpty)
    }

    func testEqualTimestampImportsUseStableOrder() async {
        let first = await savedTitles(for: ["乙", "甲", "丙"])
        let second = await savedTitles(for: ["丙", "乙", "甲"])

        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(first, second)
    }

    func testFailureLeavesMarkerUnwritten() async {
        let store = SpyResearchStore()
        await store.setShouldFail(true)

        let outcome = await LegacyResearchImporter.importArtifacts(
            ["事件": BurstResearch(summary: "摘要")],
            stateUpdatedAt: updatedAt,
            currentItems: [],
            store: store
        )

        XCTAssertTrue(outcome.failed)
        XCTAssertNotNil(outcome.errorDescription)
        XCTAssertEqual(outcome.imported, 0)
        let meta = await store.metaValue()
        XCTAssertEqual(meta.legacyImportVersion, 0)
        let saved = await store.snapshotSaved()
        XCTAssertTrue(saved.isEmpty)
    }

    func testSeedUsesMatchingCurrentItem() async {
        let item = NewsItem(title: "事件 A", url: "https://weibo.com/a", source: .weibo)
        let store = SpyResearchStore()

        _ = await LegacyResearchImporter.importArtifacts(
            ["事件 A": BurstResearch(summary: "摘要")],
            stateUpdatedAt: updatedAt,
            currentItems: [item],
            store: store
        )

        let saved = await store.snapshotSaved()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.seed.itemID, item.id)
        XCTAssertEqual(saved.first?.seed.url, "https://weibo.com/a")
        XCTAssertEqual(saved.first?.seed.source, .weibo)
    }

    func testSyntheticSeedUsesFirstValidSourceURL() async {
        let store = SpyResearchStore()
        let research = BurstResearch(
            summary: "摘要",
            sources: ["javascript:alert(1)", "https://example.com/a"]
        )

        _ = await LegacyResearchImporter.importArtifacts(
            ["无匹配事件": research],
            stateUpdatedAt: updatedAt,
            currentItems: [],
            store: store
        )

        let saved = await store.snapshotSaved()
        XCTAssertNil(saved.first?.seed.itemID)
        XCTAssertEqual(saved.first?.seed.url, "https://example.com/a")
        XCTAssertEqual(saved.first?.seed.initialSummary, "摘要")
    }

    func testMarkerAlreadySetSkipsEverything() async {
        let store = SpyResearchStore()
        _ = await store.updateMeta { $0.legacyImportVersion = 1 }

        let outcome = await LegacyResearchImporter.importArtifacts(
            ["事件": BurstResearch(summary: "摘要")],
            stateUpdatedAt: updatedAt,
            currentItems: [],
            store: store
        )

        XCTAssertFalse(outcome.failed)
        XCTAssertEqual(outcome.imported, 0)
        XCTAssertEqual(outcome.skipped, 1)
        let saved = await store.snapshotSaved()
        XCTAssertTrue(saved.isEmpty)
    }

    private func savedTitles(for keys: [String]) async -> [String] {
        let store = SpyResearchStore()
        let artifacts = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, BurstResearch(summary: $0))
        })
        _ = await LegacyResearchImporter.importArtifacts(
            artifacts,
            stateUpdatedAt: updatedAt,
            currentItems: [],
            store: store
        )
        return await store.snapshotSaved().map(\.topic)
    }
}
