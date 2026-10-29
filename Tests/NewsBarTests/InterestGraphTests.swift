import XCTest
@testable import NewsBar

/// Read-only interest network: data shape, limits, suppression markers and the
/// "no snapshot" rendering path. None of these tests asserts a ranking change.
final class InterestGraphTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ title: String, _ number: Int, source: NewsSource = .weibo) -> NewsItem {
        NewsItem(title: title, url: "https://example.com/item/\(number)", source: source)
    }

    private var sspai: NewsSource { .rss(name: "少数派", url: "https://sspai.com/feed") }
    private var kr36: NewsSource { .rss(name: "36氪", url: "https://36kr.com/feed") }

    /// Three AI reads, two from one source and one from another.
    private func evidenceState() -> LocalInterestState {
        var state = LocalInterestState()
        state.learningEnabled = true
        for (index, entry) in [
            ("人工智能模型发布", sspai),
            ("人工智能芯片进展", sspai),
            ("人工智能应用落地", kr36),
        ].enumerated() {
            _ = state.record(
                item: item(entry.0, index, source: entry.1),
                kind: .qualifiedRead,
                epoch: state.consentEpoch,
                now: now
            )
        }
        return state
    }

    private func syntheticProfile(topicCount: Int, sourceCount: Int) -> InterestProfile {
        var profile = InterestProfile()
        for topic in 0..<topicCount {
            let key = "topic\(topic)"
            let topicWeight = Double(topicCount - topic)
            profile.topics[key] = topicWeight
            for source in 0..<sourceCount {
                profile.topicSources[key, default: [:]][ "source\(source)"] = topicWeight * Double(sourceCount - source)
            }
        }
        for source in 0..<sourceCount {
            profile.sources["source\(source)"] = Double(sourceCount - source)
        }
        return profile
    }

    // MARK: - Data

    func testTopicSourcesMirrorTopicWeightsAndKeepPolicyVersion() {
        let state = evidenceState()
        let profile = InterestProfile.build(state: state, now: now)
        let topic = try? XCTUnwrap(profile.topics["ai"])
        XCTAssertNotNil(topic)
        let sources = try? XCTUnwrap(profile.topicSources["ai"])
        XCTAssertNotNil(sources)
        let summed = (sources ?? [:]).values.reduce(0, +)
        XCTAssertEqual(summed, topic ?? 0, accuracy: 1e-9)
        XCTAssertEqual(sources?[sspai.id], profile.topicSources["ai"]?[sspai.id])
        XCTAssertGreaterThan(sources?[sspai.id] ?? 0, sources?[kr36.id] ?? 0)
        // Display-only addition: the ranking policy version is untouched.
        XCTAssertEqual(RecommendationEngine.policyVersion, 4)
    }

    func testTopicSourcesAreNotReadByTheRanker() {
        var baseline = evidenceState()
        let items = [
            item("人工智能新模型", 10, source: sspai),
            item("足球联赛赛果", 11),
        ]
        let before = RecommendationEngine.rank(items: items, state: baseline, now: now, limit: 10)
        // Mutating the display-only field must not be possible through ranking;
        // proving it structurally: rebuild the profile and compare the snapshot.
        baseline.profileVersion += 1
        let after = RecommendationEngine.rank(items: items, state: baseline, now: now, limit: 10)
        XCTAssertEqual(before.policyVersion, after.policyVersion)
        XCTAssertEqual(before.items.map(\.contentID), after.items.map(\.contentID))
        XCTAssertEqual(before.items.map(\.score), after.items.map(\.score))
    }

    // MARK: - Limits

    func testGraphCapsTopicsSourcesAndEdgesByWeight() {
        let profile = syntheticProfile(topicCount: 12, sourceCount: 8)
        let graph = InterestGraphModel.make(
            profile: profile,
            dimensions: [],
            state: LocalInterestState(),
            language: .zh
        )
        XCTAssertEqual(graph.topics.count, InterestGraphModel.topicLimit)
        XCTAssertEqual(graph.sources.count, InterestGraphModel.sourceLimit)
        XCTAssertEqual(graph.edges.count, InterestGraphModel.edgeLimit)
        XCTAssertEqual(graph.truncatedTopics, 4)
        XCTAssertEqual(graph.truncatedSources, 2)
        XCTAssertGreaterThan(graph.truncatedEdges, 0)
        XCTAssertEqual(Set(graph.edges.map(\.id)).count, graph.edges.count)

        // Deterministic weight-descending order, stable tie-break by key.
        XCTAssertEqual(graph.topics.map(\.label).first, "topic0")
        XCTAssertEqual(graph.topics.map(\.weight), graph.topics.map(\.weight).sorted(by: >))
        XCTAssertEqual(graph.sources.map(\.weight), graph.sources.map(\.weight).sorted(by: >))
        XCTAssertEqual(graph.edges.map(\.weight), graph.edges.map(\.weight).sorted(by: >))
        XCTAssertTrue(graph.topics.allSatisfy { (0...1).contains($0.weight) })
        XCTAssertTrue(graph.sources.allSatisfy { (0...1).contains($0.weight) })
        XCTAssertTrue(graph.edges.allSatisfy { (0...1).contains($0.weight) })
    }

    func testGraphDropsEdgesToSourcesOutsideTheRing() {
        let profile = syntheticProfile(topicCount: 3, sourceCount: 8)
        let graph = InterestGraphModel.make(
            profile: profile,
            dimensions: [],
            state: LocalInterestState(),
            language: .zh
        )
        let sourceIDs = Set(graph.sources.map(\.id))
        XCTAssertTrue(graph.edges.allSatisfy { sourceIDs.contains($0.to) })
        XCTAssertTrue(graph.edges.allSatisfy { $0.weight > 0 })
    }

    // MARK: - Negative signals

    func testNegativeSignalsMarkNodesButNeverBecomeEdges() {
        var profile = syntheticProfile(topicCount: 3, sourceCount: 3)
        profile.negativeTopics["topic0"] = 1
        profile.negativeSources["source0"] = 0.5
        let graph = InterestGraphModel.make(
            profile: profile,
            dimensions: [],
            state: LocalInterestState(),
            language: .zh
        )
        let topic = graph.topics.first { $0.id == "topic:topic0" }
        let source = graph.sources.first { $0.id == "source:source0" }
        XCTAssertEqual(topic?.isSuppressed, true)
        XCTAssertEqual(source?.isSuppressed, true)
        // A reduced node keeps its positive evidence edges; the reduction itself
        // is a node marker, not a red causal edge.
        XCTAssertTrue(graph.edges.contains { $0.from == "topic:topic0" })
        XCTAssertTrue(graph.edges.allSatisfy { $0.weight > 0 })
        XCTAssertTrue(graph.edges.allSatisfy { !$0.to.hasPrefix("negative") })
        XCTAssertTrue(graph.topics.allSatisfy { $0.sourceShares.allSatisfy { $0.count > 0 } })
    }

    // MARK: - Built from persisted state, without a snapshot

    func testGraphAndOverviewBuildFromStateWhenSnapshotIsNil() {
        let state = evidenceState()
        var display = state
        display.learningEnabled = true
        let model = RecommendationExplanationModel.make(
            input: RecommendationExplanationInput(
                isReady: true,
                state: display,
                snapshot: nil,
                now: now,
                language: .zh
            )
        )
        XCTAssertTrue(model.hasDimensions)
        XCTAssertEqual(model.interestGraph.isEmpty, false)
        XCTAssertNotNil(model.noSnapshotNote)
        XCTAssertFalse(model.statusHeadline.isEmpty)
        XCTAssertFalse(model.statusDetail.isEmpty)
        XCTAssertFalse(model.interestGraph.textAlternative().isEmpty)
        XCTAssertEqual(model.interestGraph.hub.label, "我的兴趣")
        // The snapshot-only sections degrade, they do not blank the page.
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.candidateCount, 0)
        XCTAssertEqual(model.snapshotProfileVersion, nil)
    }

    func testGraphTextAlternativeListsWeightEvidenceAndSourceSplit() {
        let state = evidenceState()
        let graph = InterestGraphModel.make(
            profile: InterestProfile.build(state: state, now: now),
            dimensions: [],
            state: state,
            language: .zh
        )
        let text = graph.textAlternative()
        XCTAssertTrue(text.contains("我的兴趣"))
        XCTAssertTrue(text.contains("证据 3 条"))
        XCTAssertTrue(text.contains("少数派 2"))
        XCTAssertTrue(text.contains("36氪 1"))
        XCTAssertTrue(text.contains("不代表因果"))
    }

    func testEnglishGraphUsesEnglishCopyAndLabels() {
        let state = evidenceState()
        let graph = InterestGraphModel.make(
            profile: InterestProfile.build(state: state, now: now),
            dimensions: [],
            state: state,
            language: .en
        )
        XCTAssertEqual(graph.hub.label, "My interests")
        XCTAssertTrue(graph.textAlternative().contains("evidence items"))
        XCTAssertFalse(graph.textAlternative().contains("证据"))
    }

    // MARK: - Single-topic cut

    func testSingleTopicSubgraphKeepsOnlyItsNeighbours() {
        let profile = syntheticProfile(topicCount: 4, sourceCount: 4)
        let graph = InterestGraphModel.make(
            profile: profile,
            dimensions: [],
            state: LocalInterestState(),
            language: .zh
        )
        let topic = try? XCTUnwrap(graph.topics.first)
        let cut = graph.subgraph(topicID: topic?.id ?? "")
        XCTAssertEqual(cut.topics.map(\.id), [topic?.id])
        XCTAssertTrue(cut.edges.allSatisfy { $0.from == topic?.id })
        XCTAssertEqual(Set(cut.sources.map(\.id)), Set(cut.edges.map(\.to)))
        // Weights are not renormalized by the cut, so a topic cannot look bigger
        // when isolated.
        XCTAssertEqual(cut.topics.first?.weight, topic?.weight)
    }

    func testUnknownTopicCutReturnsTheWholeGraph() {
        let graph = InterestGraphModel.make(
            profile: syntheticProfile(topicCount: 2, sourceCount: 2),
            dimensions: [],
            state: LocalInterestState(),
            language: .zh
        )
        XCTAssertEqual(graph.subgraph(topicID: "topic:missing"), graph)
    }

    // MARK: - Empty and off

    func testOffStateDoesNotInventGraphNodes() {
        let state = evidenceState()
        var off = state
        off.learningEnabled = false
        let model = RecommendationExplanationModel.make(
            input: RecommendationExplanationInput(
                isReady: true,
                state: off,
                snapshot: nil,
                now: now,
                language: .zh
            )
        )
        // Off keeps the retained profile for display, and the graph shows that
        // retained copy. It is labelled as retained, never as live ranking data.
        XCTAssertTrue(model.retainedProfileShown)
        XCTAssertFalse(model.interestGraph.isEmpty)
        let emptyGraph = InterestGraphModel.make(
            profile: InterestProfile.build(state: LocalInterestState(), now: now),
            dimensions: [],
            state: LocalInterestState(),
            language: .zh
        )
        XCTAssertTrue(emptyGraph.isEmpty)
        XCTAssertTrue(emptyGraph.textAlternative().contains("尚无兴趣网络"))
    }

    func testResettingHidesTheGraph() {
        let state = evidenceState()
        let model = RecommendationExplanationModel.make(
            input: RecommendationExplanationInput(
                isReady: true,
                isResetting: true,
                state: state,
                now: now,
                language: .zh
            )
        )
        XCTAssertTrue(model.interestGraph.isEmpty)
        XCTAssertEqual(model.interestGraph.nodeCount, 1)
    }
}
