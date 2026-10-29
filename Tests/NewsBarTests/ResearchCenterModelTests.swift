import XCTest
@testable import NewsBar

@MainActor
final class ResearchCenterModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func records() -> [ResearchRecord] {
        [
            researchTestRecord(
                title: "爆款未读",
                status: .ready,
                origin: .burst,
                updatedAt: now,
                isRead: false,
                report: BurstResearch(summary: "爆款摘要")
            ),
            researchTestRecord(
                title: "手动已读",
                status: .ready,
                origin: .manual,
                updatedAt: now.addingTimeInterval(-60),
                isRead: true,
                report: BurstResearch(summary: "手动摘要")
            ),
            researchTestRecord(
                title: "关键词失败",
                status: .failed,
                origin: .keyword,
                updatedAt: now.addingTimeInterval(-120),
                isRead: false
            ),
            researchTestRecord(
                title: "固定爆款",
                status: .ready,
                origin: .burst,
                updatedAt: now.addingTimeInterval(-180),
                isPinned: true,
                isRead: true,
                report: BurstResearch(summary: "固定摘要")
            ),
        ]
    }

    private func makeModel(
        records: [ResearchRecord]? = nil,
        executor: ResearchCenterModel.ResearchExecutor? = nil
    ) -> (ResearchCenterModel, ResearchFakeStore, NewsOrchestrator) {
        let store = ResearchFakeStore(records: records ?? self.records())
        let coordinator = ResearchCoordinator(store: store, notifier: { _ in })
        let orchestrator = NewsOrchestrator()
        let settings = AppSettings()
        let model = ResearchCenterModel(
            orchestrator: orchestrator,
            settings: settings,
            store: store,
            coordinator: coordinator,
            clearHistoryAction: {
                try? await store.deleteAll()
                return ResearchClearResult(isComplete: true)
            },
            executor: executor
        )
        return (model, store, orchestrator)
    }

    func testLoadSelectsNewestAndBuildsSummary() async {
        let (model, _, orchestrator) = makeModel()
        await model.load()

        XCTAssertEqual(model.entries.count, 4)
        XCTAssertEqual(model.selectedID, model.entries.first?.id)
        XCTAssertEqual(model.entries.first?.topic, "爆款未读")
        XCTAssertEqual(model.summary.burstCount, 2)
        XCTAssertEqual(model.summary.unreadBurstCount, 1)
        XCTAssertEqual(orchestrator.researchSummary, model.summary)
    }

    func testFiltersSearchAndUnreadOnly() async {
        let (model, _, _) = makeModel()
        await model.load()

        model.filter = .burst
        XCTAssertEqual(model.visibleEntries.count, 2)

        model.filter = .unread
        XCTAssertEqual(model.visibleEntries.count, 2)

        model.filter = .failed
        XCTAssertEqual(model.visibleEntries.count, 1)

        model.filter = .pinned
        XCTAssertEqual(model.visibleEntries.count, 1)

        model.filter = .manual
        XCTAssertEqual(model.visibleEntries.count, 1)

        model.filter = .all
        model.onlyUnread = true
        XCTAssertEqual(model.visibleEntries.count, 2)

        model.onlyUnread = false
        model.searchText = "关键词"
        XCTAssertEqual(model.visibleEntries.count, 1)
        XCTAssertEqual(model.visibleEntries.first?.topic, "关键词失败")
    }

    func testMarkReadPersistsAndUpdatesPopoverSummary() async throws {
        let (model, store, orchestrator) = makeModel()
        await model.load()
        let unread = try XCTUnwrap(model.entries.first { $0.topic == "爆款未读" })

        await model.markRead(id: unread.id, read: true)

        let stored = await store.record(id: unread.id)
        XCTAssertEqual(stored?.isRead, true)
        XCTAssertEqual(model.summary.unreadBurstCount, 0)
        XCTAssertEqual(orchestrator.researchSummary.unreadBurstCount, 0)
    }

    func testOpeningAnAlreadyReadRecordUpdatesItsAccessTime() async throws {
        let oldAccess = Date().addingTimeInterval(-3600)
        let record = researchTestRecord(title: "已读报告", lastAccessedAt: oldAccess, isRead: true)
        let store = ResearchFakeStore(records: [record])
        let settings = AppSettings()
        let originalSetting = settings.researchMarkReadOnOpen
        defer { settings.researchMarkReadOnOpen = originalSetting }
        settings.researchMarkReadOnOpen = true
        let model = ResearchCenterModel(
            orchestrator: NewsOrchestrator(),
            settings: settings,
            store: store,
            coordinator: ResearchCoordinator(store: store, notifier: { _ in })
        )

        await model.load()
        await model.select(record.id)
        try await Task.sleep(nanoseconds: 450_000_000)

        let stored = await store.record(id: record.id)
        XCTAssertGreaterThan(try XCTUnwrap(stored?.lastAccessedAt), oldAccess)
        XCTAssertEqual(stored?.isRead, true)
    }

    func testSlowPreviousSelectionCannotReplaceCurrentDetail() async throws {
        let first = researchTestRecord(title: "慢记录", status: .ready, updatedAt: now, isRead: true)
        let second = researchTestRecord(title: "新选择", status: .ready, updatedAt: now, isRead: true)
        let (model, store, _) = makeModel(records: [first, second])
        await model.load()
        await store.setRecordDelay(id: first.id, nanoseconds: 200_000_000)

        let slowSelection = Task { await model.select(first.id) }
        try await Task.sleep(nanoseconds: 20_000_000)
        await model.select(second.id)
        await slowSelection.value

        XCTAssertEqual(model.selectedID, second.id)
        XCTAssertEqual(model.selectedRecord?.id, second.id)
    }

    func testActionNoticeIsScopedToItsRecord() async throws {
        let first = researchTestRecord(title: "进行中", status: .running, updatedAt: now)
        let second = researchTestRecord(title: "另一条", status: .failed, updatedAt: now)
        let (model, _, _) = makeModel(records: [first, second])
        await model.load()

        await model.retry(id: first.id)

        XCTAssertNotNil(model.notice(for: first.id))
        XCTAssertNil(model.notice(for: second.id))
    }

    func testTogglePinKeepsIssueBadge() async throws {
        let record = researchTestRecord(title: "只读记录", status: .ready, updatedAt: now)
        let (model, _, _) = makeModel(records: [record])
        await model.load()
        let index = try XCTUnwrap(model.entries.firstIndex { $0.id == record.id })
        model.entries[index].issue = .unsupportedVersion

        await model.togglePin(id: record.id)

        XCTAssertEqual(model.entries.first { $0.id == record.id }?.issue, .unsupportedVersion)
    }

    func testDeleteClearsRetryOverlay() async throws {
        let record = researchTestRecord(title: "待删除", status: .failed, updatedAt: now)
        let (model, _, _) = makeModel(records: [record])
        await model.load()
        model.retryOverlay[record.id] = ResearchRetryOverlay()

        await model.delete(id: record.id)

        XCTAssertNil(model.retryOverlay[record.id])
    }

    func testExplicitUnreadCancelsPendingOpenRead() async throws {
        let record = researchTestRecord(title: "保持未读", status: .ready, updatedAt: now, isRead: false)
        let (model, store, _) = makeModel(records: [record])
        await model.load()
        await model.select(record.id)

        await model.markRead(id: record.id, read: false)
        try await Task.sleep(nanoseconds: 450_000_000)

        let stored = await store.record(id: record.id)
        XCTAssertEqual(stored?.isRead, false)
    }

    func testDeleteRemovesOnlyTarget() async throws {
        let (model, store, _) = makeModel()
        await model.load()
        let manual = try XCTUnwrap(model.entries.first { $0.topic == "手动已读" })

        await model.delete(id: manual.id)

        XCTAssertEqual(model.entries.count, 3)
        let deleted = await store.record(id: manual.id)
        XCTAssertNil(deleted)
        let remaining = await store.snapshot()
        XCTAssertEqual(remaining.count, 3)
    }

    func testTogglePinPersists() async throws {
        let (model, store, _) = makeModel()
        await model.load()
        let manual = try XCTUnwrap(model.entries.first { $0.topic == "手动已读" })

        await model.togglePin(id: manual.id)

        let stored = await store.record(id: manual.id)
        XCTAssertEqual(stored?.isPinned, true)
        XCTAssertEqual(model.entries.first { $0.id == manual.id }?.isPinned, true)
    }

    func testClearHistoryDeletesAllRecords() async {
        let (model, store, _) = makeModel()
        await model.load()

        await model.clearHistory()

        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(model.selectedID)
        let didDeleteAll = await store.didDeleteAll
        XCTAssertTrue(didDeleteAll)
    }

    // MARK: - Retry feedback

    func testPollDoesNotClearRetryOverlayBeforeQueueWrite() async throws {
        let target = researchTestRecord(title: "慢速重试", status: .failed, updatedAt: now)
        let (model, store, _) = makeModel(records: [target], executor: { _, _ in .failure("test") })
        await model.load()
        await store.setSaveDelay(nanoseconds: 800_000_000)

        let retry = Task { await model.retry(id: target.id) }
        for _ in 0..<100 where model.retryOverlay[target.id] == nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(model.retryOverlay[target.id])
        let poll = Task { await model.poll(id: target.id) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(model.retryOverlay[target.id], "A stale terminal record must not cancel the pending retry")
        poll.cancel()
        await poll.value
        await retry.value
    }

    func testRetryShowsQueuedOverlayThenAccepts() async throws {
        let target = researchTestRecord(title: "待重试", status: .failed, updatedAt: now)
        let (model, store, _) = makeModel(records: [target], executor: { _, _ in
            try? await Task.sleep(nanoseconds: 300_000_000)
            return .failure("test")
        })
        await model.load()
        // Hold the queued write open so the overlay is observable.
        await store.setSaveDelay(nanoseconds: 200_000_000)

        let task = Task { await model.retry(id: target.id) }
        var observedQueued = false
        for _ in 0..<60 {
            if model.retryOverlay[target.id]?.status == .queued {
                observedQueued = true
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(observedQueued, "overlay must appear before the coordinator returns")
        await task.value
        XCTAssertNil(model.actionNotice)

        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let stored = await store.record(id: target.id)
        XCTAssertEqual(stored?.status, .failed, "accepted retry must actually run the executor")
        XCTAssertNil(model.retryOverlay[target.id])
    }

    func testRetryOnActiveRecordShowsInfoNotice() async throws {
        let active = researchTestRecord(title: "在跑", status: .running, updatedAt: now)
        let (model, _, _) = makeModel(records: [active])
        await model.load()

        await model.retry(id: active.id)

        XCTAssertNil(model.retryOverlay[active.id])
        XCTAssertEqual(model.actionNotice?.tone, .info)
    }

    func testRetryPersistenceFailureShowsErrorAndClearsOverlay() async throws {
        let failed = researchTestRecord(title: "写盘失败", status: .failed, updatedAt: now)
        let (model, store, _) = makeModel(records: [failed])
        await model.load()
        await store.setShouldFailSaves(true)

        await model.retry(id: failed.id)

        XCTAssertNil(model.retryOverlay[failed.id])
        XCTAssertEqual(model.actionNotice?.tone, .error)
    }

    // MARK: - Opened-read state

    func testOpeningFinishedRecordMarksReadOnce() async throws {
        let (model, store, _) = makeModel()
        await model.load()
        let unread = try XCTUnwrap(model.entries.first { $0.topic == "爆款未读" })

        await model.select(unread.id)
        try? await Task.sleep(nanoseconds: 420_000_000)

        let stored = await store.record(id: unread.id)
        XCTAssertEqual(stored?.isRead, true)
        XCTAssertEqual(model.entries.first { $0.id == unread.id }?.isRead, true)
        let saves = await store.saveCount(for: unread.id)
        XCTAssertEqual(saves, 1, "one merged save per open")
    }

    func testOpeningActiveRecordDoesNotMarkRead() async throws {
        let active = researchTestRecord(title: "排队中", status: .queued, updatedAt: now)
        let (model, store, _) = makeModel(records: [active])
        await model.load()

        await model.select(active.id)
        try? await Task.sleep(nanoseconds: 420_000_000)

        let stored = await store.record(id: active.id)
        XCTAssertEqual(stored?.isRead, false)
    }

    func testLoadAutoSelectionDoesNotMarkRead() async throws {
        let (model, store, _) = makeModel()
        await model.load()
        let first = try XCTUnwrap(model.selectedID)

        try? await Task.sleep(nanoseconds: 420_000_000)

        let stored = await store.record(id: first)
        XCTAssertEqual(stored?.isRead, false)
    }

    func testRapidSelectionOnlyMarksTheLastRecord() async throws {
        let (model, store, _) = makeModel()
        await model.load()
        let records = model.entries.filter { $0.status.marksReadOnOpen }
        let first = try XCTUnwrap(records.first)
        let second = try XCTUnwrap(records.dropFirst().first)

        await model.select(first.id)
        await model.select(second.id)
        try? await Task.sleep(nanoseconds: 420_000_000)

        let firstStored = await store.record(id: first.id)
        let secondStored = await store.record(id: second.id)
        XCTAssertEqual(firstStored?.isRead, false)
        XCTAssertEqual(secondStored?.isRead, true)
    }

    func testSelectDoesNotRescanStorage() async throws {
        let (model, store, _) = makeModel()
        await model.load()
        let unread = try XCTUnwrap(model.entries.first { $0.topic == "爆款未读" })
        let afterLoad = await store.storageFootprintCount()

        await model.select(unread.id)
        try? await Task.sleep(nanoseconds: 420_000_000)

        let afterSelect = await store.storageFootprintCount()
        XCTAssertEqual(afterSelect, afterLoad)
    }
}
