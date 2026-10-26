import AppKit
import SwiftUI
import XCTest
@testable import NewsBar

final class RecommendationExplanationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Fixtures

    private func item(_ title: String, _ number: Int, source: NewsSource = .weibo, rank: Int? = nil) -> NewsItem {
        NewsItem(title: title, url: "https://example.com/item/\(number)", source: source, rank: rank)
    }

    private func rssItem(_ title: String, _ number: Int, feed: String = "https://rss.example/feed") -> NewsItem {
        NewsItem(title: title, url: "https://example.com/item/\(number)", source: .rss(name: "Feed", url: feed))
    }

    /// One AI read, one Apple read, one canonical follow (Swift -> technology)
    /// and one local Swift title.
    private func activeState() -> LocalInterestState {
        var state = LocalInterestState()
        state.learningEnabled = true
        _ = state.record(item: item("人工智能模型发布", 1), kind: .qualifiedRead, epoch: state.consentEpoch, now: now)
        _ = state.record(item: item("苹果 iPhone 新机发布", 2), kind: .qualifiedRead, epoch: state.consentEpoch, now: now)
        state.followedTopics = ["Swift"]
        state.ingest([item("Swift 并发编程实践", 3, source: .rss(name: "Dev", url: "https://dev.example/rss"))], now: now)
        return state
    }

    /// A literal keyword outside the shared lexicon.
    private func literalFollowState(keyword: String = "SwiftUI", title: String = "SwiftUI 并发实践") -> LocalInterestState {
        var state = LocalInterestState()
        state.learningEnabled = true
        state.followedTopics = [keyword]
        state.ingest([rssItem(title, 3)], now: now)
        return state
    }

    private func activeSnapshot(_ state: LocalInterestState) -> RecommendationSnapshot {
        RecommendationEngine.rank(
            items: [
                rssItem("人工智能新模型", 10, feed: "https://tech.example/rss"),
                rssItem("苹果 iPhone 更新", 11, feed: "https://tech.example/rss"),
                rssItem("足球联赛赛果", 12, feed: "https://sport.example/rss")
            ],
            state: state,
            now: now,
            limit: 10
        )
    }

    private func makeSnapshot(
        _ items: [ScoredRecommendation],
        profileVersion: Int = 1,
        policyVersion: Int = 3,
        confidence: Double = 0.25,
        asOf: Date? = nil
    ) -> RecommendationSnapshot {
        RecommendationSnapshot(
            asOf: asOf ?? now,
            profileVersion: profileVersion,
            policyVersion: policyVersion,
            profileConfidence: confidence,
            semanticDegraded: true,
            items: items
        )
    }

    private func trace(
        policy: String = "score",
        rawScore: Double = 0.6,
        rankBefore: Int = 1,
        finalRank: Int = 1,
        rotation: (uses: Int, offset: Int, index: Int, count: Int)? = nil
    ) -> RecommendationExplanationTrace {
        RecommendationExplanationTrace(
            contributions: ["personal": 0.6, "publicHeat": 0.1],
            personalScore: 0.72,
            baselineScore: 0.64,
            confidence: 0.5,
            readPenalty: 0.15,
            feedbackPenalty: 0,
            rawScore: rawScore,
            selectionScore: 0.5,
            sourcePenalty: 0.12,
            topicPenalty: 0.04,
            diversityPenalty: 0,
            rankBeforeDiversity: rankBefore,
            finalRank: finalRank,
            selectionPolicy: policy,
            rotationSourceUseCount: rotation?.uses,
            rotationOffset: rotation?.offset,
            rotationCandidateIndex: rotation?.index,
            rotationCandidateCount: rotation?.count
        )
    }

    private func engineTrace(
        policy: String = "score",
        rotation: (uses: Int, offset: Int, index: Int, count: Int)? = nil
    ) -> RecommendationTrace {
        RecommendationTrace(
            contributions: ["personal.interest": 0.4],
            personalScore: 0.72,
            baselineScore: 0.6,
            confidence: 0.5,
            readPenalty: 0,
            feedbackPenalty: 0,
            rawScore: 0.65,
            selectionScore: 0.5,
            sourcePenalty: 0.1,
            topicPenalty: 0,
            diversityPenalty: 0,
            rankBeforeDiversity: 1,
            finalRank: 1,
            selectionPolicy: policy,
            rotationSourceUseCount: rotation?.uses,
            rotationOffset: rotation?.offset,
            rotationCandidateIndex: rotation?.index,
            rotationCandidateCount: rotation?.count
        )
    }

    private func model(
        state: LocalInterestState,
        snapshot: RecommendationSnapshot? = nil,
        enabled: Bool = true,
        ready: Bool = true,
        paused: Bool = false,
        privateReading: Bool = false,
        storageError: String? = nil,
        sessionFeedback: [InterestFeedback] = [],
        language: AppLanguage = .zh,
        traces: [String: RecommendationExplanationTrace] = [:],
        guide: [ExplanationGuideSection] = []
    ) -> RecommendationExplanationModel {
        var value = state
        value.learningEnabled = enabled
        value.learningPaused = paused
        let input = RecommendationExplanationInput(
            isReady: ready,
            storageError: storageError,
            privateReading: privateReading,
            state: value,
            snapshot: snapshot,
            sessionFeedback: sessionFeedback,
            now: now,
            language: language
        )
        return RecommendationExplanationModel.make(input: input, guide: guide, traceFor: { traces[$0.contentID] })
    }

    private func profile(_ state: LocalInterestState) -> InterestProfile {
        InterestProfile.build(state: state, now: now)
    }

    // MARK: - Status

    func testStatusDistinguishesOffPausedPrivateAndStorageFailure() {
        let state = activeState()
        XCTAssertEqual(model(state: state).status, .active)
        XCTAssertEqual(model(state: state, paused: true).status, .paused)
        XCTAssertEqual(model(state: state, privateReading: true).status, .privateReading)
        XCTAssertEqual(model(state: state, enabled: false).status, .off)
        XCTAssertEqual(model(state: state, ready: false).status, .notLoaded)
        XCTAssertEqual(model(state: state, storageError: "failed").status, .unavailable)
    }

    func testOffWinsOverAStalePrivateReadingFlag() {
        let state = activeState()
        let built = model(state: state, enabled: false, privateReading: true)
        XCTAssertEqual(built.status, .off)
        XCTAssertTrue(built.retainedProfileShown)
        XCTAssertTrue(built.statusDetail.contains("保留"))
        XCTAssertTrue(built.statusDetail.contains("不参与当前排序"))
        XCTAssertTrue(built.retainedProfileNote?.contains("保留画像·未参与当前排序") == true)
    }

    func testStorageFailureKeepsClearRecoveryGuidanceAndReadOnlyPromise() {
        let state = activeState()
        let zh = model(state: state, storageError: "failed")
        XCTAssertTrue(zh.storageErrorNote?.contains("清空") == true)
        XCTAssertTrue(zh.storageErrorNote?.contains("只读") == true)
        XCTAssertTrue(zh.readOnlyNote.contains("不会写入"))
        XCTAssertTrue(zh.lastKnownNote?.contains("上次已知") == true)

        let en = model(state: state, storageError: "failed", language: .en)
        XCTAssertTrue(en.storageErrorNote?.lowercased().contains("clear") == true)
        XCTAssertTrue(en.readOnlyNote.lowercased().contains("read-only"))
    }

    func testResettingHidesOldProfileAndSnapshot() {
        let state = activeState()
        let snapshot = activeSnapshot(state)
        let input = RecommendationExplanationInput(
            isReady: true,
            isResetting: true,
            state: state,
            snapshot: snapshot,
            now: now,
            language: .zh
        )
        let built = RecommendationExplanationModel.make(input: input)
        XCTAssertEqual(built.status, .resetting)
        XCTAssertTrue(built.dimensions.isEmpty)
        XCTAssertTrue(built.items.isEmpty)
        XCTAssertTrue(built.statusDetail.contains("清空"))
        XCTAssertTrue(built.statusDetail.contains("失败会报告"))
    }

    func testNotLoadedReasonAwaitsLoadingInsteadOfClaimingStoreFailure() {
        var state = LocalInterestState()
        state.learningEnabled = true
        let built = model(state: state, ready: false)
        XCTAssertEqual(built.status, .notLoaded)
        XCTAssertTrue(built.emptyReason?.contains("载入") == true)
        XCTAssertNil(built.lastKnownNote)
    }

    // MARK: - C1 real profile weights for follows

    func testCanonicalFollowDoesNotCreateDuplicateManualRow() {
        let state = activeState()
        let built = model(state: state)
        XCTAssertTrue(built.groups[2].dimensions.isEmpty,
                      "a lexicon follow must be represented on its topic row, not duplicated as a manual +4")
        guard let tech = built.dimensions.first(where: { $0.key == "technology" }) else {
            return XCTFail("Swift follow must surface on the technology row")
        }
        XCTAssertEqual(tech.kind, .topic)
        XCTAssertEqual(tech.longTerm, profile(state).topics["technology"] ?? -1, accuracy: 0.0001)
        XCTAssertEqual(tech.manualFollowKeywords, ["Swift"])
        XCTAssertEqual(built.dimensions.filter { $0.kind == .topic && $0.key == "technology" }.count, 1)
    }

    func testTwoAliasesOfOneTopicAddOneWeight() {
        var state = activeState()
        state.followedTopics = ["AI", "人工智能"]
        let built = model(state: state)
        XCTAssertTrue(built.groups[2].dimensions.isEmpty)
        XCTAssertEqual(built.dimensions.filter { $0.key == "ai" }.count, 1)
        guard let ai = built.dimensions.first(where: { $0.key == "ai" }) else { return XCTFail("missing ai") }
        XCTAssertEqual(ai.longTerm, profile(state).topics["ai"] ?? -1, accuracy: 0.0001)
        XCTAssertEqual(Set(ai.manualFollowKeywords), ["AI", "人工智能"])
        XCTAssertLessThan(ai.longTerm, 9, "two aliases must be counted once, not +4 each")
    }

    func testEVFollowUsesAutomotiveTagScope() {
        var state = LocalInterestState()
        state.learningEnabled = true
        state.followedTopics = ["EV"]
        state.ingest([rssItem("电动车新政策", 50, feed: "https://auto.example/rss")], now: now)
        let snapshot = RecommendationEngine.rank(
            items: [rssItem("新能源车销量", 51, feed: "https://auto.example/rss")],
            state: state,
            now: now,
            limit: 5
        )
        let built = model(state: state, snapshot: snapshot)
        XCTAssertTrue(built.groups[2].dimensions.isEmpty)
        guard let auto = built.dimensions.first(where: { $0.key == "auto" }) else {
            return XCTFail("EV must land on the automotive tag")
        }
        XCTAssertEqual(auto.longTerm, 4, accuracy: 0.0001)
        XCTAssertEqual(auto.manualFollowKeywords, ["EV"])
        XCTAssertEqual(built.connections(for: auto.id)?.candidates.first?.title, "新能源车销量")
    }

    func testCanonicalEntityFollowAnnotatesTheEntityRow() {
        var state = LocalInterestState()
        state.learningEnabled = true
        state.followedTopics = ["iPhone"]
        let built = model(state: state)
        XCTAssertTrue(built.groups[2].dimensions.isEmpty)
        guard let apple = built.dimensions.first(where: { $0.key == "entity:apple" }) else {
            return XCTFail("iPhone follow must land on the Apple entity row")
        }
        XCTAssertEqual(apple.manualFollowKeywords, ["iPhone"])
        XCTAssertEqual(apple.longTerm, 4, accuracy: 0.0001)
    }

    func testReducedCanonicalFollowKeepsRealZeroNetRow() {
        var state = activeState()
        _ = state.feedback(item: item("科技新闻", 60), kind: .reduceTopic, topic: "technology", now: now)
        let built = model(state: state)
        guard let tech = built.dimensions.first(where: { $0.key == "technology" }) else {
            return XCTFail("a net-zero reduced topic must stay visible with its real value")
        }
        XCTAssertEqual(tech.longTerm, profile(state).topics["technology"] ?? -1, accuracy: 0.0001)
        XCTAssertEqual(tech.longTerm, 0, accuracy: 0.0001)
        XCTAssertTrue(tech.isReduced)
        XCTAssertEqual(tech.manualFollowKeywords, ["Swift"])
    }

    func testReducedLiteralFollowUsesRealProfileValue() {
        var state = literalFollowState()
        _ = state.feedback(item: item("任意新闻", 70), kind: .reduceTopic, topic: "followed:SwiftUI", now: now)
        let built = model(state: state)
        guard let followed = built.dimensions.first(where: { $0.kind == .followed }) else {
            return XCTFail("a literal follow must stay visible with its real net value")
        }
        XCTAssertEqual(followed.key, "SwiftUI")
        XCTAssertEqual(followed.longTerm, profile(state).topics["followed:SwiftUI"] ?? -1, accuracy: 0.0001)
        XCTAssertEqual(followed.longTerm, 0, accuracy: 0.0001)
        XCTAssertTrue(followed.isReduced)
    }

    func testLiteralFollowIsTheOnlyManualGroupMemberAndUsesItsRealKey() {
        let state = literalFollowState()
        let built = model(state: state)
        let follows = built.groups[2].dimensions
        XCTAssertEqual(follows.map(\.key), ["SwiftUI"])
        XCTAssertEqual(follows.first?.longTerm ?? 0, profile(state).topics["followed:SwiftUI"] ?? -1, accuracy: 0.0001)
        XCTAssertTrue(follows.first?.manualFollowKeywords.isEmpty == true)
    }

    func testFollowMergeNoteDescribesSingleWeightWithoutFakePromise() {
        let built = model(state: activeState())
        guard let note = built.followMergeNote else { return XCTFail("missing merge note") }
        XCTAssertTrue(note.contains("只计一次"))
        XCTAssertTrue(note.contains("词典外"))
    }

    // MARK: - Dimensions and weights

    func testDimensionsSeparateTopicsEntitiesAndManualFollows() {
        let state = activeState()
        let built = model(state: state)
        XCTAssertEqual(built.groups.map(\.kind), [.topic, .entity, .followed])

        let topics = built.groups[0].dimensions
        XCTAssertTrue(topics.contains { $0.key == "ai" && $0.label == "AI" && $0.kind == .topic })
        let entities = built.groups[1].dimensions
        XCTAssertTrue(entities.contains { $0.key == "entity:apple" && $0.label == "Apple" && $0.kind == .entity })
        XCTAssertTrue(built.groups[2].dimensions.isEmpty)
        XCTAssertTrue(built.dimensions.allSatisfy { $0.key != "Swift" })
    }

    func testEntityLabelsAreNotMistakenForTopics() {
        let state = activeState()
        let built = model(state: state)
        let apple = built.dimensions.first { $0.key == "entity:apple" }
        XCTAssertEqual(apple?.kind, .entity)
        XCTAssertEqual(apple?.entityDisplayName, "Apple")
    }

    func testEmptyProfileDoesNotInventInterestRows() {
        var state = LocalInterestState()
        state.learningEnabled = true
        let built = model(state: state)
        XCTAssertTrue(built.dimensions.isEmpty)
        XCTAssertEqual(built.groups.count, 3)
        XCTAssertTrue(built.groups.allSatisfy { $0.dimensions.isEmpty && !$0.emptyText.isEmpty })
        XCTAssertTrue(built.emptyReason?.contains("尚无") == true)
        let en = model(state: state, language: .en)
        XCTAssertTrue(en.emptyReason?.lowercased().contains("no local") == true)
    }

    func testRelativeWeightsUseRealProfilePeakNotProbabilities() {
        let state = activeState()
        let built = model(state: state)
        XCTAssertEqual(built.dimensions.map(\.relativeWeight).max() ?? 0, 1, accuracy: 0.0001)
        XCTAssertTrue(built.dimensions.map(\.relativeWeight).allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertTrue(built.weightNote.contains("不是概率"))
        XCTAssertTrue(model(state: state, language: .en).weightNote.lowercased().contains("not a probability"))
        let realPeak = built.dimensions.map { abs($0.longTerm) }.max() ?? 0
        for dimension in built.dimensions {
            XCTAssertEqual(dimension.longTerm, profile(state).topics[dimension.kind == .followed ? "followed:" + dimension.key : dimension.key] ?? -1, accuracy: 0.0001)
            if realPeak > 0 {
                XCTAssertEqual(dimension.relativeWeight, max(0, dimension.longTerm) / realPeak, accuracy: 0.0001)
            }
        }
    }

    func testSessionOnlyMoreLikeThisIsShownWithoutFakingLongTermWeight() {
        var state = LocalInterestState()
        state.learningEnabled = true
        let article = item("人工智能新模型", 900)
        let feedback = InterestFeedback(item: article, kind: .moreLikeThis, occurredAt: now)

        let built = model(state: state, sessionFeedback: [feedback])
        XCTAssertNil(built.emptyReason, "a session-only tag must not be reported as no evidence")
        guard let ai = built.dimensions.first(where: { $0.key == "ai" }) else {
            return XCTFail("shortTermTopics must be included in the dimension keys")
        }
        XCTAssertEqual(ai.longTerm, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(ai.shortTerm, 0)
        XCTAssertTrue(ai.isSessionOnly)
        XCTAssertEqual(ai.relativeWeight, 0, "short-term values must not enter the long-term peak")
        XCTAssertTrue(built.weightNote.contains("条形按长期值"))
        XCTAssertTrue(built.weightNote.contains("会话/近期"))

        // With some independent evidence, the ranker's blend confidence is
        // non-zero, so the same session feedback shows up in the trace. The
        // row above explains that contribution instead of hiding it.
        var correlatedState = state
        _ = correlatedState.record(item: item("足球联赛赛果", 902), kind: .qualifiedRead, epoch: correlatedState.consentEpoch, now: now)
        let candidate = rssItem("人工智能候选", 901)
        let snapshot = RecommendationEngine.rank(items: [candidate], state: correlatedState, now: now, limit: 5, sessionFeedback: [feedback])
        guard let first = snapshot.items.first,
              let trace = RecommendationExplanationIntegration.trace(for: first) else {
            return XCTFail("expected a ranked item with a trace")
        }
        XCTAssertGreaterThan(trace.contributions["personal.interest"] ?? 0, 0)
        let correlated = model(state: correlatedState, snapshot: snapshot, sessionFeedback: [feedback], traces: [first.contentID: trace])
        XCTAssertTrue(correlated.dimensions.contains { $0.key == "ai" })
        XCTAssertNil(correlated.emptyReason)
    }

    func testSoftFeedbackAvailabilityIsExplainedForOffPausedAndPrivate() {
        let cases: [RecommendationExplanationModel] = [
            model(state: activeState(), enabled: false),
            model(state: activeState(), paused: true),
            model(state: activeState(), privateReading: true)
        ]
        for built in cases {
            XCTAssertTrue(built.statusDetail.contains("收藏"))
            XCTAssertTrue(built.statusDetail.contains("更多同类"))
            XCTAssertTrue(built.statusDetail.contains("关注"))
            XCTAssertTrue(built.statusDetail.contains("需要开启学习"))
        }
        let en = model(state: activeState(), paused: true, language: .en)
        XCTAssertTrue(en.statusDetail.lowercased().contains("bookmark"))
        XCTAssertTrue(en.statusDetail.lowercased().contains("more like this"))
        XCTAssertTrue(en.statusDetail.lowercased().contains("follow"))
        XCTAssertTrue(en.statusDetail.lowercased().contains("learning on"))
    }

    func testFollowedEvidenceUsesLocalLiteralTitlesWithoutClaimingInference() {
        let state = literalFollowState()
        let built = model(state: state)
        guard let followed = built.dimensions.first(where: { $0.kind == .followed }) else {
            return XCTFail("missing followed dimension")
        }
        let connections = built.connections(for: followed.id)
        XCTAssertEqual(connections?.evidence.count, 1)
        XCTAssertEqual(connections?.evidence.first?.title, "SwiftUI 并发实践")
        XCTAssertTrue(connections?.textAlternative(.zh).contains("手动关注") == true)
        XCTAssertTrue(connections?.textAlternative(.zh).contains("最多 8") == true)
    }

    func testCanonicalDimensionConnectionsUseTopicTagAndExplainMergedFollow() {
        let state = activeState()
        let built = model(state: state, snapshot: integrationSnapshot(state))
        guard let tech = built.dimensions.first(where: { $0.key == "technology" }) else {
            return XCTFail("missing technology row")
        }
        let connections = built.connections(for: tech.id)
        XCTAssertEqual(connections?.manualFollowKeywords, ["Swift"])
        XCTAssertTrue(connections?.candidates.contains { $0.title == "Swift 工具链更新" } == true)
        XCTAssertTrue(connections?.textAlternative(.zh).contains("权重还包含手动关注") == true)
    }

    // MARK: - Evidence order and bounds

    func testEvidenceListIsNewestFirstInsteadOfDictionaryOrder() {
        var state = LocalInterestState()
        state.learningEnabled = true
        _ = state.record(item: item("人工智能旧闻", 1), kind: .qualifiedRead, epoch: state.consentEpoch, now: now.addingTimeInterval(-3 * 3600))
        _ = state.record(item: item("人工智能中闻", 2), kind: .qualifiedRead, epoch: state.consentEpoch, now: now.addingTimeInterval(-2 * 3600))
        _ = state.record(item: item("人工智能新讯", 3), kind: .qualifiedRead, epoch: state.consentEpoch, now: now)
        let built = model(state: state)
        guard let ai = built.dimensions.first(where: { $0.key == "ai" }) else { return XCTFail("missing ai") }
        XCTAssertEqual(built.connections(for: ai.id)?.evidence.map(\.title), ["人工智能新讯", "人工智能中闻", "人工智能旧闻"])
    }

    func testLiteralFollowEvidenceIsBoundedToNewestEight() {
        var state = LocalInterestState()
        state.learningEnabled = true
        state.followedTopics = ["SwiftUI"]
        for index in 0..<20 {
            state.ingest([rssItem("SwiftUI 实践 \(index)", 300 + index)], now: now.addingTimeInterval(Double(index)))
        }
        let built = model(state: state)
        guard let followed = built.dimensions.first(where: { $0.kind == .followed }) else { return XCTFail("missing follow") }
        guard let connections = built.connections(for: followed.id) else { return XCTFail("missing connections") }
        XCTAssertEqual(followed.evidenceCount, RecommendationExplanationConnections.evidenceCap)
        XCTAssertEqual(connections.evidence.count, RecommendationExplanationConnections.evidenceLimit)
        XCTAssertEqual(connections.evidence.first?.title, "SwiftUI 实践 19")
        XCTAssertEqual(connections.evidence.last?.title, "SwiftUI 实践 15")
        XCTAssertTrue(connections.textAlternative(.zh).contains("最近 8 条"))
    }

    func testOffStateSkipsLiteralFollowEvidenceScan() {
        // With no retained evidence there is nothing to display, so the sheet
        // must not scan local contents for literal follows while off.
        var state = literalFollowState()
        state.learningEnabled = false
        state.followedTopics = []
        let built = model(state: state, enabled: false)
        XCTAssertFalse(built.retainedProfileShown)
        XCTAssertTrue(built.dimensions.isEmpty)
        XCTAssertTrue(built.groups[2].dimensions.isEmpty)
    }

    // MARK: - Tag connections

    func testConnectionsAreBoundedAndExplainTagHitsOnly() {
        var state = LocalInterestState()
        state.learningEnabled = true
        for index in 0..<40 {
            _ = state.record(item: item("人工智能进展 \(index)", 100 + index), kind: .qualifiedRead, epoch: state.consentEpoch, now: now.addingTimeInterval(Double(index)))
        }
        let candidates = (0..<40).map { rssItem("人工智能候选 \($0)", 200 + $0) }
        let snapshot = RecommendationEngine.rank(items: candidates, state: state, now: now, limit: 20)
        let built = model(state: state, snapshot: snapshot)
        guard let ai = built.dimensions.first(where: { $0.key == "ai" }) else { return XCTFail("missing ai dimension") }
        guard let connections = built.connections(for: ai.id) else { return XCTFail("missing connections") }
        XCTAssertLessThanOrEqual(connections.evidence.count, RecommendationExplanationConnections.evidenceLimit)
        XCTAssertLessThanOrEqual(connections.candidates.count, RecommendationExplanationConnections.candidateLimit)
        XCTAssertLessThanOrEqual(connections.nodeCount, 24)
        XCTAssertTrue(connections.candidates.allSatisfy { TitleFeatures.tags($0.title).contains("ai") })
        let text = connections.textAlternative(.zh)
        XCTAssertTrue(text.contains("命中"))
        XCTAssertTrue(text.contains("不代表"))
        XCTAssertTrue(text.contains("向量"))
        XCTAssertTrue(text.contains("最多 8"))
    }

    func testUnknownDimensionHasNoSyntheticConnections() {
        let built = model(state: activeState())
        XCTAssertNil(built.connections(for: "topic:missing"))
    }

    // MARK: - Snapshot metadata truth

    func testSnapshotMetadataIsUsedInsteadOfLiveState() {
        var state = activeState()
        state.profileVersion = 9
        let base = activeSnapshot(state)
        let snapshot = makeSnapshot(base.items, profileVersion: 4, policyVersion: 3, confidence: 0.25)
        let built = model(state: state, snapshot: snapshot)
        XCTAssertEqual(built.snapshotProfileVersion, 4)
        XCTAssertEqual(built.snapshotConfidencePercent, 25)
        XCTAssertEqual(built.currentStateVersion, 9)
        XCTAssertEqual(built.currentProfilePercent, Int((profile(state).confidence * 100).rounded()))
        guard let note = built.currentProfileNote else { return XCTFail("expected an explicitly labelled live profile note") }
        XCTAssertTrue(note.contains("当前实时"))
        XCTAssertTrue(note.contains("v4"))
        XCTAssertTrue(note.contains("v9"))
    }

    func testNoSnapshotNeverPresentsLiveProfileAsSnapshotWeight() {
        let built = model(state: activeState())
        XCTAssertNil(built.snapshotProfileVersion)
        XCTAssertNil(built.snapshotConfidencePercent)
        guard let note = built.noSnapshotNote else { return XCTFail("missing no-snapshot note") }
        XCTAssertTrue(note.contains("不是快照"))
    }

    func testOffWithRetainedProfileExplainsRetentionInsteadOfClaimingNoEvidence() {
        let state = activeState()
        let built = model(state: state, enabled: false)

        XCTAssertEqual(built.status, .off)
        XCTAssertTrue(built.retainedProfileShown)
        XCTAssertNil(built.emptyReason, "a retained profile must not render the empty-evidence state")
        XCTAssertTrue(built.dimensions.contains { $0.key == "ai" }, "retained tags stay inspectable")
        XCTAssertEqual(built.groups[0].dimensions.count, built.dimensions.filter { $0.kind == .topic }.count)

        let note = built.retainedProfileNote ?? ""
        XCTAssertTrue(note.contains("保留画像·未参与当前排序"))
        XCTAssertTrue(note.contains("重新开启"))
        XCTAssertTrue(built.statusDetail.contains("仍保留"))
        XCTAssertTrue(built.statusDetail.contains("重新开启"))
        XCTAssertFalse(built.statusDetail.contains("开启后才会形成画像"))
        XCTAssertEqual(built.currentProfilePercent, 0, "the display copy must not be reported as the live profile")
        XCTAssertFalse(built.groups.contains { $0.dimensions.isEmpty && $0.emptyText.contains("尚无") })

        let en = model(state: state, enabled: false, language: .en)
        XCTAssertTrue((en.retainedProfileNote ?? "").lowercased().contains("retained profile"))
        XCTAssertTrue(en.statusDetail.lowercased().contains("kept"))
        XCTAssertFalse(en.statusDetail.lowercased().contains("turning it on starts collecting"))
        XCTAssertNil(en.emptyReason)
    }

    func testOffWithoutAnyRetainedEvidenceStillShowsEmptyState() {
        var state = LocalInterestState()
        state.learningEnabled = false
        let built = model(state: state, enabled: false)

        XCTAssertFalse(built.retainedProfileShown)
        XCTAssertNil(built.retainedProfileNote)
        XCTAssertTrue(built.dimensions.isEmpty)
        XCTAssertTrue(built.emptyReason?.contains("尚无") == true)
        XCTAssertTrue(built.statusDetail.contains("开启后"))

        let en = model(state: state, enabled: false, language: .en)
        XCTAssertFalse(en.retainedProfileShown)
        XCTAssertTrue(en.emptyReason?.lowercased().contains("no local") == true)
    }

    func testRetainedDisplayNeverChangesRealStateOrRanking() {
        var state = activeState()
        state.learningEnabled = false
        let items = [
            rssItem("人工智能新模型", 40, feed: "https://tech.example/rss"),
            rssItem("足球联赛赛果", 41, feed: "https://sport.example/rss")
        ]
        let before = RecommendationEngine.rank(items: items, state: state, now: now, limit: 10)
        let built = model(state: state, snapshot: before, enabled: false)
        XCTAssertTrue(built.retainedProfileShown, "display copy is shown")
        XCTAssertTrue(InterestProfile.build(state: state, now: now).topics.isEmpty,
                      "the real off profile stays empty; only the display copy is populated")

        let after = RecommendationEngine.rank(items: items, state: state, now: now, limit: 10)
        XCTAssertEqual(before.items.map(\.contentID), after.items.map(\.contentID))
        XCTAssertEqual(before.items.map(\.score), after.items.map(\.score))
        XCTAssertEqual(before.profileVersion, after.profileVersion)
        XCTAssertFalse(state.learningEnabled)
    }

    func testOffWithoutSnapshotDoesNotBorrowLiveState() {
        var state = LocalInterestState()
        state.learningEnabled = false
        state.profileVersion = 7
        let built = model(state: state, enabled: false)
        XCTAssertNil(built.snapshotConfidencePercent)
        XCTAssertTrue(built.dimensions.isEmpty)
        XCTAssertTrue(built.items.isEmpty)
        XCTAssertFalse(built.noSnapshotNote?.contains("混合权重") == true)
    }

    // MARK: - Ranking trace

    func testRankedItemsFollowSnapshotOrderAndAreBounded() {
        let state = activeState()
        var snapshot = activeSnapshot(state)
        snapshot.items = Array(snapshot.items.prefix(10))
        let built = model(state: state, snapshot: snapshot)
        XCTAssertEqual(built.items.map(\.id), snapshot.items.map(\.contentID))
        XCTAssertEqual(built.items.map(\.rank), Array(1...snapshot.items.count))
        XCTAssertEqual(built.candidateCount, snapshot.items.count)
        XCTAssertEqual(built.policyVersion, snapshot.policyVersion)
        XCTAssertTrue(built.itemsNote.contains("\(snapshot.items.count)"))
    }

    func testItemsNoteStatesTopTenWhenSnapshotHasMore() {
        var state = LocalInterestState()
        state.learningEnabled = true
        let items = (0..<14).map { rssItem("新闻条目 \($0)", 500 + $0) }
        let snapshot = RecommendationEngine.rank(items: items, state: state, now: now, limit: 14)
        let built = model(state: state, snapshot: snapshot)
        XCTAssertEqual(built.items.count, 10)
        XCTAssertTrue(built.itemsNote.contains("10"))
        XCTAssertTrue(built.itemsNote.contains("14"))
    }

    func testTraceDrillDownUsesInjectedValuesAndFlagsMismatch() {
        let state = activeState()
        let snapshot = activeSnapshot(state)
        guard let first = snapshot.items.first else { return XCTFail("no candidates") }
        let built = model(state: state, snapshot: snapshot, traces: [first.contentID: trace()])
        guard let item = built.item(id: first.contentID) else { return XCTFail("missing item") }
        let recorded = try? XCTUnwrap(item.trace)
        guard let recorded else { return XCTFail("missing trace") }
        XCTAssertEqual(recorded.finalRank, 1)
        XCTAssertEqual(recorded.contributionMismatch, 0.05, accuracy: 0.0001)
        XCTAssertNotNil(recorded.consistencyNote(.zh))
        XCTAssertTrue(recorded.rows(.zh).contains { $0.id == "personalScore" && $0.label.contains("未乘") })
        XCTAssertTrue(recorded.rows(.zh).contains { $0.id == "finalRank" })
        XCTAssertTrue(recorded.rows(.zh).contains { $0.id == "selectionPolicy" })
        XCTAssertTrue(recorded.rows(.zh).contains { $0.id == "contribution.publicHeat" })
        XCTAssertTrue(recorded.rows(.zh).contains { $0.id == "confidence" && $0.value == "50%" })
        XCTAssertTrue(item.traceAvailableNote.contains("实际"))

        let consistent = model(state: state, snapshot: snapshot, traces: [first.contentID: trace(rawScore: 0.55)])
        XCTAssertNil(consistent.item(id: first.contentID)?.trace?.consistencyNote(.zh))
    }

    func testSelectionScoreWordingFollowsActualPolicy() {
        XCTAssertTrue(trace(policy: "score").selectionScoreLabel(.zh).contains("实际选择分"))
        XCTAssertTrue(trace(policy: "publicHeat").selectionScoreLabel(.zh).contains("实际排序键（公共热度"))
        XCTAssertTrue(trace(policy: "publicHeat").rows(.zh).contains { $0.id == "selectionScore" && $0.label.contains("实际排序键") })
        XCTAssertTrue(trace(policy: "publicFresh").selectionScoreLabel(.zh).contains("实际排序键（时效"))
        XCTAssertTrue(trace(policy: "sourceRotation").selectionScoreLabel(.zh).contains("审计值"))
        XCTAssertFalse(trace(policy: "sourceRotation").selectionScoreIsDecisionKey)
        XCTAssertTrue(trace(policy: "publicHeat").selectionScoreIsDecisionKey)
    }

    func testRotationTraceExposesLexicographicDecisionFields() {
        let rotation = trace(policy: "sourceRotation", rotation: (uses: 9, offset: 2, index: 3, count: 5))
        let rows = rotation.rows(.zh)
        XCTAssertTrue(rows.contains { $0.id == "rotation.sourceUseCount" && $0.value == "9" })
        XCTAssertTrue(rows.contains { $0.id == "rotation.offset" && $0.value == "2" })
        XCTAssertTrue(rows.contains { $0.id == "rotation.candidateIndex" && $0.value == "3" })
        XCTAssertTrue(rows.contains { $0.id == "rotation.candidateCount" && $0.value == "5" })
        XCTAssertTrue(rows.contains { $0.id == "selectionPolicy" && $0.label == "选择策略" })
        XCTAssertFalse(trace(policy: "score").rows(.zh).contains { $0.id.hasPrefix("rotation.") })
    }

    func testIntegrationMirrorsEveryRotationField() {
        let recommendation = ScoredRecommendation(
            item: item("人工智能", 1, rank: 1),
            contentID: "content-1",
            clusterID: "cluster-1",
            score: 0.5,
            components: ["publicHeat": 0.83, "recency": 0.91],
            reason: "exploration",
            topic: "ai",
            trace: engineTrace(policy: "sourceRotation", rotation: (uses: 7, offset: 1, index: 4, count: 9))
        )
        let mirrored = RecommendationExplanationIntegration.trace(for: recommendation)
        XCTAssertEqual(mirrored?.rotationSourceUseCount, 7)
        XCTAssertEqual(mirrored?.rotationOffset, 1)
        XCTAssertEqual(mirrored?.rotationCandidateIndex, 4)
        XCTAssertEqual(mirrored?.rotationCandidateCount, 9)
        XCTAssertEqual(mirrored?.selectionPolicy, "sourceRotation")
    }

    func testPublicSlotUsesTheRealComponentKey() {
        let recommendation = ScoredRecommendation(
            item: item("热门人工智能", 1, rank: 1),
            contentID: "content-heat",
            clusterID: "cluster-heat",
            score: 0.5,
            components: ["publicHeat": 0.83, "recency": 0.91],
            reason: "publicHeat",
            topic: "ai",
            trace: engineTrace(policy: "publicHeat")
        )
        let snapshot = makeSnapshot([recommendation])
        let built = model(state: activeState(), snapshot: snapshot, traces: [recommendation.contentID: trace(policy: "publicHeat")])
        guard let note = built.items.first?.slotKeyNote else { return XCTFail("missing slot key note") }
        XCTAssertTrue(note.contains("公共热度"))
        XCTAssertTrue(note.contains("0.830"))
        XCTAssertTrue(note.contains("排序基数（惩罚前）"))
        XCTAssertFalse(note.contains("排序键"))
    }

    func testRankBeforeDiversityContractExplainsGaps() {
        let rotation = trace(policy: "score", rankBefore: 13, finalRank: 5)
        XCTAssertTrue(rotation.rows(.zh).contains { $0.id == "rankBeforeDiversity" && $0.label.contains("候选池") })
        let note = rotation.rankContractNote(.zh)
        XCTAssertTrue(note.contains("聚类去重"))
        XCTAssertTrue(note.contains("空档"))
        XCTAssertTrue(note.contains("URL 去重"))
    }

    func testMissingTraceIsUnavailableInsteadOfReconstructed() {
        let state = activeState()
        let snapshot = activeSnapshot(state)
        let built = model(state: state, snapshot: snapshot)
        guard let item = built.items.first else { return XCTFail("no items") }
        XCTAssertNil(item.trace)
        XCTAssertTrue(item.traceUnavailableNote.contains("不可用"))
        XCTAssertFalse(item.traceUnavailableNote.contains("推算"))
        XCTAssertFalse(item.components.isEmpty)
        XCTAssertNil(item.slotKeyNote)
    }

    func testSemanticEmbeddingsAreReportedAsNotRanking() {
        let state = activeState()
        let built = model(state: state, snapshot: activeSnapshot(state))
        XCTAssertTrue(built.semanticNote.contains("语义"))
        XCTAssertTrue(built.semanticNote.contains("未参与"))
        XCTAssertTrue(model(state: state, snapshot: activeSnapshot(state), language: .en).semanticNote.lowercased().contains("not"))
    }

    func testSelectionNoteCoversPublicAndRotationSlots() {
        let state = activeState()
        let built = model(state: state, snapshot: activeSnapshot(state))
        XCTAssertTrue(built.selectionNote.contains("公共"))
        XCTAssertTrue(built.selectionNote.contains("来源"))
        XCTAssertTrue(built.selectionNote.contains("轮换"))
        XCTAssertFalse(built.selectionNote.contains("随机探索"))
    }

    // MARK: - Guide and privacy copy

    func testGuideUnavailableIsExplicitAndNeverFabricated() {
        let built = model(state: activeState())
        XCTAssertTrue(built.guide.isEmpty)
        XCTAssertTrue(built.guideUnavailable)
        XCTAssertTrue(built.guideUnavailableNote.contains("不可用"))
        XCTAssertFalse(built.guideUnavailableNote.contains("动态归一化"))
    }

    func testGuideSectionsArePreservedVerbatim() {
        let sections = [ExplanationGuideSection(id: "scoring", title: "排序", body: "动态归一化与公共基线。")]
        let built = model(state: activeState(), guide: sections)
        XCTAssertEqual(built.guide, sections)
        XCTAssertFalse(built.guideUnavailable)
        XCTAssertTrue(built.guideUnavailableNote.isEmpty)
    }

    func testClearingCopyStatesLearningStopsAndBrowserScopeIsSeparate() {
        let zh = model(state: activeState())
        XCTAssertTrue(zh.clearNote.contains("停止学习"))
        XCTAssertTrue(zh.clearNote.contains("重新开启"))
        XCTAssertTrue(zh.clearNote.contains("关注词"))
        XCTAssertTrue(zh.clearNote.contains("调研状态"))
        XCTAssertTrue(zh.clearNote.contains("网页会话"))
        XCTAssertTrue(zh.browserScopeNote.contains("设置页的清空"))
        XCTAssertTrue(zh.browserScopeNote.contains("Cookie"))
        XCTAssertTrue(zh.outboundNote.contains("标题"))
        XCTAssertTrue(zh.outboundNote.contains("调研"))
        XCTAssertTrue(zh.privacyFacts.contains { $0.body.contains("30") && $0.body.contains("180") })

        let en = model(state: activeState(), language: .en)
        XCTAssertTrue(en.clearNote.lowercased().contains("stops learning"))
        XCTAssertTrue(en.clearNote.lowercased().contains("followed keywords"))
        XCTAssertTrue(en.browserScopeNote.lowercased().contains("clearing in settings"))
        XCTAssertTrue(en.browserScopeNote.lowercased().contains("cookie"))
        XCTAssertTrue(en.outboundNote.lowercased().contains("titles"))
        XCTAssertTrue(en.outboundNote.lowercased().contains("research"))
    }

    func testRawScoreColumnIsLabelledAsMixedScoreBeforePenalties() {
        let built = model(state: activeState(), snapshot: activeSnapshot(activeState()))
        XCTAssertTrue(built.scoreColumnNote.contains("混合分（惩罚前）"))
        XCTAssertTrue(built.scoreColumnNote.contains("不是实际选择键"))
        let en = model(state: activeState(), snapshot: activeSnapshot(activeState()), language: .en)
        XCTAssertTrue(en.scoreColumnNote.lowercased().contains("before slot penalties"))
        XCTAssertTrue(en.scoreColumnNote.lowercased().contains("not the actual selection key"))
    }

    func testEvaluationOnlyEmbeddingBranchNeverClaimsLiveRanking() {
        let item = ScoredRecommendation(
            item: rssItem("人工智能新模型", 950),
            contentID: "semantic-eval",
            clusterID: "semantic-eval",
            score: 0.5,
            components: ["interest": 0.4],
            reason: "interest",
            topic: "ai"
        )
        let snapshot = RecommendationSnapshot(
            asOf: now,
            profileVersion: 1,
            policyVersion: 3,
            profileConfidence: 0.4,
            semanticDegraded: false,
            items: [item]
        )
        let zh = model(state: activeState(), snapshot: snapshot)
        XCTAssertTrue(zh.semanticNote.contains("仅用于离线评测"))
        XCTAssertTrue(zh.semanticNote.contains("不参与线上排序"))
        let en = model(state: activeState(), snapshot: snapshot, language: .en)
        XCTAssertTrue(en.semanticNote.lowercased().contains("evaluation-only"))
        XCTAssertTrue(en.semanticNote.lowercased().contains("does not take part in live ranking"))
    }

    func testSegmentsExposeTitlesInBothLanguages() {
        for language in AppLanguage.allCases {
            let titles = RecommendationExplanationSegment.allCases.map { $0.title(language) }
            XCTAssertEqual(Set(titles).count, 4)
            XCTAssertTrue(titles.allSatisfy { !$0.isEmpty })
        }
        XCTAssertEqual(RecommendationExplanationSegment.allCases.count, 4)
    }

    // MARK: - Cross-task integration (real engine trace, real bundled guide)

    private func integrationSnapshot(_ state: LocalInterestState) -> RecommendationSnapshot {
        RecommendationEngine.rank(
            items: [
                rssItem("人工智能新模型", 30, feed: "https://tech.example/rss"),
                rssItem("Swift 工具链更新", 31, feed: "https://dev.example/rss"),
                rssItem("苹果 iPhone 更新", 32, feed: "https://tech.example/rss")
            ],
            state: state,
            now: now,
            limit: 5
        )
    }

    func testEngineTraceFlowsThroughIntegrationSeamWithoutRecomputation() {
        let snapshot = integrationSnapshot(activeState())
        guard let first = snapshot.items.first else { return XCTFail("no snapshot items") }
        guard let trace = RecommendationExplanationIntegration.trace(for: first) else {
            return XCTFail("engine did not expose a trace")
        }
        XCTAssertFalse(trace.contributions.isEmpty)
        XCTAssertLessThan(trace.contributionMismatch, 0.0001)
        XCTAssertEqual(trace.finalRank, 1)
        XCTAssertFalse(trace.selectionPolicy.isEmpty)
        XCTAssertTrue(trace.rows(.zh).contains { $0.id == "selectionPolicy" })

        var untraced = first
        untraced.trace = nil
        XCTAssertNil(RecommendationExplanationIntegration.trace(for: untraced))
    }

    func testRealSnapshotDrillDownPairsComponentsWithPersonalContributions() {
        let state = activeState()
        let snapshot = integrationSnapshot(state)
        let built = RecommendationExplanationModel.make(
            input: RecommendationExplanationInput(state: state, snapshot: snapshot, now: now, language: .zh),
            guide: RecommendationExplanationIntegration.guideSections(language: .zh),
            traceFor: RecommendationExplanationIntegration.trace(for:)
        )
        guard let first = built.items.first else { return XCTFail("no items") }
        XCTAssertNotNil(first.trace)
        XCTAssertEqual(first.trace?.contributionMismatch ?? 1, 0, accuracy: 0.0001)
        XCTAssertTrue(first.components.contains { $0.contribution != nil })
        XCTAssertFalse(built.guideUnavailable)
        XCTAssertFalse(built.guide.isEmpty)
        XCTAssertEqual(built.snapshotProfileVersion, snapshot.profileVersion)
        XCTAssertEqual(built.snapshotConfidencePercent, Int((snapshot.profileConfidence * 100).rounded()))
    }

    func testBundledGuideIsConsumedThroughIntegrationSeamInBothLanguages() {
        for language in AppLanguage.allCases {
            let sections = RecommendationExplanationIntegration.guideSections(language: language)
            XCTAssertEqual(sections.count, RecommendationGuideDocument.requiredSectionIDs.count)
            XCTAssertTrue(sections.contains { $0.id == "privacy" && !$0.body.isEmpty })
            XCTAssertTrue(sections.allSatisfy { !$0.title.isEmpty && !$0.body.isEmpty })
        }
    }
}

final class RecommendationExplanationRenderingTests: XCTestCase {
    @MainActor
    func testSheetsRenderAcrossThemesLanguagesSegmentsAndStates() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func item(_ title: String, _ number: Int, source: NewsSource = .weibo) -> NewsItem {
            NewsItem(title: title, url: "https://example.com/render/\(number)", source: source)
        }
        var state = LocalInterestState()
        state.learningEnabled = true
        _ = state.record(item: item("人工智能模型发布", 1), kind: .qualifiedRead, epoch: state.consentEpoch, now: now)
        _ = state.record(item: item("苹果 iPhone 新机发布", 2), kind: .qualifiedRead, epoch: state.consentEpoch, now: now)
        state.followedTopics = ["Swift"]
        let snapshot = RecommendationEngine.rank(
            items: [
                item("人工智能新模型", 10, source: .rss(name: "Tech", url: "https://tech.example/rss")),
                item("Swift 工具链更新", 11, source: .rss(name: "Dev", url: "https://dev.example/rss")),
                item("足球联赛赛果", 12, source: .rss(name: "Sport", url: "https://sport.example/rss"))
            ],
            state: state,
            now: now,
            limit: 10
        )
        var untraced = snapshot
        untraced.items = snapshot.items.map {
            var copy = $0
            copy.trace = nil
            return copy
        }
        func make(
            _ value: LocalInterestState,
            enabled: Bool = true,
            ready: Bool = true,
            error: String? = nil,
            paused: Bool = false,
            privateReading: Bool = false,
            language: AppLanguage,
            snapshotOverride: RecommendationSnapshot? = nil,
            useTrace: Bool = true
        ) -> RecommendationExplanationModel {
            var configured = value
            configured.learningEnabled = enabled
            configured.learningPaused = paused
            return RecommendationExplanationModel.make(
                input: RecommendationExplanationInput(
                    isReady: ready,
                    storageError: error,
                    privateReading: privateReading,
                    state: configured,
                    snapshot: snapshotOverride ?? snapshot,
                    now: now,
                    language: language
                ),
                guide: RecommendationExplanationIntegration.guideSections(language: language),
                traceFor: useTrace ? RecommendationExplanationIntegration.trace(for:) : { _ in nil }
            )
        }
        var empty = LocalInterestState()
        let publicSnapshot = RecommendationEngine.rank(
            items: [
                item("人工智能新模型", 20, source: .rss(name: "Tech", url: "https://tech.example/rss")),
                item("Swift 工具链更新", 21, source: .rss(name: "Dev", url: "https://dev.example/rss")),
                item("足球联赛赛果", 22, source: .rss(name: "Sport", url: "https://sport.example/rss"))
            ],
            state: empty,
            now: now,
            limit: 10
        )

        let rotationTrace = RecommendationTrace(
            contributions: ["personal.recency": 0.09, "baseline.recency": 0.464, "baseline.novelty": 0.12],
            personalScore: 0.5,
            baselineScore: 0.8,
            confidence: 0.42,
            readPenalty: 0,
            feedbackPenalty: 0,
            rawScore: 0.674,
            selectionScore: 0.674,
            sourcePenalty: 0,
            topicPenalty: 0,
            diversityPenalty: 0,
            rankBeforeDiversity: 13,
            finalRank: 1,
            selectionPolicy: "sourceRotation",
            rotationSourceUseCount: 9,
            rotationOffset: 2,
            rotationCandidateIndex: 3,
            rotationCandidateCount: 5
        )
        let rotationItem = ScoredRecommendation(
            item: item("第 10 位来源轮换候选", 30, source: .rss(name: "Alt", url: "https://alt.example/rss")),
            contentID: "rotation-content",
            clusterID: "rotation-cluster",
            score: 0.674,
            components: ["recency": 0.9, "novelty": 1],
            reason: "exploration",
            topic: "technology",
            trace: rotationTrace
        )
        let rotationSnapshot = RecommendationSnapshot(
            asOf: now,
            profileVersion: state.profileVersion,
            policyVersion: 3,
            profileConfidence: 0.42,
            semanticDegraded: true,
            items: [rotationItem]
        )
        let staleSnapshot = RecommendationSnapshot(
            asOf: now.addingTimeInterval(-300),
            profileVersion: 1,
            policyVersion: 3,
            profileConfidence: 0.25,
            semanticDegraded: true,
            items: snapshot.items
        )

        let variants: [(String, RecommendationExplanationModel, AppTheme, ColorScheme, AppLanguage, CGFloat, CGFloat, RecommendationExplanationSegment)] = [
            ("overview-modern-zh-narrow", make(state, language: .zh), .modern, .light, .zh, 640, 560, .overview),
            ("overview-off-modern-en", make(empty, enabled: false, language: .en, snapshotOverride: publicSnapshot), .modern, .dark, .en, 640, 560, .overview),
            ("overview-off-retained-modern-zh", make(state, enabled: false, language: .zh, snapshotOverride: publicSnapshot), .modern, .light, .zh, 640, 560, .overview),
            ("interests-off-retained-modern-zh", make(state, enabled: false, language: .zh, snapshotOverride: publicSnapshot), .modern, .light, .zh, 640, 560, .interests),
            ("overview-stale-snapshot-zh", make(state, language: .zh, snapshotOverride: staleSnapshot), .modern, .light, .zh, 640, 560, .overview),
            ("interests-retro-zh-narrow", make(state, language: .zh), .retroEditorial, .light, .zh, 560, 480, .interests),
            ("interests-modern-en", make(state, language: .en), .modern, .light, .en, 720, 620, .interests),
            ("interests-modern-en-wide", make(state, language: .en), .modern, .light, .en, 1000, 720, .interests),
            ("interests-modern-en-tall", make(state, language: .en), .modern, .light, .en, 720, 1080, .interests),
            ("ranking-retro-en-trace", make(state, language: .en), .retroEditorial, .light, .en, 640, 560, .ranking),
            ("ranking-modern-en-wide", make(state, language: .en), .modern, .light, .en, 1000, 720, .ranking),
            ("ranking-modern-en-tall", make(state, language: .en), .modern, .light, .en, 720, 1200, .ranking),
            ("ranking-modern-zh-missing", make(state, language: .zh, snapshotOverride: untraced, useTrace: false), .modern, .dark, .zh, 560, 480, .ranking),
            ("ranking-rotation-modern-en-wide", make(state, language: .en, snapshotOverride: rotationSnapshot), .modern, .light, .en, 1000, 720, .ranking),
            ("privacy-modern-zh-guide", make(state, language: .zh), .modern, .light, .zh, 640, 560, .dataPrivacy),
            ("privacy-modern-zh-tall", make(state, language: .zh), .modern, .light, .zh, 720, 1240, .dataPrivacy),
            ("privacy-retro-error-narrow", make(state, error: "failed", language: .zh), .retroEditorial, .light, .zh, 560, 480, .dataPrivacy),
            ("interests-paused-en", make(state, paused: true, language: .en), .modern, .light, .en, 640, 560, .interests)
        ]

        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/recommendation-explanation-ui-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for (name, model, theme, scheme, language, width, height, segment) in variants {
            if name.contains("paused") {
                XCTAssertEqual(model.status, .paused)
            }
            let view = RecommendationExplanationView(model: model, theme: theme, initialSegment: segment)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
                .frame(width: width, height: height)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 2000, "blank render for \(name)")
            XCTAssertFalse(model.guideUnavailable, "bundled guide unavailable for \(name)")
            if !name.contains("missing") {
                XCTAssertNotNil(model.items.first?.trace, "engine trace missing for \(name)")
            }
            try data.write(to: output.appendingPathComponent("\(language.rawValue)-" + name + ".png"))
            window.contentView = nil
        }
    }

    @MainActor
    func testCloseAffordanceIsExplicitAndRenders() throws {
        XCTAssertFalse(RecommendationExplanationChrome.closeButtonIdentifier.isEmpty)
        XCTAssertEqual(RecommendationExplanationChrome.closeLabel(.zh), "完成")
        XCTAssertEqual(RecommendationExplanationChrome.closeLabel(.en), "Done")
        XCTAssertTrue(RecommendationExplanationChrome.closeAccessibilityLabel(.zh).contains("关闭"))
        XCTAssertTrue(RecommendationExplanationChrome.closeAccessibilityLabel(.en).lowercased().contains("close"))

        let view = RecommendationExplanationCloseButton(
            language: .zh,
            palette: ExplanationPalette(retro: false),
            action: {}
        )
        .frame(width: 120, height: 44)
        .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 44), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 500, "the Done/Close control must render")
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/recommendation-explanation-ui-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("close-button-modern-zh.png"))
        window.contentView = nil
    }

    @MainActor
    func testEntryRowRendersWithoutSingletonController() throws {
        let view = Form {
            Section {
                RecommendationExplanationEntry(
                    statusTitle: "本地学习",
                    detail: "查看本地画像、排序链路与隐私范围（只读）",
                    theme: .modern,
                    action: {}
                )
            } header: {
                Text("本地兴趣与隐私")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 640, height: 220)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 220), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 1000)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/recommendation-explanation-ui-validation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("entry-modern-zh.png"))
        window.contentView = nil
    }
}
