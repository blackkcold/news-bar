import XCTest
@testable import NewsBar

private actor ConcurrencyProbe {
    private var active = 0
    private var maximum = 0

    func begin() {
        active += 1
        maximum = max(maximum, active)
    }

    func end() {
        active -= 1
    }

    var maxActive: Int { maximum }
}

final class ResearchCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func queuedRecord(_ title: String) -> ResearchRecord {
        var record = researchTestRecord(title: title, status: .queued, updatedAt: now)
        record.run.phase = .idle
        record.run.startedAt = nil
        record.reportVersion = 0
        return record
    }

    private func success(_ summary: String = "新报告") -> ResearchExecution {
        ResearchExecution(
            research: BurstResearch(summary: summary, searchStatus: .succeeded),
            error: nil,
            pagesRead: 2,
            searchCalls: 1,
            aiCalls: 1,
            queries: ["q"]
        )
    }

    @MainActor
    func testSuccessfulRunBecomesReadyAndNotifies() async throws {
        let record = queuedRecord("事件")
        let store = ResearchFakeStore(records: [record])
        var notified: [String] = []
        let coordinator = ResearchCoordinator(
            store: store,
            maxConcurrent: 1,
            notifier: { notified.append($0.id) }
        )

        await coordinator.schedule(recordID: record.id) { _, _ in self.success() }
        await coordinator.waitForAll()

        let stored = await store.record(id: record.id)
        let saved = try XCTUnwrap(stored)
        XCTAssertEqual(saved.status, .ready)
        XCTAssertEqual(saved.report?.summary, "新报告")
        XCTAssertEqual(saved.reportVersion, 1)
        XCTAssertEqual(saved.run.phase, .done)
        XCTAssertEqual(saved.run.pagesRead, 2)
        XCTAssertEqual(saved.run.searchCalls, 1)
        XCTAssertEqual(saved.run.aiCalls, 1)
        XCTAssertNotNil(saved.run.finishedAt)
        XCTAssertEqual(notified, [record.id])
    }

    @MainActor
    func testFailureKeepsPreviousReportAndDoesNotNotify() async throws {
        let oldReport = BurstResearch(summary: "旧报告")
        let record = researchTestRecord(
            title: "事件",
            status: .ready,
            updatedAt: now.addingTimeInterval(-100),
            report: oldReport
        )
        let store = ResearchFakeStore(records: [record])
        var notified: [String] = []
        let coordinator = ResearchCoordinator(
            store: store,
            maxConcurrent: 1,
            notifier: { notified.append($0.id) }
        )

        await coordinator.schedule(recordID: record.id) { _, _ in .failure("boom") }
        await coordinator.waitForAll()

        let stored = await store.record(id: record.id)
        let saved = try XCTUnwrap(stored)
        XCTAssertEqual(saved.status, .failed)
        XCTAssertEqual(saved.report?.summary, "旧报告")
        XCTAssertEqual(saved.run.lastError, "boom")
        XCTAssertTrue(notified.isEmpty)
    }

    @MainActor
    func testMaxConcurrencyIsOne() async throws {
        let records = (0..<3).map { queuedRecord("事件 \($0)") }
        let store = ResearchFakeStore(records: records)
        let probe = ConcurrencyProbe()
        let coordinator = ResearchCoordinator(store: store, notifier: { _ in })

        for record in records {
            await coordinator.schedule(recordID: record.id) { _, _ in
                await probe.begin()
                try? await Task.sleep(nanoseconds: 20_000_000)
                await probe.end()
                return self.success()
            }
        }
        await coordinator.waitForAll()

        let maxActive = await probe.maxActive
        XCTAssertEqual(maxActive, 1)

        for record in records {
            let saved = await store.record(id: record.id)
            XCTAssertEqual(saved?.status, .ready)
        }
    }

    @MainActor
    func testCancelMarksRunningRecordCancelled() async throws {
        let record = queuedRecord("事件")
        let store = ResearchFakeStore(records: [record])
        let coordinator = ResearchCoordinator(store: store, notifier: { _ in })

        await coordinator.schedule(recordID: record.id) { _, _ in
            try? await Task.sleep(nanoseconds: 300_000_000)
            return self.success()
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        coordinator.cancel(recordID: record.id)
        await coordinator.waitForAll()
        try? await Task.sleep(nanoseconds: 60_000_000)

        let stored = await store.record(id: record.id)
        let saved = try XCTUnwrap(stored)
        XCTAssertEqual(saved.status, .cancelled)
        XCTAssertNil(saved.report)
    }

    @MainActor
    func testCancellingQueuedRecordDoesNotStartIt() async throws {
        let first = queuedRecord("一")
        let second = queuedRecord("二")
        let store = ResearchFakeStore(records: [first, second])
        let coordinator = ResearchCoordinator(store: store, maxConcurrent: 1, notifier: { _ in })

        await coordinator.schedule(recordID: first.id) { _, _ in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return self.success("一")
        }
        await coordinator.schedule(recordID: second.id) { _, _ in self.success("二") }
        try? await Task.sleep(nanoseconds: 15_000_000)
        coordinator.cancel(recordID: second.id)
        await coordinator.waitForAll()
        try? await Task.sleep(nanoseconds: 60_000_000)

        let stored = await store.record(id: second.id)
        let saved = try XCTUnwrap(stored)
        XCTAssertEqual(saved.status, .cancelled)
        XCTAssertNil(saved.report)
    }

    @MainActor
    func testSupersededCancellationIsNotRecordedAsFailure() async throws {
        let record = queuedRecord("撤销授权")
        let store = ResearchFakeStore(records: [record])
        let coordinator = ResearchCoordinator(store: store, notifier: { _ in })
        let cancelledMessage = L10n.string("research.error.cancelled", language: .zh)

        await coordinator.schedule(recordID: record.id) { _, _ in
            .failure(cancelledMessage)
        }
        await coordinator.waitForAll()

        let stored = await store.record(id: record.id)
        let saved = try XCTUnwrap(stored)
        XCTAssertEqual(saved.status, .cancelled)
        XCTAssertNil(saved.run.lastError)
    }

    @MainActor
    func testAutomaticFailureIsPersistedAndManualRetryBypassesCooldown() async throws {
        var record = researchTestRecord(title: "热点", status: .queued, origin: .burst, updatedAt: Date())
        record.run.startedAt = nil
        let store = ResearchFakeStore(records: [record])
        let coordinator = ResearchCoordinator(store: store, notifier: { _ in })

        let accepted = await coordinator.schedule(recordID: record.id, trigger: .burst) { record, progress in
            var snapshot = ResearchRun()
            snapshot.origin = record.run.origin
            snapshot.phase = .searching
            await progress(snapshot)
            return .failure("failed")
        }
        XCTAssertTrue(accepted)
        await coordinator.waitForAll()
        let failedRecord = await store.record(id: record.id)
        let failed = try XCTUnwrap(failedRecord)
        XCTAssertEqual(failed.automaticAttempts, 1)
        XCTAssertNotNil(failed.lastAutomaticAttemptAt)
        XCTAssertEqual(failed.run.origin, .burst)

        let blocked = await coordinator.schedule(recordID: record.id, trigger: .burst) { _, _ in
            XCTFail("automatic retry ignored cooldown")
            return .failure("unexpected")
        }
        XCTAssertFalse(blocked)
        var manualOrigin: ResearchOrigin?
        let manual = await coordinator.schedule(recordID: record.id, trigger: .manual) { record, _ in
            manualOrigin = record.run.origin
            return .failure("manual failure")
        }
        XCTAssertTrue(manual)
        await coordinator.waitForAll()
        XCTAssertEqual(manualOrigin, .manual)
        let retriedRecord = await store.record(id: record.id)
        let retried = try XCTUnwrap(retriedRecord)
        XCTAssertEqual(retried.automaticAttempts, 1)
    }

    @MainActor
    func testAutomaticQueueKeepsOnlyOneWaitingJob() async throws {
        let records = (0..<8).map { index -> ResearchRecord in
            var record = researchTestRecord(title: "热点 \(index)", status: .queued, origin: .burst, updatedAt: Date())
            record.run.startedAt = nil
            return record
        }
        let store = ResearchFakeStore(records: records)
        let coordinator = ResearchCoordinator(store: store, automaticStartInterval: 0, notifier: { _ in })
        var started: [String] = []
        for (index, record) in records.enumerated() {
            let accepted = await coordinator.schedule(recordID: record.id, trigger: .burst) { record, _ in
                started.append(record.id)
                if index == 0 { try? await Task.sleep(nanoseconds: 200_000_000) }
                return self.success()
            }
            XCTAssertTrue(accepted)
        }
        await coordinator.waitForAll()
        // The first job is already running; each later automatic job replaces
        // the single waiting slot, so only the last one survives.
        XCTAssertEqual(Set(started), Set([records[0].id, records[7].id]))
        for index in 1...6 {
            let evicted = await store.record(id: records[index].id)
            XCTAssertEqual(try XCTUnwrap(evicted).status, .interrupted, "record \(index)")
        }
    }

    @MainActor
    func testAutomaticJobsAreSerialAndSpacedEvenWithHigherConcurrency() async {
        let records = (0..<2).map { index -> ResearchRecord in
            var record = researchTestRecord(title: "热点 \(index)", status: .queued, origin: .keyword, updatedAt: Date())
            record.run.startedAt = nil
            return record
        }
        let store = ResearchFakeStore(records: records)
        let probe = ConcurrencyProbe()
        let coordinator = ResearchCoordinator(store: store, maxConcurrent: 3, automaticStartInterval: 0.12, notifier: { _ in })
        var starts: [Date] = []
        for record in records {
            await coordinator.schedule(recordID: record.id, trigger: .keyword) { _, _ in
                starts.append(Date())
                await probe.begin()
                try? await Task.sleep(nanoseconds: 40_000_000)
                await probe.end()
                return self.success()
            }
        }
        await coordinator.waitForAll()
        let maximum = await probe.maxActive
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(starts.count, 2)
        if starts.count == 2 { XCTAssertGreaterThanOrEqual(starts[1].timeIntervalSince(starts[0]), 0.10) }
    }

    @MainActor
    func testLegacyFailedRunCountsAsAnEarlierAttempt() async throws {
        let old = Date().addingTimeInterval(-86_400)
        let record = researchTestRecord(title: "旧失败", status: .failed, origin: .burst, updatedAt: old)
        let store = ResearchFakeStore(records: [record])
        let coordinator = ResearchCoordinator(store: store, notifier: { _ in })
        let accepted = await coordinator.schedule(recordID: record.id, trigger: .burst) { _, _ in .failure("failed again") }
        XCTAssertTrue(accepted)
        await coordinator.waitForAll()
        let stored = await store.record(id: record.id)
        XCTAssertEqual(try XCTUnwrap(stored).automaticAttempts, 2)
    }

    func testExplicitManualRunOriginSurvivesRecordRoundTrip() throws {
        var record = researchTestRecord(title: "手动重试", status: .failed, origin: .burst, updatedAt: Date())
        record.run.origin = .manual
        let decoded = try JSONDecoder().decode(ResearchRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.origin, .burst)
        XCTAssertEqual(decoded.run.origin, .manual)
    }

    @MainActor
    func testExpiredAutomaticJobIsInterruptedWithoutStarting() async throws {
        let records = (0..<2).map { index -> ResearchRecord in
            var record = researchTestRecord(title: "过期 \(index)", status: .queued, origin: .burst, updatedAt: Date())
            record.run.startedAt = nil
            return record
        }
        let store = ResearchFakeStore(records: records)
        let coordinator = ResearchCoordinator(store: store, automaticStartInterval: 0, automaticQueueLifetime: 0.05, notifier: { _ in })
        await coordinator.schedule(recordID: records[0].id, trigger: .burst) { _, _ in
            try? await Task.sleep(nanoseconds: 160_000_000)
            return self.success()
        }
        await coordinator.schedule(recordID: records[1].id, trigger: .burst) { _, _ in
            XCTFail("expired automatic job started")
            return self.success()
        }
        await coordinator.waitForAll()
        try? await Task.sleep(nanoseconds: 30_000_000)
        let expired = await store.record(id: records[1].id)
        XCTAssertEqual(try XCTUnwrap(expired).status, .interrupted)
    }
}
