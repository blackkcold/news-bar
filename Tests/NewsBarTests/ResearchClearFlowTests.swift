import XCTest
@testable import NewsBar

private actor ClearFlowStore: ResearchPersisting {
    private var records: [String: ResearchRecord]
    private let failDeletion: Bool
    private let intentURL: URL?
    private(set) var sawIntentBeforeDeletion = false
    private(set) var deleteAllCalls = 0
    private var metaState = ResearchStoreMeta()

    init(
        records: [ResearchRecord],
        failDeletion: Bool = false,
        intentURL: URL? = nil
    ) {
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        self.failDeletion = failDeletion
        self.intentURL = intentURL
    }

    func bootstrap() async -> ResearchStoreBootstrap {
        ResearchStoreBootstrap(entries: records.values.map { ResearchIndexEntry(record: $0) })
    }

    func index() async -> [ResearchIndexEntry] {
        records.values.map { ResearchIndexEntry(record: $0) }
    }

    func records() async -> [ResearchRecord] { Array(records.values) }

    func record(id: String) async -> ResearchRecord? { records[id] }

    func save(_ record: ResearchRecord) async throws { records[record.id] = record }

    func saveAll(_ records: [ResearchRecord]) async throws {
        for record in records { self.records[record.id] = record }
    }

    func saveProgress(_ record: ResearchRecord) async { records[record.id] = record }

    func flushPendingWrites() async {}

    func delete(id: String) async throws { records.removeValue(forKey: id) }

    func deleteAll() async throws {
        deleteAllCalls += 1
        if let intentURL {
            sawIntentBeforeDeletion = FileManager.default.fileExists(atPath: intentURL.path)
        }
        if failDeletion { throw ResearchStoreError.readOnlyRecord }
        records.removeAll()
    }

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

    func count() -> Int { records.count }
}

@MainActor
final class ResearchClearFlowTests: XCTestCase {
    private var directory: URL!
    private var intentStore: ResearchClearIntentStore!
    private var cache: ResearchCacheStore!

    override func setUp() async throws {
        directory = try researchTestDirectory()
        intentStore = ResearchClearIntentStore(
            fileURL: directory.appendingPathComponent("clear-intent.json")
        )
        cache = ResearchCacheStore(directoryURL: directory.appendingPathComponent("cache"))
    }

    private func seedCache() async {
        await cache.store(Data("search".utf8), kind: .search, key: "q")
        await cache.store(Data("page".utf8), kind: .pages, key: "u")
    }

    private func clearer(
        store: ClearFlowStore,
        artifactsClear: Bool = true,
        cancel: @escaping () -> Void = {}
    ) -> ResearchHistoryClearer {
        ResearchHistoryClearer(
            store: store,
            cache: cache,
            intentStore: intentStore,
            cancelResearch: cancel,
            clearArtifacts: { artifactsClear },
            verifyArtifactsCleared: { artifactsClear }
        )
    }

    func testHappyPathClearsEverythingAndRemovesIntent() async throws {
        await seedCache()
        let record = researchTestRecord(title: "历史")
        let store = ClearFlowStore(records: [record], intentURL: intentStore.url)
        var cancelled = false

        let result = await clearer(
            store: store,
            cancel: { cancelled = true }
        ).run(existing: nil, generation: 1)

        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(result.cacheCleared)
        XCTAssertTrue(result.artifactsCleared)
        XCTAssertTrue(cancelled)
        let cacheEmpty = await cache.isEmpty()
        let storeCount = await store.count()
        let sawIntent = await store.sawIntentBeforeDeletion
        XCTAssertTrue(cacheEmpty)
        XCTAssertEqual(storeCount, 0)
        XCTAssertTrue(sawIntent)
        let marker = await store.meta().legacyImportVersion
        XCTAssertEqual(marker, 1)
        if case .none = intentStore.load() {} else {
            XCTFail("intent must be removed after a verified clear")
        }
    }

    func testIntentIsWrittenBeforeAnyDeletion() async throws {
        await seedCache()
        let store = ClearFlowStore(
            records: [researchTestRecord(title: "历史")],
            intentURL: intentStore.url
        )

        _ = await clearer(store: store).run(existing: nil, generation: 7)

        let sawIntent = await store.sawIntentBeforeDeletion
        XCTAssertTrue(sawIntent)
    }

    func testRecordDeletionFailureKeepsIntentAndReportsFailure() async throws {
        let store = ClearFlowStore(
            records: [researchTestRecord(title: "历史")],
            failDeletion: true,
            intentURL: intentStore.url
        )

        let result = await clearer(store: store).run(existing: nil, generation: 2)

        XCTAssertFalse(result.isComplete)
        XCTAssertNotNil(result.error)
        let remaining = await store.count()
        XCTAssertEqual(remaining, 1)
        switch intentStore.load() {
        case .pending(let intent):
            XCTAssertEqual(intent.stage, .cacheCleared)
            XCTAssertEqual(intent.generation, 2)
        default:
            XCTFail("the intent must survive a failed stage")
        }
    }

    func testArtifactFailureKeepsIntentAndReportsFailure() async throws {
        let store = ClearFlowStore(records: [researchTestRecord(title: "历史")])
        let result = await clearer(store: store, artifactsClear: false)
            .run(existing: nil, generation: 3)

        XCTAssertFalse(result.isComplete)
        XCTAssertFalse(result.artifactsCleared)
        let remaining = await store.count()
        XCTAssertEqual(remaining, 0)
        switch intentStore.load() {
        case .pending(let intent):
            XCTAssertEqual(intent.stage, .recordsDeleted)
        default:
            XCTFail("the intent must survive a failed stage")
        }
    }

    func testRetryReusesTheSameOperation() async throws {
        let store = ClearFlowStore(records: [researchTestRecord(title: "历史")])
        _ = await clearer(store: store, artifactsClear: false)
            .run(existing: nil, generation: 4)
        guard case .pending(let first) = intentStore.load() else {
            return XCTFail("expected a pending intent")
        }

        let retry = await clearer(store: store).run(existing: first, generation: 5)
        XCTAssertTrue(retry.isComplete)
        if case .none = intentStore.load() {} else {
            XCTFail("intent must be removed after the retry completes")
        }
    }

    func testCacheDeletionFailureIsNotReportedAsSuccess() async throws {
        await seedCache()
        let cacheRoot = directory.appendingPathComponent("cache", isDirectory: true)
        let searchDirectory = cacheRoot.appendingPathComponent("search", isDirectory: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: searchDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: searchDirectory.path
            )
        }

        let store = ClearFlowStore(records: [])
        let result = await clearer(store: store).run(existing: nil, generation: 6)

        XCTAssertFalse(result.isComplete)
        XCTAssertFalse(result.cacheCleared)
        switch intentStore.load() {
        case .pending(let intent):
            XCTAssertEqual(intent.stage, .prepared)
        default:
            XCTFail("the intent must survive a failed cache clear")
        }
    }

    func testFlushReportsAReceiptForTheTargetRevision() async throws {
        let path = directory.appendingPathComponent("interest.json")
        let controller = InterestController(store: LocalInterestStore(fileURL: path))
        await controller.prepare()
        let epoch = controller.state.consentEpoch

        var research = controller.state.research
        research.artifacts = ["t": BurstResearch(summary: "摘要")]
        controller.updateResearch(research, epoch: epoch)
        _ = await controller.flush()

        // Now clear the artifacts and wait for that exact revision.
        research.artifacts = [:]
        controller.updateResearch(research, epoch: epoch)
        let revision = controller.state.revision

        let confirmed = await controller.flush(revision: revision)
        XCTAssertTrue(confirmed)

        let loaded = try await LocalInterestStore(fileURL: path).load()
        XCTAssertTrue(loaded.research.artifacts.isEmpty)
    }

    func testCacheRejectsAWriteFromBeforeAClear() async throws {
        let epoch = await cache.writeEpoch()
        await cache.clearAll()
        await cache.store(
            Data("late".utf8),
            kind: .pages,
            key: "late",
            epoch: epoch
        )
        let lateExists = await cache.hasFile(kind: .pages, key: "late")
        XCTAssertFalse(lateExists)

        await cache.store(
            Data("current".utf8),
            kind: .pages,
            key: "current",
            epoch: await cache.writeEpoch()
        )
        let currentExists = await cache.hasFile(kind: .pages, key: "current")
        XCTAssertTrue(currentExists)
    }

    func testFutureIntentIsNotInterpreted() throws {
        try Data(#"{"version":99,"operationID":"x","generation":1,"stage":"prepared","createdAt":0,"updatedAt":0}"#.utf8)
            .write(to: intentStore.url)
        if case .unsupportedVersion = intentStore.load() {} else {
            XCTFail("a future intent must not be guessed")
        }
    }

    func testIntentFileIsOwnerOnly() throws {
        try intentStore.save(ResearchClearIntent.make(generation: 1, at: Date()))
        let mode = try FileManager.default
            .attributesOfItem(atPath: intentStore.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }
}
