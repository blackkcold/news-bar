import Foundation
import XCTest
@testable import NewsBar

final class RefreshPolicyTests: XCTestCase {
    func testHotIntervalsMatchVisibilityPolicy() {
        XCTAssertEqual(RefreshPolicy.hotInterval(for: .visible), 5 * 60)
        XCTAssertEqual(RefreshPolicy.hotInterval(for: .background), 30 * 60)
        XCTAssertEqual(RefreshPolicy.hotInterval(for: .lowPower), 60 * 60)
    }

    func testRSSIntervalBecomesQuietAfterSixUnchangedRefreshes() {
        XCTAssertEqual(
            RefreshPolicy.rssInterval(
                unchangedRefreshCount: 6,
                changedRecently: false,
                visibility: .background
            ),
            3 * 60 * 60
        )
    }

    func testRSSIntervalAcceleratesAfterRecentChange() {
        XCTAssertEqual(
            RefreshPolicy.rssInterval(
                unchangedRefreshCount: 0,
                changedRecently: true,
                visibility: .visible
            ),
            30 * 60
        )
    }

    func testJitterStaysWithinTenPercentAndIsDeterministic() {
        let base: TimeInterval = 1_000
        let first = RefreshPolicy.jittered(base, key: "source-A")
        let second = RefreshPolicy.jittered(base, key: "source-A")
        XCTAssertEqual(first, second)
        XCTAssertGreaterThanOrEqual(first, 900)
        XCTAssertLessThanOrEqual(first, 1_100)
    }

    func testRSSFailureRetryUsesBoundedExponentialBackoff() {
        XCTAssertEqual(RefreshPolicy.rssFailureRetryInterval(failureCount: 1), 15 * 60)
        XCTAssertEqual(RefreshPolicy.rssFailureRetryInterval(failureCount: 2), 30 * 60)
        XCTAssertEqual(RefreshPolicy.rssFailureRetryInterval(failureCount: 3), 60 * 60)
        XCTAssertEqual(RefreshPolicy.rssFailureRetryInterval(failureCount: 9), 3 * 60 * 60)
    }
}

final class CacheFreshnessCompatibilityTests: XCTestCase {
    private struct LegacyCacheEntry: Codable {
        let items: [NewsItem]
        let timestamp: Date
        let contentHash: String
        let aiSummary: String?
        let aiSummaryHash: String?
    }

    func testOldCacheWithoutValidationFieldsStillDecodes() throws {
        let item = NewsItem(title: "旧缓存", url: "https://example.com/legacy", source: .weibo)
        let legacy = LegacyCacheEntry(
            items: [item],
            timestamp: Date(),
            contentHash: CacheEntry.contentIdentifier(for: [item]),
            aiSummary: nil,
            aiSummaryHash: nil
        )
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(CacheEntry.self, from: data)

        XCTAssertEqual(decoded.items, [item])
        XCTAssertNil(decoded.lastValidatedAt)
        XCTAssertNil(decoded.eTag)
        XCTAssertNil(decoded.lastModified)
    }

    func testRecentValidationKeepsOldContentFresh() {
        let entry = CacheEntry(
            items: [],
            timestamp: Date().addingTimeInterval(-24 * 60 * 60),
            contentHash: "hash",
            lastValidatedAt: Date()
        )
        XCTAssertFalse(entry.isStale)
    }

    func testNewsItemIdentityIsStableForSameSourceAndURL() {
        let first = NewsItem(title: "标题一", url: "https://example.com/article", source: .weibo)
        let second = NewsItem(title: "标题二", url: "https://example.com/article", source: .weibo)
        XCTAssertEqual(first.id, second.id)
    }
}

final class RSSConditionalRequestTests: XCTestCase {
    func testConditionalHeadersIncludeAvailableValidators() {
        let headers = RSSService.conditionalHeaders(
            eTag: "\"feed-v2\"",
            lastModified: "Wed, 29 Jul 2026 08:00:00 GMT"
        )
        XCTAssertEqual(headers["If-None-Match"], "\"feed-v2\"")
        XCTAssertEqual(headers["If-Modified-Since"], "Wed, 29 Jul 2026 08:00:00 GMT")
    }

    func testConditionalHeadersIgnoreEmptyValues() {
        XCTAssertTrue(RSSService.conditionalHeaders(eTag: "", lastModified: nil).isEmpty)
    }
}

final class TrendHistoryStoreTests: XCTestCase {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NewsBarTests-\(UUID().uuidString)")
            .appendingPathComponent(name)
    }

    func testSameSnapshotUsesThirtyMinuteHeartbeat() async {
        let fileURL = temporaryURL("history.json")
        let store = TrendHistoryStore(fileURL: fileURL)
        let now = Date()
        let weibo = [NewsItem(title: "稳定热点", url: "https://example.com/w", source: .weibo, rank: 1)]
        let bilibili = [NewsItem(title: "视频热点", url: "https://example.com/b", source: .bilibili, rank: 1)]

        let first = await store.record(weibo: weibo, bilibili: bilibili, now: now)
        _ = await store.record(weibo: weibo, bilibili: bilibili, now: now.addingTimeInterval(60))
        let beforeHeartbeat = await store.recentSnapshots(hours: 24, now: now.addingTimeInterval(60))
        _ = await store.record(weibo: weibo, bilibili: bilibili, now: now.addingTimeInterval(31 * 60))
        let afterHeartbeat = await store.recentSnapshots(hours: 24, now: now.addingTimeInterval(31 * 60))

        XCTAssertTrue(first.isSignificant)
        XCTAssertEqual(beforeHeartbeat.count, 1)
        XCTAssertEqual(afterHeartbeat.count, 2)
        await store.clear()
    }

    func testNewTopTopicProducesSignificantChange() async {
        let fileURL = temporaryURL("history.json")
        let store = TrendHistoryStore(fileURL: fileURL)
        let now = Date()
        let old = [NewsItem(title: "旧热点", url: "https://example.com/old", source: .weibo, rank: 1)]
        let new = [NewsItem(title: "新热点", url: "https://example.com/new", source: .weibo, rank: 1)]

        _ = await store.record(weibo: old, bilibili: [], now: now)
        let change = await store.record(weibo: new, bilibili: [], now: now.addingTimeInterval(5 * 60))

        XCTAssertTrue(change.isSignificant)
        XCTAssertTrue(change.context.contains("新热点"))
        XCTAssertFalse(change.historyHash.isEmpty)
        await store.clear()
    }
}

final class AISummaryPersistenceAndTriggerTests: XCTestCase {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NewsBarTests-\(UUID().uuidString)")
            .appendingPathComponent(name)
    }

    func testSummaryCacheRoundTripPreservesCitationSnapshot() async {
        let fileURL = temporaryURL("summary.json")
        let store = AISummaryCacheStore(fileURL: fileURL)
        let items = [NewsItem(title: "热点", url: "https://example.com/hot", source: .weibo, rank: 1)]
        let entry = AISummaryCacheEntry(
            summary: "【趋势概览】\n【热点】内容。\n引用：[#0]",
            items: items,
            contentHash: CacheEntry.contentIdentifier(for: items),
            trendHistoryHash: "history",
            generatedAt: Date(),
            trendItemCount: 1
        )

        await store.save(entry)
        let loaded = await store.load()

        XCTAssertEqual(loaded?.summary, entry.summary)
        XCTAssertEqual(loaded?.items, items)
        XCTAssertEqual(loaded?.trendItemCount, 1)
        await store.clear()
    }

    @MainActor
    func testAutomaticSummaryRespectsTrendAndRSSMinimumIntervals() {
        XCTAssertFalse(NewsOrchestrator.shouldGenerateSummary(
            hasCachedSummary: true,
            hasNewContent: true,
            isManualRefresh: false,
            hotChanged: true,
            rssChanged: false,
            trendIsSignificant: true,
            elapsedSinceSummary: 10 * 60,
            shouldRecover: false
        ))
        XCTAssertTrue(NewsOrchestrator.shouldGenerateSummary(
            hasCachedSummary: true,
            hasNewContent: true,
            isManualRefresh: false,
            hotChanged: true,
            rssChanged: false,
            trendIsSignificant: true,
            elapsedSinceSummary: 30 * 60,
            shouldRecover: false
        ))
        XCTAssertFalse(NewsOrchestrator.shouldGenerateSummary(
            hasCachedSummary: true,
            hasNewContent: true,
            isManualRefresh: false,
            hotChanged: false,
            rssChanged: true,
            trendIsSignificant: false,
            elapsedSinceSummary: 2 * 60 * 60,
            shouldRecover: false
        ))
        XCTAssertTrue(NewsOrchestrator.shouldGenerateSummary(
            hasCachedSummary: true,
            hasNewContent: true,
            isManualRefresh: false,
            hotChanged: false,
            rssChanged: true,
            trendIsSignificant: false,
            elapsedSinceSummary: 4 * 60 * 60,
            shouldRecover: false
        ))
    }

    @MainActor
    func testGlobalManualRefreshDoesNotRepeatIdenticalSummary() {
        XCTAssertFalse(NewsOrchestrator.shouldGenerateSummary(
            hasCachedSummary: true,
            hasNewContent: false,
            isManualRefresh: true,
            hotChanged: false,
            rssChanged: false,
            trendIsSignificant: false,
            elapsedSinceSummary: 24 * 60 * 60,
            shouldRecover: false
        ))
    }
}
