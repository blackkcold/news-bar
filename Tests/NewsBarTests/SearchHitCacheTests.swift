import XCTest
@testable import NewsBar

final class SearchHitCacheTests: XCTestCase {
    private func hit(_ i: Int) -> SearchHit {
        SearchHit(
            url: "https://c\(i).example/1",
            title: "t\(i)",
            snippet: "s",
            provider: .tavily,
            providerRank: i
        )
    }

    func testStoreThenHitWithinLifetime() async {
        let cache = SearchHitCache()
        let now = Date()
        await cache.store([hit(1)], for: "q")
        let hits = await cache.hits(for: "q", now: now.addingTimeInterval(59))
        XCTAssertEqual(hits?.count, 1)
    }

    func testExpiredEntryIsNotServed() async {
        let cache = SearchHitCache()
        let now = Date()
        await cache.store([hit(1)], for: "q")
        let hits = await cache.hits(for: "q", now: now.addingTimeInterval(601))
        XCTAssertNil(hits)
    }

    func testKeysAreIsolatedAndLimitEvictsOldest() async {
        let cache = SearchHitCache()
        for i in 0..<25 { await cache.store([hit(i)], for: "q\(i)") }
        let oldest = await cache.hits(for: "q0")
        let newest = await cache.hits(for: "q24")
        XCTAssertNil(oldest)
        XCTAssertEqual(newest?.first?.title, "t24")
        let other = await cache.hits(for: "different")
        XCTAssertNil(other)
    }
}
