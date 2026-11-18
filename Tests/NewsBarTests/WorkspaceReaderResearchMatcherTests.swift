import XCTest
@testable import NewsBar

private actor WorkspaceReaderResearchGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor WorkspaceReaderResearchRecordFake: WorkspaceReaderResearchRecordProviding {
    private var entries: [ResearchIndexEntry]
    private var records: [String: ResearchRecord]
    private let indexGate: WorkspaceReaderResearchGate?
    private let recordGates: [String: WorkspaceReaderResearchGate]
    private var indexCalls = 0
    private var recordCalls: [String: Int] = [:]

    init(
        entries: [ResearchIndexEntry] = [],
        records: [ResearchRecord] = [],
        indexGate: WorkspaceReaderResearchGate? = nil,
        recordGates: [String: WorkspaceReaderResearchGate] = [:]
    ) {
        self.entries = entries
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        self.indexGate = indexGate
        self.recordGates = recordGates
    }

    func index() async -> [ResearchIndexEntry] {
        indexCalls += 1
        let snapshot = entries
        await indexGate?.hold()
        return snapshot
    }

    func record(id: String) async -> ResearchRecord? {
        recordCalls[id, default: 0] += 1
        await recordGates[id]?.hold()
        return records[id]
    }

    func setEntries(_ entries: [ResearchIndexEntry]) { self.entries = entries }
    func setRecord(_ record: ResearchRecord) { records[record.id] = record }

    func indexCallCount() -> Int { indexCalls }
    func recordCallCount(for id: String) -> Int { recordCalls[id, default: 0] }
}

private actor WorkspaceReaderResearchSubjectFake: WorkspaceReaderResearchSubjectProviding {
    private var values: [WorkspaceSubject] = []
    private var calls = 0

    func subjects() async -> [WorkspaceSubject] {
        calls += 1
        return values
    }

    func callCount() -> Int { calls }
}

private actor WorkspaceReaderResearchEventFake: WorkspaceReaderResearchEventProviding {
    private var values: [NewsEvent] = []
    private var calls = 0

    func events() async throws -> [NewsEvent] {
        calls += 1
        return values
    }

    func callCount() -> Int { calls }
}

private actor WorkspaceReaderResearchCompletionProbe {
    private var didComplete = false

    func markCompleted() { didComplete = true }
    func completed() -> Bool { didComplete }
}

@MainActor
final class WorkspaceReaderResearchMatcherTests: XCTestCase {
    func testDisabledReaderDoesNoStoreWorkAndEnablingLoadsCurrentIndex() async {
        let record = makeRecord(itemID: "article-a", url: "https://example.com/a", status: .ready, report: true)
        let source = WorkspaceReaderResearchRecordFake(entries: [ResearchIndexEntry(record: record)], records: [record])
        let subjects = WorkspaceReaderResearchSubjectFake()
        let events = WorkspaceReaderResearchEventFake()
        let matcher = WorkspaceReaderResearchMatcher(
            researchStore: source,
            workspaceStore: subjects,
            eventStore: events
        )
        let signal = WorkspaceReaderResearchAssociationSignal()

        await matcher.observe(signal, itemID: "article-a", urls: ["https://example.com/a"], enabled: false)
        XCTAssertNil(signal.match)
        let disabledIndexCalls = await source.indexCallCount()
        let disabledSubjectCalls = await subjects.callCount()
        let disabledEventCalls = await events.callCount()
        XCTAssertEqual(disabledIndexCalls, 0)
        XCTAssertEqual(disabledSubjectCalls, 0)
        XCTAssertEqual(disabledEventCalls, 0)

        await matcher.observe(signal, itemID: "article-a", urls: ["https://example.com/a"], enabled: true)
        XCTAssertEqual(signal.match?.recordID, record.id)
        let enabledIndexCalls = await source.indexCallCount()
        XCTAssertEqual(enabledIndexCalls, 1)
    }

    func testConcurrentVisibleReadersShareOneInitialLoadAndLocalProgressDoesNotWakeUnrelatedRows() async {
        let records = (0..<64).map { index in
            makeRecord(
                itemID: "article-\(index)",
                url: "https://example.com/\(index)",
                status: .running,
                report: false
            )
        }
        let source = WorkspaceReaderResearchRecordFake(
            entries: records.map { ResearchIndexEntry(record: $0) },
            records: records
        )
        let subjects = WorkspaceReaderResearchSubjectFake()
        let events = WorkspaceReaderResearchEventFake()
        let matcher = WorkspaceReaderResearchMatcher(
            researchStore: source,
            workspaceStore: subjects,
            eventStore: events
        )
        let signals = records.map { _ in WorkspaceReaderResearchAssociationSignal() }

        await withTaskGroup(of: Void.self) { group in
            for (index, signal) in signals.enumerated() {
                group.addTask {
                    await matcher.observe(
                        signal,
                        itemID: "article-\(index)",
                        urls: ["https://example.com/\(index)"],
                        enabled: true
                    )
                }
            }
            await group.waitForAll()
        }

        let initialIndexCalls = await source.indexCallCount()
        let initialSubjectCalls = await subjects.callCount()
        let initialEventCalls = await events.callCount()
        XCTAssertEqual(initialIndexCalls, 1)
        XCTAssertEqual(initialSubjectCalls, 1)
        XCTAssertEqual(initialEventCalls, 1)
        var metrics = matcher.metricsSnapshot()
        XCTAssertEqual(metrics.fullIndexLoads, 1)
        XCTAssertEqual(metrics.signalRefreshes, 64)
        XCTAssertEqual(signals[17].match?.recordID, records[17].id)

        var progressOnlyUpdate = records[17]
        progressOnlyUpdate.updatedAt = progressOnlyUpdate.updatedAt.addingTimeInterval(10)
        progressOnlyUpdate.run.pagesRead += 1
        await source.setRecord(progressOnlyUpdate)
        matcher.recordDidChange(id: progressOnlyUpdate.id)
        await matcher.flushPendingChanges()

        let totalIndexCalls = await source.indexCallCount()
        let targetRecordReads = await source.recordCallCount(for: progressOnlyUpdate.id)
        XCTAssertEqual(totalIndexCalls, 1)
        XCTAssertEqual(targetRecordReads, 1)
        metrics = matcher.metricsSnapshot()
        XCTAssertEqual(metrics.fullIndexLoads, 1)
        XCTAssertEqual(metrics.processedBatches, 2, "One local change should be processed as one incremental batch after the shared initial load.")
        XCTAssertEqual(metrics.signalRefreshes, 64, "Progress-only changes must not rematch or wake every article row.")
        XCTAssertEqual(metrics.signalPublishes, 64)
        XCTAssertEqual(signals[18].revision, 1)
    }

    func testPreviouslyUnmatchedArticleGetsNewReportByExactItemOrCanonicalURL() async {
        let source = WorkspaceReaderResearchRecordFake()
        let matcher = WorkspaceReaderResearchMatcher(
            researchStore: source,
            workspaceStore: WorkspaceReaderResearchSubjectFake(),
            eventStore: WorkspaceReaderResearchEventFake()
        )
        let signal = WorkspaceReaderResearchAssociationSignal()
        let urlOnlySignal = WorkspaceReaderResearchAssociationSignal()

        await matcher.observe(signal, itemID: "article-new", urls: ["https://example.com/story"], enabled: true)
        await matcher.observe(urlOnlySignal, itemID: "article-url-only", urls: ["https://example.com/story"], enabled: true)
        XCTAssertNil(signal.match)
        XCTAssertNil(urlOnlySignal.match)

        let record = makeRecord(
            itemID: "article-new",
            url: "https://example.com/story?utm_source=feed",
            status: .ready,
            report: true
        )
        let recordEntry = ResearchIndexEntry(record: record)
        XCTAssertEqual(recordEntry.seedItemID, "article-new")
        XCTAssertTrue(recordEntry.hasReport)
        let metricsBeforeUpdate = matcher.metricsSnapshot()
        await source.setRecord(record)
        matcher.recordDidChange(id: record.id)
        matcher.recordDidChange(id: record.id)
        await matcher.flushPendingChanges()

        XCTAssertEqual(signal.match?.recordID, record.id)
        XCTAssertEqual(signal.revision, 1)
        XCTAssertEqual(urlOnlySignal.match?.recordID, record.id)
        XCTAssertEqual(urlOnlySignal.revision, 1)
        let directMatch = await matcher.match(itemID: "article-new", urls: [])
        XCTAssertEqual(directMatch?.recordID, record.id)
        let indexCalls = await source.indexCallCount()
        let recordReads = await source.recordCallCount(for: record.id)
        let unrelatedMatch = await matcher.match(itemID: "unrelated-article", urls: ["https://example.com/unrelated"])
        XCTAssertEqual(indexCalls, 1)
        XCTAssertEqual(recordReads, 1)
        XCTAssertNil(unrelatedMatch)
        let metrics = matcher.metricsSnapshot()
        XCTAssertEqual(metrics.fullIndexLoads, 1)
        XCTAssertEqual(metrics.recordReads, 1)
        XCTAssertEqual(metrics.processedBatches, 2, "Duplicate notifications for one record should share one incremental batch.")
        XCTAssertEqual(metrics.signalRefreshes - metricsBeforeUpdate.signalRefreshes, 2, "Publishing one new report should refresh only the two precisely matched visible articles.")
        XCTAssertEqual(metrics.signalPublishes - metricsBeforeUpdate.signalPublishes, 2)
    }

    func testConcurrentFlushWaitsForActiveSignalDelivery() async {
        let deliveryGate = WorkspaceReaderResearchGate()
        let source = WorkspaceReaderResearchRecordFake()
        let matcher = WorkspaceReaderResearchMatcher(
            researchStore: source,
            workspaceStore: WorkspaceReaderResearchSubjectFake(),
            eventStore: WorkspaceReaderResearchEventFake(),
            beforeSignalDelivery: { await deliveryGate.hold() }
        )
        let signal = WorkspaceReaderResearchAssociationSignal()
        await matcher.observe(signal, itemID: "article-pending", urls: [], enabled: true)

        let record = makeRecord(itemID: "article-pending", url: nil, status: .ready, report: true)
        await source.setRecord(record)
        matcher.recordDidChange(id: record.id)
        await deliveryGate.waitUntilEntered()

        let completion = WorkspaceReaderResearchCompletionProbe()
        let waiter = Task {
            await matcher.flushPendingChanges()
            await completion.markCompleted()
        }
        for _ in 0..<128 where matcher.metricsSnapshot().signalDeliveryWaits == 0 {
            await Task.yield()
        }

        XCTAssertEqual(matcher.metricsSnapshot().signalDeliveryWaits, 1)
        let completedBeforeDelivery = await completion.completed()
        XCTAssertFalse(completedBeforeDelivery)
        XCTAssertNil(signal.match)

        await deliveryGate.open()
        await waiter.value
        XCTAssertEqual(signal.match?.recordID, record.id)
        let completedAfterDelivery = await completion.completed()
        XCTAssertTrue(completedAfterDelivery)
    }

    func testStaleSignalGenerationCannotRemoveNewIdentityRegistration() async {
        let first = makeRecord(itemID: "article-old", url: "https://example.com/old", status: .ready, report: true)
        let second = makeRecord(itemID: "article-current", url: "https://example.com/current", status: .ready, report: true)
        let matcher = WorkspaceReaderResearchMatcher(
            researchStore: WorkspaceReaderResearchRecordFake(
                entries: [ResearchIndexEntry(record: first), ResearchIndexEntry(record: second)],
                records: [first, second]
            ),
            workspaceStore: WorkspaceReaderResearchSubjectFake(),
            eventStore: WorkspaceReaderResearchEventFake()
        )
        let signal = WorkspaceReaderResearchAssociationSignal()

        await matcher.observe(signal, itemID: "article-old", urls: ["https://example.com/old"], enabled: true)
        await matcher.observe(signal, itemID: "article-current", urls: ["https://example.com/current"], enabled: true)
        XCTAssertEqual(signal.match?.recordID, second.id)

        await matcher.refreshRegisteredSignalForTesting(signal.id, generation: 1)
        XCTAssertEqual(signal.match?.recordID, second.id)
        XCTAssertEqual(signal.revision, 3)
    }

    func testChangeDuringInitialLoadIsRetriedAndOldClearSnapshotCannotResurrect() async {
        let staleRecord = makeRecord(itemID: "article-a", url: "https://example.com/a", status: .ready, report: true)
        let gate = WorkspaceReaderResearchGate()
        let source = WorkspaceReaderResearchRecordFake(
            entries: [ResearchIndexEntry(record: staleRecord)],
            records: [staleRecord],
            indexGate: gate
        )
        let matcher = WorkspaceReaderResearchMatcher(
            researchStore: source,
            workspaceStore: WorkspaceReaderResearchSubjectFake(),
            eventStore: WorkspaceReaderResearchEventFake()
        )
        let signal = WorkspaceReaderResearchAssociationSignal()
        let request = Task {
            await matcher.observe(signal, itemID: "article-a", urls: ["https://example.com/a"], enabled: true)
        }

        await gate.waitUntilEntered()
        await source.setEntries([])
        matcher.recordDidChange(id: nil)
        await gate.open()
        await request.value

        XCTAssertNil(signal.match)
        let indexCalls = await source.indexCallCount()
        XCTAssertEqual(indexCalls, 2)
        let metrics = matcher.metricsSnapshot()
        XCTAssertEqual(metrics.fullIndexLoads, 2)
        XCTAssertEqual(metrics.signalPublishes, 0)
    }

    func testRapidIdentitySwitchAndUnregisterRejectLateLookupResults() async {
        let first = makeRecord(itemID: "article-a", url: "https://example.com/a", status: .ready, report: true)
        let second = makeRecord(itemID: "article-b", url: "https://example.com/b", status: .ready, report: true)
        let gate = WorkspaceReaderResearchGate()
        let source = WorkspaceReaderResearchRecordFake(
            entries: [ResearchIndexEntry(record: first), ResearchIndexEntry(record: second)],
            records: [first, second],
            indexGate: gate
        )
        let matcher = WorkspaceReaderResearchMatcher(
            researchStore: source,
            workspaceStore: WorkspaceReaderResearchSubjectFake(),
            eventStore: WorkspaceReaderResearchEventFake()
        )
        let signal = WorkspaceReaderResearchAssociationSignal()

        let oldRequest = Task {
            await matcher.observe(signal, itemID: "article-a", urls: ["https://example.com/a"], enabled: true)
        }
        await gate.waitUntilEntered()
        let currentRequest = Task {
            await matcher.observe(signal, itemID: "article-b", urls: ["https://example.com/b"], enabled: true)
        }
        await gate.open()
        await oldRequest.value
        await currentRequest.value
        XCTAssertEqual(signal.match?.recordID, second.id)

        let hiddenGate = WorkspaceReaderResearchGate()
        let hiddenSource = WorkspaceReaderResearchRecordFake(
            entries: [ResearchIndexEntry(record: first)],
            records: [first],
            indexGate: hiddenGate
        )
        let hiddenMatcher = WorkspaceReaderResearchMatcher(
            researchStore: hiddenSource,
            workspaceStore: WorkspaceReaderResearchSubjectFake(),
            eventStore: WorkspaceReaderResearchEventFake()
        )
        let hiddenSignal = WorkspaceReaderResearchAssociationSignal()
        let hiddenRequest = Task {
            await hiddenMatcher.observe(hiddenSignal, itemID: "article-a", urls: ["https://example.com/a"], enabled: true)
        }
        await hiddenGate.waitUntilEntered()
        hiddenMatcher.removeObserver(hiddenSignal)
        await hiddenGate.open()
        await hiddenRequest.value

        XCTAssertNil(hiddenSignal.match)
        let hiddenMetrics = hiddenMatcher.metricsSnapshot()
        XCTAssertEqual(hiddenMetrics.signalRefreshes, 0)
        XCTAssertEqual(hiddenMetrics.signalPublishes, 0)
    }

    private func makeRecord(
        itemID: String?,
        url: String?,
        status: ResearchStatus,
        report: Bool,
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> ResearchRecord {
        var record = researchTestRecord(
            id: UUID(),
            title: "Example story",
            status: status,
            updatedAt: updatedAt,
            seedURL: url,
            report: report ? BurstResearch(summary: "Grounded summary") : nil
        )
        record.seed.itemID = itemID
        return record
    }
}
