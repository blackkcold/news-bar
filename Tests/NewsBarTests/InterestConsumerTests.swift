import XCTest
@testable import NewsBar

final class InterestConsumerTests: XCTestCase {
    func testRevokedSummaryRequestStopsBeforeBudgetOrNetworkDispatch() async {
        let before = AISummaryService.readGenerationAttempts(target: .dashboard, mode: .shared)
        do {
            _ = try await AISummaryService.summarize(items: [], connection: ResolvedAIConnection(baseURL: "https://invalid.example/v1", responseFormat: .openAI, authHeaderName: "Authorization", authHeaderPrefix: "Bearer ", apiVersion: nil),
                                                     model: "test", apiKey: "not-a-real-key", target: .dashboard, budgetMode: .shared, requestAllowed: { false })
            XCTFail("Revoked requests must not dispatch")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(AISummaryService.readGenerationAttempts(target: .dashboard, mode: .shared), before)
    }
    private func item(_ title: String, id: Int, rank: Int? = nil, hot: String? = nil, source: NewsSource = .weibo) -> NewsItem {
        NewsItem(title: title, url: "https://example.com/\(id)", source: source, rank: rank, hotLabel: hot)
    }

    func testResearchKeepsPublicHeatSlotAndUsesInterestForSecondSlot() {
        var state = LocalInterestState()
        state.learningEnabled = true
        state.followedTopics = ["AI", "科技", "人工智能", "芯片"]
        let publicTop = item("公共事件", id: 1, rank: 1, hot: "爆")
        let interested = item("AI 芯片新进展", id: 2, rank: 20, hot: "爆")
        let other = item("足球新闻", id: 3, rank: 2, hot: "爆")
        let selected = ResearchSelectionPolicy.select(items: [other, interested, publicTop], state: state, limit: 2)
        XCTAssertEqual(selected.map(\.item.id), [publicTop.id, interested.id])
        XCTAssertNotNil(selected.first?.publicHeat)
        let keyword = item("AI 主题", id: 4, source: .rss(name: "Test", url: "https://example.com/feed"))
        XCTAssertNil(ResearchSelectionPolicy.select(items: [keyword], state: state, limit: 2).first?.publicHeat)
    }

    func testNotificationSkipsReadContentAndCarriesOnlyFrozenTitleLinks() {
        var state = LocalInterestState()
        state.learningEnabled = true
        let read = item("已读", id: 1)
        let fresh = item("新进展", id: 2)
        _ = state.record(item: read, kind: .qualifiedRead, epoch: state.consentEpoch)
        let selection = NotificationSelectionPolicy.select(items: [read, fresh], state: state, count: 3)
        XCTAssertEqual(selection.map(\.id), [fresh.id])
        let content = NotificationService.titleContent(items: selection, daily: false)
        XCTAssertEqual(content.userInfo["url"] as? String, fresh.url)
        XCTAssertEqual(content.userInfo["type"] as? String, "news")
        XCTAssertFalse(content.body.contains("已读"))
    }

    func testEnglishManifestParserSeparatesCategoriesAndChecksTrendSource() {
        let text = "【Trend Overview】\n【Trend】\nTitle-level overview\nCitation: [#1]\n【Daily Essentials】\n【Daily】\nAnother title overview\nCitation: [#0]"
        let result = AISummaryParser.parseDualSummary(text, itemCount: 2, trendIndices: [1])
        XCTAssertEqual(result.trendOverview.count, 1)
        XCTAssertEqual(result.trendOverview.first?.primaryIndex, 1)
        XCTAssertEqual(result.dailyEssentials.first?.primaryIndex, 0)
        XCTAssertFalse(result.isLegacyFallback)
    }

    @MainActor
    func testResearchRestartPersistsAndRejectsPostClearArtifacts() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("db.sqlite")
        let store = LocalInterestStore(fileURL: path)
        let controller = InterestController(store: store)
        await controller.prepare()
        let epoch = controller.state.consentEpoch
        var research = PersistedResearchState()
        research.notifiedBursts = ["事件"]
        research.notifiedKeywords = ["AI\n事件"]
        research.artifacts = ["事件": BurstResearch(summary: "已生成")]
        research.lastResearchAt = Date()
        controller.updateResearch(research, epoch: epoch)
        await controller.flush()
        let restored = try await LocalInterestStore(fileURL: path).load()
        XCTAssertEqual(restored.research.artifacts["事件"]?.summary, "已生成")
        await controller.clear(keepBookmarks: false)
        controller.updateResearch(research, epoch: epoch)
        await controller.flush()
        let cleared = try await store.load()
        XCTAssertTrue(cleared.research.artifacts.isEmpty)
        XCTAssertTrue(cleared.research.notifiedBursts.isEmpty)
    }
}
