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
}
