import XCTest
@testable import NewsBar

@MainActor
final class AISummaryCacheFirstTests: XCTestCase {
    func testCachedSummaryIsShownWithoutAskingForGeneration() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-summary-cache-first-\(UUID().uuidString).json")
        let store = AISummaryCacheStore(fileURL: url, language: .zh)
        let items = [NewsItem(title: "旧闻", url: "https://example.com/old", source: .weibo)]
        let summary = "【趋势概览】\n【旧闻】上次的内容。\n引用：[#0]"
        let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        await store.save(
            AISummaryCacheEntry(
                summary: summary,
                items: items,
                // Deliberately different from today's items: a stale cache is
                // still the best thing to show while the feed catches up.
                contentHash: "hash-from-yesterday",
                trendHistoryHash: "history",
                generatedAt: generatedAt,
                trendItemCount: 1
            )
        )
        let orchestrator = NewsOrchestrator(
            chineseSummaryCache: store,
            englishSummaryCache: store
        )
        let settings = AppSettings()
        settings.aiSummaryEnabled = true
        let attemptsBefore = AISummaryService.readGenerationAttempts(
            target: .dashboard,
            mode: .shared
        )

        await orchestrator.loadCached(settings: settings)

        XCTAssertEqual(orchestrator.aiSummaryState.completedText, summary)
        XCTAssertEqual(orchestrator.aiSummaryItems, items)
        XCTAssertEqual(orchestrator.aiSummaryRestoredAt, generatedAt)
        XCTAssertFalse(
            AISummaryPresentationPolicy.needsAutomaticGeneration(
                state: orchestrator.aiSummaryState,
                enabled: true
            )
        )
        XCTAssertEqual(
            AISummaryService.readGenerationAttempts(target: .dashboard, mode: .shared),
            attemptsBefore
        )

        await store.clear()
        try? FileManager.default.removeItem(at: url)
    }
}
