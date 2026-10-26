import XCTest
@testable import NewsBar

final class SummaryManifestTests: XCTestCase {
    private func item(_ title: String, _ source: NewsSource, rank: Int? = nil, hot: String? = nil) -> NewsItem {
        NewsItem(title: title, url: "https://example.com/\(title)", source: source, rank: rank, hotLabel: hot)
    }

    func testMixedSourceCitationsUseExplicitTrendSetAndFrozenItems() throws {
        let rss = item("RSS", .rss(name: "RSS", url: "https://example.com/feed"))
        let weibo = item("微博", .weibo, rank: 1)
        let manifest = SummaryManifest(items: [rss, weibo], profileVersion: 3, model: "test", provider: "https://ai.example/api", language: .zh, maxWords: 360)
        let text = "【趋势概览】\n【公共趋势】\n概述\n引用：[#1]\n【误放RSS】\n仅标题概述\n引用：[#0]\n【每日精选】\n【精选】\n内容\n引用：[#0]"
        let result = AISummaryParser.parseDualSummary(text, itemCount: 2, trendIndices: manifest.trendIndices)
        XCTAssertEqual(result.trendOverview.count, 1)
        XCTAssertEqual(result.trendOverview.first?.primaryIndex, 1)
        XCTAssertEqual(result.dailyEssentials.count, 2)
        let restored = try JSONDecoder().decode(SummaryManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(restored.items[1].id, weibo.id)
        XCTAssertEqual(restored.citations[0].url, rss.url)
        XCTAssertEqual(restored.cacheKey, manifest.cacheKey)
    }

    func testManifestCacheIdentityChangesForModelProfileHeatAndOrder() {
        let a = item("Topic", .weibo, rank: 1)
        let b = item("Topic", .weibo, rank: 2, hot: "爆")
        let base = SummaryManifest(items: [a], profileVersion: 1, model: "one", provider: "https://ai.example", language: .zh, maxWords: 360)
        for variant in [
            SummaryManifest(items: [a], profileVersion: 2, model: "one", provider: "https://ai.example", language: .zh, maxWords: 360),
            SummaryManifest(items: [b], profileVersion: 1, model: "one", provider: "https://ai.example", language: .zh, maxWords: 360),
            SummaryManifest(items: [a], profileVersion: 1, model: "two", provider: "https://ai.example", language: .zh, maxWords: 360)
        ] { XCTAssertNotEqual(base.cacheKey, variant.cacheKey) }
        XCTAssertNotEqual(SummaryManifest.contentFingerprint([a, b]), SummaryManifest.contentFingerprint([b, a]))
    }

    func testSummarySelectionIsBoundedIncludesPublicTrendAndRespectsBlocks() {
        var state = LocalInterestState()
        state.learningEnabled = true
        let trend = item("公开爆款", .weibo, rank: 1, hot: "爆")
        let rss = (0..<100).map { item(String(repeating: "长标题", count: 80) + "\($0)", .rss(name: "Source", url: "https://example.com/feed")) }
        let selected = SummarySelectionPolicy.select(items: [trend] + rss, state: state)
        XCTAssertLessThanOrEqual(selected.count, 20)
        XCTAssertLessThanOrEqual(selected.reduce(0) { $0 + min(300, $1.title.count) * 4 + 96 }, 3500)
        XCTAssertTrue(selected.contains { $0.id == trend.id })
        _ = state.feedback(item: trend, kind: .muteSource)
        XCTAssertFalse(SummarySelectionPolicy.select(items: [trend] + rss, state: state).contains { $0.source == .weibo })
    }

    func testManifestRestoresAlongsideSummaryCache() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("summary.json")
        let items = [item("标题", .weibo, rank: 1)]
        let manifest = SummaryManifest(items: items, profileVersion: 4, model: "test", provider: "provider", language: .en, maxWords: 360)
        let store = AISummaryCacheStore(fileURL: url)
        await store.save(AISummaryCacheEntry(summary: "frozen", items: items, contentHash: "hash", trendHistoryHash: "history", generatedAt: Date(), trendItemCount: 1, language: .en, manifest: manifest))
        let restored = await store.load()
        XCTAssertEqual(restored?.manifest?.id, manifest.id)
        XCTAssertEqual(restored?.manifest?.profileVersion, 4)
    }
}
