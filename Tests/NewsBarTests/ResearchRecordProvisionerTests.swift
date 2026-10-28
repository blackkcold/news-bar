import XCTest
@testable import NewsBar

@MainActor
final class ResearchRecordProvisionerTests: XCTestCase {
    func testReusesExactTopicWithinSevenDays() async throws {
        let store = ResearchFakeStore()
        let item = NewsItem(title: "事件 A", url: "https://weibo.com/a", source: .weibo)

        let firstRecord = await ResearchRecordProvisioner.ensureRecord(
            for: item,
            origin: .burst,
            store: store
        )
        let first = try XCTUnwrap(firstRecord)

        let secondRecord = await ResearchRecordProvisioner.ensureRecord(
            for: item,
            origin: .burst,
            store: store
        )
        let second = try XCTUnwrap(secondRecord)

        XCTAssertEqual(first.id, second.id)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.count, 1)
    }

    func testCreatesSeparateRecordsForDifferentTopics() async throws {
        let store = ResearchFakeStore()

        let firstRecord = await ResearchRecordProvisioner.ensureRecord(
            for: NewsItem(title: "事件 A", url: "https://weibo.com/a", source: .weibo),
            origin: .burst,
            store: store
        )
        let first = try XCTUnwrap(firstRecord)

        let secondRecord = await ResearchRecordProvisioner.ensureRecord(
            for: NewsItem(title: "事件 B", url: "https://weibo.com/b", source: .weibo),
            origin: .burst,
            store: store
        )
        let second = try XCTUnwrap(secondRecord)

        XCTAssertNotEqual(first.id, second.id)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.count, 2)
    }

    func testManualReusesOldExactRecordWithoutChangingOrigin() async throws {
        let old = researchTestRecord(
            title: "事件 A",
            origin: .burst,
            updatedAt: Date().addingTimeInterval(-30 * 86_400),
            seedURL: "https://weibo.com/a"
        )
        let store = ResearchFakeStore(records: [old])
        let item = NewsItem(title: "事件 A", url: "https://weibo.com/a", source: .weibo)

        let reusedRecord = await ResearchRecordProvisioner.ensureRecord(
            for: item,
            origin: .manual,
            store: store
        )
        let reused = try XCTUnwrap(reusedRecord)

        XCTAssertEqual(reused.id, old.id)
        XCTAssertEqual(reused.origin, .burst)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.count, 1)
    }

    func testRenamedAutomaticTopicReusesRecentRecord() async throws {
        let store = ResearchFakeStore()
        let firstItem = NewsItem(title: "事件 A", url: "https://weibo.com/a", source: .weibo)
        let firstRecord = await ResearchRecordProvisioner.ensureRecord(
            for: firstItem,
            origin: .burst,
            store: store
        )
        let first = try XCTUnwrap(firstRecord)

        let renamedItem = NewsItem(title: "事件A", url: "https://weibo.com/a", source: .weibo)
        let renamedRecord = await ResearchRecordProvisioner.ensureRecord(
            for: renamedItem,
            origin: .burst,
            store: store
        )
        let renamed = try XCTUnwrap(renamedRecord)

        XCTAssertEqual(renamed.id, first.id)
        XCTAssertEqual(renamed.topic, "事件A")
        XCTAssertEqual(renamed.topicKey, TopicFingerprint.key(for: "事件A"))
        XCTAssertTrue(renamed.aliases.contains("事件 A"))
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.count, 1)
    }

    func testAutoCreatesNewRecordWhenLastSeenIsOlderThanSevenDays() async throws {        let old = researchTestRecord(
            title: "事件 A",
            origin: .burst,
            updatedAt: Date().addingTimeInterval(-8 * 86_400),
            seedURL: "https://weibo.com/a"
        )
        let store = ResearchFakeStore(records: [old])
        let item = NewsItem(title: "事件 A", url: "https://weibo.com/a", source: .weibo)

        let createdRecord = await ResearchRecordProvisioner.ensureRecord(
            for: item,
            origin: .burst,
            store: store
        )
        let created = try XCTUnwrap(createdRecord)

        XCTAssertNotEqual(created.id, old.id)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.count, 2)
    }
}
