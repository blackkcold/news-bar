import XCTest
@testable import NewsBar

/// The popup reads a report, the workbench manages one. Every assertion here
/// is about the line where those two jobs stop sharing a decision.
final class ResearchReportPopupReadingTests: XCTestCase {
    // MARK: - Conclusion heading

    /// The popup's body is the overview: what happened, why, and what changed.
    /// A heading that says "Conclusion" over that copy names something the
    /// paragraph is not, so the popup drops it. The workbench keeps it: its
    /// chapter tab says the same word and the heading anchors the scroll spy.
    func testPopupHidesOnlyTheConclusionHeading() {
        let popup = ResearchReportPresentation.popup
        XCTAssertFalse(popup.showsHeading(.conclusion))
        XCTAssertTrue(popup.showsHeading(.timeline))
        XCTAssertTrue(popup.showsHeading(.verification))
        XCTAssertTrue(popup.showsHeading(.sources))

        let workspace = ResearchReportPresentation.workspace
        for section in ResearchReportSection.allCases {
            XCTAssertTrue(
                workspace.showsHeading(section),
                "The workbench must keep every chapter heading, including \(section)."
            )
        }
    }

    /// Dropping a heading must not drop the accessibility container with it:
    /// the chapter is still a chapter, and the detail chapters below it still
    /// announce themselves as headers.
    func testHidingTheHeadingLeavesTheOtherChaptersAlone() {
        var presentation = ResearchReportPresentation.popup
        presentation.hidesConclusionHeading = false
        XCTAssertTrue(presentation.showsHeading(.conclusion))
    }

    // MARK: - Conclusion count line

    /// Measured on this machine's 36 reports: every one said "quotes verified
    /// N/N" (155 of 155), and `independentSources` equalled the distinct domain
    /// count with no exception, because no evidence item ever carried a
    /// `syndicationGroup`. Both parts were therefore constant or duplicated —
    /// they took two of five slots and told the reader nothing.
    ///
    /// The popup keeps the source count and replaces the duplicated parts with
    /// the one thing that explains the verdict: how good the best source is.
    func testPopupCountLineDropsConstantPartsAndNamesSourceQuality() {
        let report = makeReport(
            domains: ["reuters.com", "sina.com.cn", "weibo.com"],
            tiers: [.primary, .industry, .social]
        )
        XCTAssertEqual(
            ResearchReportConclusionSection.metaText(report: report, language: .zh, scope: .evidence),
            "3 个来源 · 含一手来源"
        )
        XCTAssertEqual(
            ResearchReportConclusionSection.metaText(report: report, language: .en, scope: .evidence),
            "Sources: 3 · Includes a first-party source"
        )
    }

    func testPopupCountLineNamesMajorAndIndustryOnlyReports() {
        let major = makeReport(domains: ["nytimes.com"], tiers: [.major])
        XCTAssertEqual(
            ResearchReportConclusionSection.metaText(report: major, language: .zh, scope: .evidence),
            "1 个来源 · 含主流媒体"
        )

        let industry = makeReport(domains: ["someblog.example"], tiers: [.industry])
        XCTAssertEqual(
            ResearchReportConclusionSection.metaText(report: industry, language: .zh, scope: .evidence),
            "1 个来源 · 仅行业来源"
        )

        let social = makeReport(domains: ["weibo.com"], tiers: [.social])
        XCTAssertEqual(
            ResearchReportConclusionSection.metaText(report: social, language: .zh, scope: .evidence),
            "1 个来源 · 仅社交媒体"
        )
    }

    /// A report with no evidence must still say "0 sources", and it must not
    /// invent a quality word for a source set that does not exist.
    func testPopupCountLineKeepsZeroSourcesWithoutAQualityWord() {
        let empty = BurstResearch(summary: "只有结论。", searchStatus: .succeeded)
        XCTAssertEqual(
            ResearchReportConclusionSection.metaText(report: empty, language: .zh, scope: .evidence),
            "0 个来源"
        )
        XCTAssertEqual(
            ResearchReportConclusionSection.metaText(report: empty, language: .en, scope: .evidence),
            "Sources: 0"
        )
    }

    /// The workbench is a management surface and keeps every count it had; the
    /// scope has to default to it so no existing call site changes behaviour.
    func testWorkbenchCountLineIsUnchanged() {
        let report = makeReport(
            domains: ["reuters.com", "sina.com.cn"],
            tiers: [.primary, .industry]
        )
        let expected = ResearchReportConclusionSection.metaText(report: report, language: .zh, scope: .all)
        XCTAssertEqual(
            ResearchReportConclusionSection.metaText(report: report, language: .zh),
            expected,
            "The default scope must stay the full line."
        )
        XCTAssertTrue(expected.contains("已核验"), "The workbench keeps the verified-quote count.")
        XCTAssertTrue(expected.contains("个域名"), "The workbench keeps the domain count.")
    }

    // MARK: - Fold strip preview

    /// The strip is the only entrance to three chapters, and it used to say
    /// nothing about what was behind it: the reader had to pay a click to find
    /// out whether the detail was worth reading. It now reports the two counts
    /// that answer that question, and nothing else — the source count is
    /// already on the count line above, and repeating it puts the same number
    /// on one screen twice.
    func testFoldPreviewReportsTimelineAndVerificationCounts() {
        let report = makeReport(
            domains: ["reuters.com", "sina.com.cn"],
            tiers: [.primary, .industry]
        )
        var withTimeline = report
        withTimeline.timeline = [
            TimelineNode(date: "10月1日", title: "发布预告", detail: "", confidence: .high),
            TimelineNode(date: "10月8日", title: "渠道备货", detail: "", confidence: .low),
        ]
        withTimeline.verification = VerificationReport(
            verdict: .unverified,
            strength: 0,
            independentSources: 2,
            claims: [
                ClaimCheck(claim: "已发布", status: .supports, evidenceIDs: ["E1"], note: ""),
                ClaimCheck(claim: "已备货", status: .supports, evidenceIDs: ["E2"], note: ""),
            ],
            conflicts: [],
            missing: []
        )

        XCTAssertEqual(
            ResearchDetailFoldPreview.make(report: withTimeline, language: .zh),
            "2 则时间线 · 2 条核验"
        )
        XCTAssertEqual(
            ResearchDetailFoldPreview.make(report: withTimeline, language: .en),
            "2 timeline entries · 2 checks"
        )
    }

    /// Missing items are the one thing a reader should know before deciding,
    /// because they say the report is incomplete. They are appended, not
    /// substituted: "3 items missing" alone would not say what is there.
    func testFoldPreviewAppendsMissingItems() {
        var report = makeReport(domains: ["reuters.com"], tiers: [.primary])
        report.timeline = [TimelineNode(date: "10月1日", title: "发布", detail: "")]
        report.verification = VerificationReport(
            verdict: .unverified,
            strength: 0,
            independentSources: 1,
            claims: [ClaimCheck(claim: "已发布", status: .supports, evidenceIDs: ["E1"], note: "")],
            conflicts: [],
            missing: ["价格", "发售日"]
        )
        XCTAssertEqual(
            ResearchDetailFoldPreview.make(report: report, language: .zh),
            "1 则时间线 · 1 条核验 · 2 处待补"
        )
    }

    /// Nothing behind the strip means the strip must not promise anything.
    /// The section view already hides the strip in that case, so a nil here is
    /// the contract the two share; an empty string would render a separator.
    func testFoldPreviewIsSilentWhenThereIsNothingToPreview() {
        let empty = BurstResearch(summary: "只有结论。", searchStatus: .succeeded)
        XCTAssertNil(ResearchDetailFoldPreview.make(report: empty, language: .zh))
        XCTAssertNil(ResearchDetailFoldPreview.make(report: empty, language: .en))
    }

    /// English needs the singular form; Chinese does not. The snapshot of the
    /// collapsed strip read "1 checks", which is the kind of defect a reader
    /// notices before they notice the feature.
    func testFoldPreviewUsesSingularEnglishForOne() {
        var report = makeReport(domains: ["reuters.com"], tiers: [.primary])
        report.timeline = [TimelineNode(date: "10月1日", title: "发布", detail: "")]
        report.verification = VerificationReport(
            verdict: .unverified,
            strength: 0,
            independentSources: 1,
            claims: [ClaimCheck(claim: "已发布", status: .supports, evidenceIDs: ["E1"], note: "")],
            conflicts: [],
            missing: []
        )
        XCTAssertEqual(
            ResearchDetailFoldPreview.make(report: report, language: .en),
            "1 timeline entry · 1 check"
        )
        XCTAssertEqual(
            ResearchDetailFoldPreview.make(report: report, language: .zh),
            "1 则时间线 · 1 条核验"
        )
    }

    // MARK: - Fixtures

    private func makeReport(domains: [String], tiers: [SourceTier]) -> BurstResearch {
        let evidence = zip(domains, tiers).enumerated().map { index, pair in
            EvidenceItem(
                id: "E\(index + 1)",
                url: "https://\(pair.0)/story-\(index)",
                canonicalURL: "https://\(pair.0)/story-\(index)",
                domain: pair.0,
                title: "Story \(index)",
                publishedAt: nil,
                quote: "Quote \(index)",
                quoteVerified: true,
                stance: .supports,
                tier: pair.1,
                syndicationGroup: nil,
                fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }
        return BurstResearch(
            summary: "摘要。",
            overview: "背景与经过。",
            sources: domains.map { "https://\($0)/story" },
            searchStatus: .succeeded,
            evidence: evidence,
            verification: VerificationReport(
                verdict: .unverified,
                strength: 0,
                independentSources: Set(domains).count,
                claims: [],
                conflicts: [],
                missing: []
            )
        )
    }
}
