import XCTest
@testable import NewsBar

final class RecommendationTraceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let rssA = NewsSource.rss(name: "A", url: "https://a.example/rss")
    private let rssB = NewsSource.rss(name: "B", url: "https://b.example/rss")

    private func item(_ title: String, _ id: Int, source: NewsSource = .weibo, rank: Int? = nil,
                      hot: String? = nil, publishedAt: Date? = nil) -> NewsItem {
        NewsItem(title: title, url: "https://example.com/trace/\(id)", source: source,
                 rank: rank, hotLabel: hot, publishedAt: publishedAt)
    }

    func testContributionSumMinusReadAndFeedbackPenaltiesEqualsRawScore() throws {
        var state = LocalInterestState()
        state.learningEnabled = true
        let read = item("人工智能模型发布", 1, rank: 3, hot: "爆")
        state.ingest([read], now: now)
        _ = state.record(item: read, kind: .qualifiedRead, epoch: state.consentEpoch, now: now)
        _ = state.feedback(item: read, kind: .reduceTopic, topic: "ai", now: now)

        let ranked = RecommendationEngine.rank(items: [read], state: state, now: now, limit: 5)
        let row = try XCTUnwrap(ranked.items.first)
        let trace = try XCTUnwrap(row.trace)

        // Contributions are the actual additive terms of the displayed score.
        let sum = trace.contributions.values.reduce(0, +)
        XCTAssertEqual(sum - trace.readPenalty - trace.feedbackPenalty, trace.rawScore, accuracy: 1e-9)
        XCTAssertEqual(trace.rawScore,
                       trace.confidence * trace.personalScore + (1 - trace.confidence) * trace.baselineScore
                           - trace.readPenalty - trace.feedbackPenalty,
                       accuracy: 1e-9)
        XCTAssertEqual(trace.readPenalty, 0.15, accuracy: 1e-12)
        XCTAssertEqual(trace.feedbackPenalty, 0.2, accuracy: 1e-12)
        XCTAssertEqual(trace.selectionScore,
                       trace.rawScore - trace.sourcePenalty - trace.topicPenalty - trace.diversityPenalty,
                       accuracy: 1e-9)
        XCTAssertEqual(row.score, trace.rawScore, accuracy: 1e-9)
        XCTAssertNotNil(trace.contributions["personal.interest"])
        XCTAssertNotNil(trace.contributions["baseline.publicHeat"])
        XCTAssertEqual(trace.finalRank, 1)
        XCTAssertEqual(trace.rankBeforeDiversity, 1)
        XCTAssertEqual(trace.selectionPolicy, "score")
    }

    func testSelectionPolicyNamesTheActualSlotAndRotationIsLexicographic() throws {
        var state = LocalInterestState()
        state.learningEnabled = true
        let items = (0..<14).map { item("人工智能模型 \($0)", $0, rank: $0 + 1, hot: $0 % 2 == 0 ? "爆" : nil) }
        state.ingest(items, now: now)

        let ranked = RecommendationEngine.rank(items: items, state: state, now: now, limit: 12, seed: 7)
        XCTAssertEqual(ranked.items.count, 12)
        let traces = try ranked.items.map { try XCTUnwrap($0.trace) }

        XCTAssertEqual(traces[0].selectionPolicy, "score")
        XCTAssertEqual(traces[7].selectionPolicy, "publicHeat")
        XCTAssertEqual(traces[8].selectionPolicy, "publicHeat")
        XCTAssertEqual(traces[9].selectionPolicy, "sourceRotation")

        for (index, trace) in traces.enumerated() {
            XCTAssertEqual(trace.finalRank, index + 1)
            XCTAssertGreaterThanOrEqual(trace.rankBeforeDiversity, 1)
        }
        XCTAssertEqual(Set(traces.map(\.rankBeforeDiversity)).count, traces.count)

        // Public slots report the key that actually ordered them: heat minus the
        // penalties applied in that slot.
        for (row, trace) in zip(ranked.items[7...8], traces[7...8]) {
            let heat = try XCTUnwrap(row.components["publicHeat"])
            XCTAssertEqual(trace.selectionScore,
                           heat - trace.sourcePenalty - trace.topicPenalty - trace.diversityPenalty,
                           accuracy: 1e-9)
        }

        // Same-source cap is enforced from the sixth pick onward.
        XCTAssertEqual(traces[4].diversityPenalty, 0, accuracy: 1e-12)
        XCTAssertEqual(traces[5].diversityPenalty, 1, accuracy: 1e-12)

        // The rotation slot orders by least-used source and a seed offset; it is
        // not an additive score, so no diversity penalties were applied to it.
        let rotation = traces[9]
        XCTAssertEqual(rotation.sourcePenalty, 0)
        XCTAssertEqual(rotation.topicPenalty, 0)
        XCTAssertEqual(rotation.diversityPenalty, 0)
        XCTAssertEqual(rotation.selectionScore, rotation.rawScore, accuracy: 1e-9)
        // With seed 7 the remaining pool has 5 candidates, so offset 2 picks the
        // candidate at index 3: original rank 13 while only 12 rows are returned.
        XCTAssertEqual(rotation.rankBeforeDiversity, 13)
        XCTAssertGreaterThan(rotation.rankBeforeDiversity, ranked.items.count)
        XCTAssertEqual(rotation.rotationSourceUseCount, 9)
        XCTAssertEqual(rotation.rotationOffset, 2)
        XCTAssertEqual(rotation.rotationCandidateIndex, 3)
        XCTAssertEqual(rotation.rotationCandidateCount, 5)
        XCTAssertNil(traces[0].rotationSourceUseCount)
    }

    func testPublicHeatSlotFallsBackToFreshnessWithoutInventingHeat() throws {
        var state = LocalInterestState()
        let items = (0..<9).map {
            item("新闻 \($0)", $0, source: .rss(name: "S\($0)", url: "https://s\($0).example/rss"),
                 publishedAt: now.addingTimeInterval(TimeInterval(-$0 * 60)))
        }
        state.ingest(items, now: now)

        let ranked = RecommendationEngine.rank(items: items, state: state, now: now, limit: 9)
        let traces = try ranked.items.map { try XCTUnwrap($0.trace) }
        XCTAssertEqual(traces.count, 9)
        XCTAssertTrue(traces.prefix(7).allSatisfy { $0.selectionPolicy == "score" })
        XCTAssertEqual(traces[7].selectionPolicy, "publicFresh")
        XCTAssertEqual(traces[8].selectionPolicy, "publicFresh")
        XCTAssertNil(traces[7].contributions["baseline.publicHeat"])
        XCTAssertNil(traces[8].contributions["personal.publicHeat"])
        let recency = try XCTUnwrap(ranked.items[7].components["recency"])
        XCTAssertEqual(traces[7].selectionScore,
                       recency - traces[7].sourcePenalty - traces[7].topicPenalty - traces[7].diversityPenalty,
                       accuracy: 1e-9)
    }

    func testSourceAndTopicPenaltiesComeFromTheActualPass() throws {
        var state = LocalInterestState()
        let a = item("新闻甲", 1, source: rssA)
        let b = item("新闻乙", 2, source: rssA)
        state.ingest([a, b], now: now)

        let ranked = RecommendationEngine.rank(items: [a, b], state: state, now: now, limit: 2)
        let second = try XCTUnwrap(ranked.items.last?.trace)
        XCTAssertEqual(second.sourcePenalty, 0.12, accuracy: 1e-12)
        XCTAssertEqual(second.topicPenalty, 0.04, accuracy: 1e-12) // both untagged -> "unknown"
        XCTAssertEqual(second.diversityPenalty, 0, accuracy: 1e-12)

        let filtered = RecommendationEngine.rank(items: [a, b], state: state, now: now, limit: 2, sourceFiltered: true)
        for item in filtered.items {
            XCTAssertEqual(try XCTUnwrap(item.trace).sourcePenalty, 0, accuracy: 1e-12)
        }
    }

    func testRankBeforeDiversityCanDifferFromFinalRank() throws {
        var state = LocalInterestState()
        // Small recency gaps keep the second item's pre-diversity rank above the
        // other source, so the 0.12 same-source penalty lets the other overtake.
        let first = item("新闻 一", 1, source: rssA, publishedAt: now)
        let sameSource = item("新闻 二", 2, source: rssA, publishedAt: now.addingTimeInterval(-3600))
        let otherSource = item("新闻 三", 3, source: rssB, publishedAt: now.addingTimeInterval(-7200))
        state.ingest([first, sameSource, otherSource], now: now)

        let ranked = RecommendationEngine.rank(items: [first, sameSource, otherSource], state: state, now: now, limit: 3)
        let traces = try ranked.items.map { try XCTUnwrap($0.trace) }
        XCTAssertEqual(traces.map(\.rankBeforeDiversity), [1, 3, 2])
        XCTAssertEqual(traces.map(\.finalRank), [1, 2, 3])
        XCTAssertEqual(traces[1].sourcePenalty, 0, accuracy: 1e-12)
        XCTAssertEqual(traces[2].sourcePenalty, 0.12, accuracy: 1e-12)
    }

    func testClusterDuplicateLeavesRankGapBeyondReturnedCount() throws {
        var state = LocalInterestState()
        // Two different URLs with the exact same title share a cluster; the
        // lower-ranked third item is returned after the duplicate is skipped.
        let first = item("人工智能模型", 1, source: rssA, publishedAt: now)
        let duplicateCluster = item(first.title, 2, source: rssA, publishedAt: now)
        let other = item("体育新闻", 3, source: rssA, publishedAt: now.addingTimeInterval(-24 * 3600))
        state.ingest([first, duplicateCluster, other], now: now)

        let ranked = RecommendationEngine.rank(items: [first, duplicateCluster, other], state: state, now: now, limit: 2)
        XCTAssertEqual(ranked.items.count, 2)
        let traces = try ranked.items.map { try XCTUnwrap($0.trace) }
        XCTAssertEqual(traces.map(\.finalRank), [1, 2])
        XCTAssertEqual(traces[1].rankBeforeDiversity, 3)
        XCTAssertGreaterThan(traces[1].rankBeforeDiversity, ranked.items.count)
    }

    func testMissingHeatDateAndTagsStayUnknownInTrace() throws {
        var state = LocalInterestState()
        let undated = item("新闻速览", 1, source: rssA)
        state.ingest([undated], now: now)

        let ranked = RecommendationEngine.rank(items: [undated], state: state, now: now)
        let row = try XCTUnwrap(ranked.items.first)
        let trace = try XCTUnwrap(row.trace)

        XCTAssertNil(row.components["publicHeat"])
        XCTAssertNil(row.components["interest"])
        XCTAssertNil(row.topic)
        XCTAssertNil(trace.contributions["personal.publicHeat"])
        XCTAssertNil(trace.contributions["baseline.publicHeat"])
        XCTAssertNil(trace.contributions["personal.interest"])
        XCTAssertEqual(trace.baselineScore, 1.0, accuracy: 1e-9) // recency 1, novelty 1, no heat
        XCTAssertEqual(trace.contributions["baseline.recency"] ?? -1, 0.7, accuracy: 1e-9)
        XCTAssertEqual(trace.contributions["baseline.novelty"] ?? -1, 0.3, accuracy: 1e-9)
        XCTAssertEqual(trace.selectionPolicy, "score")

        let old = item("新闻旧闻", 2, source: rssA, publishedAt: now.addingTimeInterval(-48 * 3600))
        state.ingest([old], now: now)
        let oldTrace = try XCTUnwrap(RecommendationEngine.rank(items: [old], state: state, now: now).items.first?.trace)
        XCTAssertEqual(oldTrace.baselineScore, 0.7 * 0.25 + 0.3, accuracy: 1e-9)
        XCTAssertNil(oldTrace.contributions["baseline.publicHeat"])
    }

    func testDeterministicReplayProducesIdenticalTraces() throws {
        var state = LocalInterestState()
        state.learningEnabled = true
        state.followedTopics = ["人工智能"]
        let items = (0..<14).map {
            item("人工智能模型 \($0)", $0, source: $0.isMultiple(of: 2) ? rssA : rssB,
                 publishedAt: now.addingTimeInterval(TimeInterval(-$0 * 600)))
        }
        state.ingest(items, now: now)

        let first = RecommendationEngine.rank(items: items, state: state, now: now, limit: 10, seed: 4)
        let second = RecommendationEngine.rank(items: items, state: state, now: now, limit: 10, seed: 4)
        XCTAssertEqual(first.policyVersion, 3)
        XCTAssertEqual(first.items.map(\.contentID), second.items.map(\.contentID))
        for (lhs, rhs) in zip(first.items, second.items) {
            XCTAssertEqual(try XCTUnwrap(lhs.trace), try XCTUnwrap(rhs.trace))
        }
    }

    func testLegacyScoredRecommendationLeavesTraceNil() {
        let legacy = ScoredRecommendation(item: item("新闻", 1), contentID: "content", clusterID: "cluster",
                                          score: 1, components: [:], reason: "fresh", topic: nil)
        XCTAssertNil(legacy.trace)
    }
}
