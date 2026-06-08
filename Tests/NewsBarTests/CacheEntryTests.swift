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
}
