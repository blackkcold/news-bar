import XCTest
@testable import NewsBar

final class WeiboRelevanceStoreTests: XCTestCase {
    private var root: URL!
    private var store: WeiboMonitorStore!
    private let now = WeiboMonitorTestSupport.date(2026, 11, 7, 12, 0)

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeiboRelevanceStoreTests-\(UUID().uuidString)", isDirectory: true)
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

    func testPostRelevanceRoundTrips() async throws {
        var post = WeiboMonitorTestSupport.post(uid: "1", createdAt: now)
        post.relevance = WeiboPostRelevance(
            adScore: 0.72,
            interestScore: 0.31,
            verdict: .lowConfidence,
            reasons: ["lottery", "crossPost:0.24"],
            decider: "rules+openCodeFree",
            decidedAt: now,
            modelConfidence: 0.91
        )
        try await store.save(
            users: [WeiboMonitorTestSupport.user(uid: "1", now: now)],
            now: now
        )
        try await store.savePosts(uid: "1", posts: [post], now: now)

        let loaded = await store.load()
        let decoded = try XCTUnwrap(loaded.postsByUID["1"]?.first)
        XCTAssertEqual(decoded.relevance, post.relevance)
    }

    func testOldPostsFileWithoutRelevanceDecodesToNil() async throws {
        // A posts file written before the filter existed has no `relevance`
        // key at all. Optional decoding must keep it loadable.
        var post = WeiboMonitorTestSupport.post(uid: "1", createdAt: now)
        post.relevance = nil
        try await store.save(
            users: [WeiboMonitorTestSupport.user(uid: "1", now: now)],
            now: now
        )
        try await store.savePosts(uid: "1", posts: [post], now: now)

        let loaded = await store.load()
        XCTAssertTrue(loaded.issues.isEmpty)
        XCTAssertNil(loaded.postsByUID["1"]?.first?.relevance)
    }

    func testAccountRelevanceFieldsRoundTrip() async throws {
        var user = WeiboMonitorTestSupport.user(uid: "1", now: now)
        user.relevanceMode = .strict
        var stats = WeiboRelevanceStats()
        stats.decided = 10
        stats.relevant = 6
        stats.filtered = 2
        stats.lowConfidence = 1
        stats.offTopic = 1
        stats.aiCorrected = 3
        user.relevanceStats = stats

        try await store.save(users: [user], now: now)
        let loaded = await store.load()
        let decoded = try XCTUnwrap(loaded.users.first)
        XCTAssertEqual(decoded.relevanceMode, .strict)
        XCTAssertEqual(decoded.relevanceStats, stats)
        XCTAssertTrue(loaded.issues.isEmpty)
    }

    func testOldMonitorFileWithoutRelevanceFieldsIsNotArchived() async throws {
        // Simulate a monitor.json written by the previous version: the two
        // relevance keys are absent. It must load, not become `.corrupt-*`.
        let user = WeiboMonitorTestSupport.user(uid: "1", now: now)
        try await store.save(users: [user], now: now)

        let monitorURL = root.appendingPathComponent("monitor.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: monitorURL)) as? [String: Any]
        )
        if var users = object["users"] as? [[String: Any]], !users.isEmpty {
            users[0].removeValue(forKey: "relevanceMode")
            users[0].removeValue(forKey: "relevanceStats")
            object["users"] = users
        }
        try JSONSerialization.data(withJSONObject: object).write(to: monitorURL)

        let loaded = await store.load()
        XCTAssertTrue(loaded.issues.isEmpty, "\(loaded.issues)")
        XCTAssertEqual(loaded.users.first?.uid, "1")
        XCTAssertNil(loaded.users.first?.relevanceMode)
        XCTAssertNil(loaded.users.first?.relevanceStats)
    }

    func testRelevanceStatsBaselineStartsNeutral() {
        var stats = WeiboRelevanceStats()
        XCTAssertEqual(stats.onTopicRatio, 0.5, accuracy: 0.0001)
        stats.record(
            WeiboPostRelevance(
                adScore: 0,
                interestScore: 0.8,
                verdict: .relevant,
                reasons: [],
                decidedAt: now
            )
        )
        // A weak prior: one good post lifts the ratio without jumping to 1.
        XCTAssertEqual(stats.onTopicRatio, 0.6, accuracy: 0.0001)
    }
}
