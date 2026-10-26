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

    func testKnownDictionaryFollowTransfersAcrossAliasesAndKeepsLiteralKeywords() {
        let source = NewsSource.rss(name: "Tech", url: "https://tech.example/rss")
        let aliasOnly = item("AI 新模型发布", 1, source: source)
        let iphone = item("iPhone 新品发布", 2, source: source)

        var followed = LocalInterestState()
        followed.learningEnabled = true
        followed.followedTopics = ["人工智能"]
        let transferred = RecommendationEngine.rank(items: [aliasOnly], state: followed, now: now)
        XCTAssertEqual(transferred.items.first?.topic, "ai")
        XCTAssertEqual(transferred.items.first?.components["interest"] ?? -1, 0.65, accuracy: 1e-9)

        var cold = LocalInterestState()
        cold.learningEnabled = true
        let coldRanked = RecommendationEngine.rank(items: [aliasOnly], state: cold, now: now)
        XCTAssertEqual(coldRanked.items.first?.components["interest"] ?? -1, 0, accuracy: 1e-12)

        var apple = LocalInterestState()
        apple.learningEnabled = true
        apple.followedTopics = ["苹果"]
        let appleRanked = RecommendationEngine.rank(items: [iphone], state: apple, now: now)
        XCTAssertEqual(appleRanked.items.first?.topic, "entity:apple")
        XCTAssertEqual(appleRanked.items.first?.components["interest"] ?? -1, 0.65, accuracy: 1e-9)

        var literal = LocalInterestState()
        literal.learningEnabled = true
        literal.followedTopics = ["量子计算"]
        let literalItem = item("量子计算取得突破", 3, source: source)
        let literalRanked = RecommendationEngine.rank(items: [literalItem], state: literal, now: now)
        XCTAssertEqual(literalRanked.items.first?.topic, "followed:量子计算")
        XCTAssertEqual(literalRanked.items.first?.components["interest"] ?? -1, 0.65, accuracy: 1e-9)

        let unrelated = RecommendationEngine.rank(items: [item("足球联赛结果", 4)], state: followed, now: now)
        XCTAssertEqual(unrelated.items.first?.components["interest"] ?? -1, 0, accuracy: 1e-12)
    }

    func testDuplicateAliasFollowsMergeIntoOneCanonicalEvidence() {
        let source = NewsSource.rss(name: "Tech", url: "https://tech.example/rss")

        var single = LocalInterestState()
        single.learningEnabled = true
        single.followedTopics = ["人工智能"]
        var double = LocalInterestState()
        double.learningEnabled = true
        double.followedTopics = ["人工智能", "AI"]

        let one = InterestProfile.build(state: single, now: now)
        let two = InterestProfile.build(state: double, now: now)
        XCTAssertEqual(one.topics["ai"] ?? 0, 4, accuracy: 1e-12)
        XCTAssertEqual(two.topics["ai"] ?? 0, 4, accuracy: 1e-12)
        XCTAssertEqual(one.confidence, two.confidence, accuracy: 1e-12)
        XCTAssertEqual(two.confidence, 0.25, accuracy: 1e-12)
        XCTAssertNil(two.topics["followed:AI"])

        // A second canonical topic keeps full affinity: the collapsed follow must
        // not inflate peak normalization and halve unrelated topics.
        double.followedTopics.append("科技")
        let chip = item("芯片进展", 1, source: source)
        let ranked = RecommendationEngine.rank(items: [chip], state: double, now: now)
        XCTAssertEqual(ranked.items.first?.components["interest"] ?? -1, 0.65, accuracy: 1e-9)
    }

    func testArbitraryLiteralFollowsKeepTheirOwnKeysAndEvidence() {
        var state = LocalInterestState()
        state.learningEnabled = true
        state.followedTopics = ["量子计算", "室温超导"]

        let profile = InterestProfile.build(state: state, now: now)
        XCTAssertEqual(profile.topics["followed:量子计算"] ?? 0, 4, accuracy: 1e-12)
        XCTAssertEqual(profile.topics["followed:室温超导"] ?? 0, 4, accuracy: 1e-12)
        XCTAssertEqual(profile.confidence, 0.5, accuracy: 1e-12)
    }

    func testNonParticipatingSoftFeedbackNeverAppliesAfterReEnabling() throws {
        let source = NewsSource.rss(name: "Tech", url: "https://tech.example/rss")
        let ai = item("人工智能模型", 1, source: source)

        var legacy = LocalInterestState()
        legacy.learningEnabled = false
        legacy.feedbacks = [
            InterestFeedback(item: ai, kind: .reduceTopic, occurredAt: now, topic: "ai", participatesInProfile: false),
            InterestFeedback(item: ai, kind: .moreLikeThis, occurredAt: now, participatesInProfile: false),
            InterestFeedback(item: ai, kind: .followTopic, occurredAt: now, topic: "ai", participatesInProfile: false)
        ]
        legacy.learningEnabled = true

        let profile = InterestProfile.build(state: legacy, now: now)
        XCTAssertNil(profile.topics["ai"]) // old reduce must not apply -4
        XCTAssertEqual(profile.shortTermTopics["ai"] ?? 0, 0, accuracy: 1e-12) // no moreLikeThis +2
        XCTAssertEqual(profile.confidence, 0, accuracy: 1e-12) // followTopic is not consent evidence
        let legacyTrace = try XCTUnwrap(RecommendationEngine.rank(items: [ai], state: legacy, now: now).items.first?.trace)
        XCTAssertEqual(legacyTrace.feedbackPenalty, 0, accuracy: 1e-12)

        // The same flag must not disable feedback that was recorded with consent.
        var active = LocalInterestState()
        active.learningEnabled = true
        active.feedbacks = [
            InterestFeedback(item: ai, kind: .reduceTopic, occurredAt: now, topic: "ai", participatesInProfile: true)
        ]
        XCTAssertEqual(InterestProfile.build(state: active, now: now).topics["ai"] ?? 0, -4, accuracy: 1e-12)
        let activeTrace = try XCTUnwrap(RecommendationEngine.rank(items: [ai], state: active, now: now).items.first?.trace)
        XCTAssertEqual(activeTrace.feedbackPenalty, 0.2, accuracy: 1e-12)
    }

    func testScopedHardBlocksOnlyRemoveTheirOwnScope() {
        let source = NewsSource.rss(name: "S", url: "https://s.example/rss")
        let other = NewsSource.rss(name: "T", url: "https://t.example/rss")
        let blockedContent = item("人工智能一", 1, source: source)
        let sameCluster = NewsItem(title: blockedContent.title, url: "https://example.com/other/1", source: source)
        let sameSourceOther = item("人工智能二", 2, source: source)
        let otherSource = item("人工智能三", 3, source: other)
        let items = [blockedContent, sameCluster, sameSourceOther, otherSource]

        func ranked(after feedback: (inout LocalInterestState) -> Void) -> RecommendationSnapshot {
            var state = LocalInterestState()
            state.learningEnabled = true
            state.ingest(items, now: now)
            feedback(&state)
            return RecommendationEngine.rank(items: items, state: state, now: now)
        }

        let content = ranked { $0.feedback(item: blockedContent, kind: .notInterested, now: now) }
        XCTAssertFalse(content.items.contains { $0.contentID == ContentIdentity.id(for: blockedContent.url) })
        XCTAssertTrue(content.items.contains { $0.item.id == sameCluster.id })
        XCTAssertTrue(content.items.contains { $0.item.id == sameSourceOther.id })

        let cluster = ranked { $0.feedback(item: blockedContent, kind: .hideEvent, now: now) }
        XCTAssertFalse(cluster.items.contains { $0.clusterID == ContentIdentity.cluster(for: blockedContent) })
        XCTAssertTrue(cluster.items.contains { $0.item.id == sameSourceOther.id })

        let muted = ranked { $0.feedback(item: blockedContent, kind: .muteSource, now: now) }
        XCTAssertFalse(muted.items.contains { $0.item.source.id == source.id })
        XCTAssertEqual(muted.items.map(\.item.id), [otherSource.id])
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
