import Foundation
import XCTest
@testable import NewsBar

final class CacheClearRaceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PrivateFileFaults.reset()
    }

    override func tearDown() {
        PrivateFileFaults.reset()
        super.tearDown()
    }

    private func directory() throws -> URL {
        let result = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewsBarCacheClear-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    private var item: NewsItem {
        NewsItem(title: "Fictional item", url: "https://example.com/item", source: .weibo, rank: 1)
    }

    private func summaryEntry() -> AISummaryCacheEntry {
        AISummaryCacheEntry(
            summary: "Fictional summary", items: [item], contentHash: "fixture",
            trendHistoryHash: "history", generatedAt: Date(), trendItemCount: 1
        )
    }

    func testLateFeedWriteCannotRepopulateClearedCache() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CacheManager(cacheDirectory: root)
        let epoch = CacheWriteGeneration()
        let old = epoch.capture()
        let entry = CacheEntry(items: [item], timestamp: Date(), contentHash: "fictional")
        await store.save(entry, for: .weibo, token: old)

        epoch.invalidate()
        await store.clear()
        await store.save(entry, for: .weibo, token: old)
        let stale = await store.load(for: .weibo)
        XCTAssertNil(stale)

        await store.save(entry, for: .weibo, token: epoch.capture())
        let fresh = await store.load(for: .weibo)
        XCTAssertEqual(fresh?.contentHash, "fictional")
    }

    func testLateTranslationCannotRepopulateClearedCache() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TranslationCacheStore(cacheDirectory: root)
        let epoch = CacheWriteGeneration()
        let old = epoch.capture()
        await store.saveTranslation("fictional", for: "标题", targetLang: "en", token: old)

        epoch.invalidate()
        await store.clear()
        await store.saveTranslation("fictional", for: "标题", targetLang: "en", token: old)
        let stale = await store.cachedTranslation(for: "标题", targetLang: "en")
        XCTAssertNil(stale)

        await store.saveTranslation("fresh", for: "标题", targetLang: "en", token: epoch.capture())
        let fresh = await store.cachedTranslation(for: "标题", targetLang: "en")
        XCTAssertEqual(fresh, "fresh")
    }

    func testLateSummaryCannotRepopulateClearedCache() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AISummaryCacheStore(fileURL: root.appendingPathComponent("summary.json"))
        let epoch = CacheWriteGeneration()
        let old = epoch.capture()
        let entry = summaryEntry()
        await store.save(entry, token: old)

        epoch.invalidate()
        await store.clear()
        await store.save(entry, token: old)
        let stale = await store.load()
        XCTAssertNil(stale)

        await store.save(entry, token: epoch.capture())
        let fresh = await store.load()
        XCTAssertEqual(fresh?.summary, "Fictional summary")
    }

    func testLateTrendRecordCannotRepopulateClearedCache() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrendHistoryStore(fileURL: root.appendingPathComponent("trend.json"))
        let epoch = CacheWriteGeneration()
        let old = epoch.capture()
        _ = await store.record(weibo: [item], bilibili: [], token: old)

        epoch.invalidate()
        await store.clear()
        _ = await store.record(weibo: [item], bilibili: [], token: old)
        let stale = await store.recentSnapshots(hours: 1)
        XCTAssertTrue(stale.isEmpty)

        _ = await store.record(weibo: [item], bilibili: [], token: epoch.capture())
        let fresh = await store.recentSnapshots(hours: 1)
        XCTAssertEqual(fresh.count, 1)
    }

    @MainActor
    func testSummaryReadCompletedAfterClearIsNotRestored() async {
        let epoch = CacheWriteGeneration()
        let old = epoch.capture()
        let cached = summaryEntry()
        let restored = await AISummaryCacheRestore.loadIfEligible(
            isEligible: { old.isCurrent },
            load: {
                epoch.invalidate()
                return cached
            }
        )
        XCTAssertNil(restored)
    }
}
