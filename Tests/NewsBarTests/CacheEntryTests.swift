import XCTest
@testable import NewsBar

final class CacheEntryTests: XCTestCase {
    func testHashForItems_SameContent_SameHash() {
        let items = [
            NewsItem(title: "Test", url: "https://example.com", source: .weibo),
        ]
        let hash1 = CacheEntry.hashForItems(items)
        let hash2 = CacheEntry.hashForItems(items)
        XCTAssertEqual(hash1, hash2)
    }

    func testHashForItems_DifferentContent_DifferentHash() {
        let items1 = [NewsItem(title: "Test1", url: "https://example.com", source: .weibo)]
        let items2 = [NewsItem(title: "Test2", url: "https://example.com", source: .weibo)]
        XCTAssertNotEqual(CacheEntry.hashForItems(items1), CacheEntry.hashForItems(items2))
    }

    func testIsStale_15Minutes_False() {
        // Use 14:59 to avoid timing precision issues
        let entry = CacheEntry(items: [], timestamp: Date().addingTimeInterval(-14 * 60 - 59), contentHash: "test")
        XCTAssertFalse(entry.isStale)
    }

    func testIsStale_16Minutes_True() {
        let entry = CacheEntry(items: [], timestamp: Date().addingTimeInterval(-16 * 60), contentHash: "test")
        XCTAssertTrue(entry.isStale)
    }

    func testIsExpired_24HoursPlusOneSecond_True() {
        let now = Date()
        let entry = CacheEntry(
            items: [],
            timestamp: now.addingTimeInterval(-CacheEntry.maxDisplayableAge - 1),
            contentHash: "test"
        )
        XCTAssertTrue(entry.isExpired(at: now))
    }

    func testIsExpired_Within24Hours_False() {
        let now = Date()
        let entry = CacheEntry(
            items: [],
            timestamp: now.addingTimeInterval(-CacheEntry.maxDisplayableAge + 1),
            contentHash: "test"
        )
        XCTAssertFalse(entry.isExpired(at: now))
    }
}

final class CacheManagerTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NewsBarFeedCache-\(UUID().uuidString)", isDirectory: true)
    }

    private func entry(for source: NewsSource, title: String) -> CacheEntry {
        CacheEntry(
            items: [NewsItem(title: title, url: "https://example.test/article", source: source)],
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            contentHash: title
        )
    }

    func testFeedURLsContainingSlashAndUnderscoreDoNotCollide() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CacheManager(cacheDirectory: directory)
        let first = NewsSource.rss(name: "First", url: "https://example.test/a/b")
        let second = NewsSource.rss(name: "Second", url: "https://example.test/a_b")

        await store.save(entry(for: first, title: "First story"), for: first)
        let beforeSave = await store.load(for: second)
        XCTAssertNil(beforeSave)
        await store.save(entry(for: second, title: "Second story"), for: second)
        let firstAfter = await store.load(for: first)
        let secondAfter = await store.load(for: second)
        XCTAssertEqual(firstAfter?.items.first?.title, "First story")
        XCTAssertEqual(secondAfter?.items.first?.title, "Second story")
    }

    func testLongFeedURLCanBeCached() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CacheManager(cacheDirectory: directory)
        let source = NewsSource.rss(name: "Long", url: "https://example.test/" + String(repeating: "path", count: 100))

        await store.save(entry(for: source, title: "Long feed"), for: source)
        let cached = await store.load(for: source)

        XCTAssertEqual(cached?.items.first?.title, "Long feed")
    }

    func testLegacyFeedCacheBelongsOnlyToItsStoredSource() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CacheManager(cacheDirectory: directory)
        let first = NewsSource.rss(name: "First", url: "https://example.test/a/b")
        let renamed = NewsSource.rss(name: "Renamed", url: "https://example.test/a/b")
        let second = NewsSource.rss(name: "Second", url: "https://example.test/a_b")
        let legacy = directory.appendingPathComponent("https:__example.test_a_b.json")
        try JSONEncoder().encode(entry(for: first, title: "Legacy story")).write(to: legacy)

        let matching = await store.load(for: renamed)
        let unrelated = await store.load(for: second)

        XCTAssertEqual(matching?.items.first?.title, "Legacy story")
        XCTAssertNil(unrelated)
    }

    func testEmptyLegacyFeedCacheIsNotAssignedWithoutSourceEvidence() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CacheManager(cacheDirectory: directory)
        let source = NewsSource.rss(name: "First", url: "https://example.test/a/b")
        let legacy = directory.appendingPathComponent("https:__example.test_a_b.json")
        let empty = CacheEntry(items: [], timestamp: Date(), contentHash: "empty")
        try JSONEncoder().encode(empty).write(to: legacy)

        let cached = await store.load(for: source)

        XCTAssertNil(cached)
    }
}
