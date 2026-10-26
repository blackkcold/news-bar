import XCTest
@testable import NewsBar

final class RecommendationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func item(_ title: String, _ id: Int, source: NewsSource = .weibo, rank: Int? = nil, hot: String? = nil) -> NewsItem {
        NewsItem(title: title, url: "https://example.com/a/\(id)", source: source, rank: rank, hotLabel: hot)
    }

    func testShortLatinKeywordDoesNotMatchInsideUnrelatedWords() {
        XCTAssertFalse(TitleFeatures.matches("AI", in: "chair and railway"))
        XCTAssertTrue(TitleFeatures.matches("AI", in: "AI模型发布"))
        XCTAssertTrue(TitleFeatures.matches("苹果", in: "苹果发布新手机"))
        XCTAssertTrue(TitleFeatures.tags("人工智能模型发布").contains("ai"))
    }

    func testLearningBoostsRelatedTopicsAndDecaysShortTerm() {
        var state = LocalInterestState()
        state.learningEnabled = true
        for n in 0..<12 {
            _ = state.record(item: item("人工智能模型 \(n)", n), kind: .qualifiedRead, epoch: state.consentEpoch, now: now)
        }
        let profile = InterestProfile.build(state: state, now: now)
        let later = InterestProfile.build(state: state, now: now.addingTimeInterval(4 * 86400))
        XCTAssertGreaterThan(profile.topics["ai"] ?? 0, 0)
        XCTAssertLessThan(later.shortTermTopics["ai"] ?? 0, (profile.shortTermTopics["ai"] ?? 0) / 2)
        let a = item("人工智能推出新模型", 100, source: .rss(name: "A", url: "https://a.example/feed"))
        let b = item("足球联赛结果", 101, source: a.source)
        state.ingest([a, b], now: now)
        let ranked = RecommendationEngine.rank(items: [b, a], state: state, now: now)
        XCTAssertEqual(ranked.items.first?.item.id, a.id)
        XCTAssertGreaterThan(ranked.profileConfidence, 0.5)
    }

    func testHardBlocksSurvivePublicHeatAndUndoRestoresCandidate() {
        var state = LocalInterestState()
        state.learningEnabled = true
        let blocked = item("人工智能爆款", 1, hot: "爆")
        let feedback = state.feedback(item: blocked, kind: .muteSource, now: now)
        XCTAssertTrue(RecommendationEngine.rank(items: [blocked], state: state, now: now).items.isEmpty)
        state.undoFeedback(feedback)
        XCTAssertEqual(RecommendationEngine.rank(items: [blocked], state: state, now: now).items.count, 1)
    }

    func testColdStartDeduplicatesAliasesAndDoesNotInventMissingHeat() {
        let a = item("新闻", 1, source: .rss(name: "Test", url: "https://example.com/rss"))
        let alias = NewsItem(title: a.title, url: a.url + "?utm_source=x", source: a.source)
        let result = RecommendationEngine.rank(items: [a, alias], state: LocalInterestState(), now: now)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.profileConfidence, 0)
        XCTAssertNil(result.items.first?.components["publicHeat"])
        XCTAssertTrue(result.semanticDegraded)
    }

    func testDiversityAndExplorationUseAllEligibleCandidates() {
        var state = LocalInterestState()
        state.learningEnabled = true
        var items = (0..<30).map { item("人工智能模型更新 \($0)", $0, rank: $0 + 1) }
        let outside = item("足球新闻", 99, source: .rss(name: "Sports", url: "https://sports.example/rss"))
        items.append(outside)
        state.ingest(items, now: now)
        let ranked = RecommendationEngine.rank(items: items, state: state, now: now, limit: 10, seed: 8)
        XCTAssertTrue(ranked.items.contains { $0.item.id == outside.id })
        XCTAssertEqual(items[0].rank, 1)
        XCTAssertEqual(ranked.items.count, 10)
    }

    func testOldReadsRetainLongTermAggregateAfterRawEventRetention() {
        var state = LocalInterestState()
        state.learningEnabled = true
        _ = state.record(item: item("人工智能模型", 1), kind: .qualifiedRead, epoch: state.consentEpoch, now: now)
        state.prune(now: now.addingTimeInterval(40 * 86400))
        XCTAssertTrue(state.events.isEmpty)
        XCTAssertGreaterThan(InterestProfile.build(state: state, now: now.addingTimeInterval(40 * 86400)).topics["ai"] ?? 0, 0)
        state.clearPersonalData(keepBookmarks: false)
        XCTAssertTrue(InterestProfile.build(state: state, now: now).topics.isEmpty)
    }

    func testFiveHundredCandidateRankingTiming() {
        let items = (0..<500).map { item("科技新闻人工智能 \($0)", $0, rank: ($0 % 50) + 1) }
        var state = LocalInterestState()
        state.ingest(items, now: now)
        let coldStart = ProcessInfo.processInfo.systemUptime
        _ = RecommendationEngine.rank(items: items, state: state, now: now, limit: 40)
        print("500-candidate cold ranking: \((ProcessInfo.processInfo.systemUptime - coldStart) * 1000) ms (debug)")
        var durations: [Double] = []
        for _ in 0..<10 {
            let start = ProcessInfo.processInfo.systemUptime
            let result = RecommendationEngine.rank(items: items, state: state, now: now, limit: 40)
            durations.append(ProcessInfo.processInfo.systemUptime - start)
            XCTAssertEqual(result.items.count, 40)
        }
        let p95 = durations.sorted()[9]
        print("500-candidate cached ranking, 10 samples, max/P95 upper bound: \(p95 * 1000) ms (debug)")
        XCTAssertLessThan(p95, 0.2)
    }
}
