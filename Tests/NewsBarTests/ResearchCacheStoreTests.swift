import XCTest
@testable import NewsBar

final class ResearchCacheStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testStoreLoadAndKindIsolation() async throws {
        let directory = try researchTestDirectory()
        let cache = ResearchCacheStore(directoryURL: directory)
        await cache.store(Data("search-payload".utf8), kind: .search, key: "q", now: now)
        await cache.store(Data("page-payload".utf8), kind: .pages, key: "u", now: now)

        let searchPayload = await cache.load(kind: .search, key: "q", now: now)
        XCTAssertEqual(searchPayload, Data("search-payload".utf8))

        let wrongKind = await cache.load(kind: .search, key: "u", now: now)
        XCTAssertNil(wrongKind)

        let pagePayload = await cache.load(kind: .pages, key: "u", now: now)
        XCTAssertEqual(pagePayload, Data("page-payload".utf8))

        let total = await cache.totalBytes()
        XCTAssertGreaterThan(total, 0)
    }

    func testExpiredEntryIsRemovedOnRead() async throws {
        let directory = try researchTestDirectory()
        let cache = ResearchCacheStore(directoryURL: directory)
        await cache.store(Data("x".utf8), kind: .search, key: "q", now: now)

        let expired = await cache.load(
            kind: .search,
            key: "q",
            now: now.addingTimeInterval(ResearchCacheStore.searchTTL + 1)
        )
        XCTAssertNil(expired)

        let exists = await cache.hasFile(kind: .search, key: "q")
        XCTAssertFalse(exists)
    }

    func testPageTTLIsLongerThanSearchTTL() async throws {
        let directory = try researchTestDirectory()
        let cache = ResearchCacheStore(directoryURL: directory)
        await cache.store(Data("page".utf8), kind: .pages, key: "p", now: now)

        let stillValid = await cache.load(
            kind: .pages,
            key: "p",
            now: now.addingTimeInterval(ResearchCacheStore.searchTTL + 60)
        )
        XCTAssertEqual(stillValid, Data("page".utf8))

        let expired = await cache.load(
            kind: .pages,
            key: "p",
            now: now.addingTimeInterval(ResearchCacheStore.pagesTTL + 1)
        )
        XCTAssertNil(expired)
    }

    func testEnforceLimitsDeletesExpiredEntries() async throws {
        let directory = try researchTestDirectory()
        let cache = ResearchCacheStore(directoryURL: directory)
        await cache.store(
            Data("old-search".utf8),
            kind: .search,
            key: "s",
            now: now.addingTimeInterval(-ResearchCacheStore.searchTTL - 60)
        )
        await cache.store(
            Data("old-page".utf8),
            kind: .pages,
            key: "p",
            now: now.addingTimeInterval(-ResearchCacheStore.pagesTTL - 60)
        )
        await cache.store(Data("fresh".utf8), kind: .search, key: "f", now: now)

        let stats = await cache.enforceLimits(now: now, maxBytes: 10_000_000)
        XCTAssertEqual(stats.removedFiles, 2)

        let oldSearch = await cache.hasFile(kind: .search, key: "s")
        let oldPage = await cache.hasFile(kind: .pages, key: "p")
        let fresh = await cache.hasFile(kind: .search, key: "f")
        XCTAssertFalse(oldSearch)
        XCTAssertFalse(oldPage)
        XCTAssertTrue(fresh)
    }

    func testByteCapTrimsToNinetyPercentAndProtectsActiveFile() async throws {
        let directory = try researchTestDirectory()
        let cache = ResearchCacheStore(directoryURL: directory)

        await cache.store(Data([0]), kind: .pages, key: "newest", now: now)
        for index in 0..<10 {
            await cache.store(
                Data([UInt8(index)]),
                kind: .pages,
                key: "k\(index)",
                now: now.addingTimeInterval(TimeInterval(-100 + index))
            )
        }

        let protectedKey = await cache.fileKey(kind: .pages, key: "newest")
        let stats = await cache.enforceLimits(
            now: now,
            maxBytes: 400,
            protecting: [protectedKey]
        )

        XCTAssertGreaterThan(stats.removedFiles, 0)
        XCTAssertLessThanOrEqual(stats.totalBytes, 400)
        let newestExists = await cache.hasFile(kind: .pages, key: "newest")
        XCTAssertTrue(newestExists)
    }

    func testCorruptCacheFileIsMissAndRemoved() async throws {
        let directory = try researchTestDirectory()
        let cache = ResearchCacheStore(directoryURL: directory)
        await cache.store(Data("x".utf8), kind: .search, key: "q", now: now)

        let key = await cache.fileKey(kind: .search, key: "q")
        let url = directory
            .appendingPathComponent("search", isDirectory: true)
            .appendingPathComponent("\(key).json")
        try Data("not-json".utf8).write(to: url)

        let loaded = await cache.load(kind: .search, key: "q", now: now)
        XCTAssertNil(loaded)
        let exists = await cache.hasFile(kind: .search, key: "q")
        XCTAssertFalse(exists)
    }

    func testClearAllRemovesBothKinds() async throws {
        let directory = try researchTestDirectory()
        let cache = ResearchCacheStore(directoryURL: directory)
        await cache.store(Data("s".utf8), kind: .search, key: "q", now: now)
        await cache.store(Data("p".utf8), kind: .pages, key: "u", now: now)

        await cache.clearAll()

        let total = await cache.totalBytes()
        XCTAssertEqual(total, 0)
        let search = await cache.hasFile(kind: .search, key: "q")
        let page = await cache.hasFile(kind: .pages, key: "u")
        XCTAssertFalse(search)
        XCTAssertFalse(page)
    }

    func testCacheDirectoryIsExcludedFromBackup() async throws {
        let directory = try researchTestDirectory()
        let cache = ResearchCacheStore(directoryURL: directory)
        await cache.prepare()

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
}
