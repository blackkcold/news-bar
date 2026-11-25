import XCTest
@testable import NewsBar

final class RecommendationShadowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testOnlyTaggedWithoutMatchChangesRawScoring() throws {
        let source = NewsSource.rss(name: "Synthetic", url: "https://example.invalid/rss")
        let items = ["未分类快讯", "体育头条", "人工智能头条"].enumerated().map { index, title in
            NewsItem(title: title, url: "https://example.invalid/\(index)", source: source, publishedAt: now)
        }
        var state = LocalInterestState()
        state.learningEnabled = true
        state.followedTopics = ["人工智能"]
        let a = RecommendationEngine.rank(items: items, state: state, now: now, variant: .v4)
        let b = RecommendationEngine.rank(items: items, state: state, now: now, variant: .taggedNoMatchNeutral)
        let defaultRank = RecommendationEngine.rank(items: items, state: state, now: now)
        XCTAssertEqual(a.items.map(\.trace), defaultRank.items.map(\.trace))
        XCTAssertEqual(a.policyVersion, b.policyVersion)
        XCTAssertFalse(RecommendationExperimentGate.dashboardTimeBlocksEnabled)
        for item in b.items {
            let previous = try XCTUnwrap(a.items.first { $0.contentID == item.contentID })
            let trace = try XCTUnwrap(item.trace)
            XCTAssertEqual(trace.contributions.values.reduce(0, +) - trace.readPenalty - trace.negativePenalty, trace.rawScore, accuracy: 1e-10)
            if item.item.title == "体育头条" {
                XCTAssertEqual(item.components["interest"], 0)
                XCTAssertEqual(trace.personalScore, 0.25 / 0.35, accuracy: 1e-10)
                XCTAssertNil(trace.contributions["personal.interest"])
                XCTAssertGreaterThan(item.score, previous.score)
            } else {
                XCTAssertEqual(item.score, previous.score)
            }
        }
    }

    func testShadowRecordsOnlyAggregateMetricsAndPreservesRankingConstraints() async throws {
        let candidates = (0..<20).map { i in
            NewsItem(title: "体育 赛事 \(i)", url: "https://example.invalid/\(i)",
                     source: i.isMultiple(of: 2) ? .weibo : .bilibili, rank: i + 1, publishedAt: now)
        }
        var state = LocalInterestState()
        state.learningEnabled = true
        state.followedTopics = ["人工智能"]
        _ = state.feedback(item: candidates[0], kind: .notInterested, now: now)
        let inputs = RecommendationShadowInput(items: candidates + [candidates[1]], state: state, feedback: [], now: now, seed: 9)
        async let a = inputs.rank(.v4)
        async let b = inputs.rank(.taggedNoMatchNeutral)
        let (resultA, resultB) = await (a, b)
        let sample = inputs.compare(resultA, resultB)
        XCTAssertLessThanOrEqual(sample.top10Overlap, 10)
        XCTAssertEqual(sample.candidateCount, 21)
        XCTAssertEqual(sample.a.ruleViolations, 0)
        XCTAssertEqual(sample.b.ruleViolations, 0)
        for ranked in [resultA.snapshot, resultB.snapshot] {
            XCTAssertFalse(ranked.items.contains { $0.item.url == candidates[0].url })
            XCTAssertEqual(Set(ranked.items.map(\.contentID)).count, ranked.items.count)
            XCTAssertEqual(ranked.items[7].trace?.selectionPolicy, "publicHeat")
            XCTAssertEqual(ranked.items[9].trace?.selectionPolicy, "sourceRotation")
        }
        let encoded = try JSONEncoder().encode(sample)
        let output = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(output.contains("example.invalid"))
        XCTAssertFalse(output.contains("体育"))
        XCTAssertFalse(output.contains(candidates[1].id))
    }
}
