import XCTest
@testable import NewsBar

final class ResearchReportMetricsTests: XCTestCase {
    func testCountsVerifiedQuotesClaimsAndDomains() {
        let metrics = ResearchReportMetrics(report: makeReport())
        XCTAssertEqual(metrics.evidenceCount, 3)
        XCTAssertEqual(metrics.verifiedQuoteCount, 2)
        XCTAssertEqual(metrics.domainCount, 2)
        XCTAssertEqual(metrics.claimCount, 4)
        XCTAssertEqual(metrics.claimsWithVerifiedEvidenceCount, 1)
        XCTAssertEqual(metrics.claimsNeedingEvidenceCount, 3)
        XCTAssertEqual(metrics.conflictCount, 1)
        XCTAssertEqual(metrics.missingCount, 2)
        XCTAssertEqual(metrics.timelineNodeCount, 2)
        XCTAssertEqual(metrics.timelineSpanDays, 4)
        XCTAssertEqual(metrics.independentSourceCount, 5)
    }

    func testEmptyReportHasZeroCountsAndNoSpan() {
        let metrics = ResearchReportMetrics(report: BurstResearch())
        XCTAssertEqual(metrics.evidenceCount, 0)
        XCTAssertEqual(metrics.timelineNodeCount, 0)
        XCTAssertNil(metrics.timelineSpanDays)
        XCTAssertEqual(metrics.claimsNeedingEvidenceCount, 0)
    }

    func testSourceGroupsSortByCountThenDomainAndNaturalID() {
        let groups = ResearchSourceGrouping.groups(for: makeEvidence())
        XCTAssertEqual(groups.map(\.domain), ["a.example", "b.example"])
        XCTAssertEqual(groups[0].items.map(\.id), ["E2", "E10"])
    }

    func testTimelineSpanIgnoresUndatedNodes() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let report = BurstResearch(
            timeline: [
                TimelineNode(date: "day 1", title: "first", detail: "detail", sortDate: base),
                TimelineNode(date: "undated", title: "no date", detail: "detail"),
                TimelineNode(
                    date: "day 5",
                    title: "second",
                    detail: "detail",
                    sortDate: base.addingTimeInterval(4 * 24 * 60 * 60)
                ),
            ]
        )
        let metrics = ResearchReportMetrics(report: report)
        XCTAssertEqual(metrics.timelineNodeCount, 3)
        XCTAssertEqual(metrics.timelineSpanDays, 4)
    }

    func testHistoricalVersionUsesSelectedReportAndDigest() {
        let latest = researchTestRecord(title: "topic", report: BurstResearch(summary: "new"))
        let oldReport = BurstResearch(summary: "old")
        let version = WorkspaceReportVersion(
            id: "\(latest.id)#1",
            recordID: latest.id,
            subjectID: "subject-1",
            sequence: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            trigger: .manual,
            report: oldReport,
            digest: WorkspaceReportDigest.make(oldReport)
        )
        XCTAssertEqual(ResearchReportDisplay.report(selectedVersion: version, record: latest)?.summary, "old")
        XCTAssertTrue(ResearchReportDisplay.isHistorical(selectedVersion: version, record: latest))
        XCTAssertEqual(ResearchReportDisplay.report(selectedVersion: nil, record: latest)?.summary, "new")
        XCTAssertFalse(ResearchReportDisplay.isHistorical(selectedVersion: nil, record: latest))
    }

    // MARK: - Fixtures

    private func makeEvidence() -> [EvidenceItem] {
        [
            makeEvidenceItem(id: "E2", domain: "a.example", quoteVerified: true),
            makeEvidenceItem(id: "E10", domain: "a.example", quoteVerified: true),
            makeEvidenceItem(id: "E3", domain: "b.example", quoteVerified: false),
        ]
    }

    private func makeEvidenceItem(
        id: String,
        domain: String,
        quoteVerified: Bool
    ) -> EvidenceItem {
        let url = "https://\(domain)/story/\(id.lowercased())"
        return EvidenceItem(
            id: id,
            url: url,
            canonicalURL: url,
            domain: domain,
            title: "Story \(id)",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            quote: "Quote \(id)",
            quoteVerified: quoteVerified,
            stance: .supports,
            tier: .major,
            syndicationGroup: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    private func makeReport() -> BurstResearch {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return BurstResearch(
            summary: "summary",
            overview: "overview",
            timeline: [
                TimelineNode(
                    date: "day 1",
                    title: "first",
                    detail: "detail",
                    sortDate: base
                ),
                TimelineNode(
                    date: "day 5",
                    title: "second",
                    detail: "detail",
                    sortDate: base.addingTimeInterval(4 * 24 * 60 * 60)
                ),
            ],
            evidence: makeEvidence(),
            verification: VerificationReport(
                verdict: .mixed,
                strength: 2,
                independentSources: 5,
                claims: [
                    ClaimCheck(claim: "C1", status: .supports, evidenceIDs: ["E2"], note: ""),
                    ClaimCheck(claim: "C2", status: .unclear, evidenceIDs: ["E3"], note: ""),
                    ClaimCheck(claim: "C3", status: nil, evidenceIDs: [], note: ""),
                    ClaimCheck(claim: "C4", status: .unclear, evidenceIDs: ["E99"], note: ""),
                ],
                conflicts: ["conflict"],
                missing: ["m1", "m2"]
            ),
            generatedAt: base
        )
    }
}
