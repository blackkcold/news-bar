import XCTest
@testable import NewsBar

/// The preview decides where the strip starts, the fold decides when the
/// detail chapters exist, and the two have to agree: a capsule click while the
/// detail is folded must open it *and* land on the node. Both are pure types so
/// this matrix runs without rendering anything.
final class ResearchTimelinePreviewTests: XCTestCase {

    // MARK: - Fixtures

    private func evidence(_ id: String, verified: Bool = true) -> EvidenceItem {
        EvidenceItem(
            id: id,
            url: "https://example.org/\(id)",
            canonicalURL: "https://example.org/\(id)",
            domain: "example.org",
            title: "Source \(id)",
            publishedAt: nil,
            quote: "Quote \(id)",
            quoteVerified: verified,
            stance: .supports,
            tier: .major,
            syndicationGroup: nil,
            fetchedAt: .distantPast
        )
    }

    private func node(
        _ title: String,
        state: ReportPresentation.NodeState = .verified,
        confidence: Confidence = .high,
        citations: Int = 1,
        dated: Bool = true
    ) -> ReportPresentation.Node {
        let evidenceItems = (0..<citations).map { evidence("E\(title.hashValue)_\($0)") }
        let timelineNode = TimelineNode(
            date: dated ? "2026-11-24" : "",
            title: title,
            detail: "Detail for \(title)",
            sortDate: dated ? Date(timeIntervalSince1970: 1_700_000_000) : nil,
            precision: dated ? .day : .unknown,
            evidenceIDs: evidenceItems.map(\.id),
            confidence: confidence
        )
        return ReportPresentation.Node(node: timelineNode, state: state, evidence: evidenceItems)
    }

    // MARK: - Window selection

    func testShortTimelineShowsEveryNodeAndNoOverflow() {
        let preview = ResearchTimelinePreview(nodes: (1...2).map { node("node \($0)") })
        XCTAssertEqual(preview.initialWindow.count, 2)
        XCTAssertEqual(preview.hiddenCount, 0)
        XCTAssertFalse(preview.showsOverflow)

        let exact = ResearchTimelinePreview(nodes: (1...3).map { node("node \($0)") })
        XCTAssertEqual(exact.initialWindow.count, 3)
        XCTAssertFalse(exact.showsOverflow, "three nodes fit the strip exactly, so nothing is off screen")
    }

    func testLongTimelineStartsAtTheStrongestContiguousWindow() {
        // A weak opening pair, then three strong nodes, then a weak tail. The
        // window must cover the strong run rather than the newest nodes: every
        // node in it is verified with high confidence and multiple citations.
        var nodes: [ReportPresentation.Node] = [
            node("weak a", state: .unsourced, confidence: .low, citations: 0),
            node("weak b", state: .unsourced, confidence: .low, citations: 0),
            node("strong 1"),
            node("strong 2"),
            node("strong 3"),
            node("weak c", state: .citedUnverified, confidence: .medium, citations: 1),
            node("weak d", state: .unsourced, confidence: .low, citations: 0, dated: false),
        ]
        let preview = ResearchTimelinePreview(nodes: nodes)
        XCTAssertEqual(preview.nodes.count, 7)
        XCTAssertEqual(preview.hiddenCount, 4)
        XCTAssertTrue(preview.showsOverflow)
        XCTAssertEqual(preview.initialWindow.map(\.node.title), ["strong 1", "strong 2", "strong 3"])
    }

    func testTiesGoToTheLaterWindow() {
        // Uniform nodes: every window scores the same, so the recent one wins.
        // A reader who opens a report mid-story wants the latest stretch.
        let nodes = (1...6).map { node("node \($0)") }
        let preview = ResearchTimelinePreview(nodes: nodes)
        XCTAssertEqual(preview.anchorIndex, nodes.count - ResearchTimelinePreview.visibleCount)
        XCTAssertEqual(preview.initialWindow.map(\.node.title), ["node 4", "node 5", "node 6"])
    }

    func testAllUnsourcedTimelineDegradesToTheRecentWindow() {
        let nodes = (1...5).map {
            node("node \($0)", state: .unsourced, confidence: .low, citations: 0)
        }
        let preview = ResearchTimelinePreview(nodes: nodes)
        XCTAssertEqual(preview.initialWindow.map(\.node.title), ["node 3", "node 4", "node 5"])
    }

    func testEmptyTimelineProducesNoWindow() {
        let preview = ResearchTimelinePreview(nodes: [])
        XCTAssertTrue(preview.initialWindow.isEmpty)
        XCTAssertEqual(preview.hiddenCount, 0)
        XCTAssertFalse(preview.showsOverflow)
        XCTAssertEqual(preview.anchorIndex, 0)
    }

    // MARK: - Scoring

    func testScoreRewardsVerificationConfidenceAndCitations() {
        let strong = node("strong", state: .verified, confidence: .high, citations: 3)
        let weak = node("weak", state: .unsourced, confidence: .low, citations: 0)
        XCTAssertEqual(ResearchTimelinePreview.score(strong), 2 + 2 + 3 + 1)
        // Weak still earns the dated point: it is real placement information,
        // not a claim about how well the node is sourced.
        XCTAssertEqual(ResearchTimelinePreview.score(weak), 1)
        XCTAssertEqual(
            ResearchTimelinePreview.score(node("undated weak", state: .unsourced,
                                               confidence: .low, citations: 0, dated: false)),
            0
        )

        // A citation count beyond three stops mattering: four sources do not
        // outrank a verified claim, they just stop adding points.
        let manyCitations = node("many", state: .verified, confidence: .high, citations: 6)
        XCTAssertEqual(ResearchTimelinePreview.score(manyCitations), 2 + 2 + 3 + 1)
    }

    func testScorePenalisesUndatedNodes() {
        let dated = node("dated", dated: true)
        let undated = node("undated", dated: false)
        XCTAssertEqual(ResearchTimelinePreview.score(dated) - ResearchTimelinePreview.score(undated), 1)
    }

    func testPreviewNeverReordersTheTimeline() {
        let nodes = [
            node("oldest", state: .unsourced, confidence: .low, citations: 0),
            node("middle"),
            node("newest"),
        ]
        let preview = ResearchTimelinePreview(nodes: nodes)
        XCTAssertEqual(preview.nodes.map(\.node.title), ["oldest", "middle", "newest"])
    }

    // MARK: - Fold state machine

    func testToggleNeverSchedulesAReveal() {
        var state = ResearchDetailDisclosureState(isExpanded: false)
        state.toggle()
        XCTAssertTrue(state.isExpanded)
        XCTAssertNil(state.consumePendingReveal())

        state.toggle()
        XCTAssertFalse(state.isExpanded)
        XCTAssertNil(state.consumePendingReveal())
    }

    func testRevealFromCollapsedOpensTheDetailAndQueuesTheTarget() {
        var state = ResearchDetailDisclosureState(isExpanded: false)
        state.reveal("node-2")
        XCTAssertTrue(state.isExpanded, "a capsule click must not silently do nothing")
        XCTAssertEqual(state.consumePendingReveal(), "node-2")
        XCTAssertNil(state.consumePendingReveal(), "the reveal is consumed once so layout cannot scroll again")
    }

    func testRevealFromExpandedQueuesWithoutToggling() {
        var state = ResearchDetailDisclosureState(isExpanded: true)
        state.reveal("node-3")
        XCTAssertTrue(state.isExpanded)
        XCTAssertEqual(state.consumePendingReveal(), "node-3")
    }

    func testPendingRevealIsDroppedWhenTheReaderFoldsAway() {
        // Folding is the reader abandoning the target, so a queued reveal must
        // not survive it and scroll somewhere unexpected on the next expand.
        var state = ResearchDetailDisclosureState(isExpanded: false)
        state.reveal("node-2")
        state.toggle()
        XCTAssertFalse(state.isExpanded)
        state.toggle()
        XCTAssertNil(state.consumePendingReveal())
    }

    func testExpansionSurvivesReopenThroughDefaults() throws {
        let suiteName = "ResearchTimelinePreviewTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(ResearchDetailDisclosureState(defaults: defaults).isExpanded)
        ResearchDetailDisclosureState.persist(true, defaults: defaults)
        XCTAssertTrue(ResearchDetailDisclosureState(defaults: defaults).isExpanded)
        ResearchDetailDisclosureState.persist(false, defaults: defaults)
        XCTAssertFalse(ResearchDetailDisclosureState(defaults: defaults).isExpanded)
    }

    // MARK: - Header tags

    func testHeaderTagsDropMissingFactsInsteadOfRenderingEmptyPills() {
        let empty = ResearchReportHeaderTagBuilder.tags(
            source: nil, depth: nil, verdict: nil, language: .zh
        )
        XCTAssertTrue(empty.isEmpty)

        let partial = ResearchReportHeaderTagBuilder.tags(
            source: .rss(name: "华尔街见闻", url: "https://example.org/rss"),
            depth: .deep,
            verdict: nil,
            language: .zh
        )
        XCTAssertEqual(partial.map(\.text), ["华尔街见闻", "深度"])
        XCTAssertEqual(partial.map(\.kind), [.source, .depth])
    }

    func testHeaderTagsUseTheShortVerdictTable() {
        let tags = ResearchReportHeaderTagBuilder.tags(
            source: .weibo,
            depth: .standard,
            verdict: .refuted,
            language: .zh
        )
        // The long table renders "已被反驳", which pushes the other tags off
        // the row at 620pt.
        XCTAssertEqual(tags.last?.text, "反驳")
        XCTAssertEqual(tags.count, 3)
    }

    func testHeaderTagAccessibilityLabelSpeaksEveryTag() {
        let tags = ResearchReportHeaderTagBuilder.tags(
            source: .bilibili, depth: .quick, verdict: .mixed, language: .zh
        )
        let label = ResearchReportHeaderTagBuilder.accessibilityLabel(tags)
        XCTAssertTrue(label.contains("B站热搜"))
        XCTAssertTrue(label.contains("快速"))
        XCTAssertTrue(label.contains("分歧"))
    }
}
