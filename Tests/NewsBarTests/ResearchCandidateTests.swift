import XCTest
@testable import NewsBar

final class ResearchCandidateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func rssItem(_ title: String, _ path: String, publishedAt: Date? = nil) -> NewsItem {
        NewsItem(
            title: title,
            url: "https://example.com/\(path)",
            source: .rss(name: "Test", url: "https://example.com/feed"),
            publishedAt: publishedAt ?? now
        )
    }

    func testPersonalInterestEntersPoolWithoutABurst() {
        var state = LocalInterestState()
        state.learningEnabled = true
        state.followedTopics = ["OpenAI"]
        let item = rssItem("OpenAI 发布新模型", "openai")

        let candidates = ResearchCandidateBuilder.build(items: [item], state: state, now: now)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.kind, .personal)
        XCTAssertGreaterThanOrEqual(candidates.first?.personalRelevance ?? 0, ResearchCandidateBuilder.personalThreshold)
    }

    func testBlockedKeywordAndOldRSSItemsAreExcluded() {
        var state = LocalInterestState()
        state.learningEnabled = true
        state.followedTopics = ["OpenAI"]
        let blocked = rssItem("OpenAI 旧闻", "blocked")
        state.feedback(item: blocked, kind: .notInterested)
        let keyword = rssItem("OpenAI 关键词稿", "keyword")
        let old = rssItem("OpenAI 昨天的稿", "old", publishedAt: now.addingTimeInterval(-48 * 3600))
        let fresh = rssItem("OpenAI 新进展", "fresh")

        let candidates = ResearchCandidateBuilder.build(
            items: [blocked, keyword, old, fresh],
            state: state,
            now: now,
            isKeywordMatch: { $0.id == keyword.id }
        )

        XCTAssertEqual(candidates.map(\.item.id), [fresh.id])
    }

    func testSameEventIsDeduplicatedBeforeTriage() {
        var state = LocalInterestState()
        state.learningEnabled = true
        state.followedTopics = ["OpenAI"]
        let first = rssItem("OpenAI 发布新模型", "a")
        let second = rssItem("OpenAI 发布新模型", "b")

        let candidates = ResearchCandidateBuilder.build(items: [first, second], state: state, now: now)

        XCTAssertEqual(candidates.count, 1)
    }

    func testPublicChartItemCanEnterWithoutInterest() {
        var state = LocalInterestState()
        state.learningEnabled = false
        let item = NewsItem(
            title: "榜内新闻",
            url: "https://weibo.com/hot/1",
            source: .weibo,
            rank: 1,
            hotLabel: "热"
        )

        let candidates = ResearchCandidateBuilder.build(items: [item], state: state, now: now)

        XCTAssertEqual(candidates.first?.kind, .publicHot)
    }

    func testTriageParserAcceptsFencesAndDefaultsMissingFields() {
        let text = """
        ```json
        [{"id":"a","worth":true,"confidence":2},
         {"id":"b","reason":"no"}]
        ```
        """
        let decisions = ResearchTriage.parse(text)

        XCTAssertEqual(decisions.count, 2)
        XCTAssertEqual(decisions[0].confidence, 1)
        XCTAssertTrue(decisions[0].worth)
        XCTAssertFalse(decisions[1].worth)
        XCTAssertEqual(decisions[1].confidence, 0)
    }

    func testTriageParserRejectsProseWithoutArray() {
        XCTAssertTrue(ResearchTriage.parse("I cannot help with that.").isEmpty)
    }

    func testTriageParserKeepsValidVerdictsWhenOneRowIsMalformed() {
        let text = #"[{"id":"good","worth":true,"confidence":0.9},{"id":"bad","worth":"true","confidence":0.8}]"#

        let decisions = ResearchTriage.parse(text)

        XCTAssertEqual(decisions.map(\.id), ["good"])
        XCTAssertEqual(decisions.first?.worth, true)
    }

    func testTriageChooseSkipsConfidentDuplicate() {
        let itemA = rssItem("同事件", "a")
        let itemB = rssItem("新事件", "b")
        let candidates = [
            ResearchCandidateItem(item: itemA, kind: .burst, publicHeat: 1, personalRelevance: 0.9, priority: 0.9),
            ResearchCandidateItem(item: itemB, kind: .personal, publicHeat: nil, personalRelevance: 0.8, priority: 0.7),
        ]
        let decisions = [
            ResearchTriageDecision(id: itemA.id, sameEventAs: "record-1", sameAngleAs: nil, worth: true, confidence: 0.9, reason: "same"),
            ResearchTriageDecision(id: itemB.id, sameEventAs: nil, sameAngleAs: nil, worth: true, confidence: 0.8, reason: "new"),
        ]

        let chosen = ResearchTriage.choose(
            candidates: candidates,
            decisions: decisions,
            knownRecordIDs: ["record-1"]
        )

        XCTAssertEqual(chosen?.item.id, itemB.id)
    }

    func testFallbackBurstIsRefusedWhenAnExistingVerdictSaysNo() {
        let burst = rssItem("极热爆款", "burst")
        let candidates = [
            ResearchCandidateItem(item: burst, kind: .burst, publicHeat: 0.95, personalRelevance: 0, priority: 1)
        ]
        let decisions = [
            ResearchTriageDecision(id: burst.id, sameEventAs: nil, sameAngleAs: nil, worth: false, confidence: 0.9, reason: "no")
        ]

        XCTAssertNil(ResearchTriage.fallbackBurst(candidates: candidates, decisions: decisions))
    }

    func testFallbackBurstRunsWhenNoVerdictExists() {
        let burst = rssItem("极热爆款", "burst")
        let candidates = [
            ResearchCandidateItem(item: burst, kind: .burst, publicHeat: 0.95, personalRelevance: 0, priority: 1)
        ]

        XCTAssertEqual(
            ResearchTriage.fallbackBurst(candidates: candidates, decisions: [])?.item.id,
            burst.id
        )
    }

    func testFallbackBurstIgnoresACoolBurstAndOnlyUsesUndecidedCandidates() {
        let cool = rssItem("普通爆款", "cool")
        let hot = rssItem("极热爆款", "hot")
        let other = rssItem("另一个候选", "other")
        let candidates = [
            ResearchCandidateItem(item: cool, kind: .burst, publicHeat: 0.6, personalRelevance: 0, priority: 0.7),
            ResearchCandidateItem(item: hot, kind: .burst, publicHeat: 0.95, personalRelevance: 0, priority: 0.9),
        ]
        let decisions = [
            ResearchTriageDecision(id: other.id, sameEventAs: nil, sameAngleAs: nil, worth: true, confidence: 0.9, reason: "other")
        ]

        XCTAssertEqual(
            ResearchTriage.fallbackBurst(candidates: candidates, decisions: decisions)?.item.id,
            hot.id
        )
    }

    func testTriageChooseRequiresConfidenceForWorth() {
        let item = rssItem("低置信", "c")
        let candidates = [
            ResearchCandidateItem(item: item, kind: .personal, publicHeat: nil, personalRelevance: 0.8, priority: 0.7)
        ]
        let decisions = [
            ResearchTriageDecision(id: item.id, sameEventAs: nil, sameAngleAs: nil, worth: true, confidence: 0.2, reason: "unsure")
        ]

        XCTAssertNil(ResearchTriage.choose(candidates: candidates, decisions: decisions, knownRecordIDs: []))
    }
}
