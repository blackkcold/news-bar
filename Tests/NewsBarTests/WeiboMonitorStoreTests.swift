import XCTest
@testable import NewsBar

final class WeiboMonitorStoreTests: XCTestCase {
    private var root: URL!
    private var store: WeiboMonitorStore!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeiboMonitorStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = WeiboMonitorStore(root: root)
    }

    override func tearDown() async throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        store = nil
        try await super.tearDown()
    }

    func testSaveAndLoadRoundTrip() async throws {
        let now = WeiboMonitorTestSupport.date(2026, 11, 7, 12, 0)
        let user = WeiboMonitorTestSupport.user(uid: "42", now: now)
        try await store.save(users: [user], now: now)
        try await store.savePosts(uid: "42", posts: [WeiboMonitorTestSupport.post(uid: "42", createdAt: now)], now: now)

        let loaded = await store.load()
        XCTAssertEqual(loaded.users.count, 1)
        XCTAssertEqual(loaded.users.first?.uid, "42")
        XCTAssertEqual(loaded.users.first?.screenName, "数码闲聊站")
        XCTAssertEqual(loaded.postsByUID["42"]?.count, 1)
        XCTAssertTrue(loaded.issues.isEmpty)
    }

    func testRetentionKeepsNewestTwoHundredPosts() async throws {
        let now = WeiboMonitorTestSupport.date(2026, 11, 7, 12, 0)
        try await store.save(
            users: [WeiboMonitorTestSupport.user(uid: "1", now: now)],
            now: now
        )
        let posts = (0..<250).map { index in
            WeiboMonitorTestSupport.post(
                mid: "\(index)",
                text: "post \(index)",
                createdAt: now.addingTimeInterval(-Double(index) * 60)
            )
        }
        try await store.savePosts(uid: "1", posts: posts, now: now)
        let loaded = await store.load()
        XCTAssertEqual(loaded.postsByUID["1"]?.count, 200)
        XCTAssertEqual(loaded.postsByUID["1"]?.first?.mid, "0")
        XCTAssertEqual(loaded.postsByUID["1"]?.last?.mid, "199")
    }

    func testRetentionDropsPostsOlderThanThirtyDays() async throws {
        let now = WeiboMonitorTestSupport.date(2026, 11, 7, 12, 0)
        try await store.save(
            users: [WeiboMonitorTestSupport.user(uid: "1", now: now)],
            now: now
        )
        let fresh = WeiboMonitorTestSupport.post(mid: "fresh", createdAt: now)
        let old = WeiboMonitorTestSupport.post(
            mid: "old",
            createdAt: now.addingTimeInterval(-31 * 24 * 60 * 60)
        )
        try await store.savePosts(uid: "1", posts: [fresh, old], now: now)
        let loaded = await store.load()
        XCTAssertEqual(loaded.postsByUID["1"]?.map(\.mid), ["fresh"])
    }

    func testCorruptMonitorFileIsArchivedAndLoadStartsEmpty() async throws {
        let monitorURL = root.appendingPathComponent("monitor.json")
        try Data("not-json".utf8).write(to: monitorURL)

        let loaded = await store.load()

        XCTAssertTrue(loaded.users.isEmpty)
        XCTAssertTrue(loaded.issues.contains("monitor.corrupt"))
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(files.contains { $0.contains(".corrupt-") })
    }

    func testFutureVersionIsArchivedAndLoadStartsEmpty() async throws {
        let monitorURL = root.appendingPathComponent("monitor.json")
        let payload: [String: Any] = [
            "version": 99,
            "updatedAt": "2026-11-07T00:00:00Z",
            "users": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: monitorURL)

        let loaded = await store.load()

        XCTAssertTrue(loaded.users.isEmpty)
        XCTAssertTrue(loaded.issues.contains("monitor.version"))
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(files.contains { $0.contains(".corrupt-") })
    }

    func testOrphanPostsFileIsRemoved() async throws {
        let postsDirectory = root.appendingPathComponent("posts", isDirectory: true)
        try FileManager.default.createDirectory(at: postsDirectory, withIntermediateDirectories: true)
        let orphan = postsDirectory.appendingPathComponent("orphan.json")
        try Data("{}".utf8).write(to: orphan)

        _ = await store.load()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testFilesAreOwnerOnly() async throws {
        let now = WeiboMonitorTestSupport.date(2026, 11, 7, 12, 0)
        let user = WeiboMonitorTestSupport.user(uid: "7", now: now)
        try await store.save(users: [user], now: now)
        try await store.savePosts(uid: "7", posts: [WeiboMonitorTestSupport.post(uid: "7")], now: now)

        let monitorAttributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("monitor.json").path
        )
        let postsAttributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("posts/7.json").path
        )

        XCTAssertEqual((monitorAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((postsAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCorruptMonitorRebuildsUsersFromPosts() async throws {
        let now = WeiboMonitorTestSupport.date(2026, 11, 7, 12, 0)
        let user = WeiboMonitorTestSupport.user(uid: "42", now: now)
        try await store.save(users: [user], now: now)
        try await store.savePosts(
            uid: "42",
            posts: [WeiboMonitorTestSupport.post(uid: "42", createdAt: now)],
            now: now
        )
        try Data("not-json".utf8).write(to: root.appendingPathComponent("monitor.json"))

        let loaded = await store.load(now: now)

        XCTAssertEqual(loaded.users.count, 1)
        XCTAssertEqual(loaded.users.first?.uid, "42")
        XCTAssertNil(loaded.users.first?.lastSuccessAt)
        XCTAssertEqual(loaded.postsByUID["42"]?.count, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("posts/42.json").path
            )
        )
    }

    func testUnreadableMonitorIsArchivedBeforeTheRebuiltListIsWritten() async throws {
        let now = WeiboMonitorTestSupport.date(2026, 11, 7, 12, 0)
        let user = WeiboMonitorTestSupport.user(uid: "42", now: now)
        try await store.save(users: [user], now: now)
        try await store.savePosts(
            uid: "42",
            posts: [WeiboMonitorTestSupport.post(uid: "42", createdAt: now)],
            now: now
        )
        let monitorURL = root.appendingPathComponent("monitor.json")
        try FileManager.default.removeItem(at: monitorURL)
        try FileManager.default.createDirectory(at: monitorURL, withIntermediateDirectories: true)

        let loaded = await store.load(now: now)

        XCTAssertTrue(loaded.issues.contains("monitor.unreadable"))
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("monitor.json.unreadable-") })

        try await store.save(users: loaded.users, now: now)
        let isDirectory = (try monitorURL.resourceValues(forKeys: [.isDirectoryKey])).isDirectory
        XCTAssertEqual(isDirectory, false)
    }

    func testResetRemovesEverything() async throws {
        let now = WeiboMonitorTestSupport.date(2026, 11, 7, 12, 0)
        try await store.save(users: [WeiboMonitorTestSupport.user(now: now)], now: now)
        try await store.reset()

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let loaded = await store.load()
        XCTAssertTrue(loaded.users.isEmpty)
    }
}
