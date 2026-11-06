import XCTest
@testable import NewsBar

final class TrendDetectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testThirtyMinuteBucketDeduplicatesAndKeepsBestRank() {
        let topic = "同一个热点"
        let snapshots = [
            snapshot(at: now.addingTimeInterval(-10 * 60), topic: topic, rank: 5),
            snapshot(at: now.addingTimeInterval(-5 * 60), topic: topic, rank: 2),
        ]
        let observations = TrendDetector.observations(from: snapshots, now: now)

        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations[0].rank, 2)
    }

    func testPersistentTopicRequiresMultipleDaysAndBuckets() {
        var snapshots: [TrendSnapshot] = []
        for day in 0..<3 {
            for bucket in 0..<2 {
                let offset = -Double(day * 24 * 60 + bucket * 30) * 60
                snapshots.append(snapshot(
                    at: now.addingTimeInterval(offset),
                    topic: "持续话题",
                    rank: 3
                ))
            }
        }
        let candidates = TrendDetector.candidates(
            from: TrendDetector.observations(from: snapshots, now: now),
            now: now
        )

        XCTAssertEqual(candidates.first?.label, .persistent)
        XCTAssertEqual(candidates.first?.activeDays, 3)
        XCTAssertEqual(candidates.first?.bucketCount, 6)
    }

    func testRisingTopicUsesRankImprovementNotSemanticGuessing() {
        let snapshots = [
            snapshot(at: now.addingTimeInterval(-2 * 60 * 60), topic: "上升话题", rank: 9),
            snapshot(at: now.addingTimeInterval(-30 * 60), topic: "上升话题", rank: 2),
        ]
        let candidate = TrendDetector.candidates(
            from: TrendDetector.observations(from: snapshots, now: now),
            now: now
        ).first

        XCTAssertEqual(candidate?.label, .rising)
        XCTAssertEqual(candidate?.rankImprovement, 7)
    }

    func testNewSignalNeedsAtLeastTwoBuckets() {
        let snapshots = [
            snapshot(at: now.addingTimeInterval(-60 * 60), topic: "新信号", rank: 4),
            snapshot(at: now.addingTimeInterval(-30 * 60), topic: "新信号", rank: 4),
        ]
        let candidate = TrendDetector.candidates(
            from: TrendDetector.observations(from: snapshots, now: now),
            now: now
        ).first

        XCTAssertEqual(candidate?.label, .emerging)
    }

    func testSingleSampleIsLabeledInsufficient() {
        let snapshots = [snapshot(at: now, topic: "只出现一次", rank: 1)]
        let candidate = TrendDetector.candidates(
            from: TrendDetector.observations(from: snapshots, now: now),
            now: now
        ).first

        XCTAssertEqual(candidate?.label, .insufficient)
    }

    func testStoreRetainsOlderEvidenceAndAddsLedgerContext() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewsBarTests-\(UUID().uuidString)")
            .appendingPathComponent("trend.json")
        let store = TrendHistoryStore(fileURL: url)
        defer { Task { await store.clear() } }

        let old = now.addingTimeInterval(-8 * 24 * 60 * 60)
        _ = await store.record(
            weibo: [NewsItem(title: "旧话题", url: "https://example.com/old", source: .weibo, rank: 1)],
            bilibili: [],
            now: old
        )
        let change = await store.record(
            weibo: [NewsItem(title: "新话题", url: "https://example.com/new", source: .weibo, rank: 1)],
            bilibili: [],
            now: now
        )

        let kept = await store.recentSnapshots(hours: 9 * 24, now: now)
        XCTAssertEqual(kept.count, 2)
        XCTAssertTrue(change.context.contains("近7天趋势证据"))
    }

    private func snapshot(
        at date: Date,
        topic: String,
        rank: Int?
    ) -> TrendSnapshot {
        TrendSnapshot(
            timestamp: date,
            weiboItems: [
                NewsItem(
                    title: topic,
                    url: "https://example.com/\(topic)",
                    source: .weibo,
                    rank: rank
                )
            ],
            bilibiliItems: [],
            contentHash: "\(date.timeIntervalSince1970)-\(topic)-\(rank ?? -1)"
        )
    }
}
