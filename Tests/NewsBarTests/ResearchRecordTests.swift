import XCTest
@testable import NewsBar

final class ResearchRecordTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    func testLegacyBurstResearchJSONDecodesWithNewDefaults() throws {
        let legacy = """
        {
          "summary": "摘要",
          "overview": "概述",
          "timeline": [{"date": "2026-08-03", "title": "起因", "detail": "事件首次被曝出。"}],
          "sources": ["https://example.com/a"],
          "needsRefetch": false,
          "refetchURLs": [],
          "searchStatus": "succeeded"
        }
        """
        let research = try JSONDecoder().decode(BurstResearch.self, from: Data(legacy.utf8))

        XCTAssertEqual(research.summary, "摘要")
        XCTAssertTrue(research.evidence.isEmpty)
        XCTAssertNil(research.verification)
        XCTAssertEqual(research.limitations, "")
        XCTAssertNil(research.generatedAt)
        XCTAssertEqual(research.promptVersion, 0)
        XCTAssertEqual(research.depth, .standard)
        XCTAssertNil(research.method)

        let node = try XCTUnwrap(research.timeline.first)
        XCTAssertNil(node.sortDate)
        XCTAssertEqual(node.precision, .unknown)
        XCTAssertEqual(node.evidenceIDs, [])
        XCTAssertEqual(node.confidence, .medium)
    }

    func testLegacyTimelineNodeJSONDecodesWithNewDefaults() throws {
        let legacy = #"{"date":"8月3日","title":"发酵","detail":"登上热搜"}"#
        let node = try JSONDecoder().decode(TimelineNode.self, from: Data(legacy.utf8))

        XCTAssertEqual(node.date, "8月3日")
        XCTAssertEqual(node.title, "发酵")
        XCTAssertEqual(node.detail, "登上热搜")
        XCTAssertNil(node.sortDate)
        XCTAssertEqual(node.precision, .unknown)
        XCTAssertEqual(node.evidenceIDs, [])
        XCTAssertEqual(node.confidence, .medium)
    }

    func testResearchRecordRoundTripPreservesEvidence() throws {
        let evidence = EvidenceItem(
            id: "E1",
            url: "https://example.com/a",
            canonicalURL: "https://example.com/a",
            domain: "example.com",
            title: "来源标题",
            publishedAt: fixedDate,
            quote: "引文",
            quoteVerified: true,
            stance: .supports,
            tier: .major,
            syndicationGroup: nil,
            fetchedAt: fixedDate
        )
        var verification = VerificationReport()
        verification.verdict = .mostlyConfirmed
        verification.strength = 3
        verification.independentSources = 2
        verification.claims = [
            ClaimCheck(claim: "关键主张", status: .supports, evidenceIDs: ["E1"], note: "备注")
        ]
        verification.missing = ["缺少官方口径"]

        let method = ResearchMethod(
            providers: ["tavily", "firecrawl"],
            queries: ["事件 时间线"],
            pagesRead: 2,
            recency: "90d",
            generatedAt: fixedDate,
            promptVersion: 2,
            failovers: 1
        )
        let node = TimelineNode(
            date: "2026-10-01",
            title: "节点",
            detail: "细节",
            sortDate: fixedDate,
            precision: .day,
            evidenceIDs: ["E1"],
            confidence: .high
        )
        let research = BurstResearch(
            summary: "摘要",
            overview: "概述",
            timeline: [node],
            sources: ["https://example.com/a"],
            searchStatus: .succeeded,
            evidence: [evidence],
            verification: verification,
            limitations: "局限",
            generatedAt: fixedDate,
            promptVersion: 2,
            depth: .deep,
            method: method
        )

        var record = researchTestRecord(
            title: "事件",
            origin: .keyword,
            updatedAt: fixedDate,
            isPinned: true,
            isRead: true,
            report: research
        )
        record.aliases = ["另一个标题"]

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(ResearchRecord.self, from: data)
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.report?.evidence.first?.quoteVerified, true)
        XCTAssertEqual(decoded.report?.verification?.strength, 3)
        XCTAssertEqual(decoded.report?.timeline.first?.precision, .day)
    }

    func testAliasCapKeepsNewestEight() {
        var record = researchTestRecord(title: "主标题")
        for index in 0..<10 {
            record.addAlias("别名\(index)")
        }

        XCTAssertEqual(record.aliases.count, ResearchRecord.aliasLimit)
        XCTAssertEqual(record.aliases.first, "别名2")
        XCTAssertEqual(record.aliases.last, "别名9")

        record.addAlias("主标题")
        record.addAlias("别名9")
        XCTAssertEqual(record.aliases.count, 8)
    }

    func testCorruptPlaceholderIsMarkedAndHasNoReport() {
        let id = UUID().uuidString
        let placeholder = ResearchRecord.corruptPlaceholder(id: id, date: fixedDate)

        XCTAssertEqual(placeholder.id, id)
        XCTAssertEqual(placeholder.status, .corrupt)
        XCTAssertNil(placeholder.report)
        XCTAssertEqual(placeholder.createdAt, fixedDate)
        XCTAssertEqual(placeholder.updatedAt, fixedDate)
        XCTAssertEqual(placeholder.run.phase, .done)
    }

    func testLocalInterestPruneKeepsLegacyResearch() {
        var state = LocalInterestState()
        state.research.artifacts["旧事件"] = BurstResearch(summary: "旧摘要")
        state.research.updatedAt = Date().addingTimeInterval(-30 * 86_400)

        state.prune(now: Date())

        XCTAssertEqual(state.research.artifacts["旧事件"]?.summary, "旧摘要")
    }
}
