import XCTest
@testable import NewsBar

private actor LegacyVerificationStore: ResearchPersisting {
    private var recordsByID: [String: ResearchRecord] = [:]
    private var metaState = ResearchStoreMeta()
    private let dropsWrites: Bool
    private let failsMarker: Bool

    init(dropsWrites: Bool = false, failsMarker: Bool = false) {
        self.dropsWrites = dropsWrites
        self.failsMarker = failsMarker
    }

    func bootstrap() async -> ResearchStoreBootstrap {
        ResearchStoreBootstrap(entries: recordsByID.values.map { ResearchIndexEntry(record: $0) })
    }

    func index() async -> [ResearchIndexEntry] {
        recordsByID.values.map { ResearchIndexEntry(record: $0) }
    }

    func records() async -> [ResearchRecord] {
        Array(recordsByID.values)
    }

    func record(id: String) async -> ResearchRecord? {
        recordsByID[id]
    }

    func save(_ record: ResearchRecord) async throws {
        guard !dropsWrites else { return }
        recordsByID[record.id] = record
    }

    func saveAll(_ records: [ResearchRecord]) async throws {
        guard !dropsWrites else { return }
        for record in records { recordsByID[record.id] = record }
    }

    func saveProgress(_ record: ResearchRecord) async {
        guard !dropsWrites else { return }
        recordsByID[record.id] = record
    }

    func flushPendingWrites() async {}

    func delete(id: String) async throws {
        recordsByID.removeValue(forKey: id)
    }

    func enforceLimits(
        now: Date,
        historyLimit: Int,
        retentionDays: Int,
        excluding: Set<String>
    ) async -> [String] { [] }

    func meta() async -> ResearchStoreMeta { metaState }

    func updateMeta(_ transform: @Sendable (inout ResearchStoreMeta) -> Void) async -> Bool {
        guard !failsMarker else { return false }
        var next = metaState
        transform(&next)
        metaState = next
        return true
    }
}

private actor ClearingDuringImportStore: ResearchPersisting {
    private var recordsByID: [String: ResearchRecord] = [:]
    private var epoch = 0
    private var metaState = ResearchStoreMeta()

    func bootstrap() async -> ResearchStoreBootstrap {
        ResearchStoreBootstrap(entries: recordsByID.values.map { ResearchIndexEntry(record: $0) })
    }

    func index() async -> [ResearchIndexEntry] {
        recordsByID.values.map { ResearchIndexEntry(record: $0) }
    }

    func records() async -> [ResearchRecord] { Array(recordsByID.values) }
    func record(id: String) async -> ResearchRecord? { recordsByID[id] }
    func save(_ record: ResearchRecord) async throws { recordsByID[record.id] = record }

    func saveAll(_ records: [ResearchRecord]) async throws {
        for record in records { recordsByID[record.id] = record }
        // A history clear lands between the write and the marker.
        recordsByID.removeAll()
        epoch += 1
    }

    func saveProgress(_ record: ResearchRecord) async {}
    func flushPendingWrites() async {}
    func delete(id: String) async throws { recordsByID.removeValue(forKey: id) }
    func deleteAll() async throws { recordsByID.removeAll(); epoch += 1 }
    func enforceLimits(
        now: Date,
        historyLimit: Int,
        retentionDays: Int,
        excluding: Set<String>
    ) async -> [String] { [] }
    func meta() async -> ResearchStoreMeta { metaState }
    func updateMeta(_ transform: @Sendable (inout ResearchStoreMeta) -> Void) async -> Bool {
        var next = metaState
        transform(&next)
        metaState = next
        return true
    }
    func dataEpoch() async -> Int { epoch }
    func count() -> Int { recordsByID.count }
}

final class LegacyImportIdentityTests: XCTestCase {
    private let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testEmptyNormalizedArtifactKeysNeverCollide() async {
        let keys = ["", " ", "!!!", "🔥", "\n\t", "。。"]
        let artifacts = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, BurstResearch(summary: "摘要"))
        })
        let store = LegacyVerificationStore()

        let outcome = await LegacyResearchImporter.importArtifacts(
            artifacts,
            stateUpdatedAt: updatedAt,
            currentItems: [],
            store: store
        )

        XCTAssertEqual(outcome.imported, keys.count)
        XCTAssertTrue(outcome.isComplete)
        let saved = await store.records()
        XCTAssertEqual(saved.count, keys.count)
        XCTAssertEqual(Set(saved.map(\.id)).count, keys.count)
        XCTAssertEqual(Set(saved.map(\.topicKey)).count, keys.count)
        XCTAssertEqual(Set(saved.map(\.seed.title)), Set(keys))
        XCTAssertTrue(saved.allSatisfy { !$0.topic.isEmpty })
    }

    func testRetryAfterMarkerLossDoesNotDuplicate() async throws {
        let directory = try researchTestDirectory()
        let store = ResearchStore(directoryURL: directory)
        let artifacts = ["🔥": BurstResearch(summary: "摘要")]

        let first = await LegacyResearchImporter.importArtifacts(
            artifacts,
            stateUpdatedAt: updatedAt,
            currentItems: [],
            store: store
        )
        XCTAssertEqual(first.imported, 1)

        // Simulate the marker write being lost while the record survived.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("meta.json"))

        let retry = await LegacyResearchImporter.importArtifacts(
            artifacts,
            stateUpdatedAt: updatedAt.addingTimeInterval(86_400),
            currentItems: [],
            store: store
        )
        XCTAssertFalse(retry.failed)
        XCTAssertEqual(retry.imported, 0)
        XCTAssertEqual(retry.skipped, 1)
        let count = await store.index().count
        XCTAssertEqual(count, 1)
    }

    func testExistingUUIDLegacyRecordIsClaimed() async {
        let existing = researchTestRecord(
            title: "旧记录",
            origin: .burst,
            updatedAt: updatedAt
        )
        var legacy = existing
        legacy.reportVersion = 0
        let store = LegacyVerificationStore()
        try? await store.save(legacy)

        let outcome = await LegacyResearchImporter.importArtifacts(
            ["旧记录": BurstResearch(summary: "摘要")],
            stateUpdatedAt: updatedAt,
            currentItems: [],
            store: store
        )

        XCTAssertEqual(outcome.imported, 0)
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertTrue(outcome.conflicts.isEmpty)
        let count = await store.records().count
        XCTAssertEqual(count, 1)
    }

    func testAmbiguousLegacyRecordsAreReportedNotSwallowed() async {
        var first = researchTestRecord(title: "!!!", origin: .burst, updatedAt: updatedAt)
        first.reportVersion = 0
        var second = researchTestRecord(title: "!!!", origin: .burst, updatedAt: updatedAt)
        second.reportVersion = 0
        let store = LegacyVerificationStore()
        try? await store.save(first)
        try? await store.save(second)

        let outcome = await LegacyResearchImporter.importArtifacts(
            ["!!!": BurstResearch(summary: "摘要")],
            stateUpdatedAt: updatedAt,
            currentItems: [],
            store: store
        )

        XCTAssertEqual(outcome.imported, 0)
        XCTAssertEqual(outcome.conflicts, ["!!!"])
        XCTAssertFalse(outcome.isComplete)
        let meta = await store.meta()
        XCTAssertEqual(meta.legacyImportVersion, 0)
        let count = await store.records().count
        XCTAssertEqual(count, 2)
    }

    func testManualRecordIsNotTreatedAsLegacyImport() async {
        let manual = researchTestRecord(title: "手动记录", origin: .manual, updatedAt: updatedAt)
        var legacyShape = manual
        legacyShape.reportVersion = 0
        let store = LegacyVerificationStore()
        try? await store.save(legacyShape)

        let outcome = await LegacyResearchImporter.importArtifacts(
            ["手动记录": BurstResearch(summary: "摘要")],
            stateUpdatedAt: updatedAt,
            currentItems: [],
            store: store
        )

        // The manual record keeps its own topic key; the artifact becomes a
        // separate burst record instead of being merged into user data.
        XCTAssertEqual(outcome.imported, 1)
        XCTAssertEqual(outcome.skipped, 0)
        let count = await store.records().count
        XCTAssertEqual(count, 2)
    }

    func testUnverifiedWriteKeepsMarkerAndArtifacts() async {
        let store = LegacyVerificationStore(dropsWrites: true)

        let outcome = await LegacyResearchImporter.importArtifacts(
            ["事件": BurstResearch(summary: "摘要")],
            stateUpdatedAt: updatedAt,
            currentItems: [],
            store: store
        )

        XCTAssertFalse(outcome.failed)
        XCTAssertEqual(outcome.unconfirmed, ["事件"])
        XCTAssertFalse(outcome.isComplete)
        let meta = await store.meta()
        XCTAssertEqual(meta.legacyImportVersion, 0)
    }

    func testMarkerWriteFailureIsReported() async {
        let store = LegacyVerificationStore(failsMarker: true)

        let outcome = await LegacyResearchImporter.importArtifacts(
            ["事件": BurstResearch(summary: "摘要")],
            stateUpdatedAt: updatedAt,
            currentItems: [],
            store: store
        )

        XCTAssertTrue(outcome.failed)
        XCTAssertFalse(outcome.isComplete)
        let meta = await store.meta()
        XCTAssertEqual(meta.legacyImportVersion, 0)
    }

    func testClearDuringImportWinsAndMarkerStaysUnwritten() async {
        let store = ClearingDuringImportStore()
        let outcome = await LegacyResearchImporter.importArtifacts(
            ["事件": BurstResearch(summary: "摘要")],
            stateUpdatedAt: updatedAt,
            currentItems: [],
            store: store
        )

        XCTAssertTrue(outcome.failed)
        XCTAssertFalse(outcome.isComplete)
        let remaining = await store.count()
        XCTAssertEqual(remaining, 0)
        let meta = await store.meta()
        XCTAssertEqual(meta.legacyImportVersion, 0)
    }

    func testDisplayTitleFallsBackToSummaryThenUntitled() {
        XCTAssertEqual(
            LegacyResearchImporter.displayTitle(rawTitle: "正常标题", summary: ""),
            "正常标题"
        )
        XCTAssertEqual(
            LegacyResearchImporter.displayTitle(
                rawTitle: "🔥",
                summary: "第一句。第二句。"
            ),
            "第一句"
        )
        let fallback = LegacyResearchImporter.displayTitle(rawTitle: "  ", summary: "")
        XCTAssertFalse(fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertNotEqual(fallback, "  ")
    }
}
