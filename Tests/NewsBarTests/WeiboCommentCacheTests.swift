import XCTest
@testable import NewsBar

final class WeiboCommentCacheTests: XCTestCase {
    private var root: URL!
    private var cache: WeiboCommentCache!

    /// The cache compares `fetchedAt` against the real clock, so a fixture with
    /// a hard-coded date turns into a stale thread seven days after it was
    /// written. Round to a whole second: the encoder writes ISO-8601 without
    /// fractions, and a round-trip must compare equal.
    private var recent: Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    private var recentISO: String {
        ISO8601DateFormatter().string(from: recent)
    }

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeiboCommentCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cache = WeiboCommentCache(root: root)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        cache = nil
        try await super.tearDown()
    }

    private func page(mid: String, count: Int, fetchedAt: Date? = nil, cursor: String? = "next") -> WeiboCommentPage {
        let date = fetchedAt ?? recent
        let comments = (0..<count).map { index in
            WeiboComment(
                id: "\(mid)-\(index)",
                mid: mid,
                uid: "1",
                screenName: "读者",
                avatarURL: nil,
                text: "评论 \(index)",
                createdAt: date.addingTimeInterval(TimeInterval(-index)),
                likeCount: index,
                replyToName: nil,
                isAuthor: false
            )
        }
        return WeiboCommentPage(
            comments: comments,
            total: count,
            nextCursor: cursor,
            fetchedAt: date,
            tier: .desktop
        )
    }

    func testRoundTripPreservesPageAndPagesLoaded() async throws {
        let original = page(mid: "9001", count: 3)
        await cache.save(mid: "9001", thread: CachedWeiboCommentThread(page: original, pagesLoaded: 2))

        let loaded = await cache.load(mid: "9001")
        XCTAssertEqual(loaded?.page, original)
        XCTAssertEqual(loaded?.pagesLoaded, 2)
    }

    func testCorruptFileIsIgnoredAndRemoved() async throws {
        let directory = root.appendingPathComponent("comments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: directory.appendingPathComponent("9001.json"))

        let loaded = await cache.load(mid: "9001")
        XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("9001.json").path))
    }

    func testExpiredThreadIsDropped() async throws {
        let stale = page(mid: "9002", count: 1, fetchedAt: recent.addingTimeInterval(-8 * 24 * 3600))
        await cache.save(mid: "9002", thread: CachedWeiboCommentThread(page: stale, pagesLoaded: 1))

        let loaded = await cache.load(mid: "9002")
        XCTAssertNil(loaded)
    }

    func testCommentCountIsCapped() async throws {
        let large = page(mid: "9003", count: 150)
        await cache.save(mid: "9003", thread: CachedWeiboCommentThread(page: large, pagesLoaded: 5))

        let loaded = await cache.load(mid: "9003")
        XCTAssertEqual(loaded?.page.comments.count, WeiboCommentCache.maxComments)
        XCTAssertEqual(loaded?.page.comments.first?.id, "9003-0")
    }

    func testThreadCountIsPruned() async throws {
        for index in 0..<(WeiboCommentCache.maxThreads + 5) {
            let mid = "90\(index)"
            await cache.save(mid: mid, thread: CachedWeiboCommentThread(page: page(mid: mid, count: 1), pagesLoaded: 1))
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("comments", isDirectory: true),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        XCTAssertLessThanOrEqual(files.count, WeiboCommentCache.maxThreads)
    }

    func testClearRemovesEverything() async throws {
        await cache.save(mid: "9004", thread: CachedWeiboCommentThread(page: page(mid: "9004", count: 1), pagesLoaded: 1))
        await cache.clear()
        let loaded = await cache.load(mid: "9004")
        XCTAssertNil(loaded)
    }

    func testLegacyJSONWithoutRunsStillDecodes() async throws {
        let directory = root.appendingPathComponent("comments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Written by a build that predates `runs`. No such key exists anywhere,
        // which is the case a non-optional field would break.
        let stamp = recentISO
        let legacy = """
        {
          "page": {
            "comments": [
              {
                "id": "1",
                "mid": "9005",
                "uid": "7",
                "screenName": "读者",
                "text": "旧评论",
                "createdAt": "\(stamp)",
                "isAuthor": false
              }
            ],
            "fetchedAt": "\(stamp)",
            "tier": "desktop"
          },
          "pagesLoaded": 1
        }
        """
        let file = directory.appendingPathComponent("9005.json")
        try Data(legacy.utf8).write(to: file)

        let loaded = await cache.load(mid: "9005")
        let thread = try XCTUnwrap(loaded)
        XCTAssertEqual(thread.page.comments.count, 1)
        XCTAssertEqual(thread.page.comments[0].text, "旧评论")
        XCTAssertNil(thread.page.comments[0].runs)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: file.path),
            "A decode failure deletes the cache file; adding an optional field must not trigger that"
        )
    }

    func testRunsRoundTripThroughCache() async throws {
        var original = page(mid: "9006", count: 1)
        original.comments[0].runs = [
            WeiboCommentRun(kind: .text, text: "看这个", url: nil),
            WeiboCommentRun(kind: .link, text: "链接", url: "https://example.com/a"),
            WeiboCommentRun(kind: .mention, text: "@某人", url: nil),
        ]
        await cache.save(mid: "9006", thread: CachedWeiboCommentThread(page: original, pagesLoaded: 1))

        let loaded = await cache.load(mid: "9006")
        XCTAssertEqual(loaded?.page.comments[0].runs, original.comments[0].runs)
    }
}
