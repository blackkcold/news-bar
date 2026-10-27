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

    private func makeModel() -> (ResearchCenterModel, ResearchFakeStore, NewsOrchestrator) {
        let store = ResearchFakeStore(records: records())
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
            }
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
}
