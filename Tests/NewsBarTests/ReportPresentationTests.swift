import XCTest
@testable import NewsBar

final class ReportPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func evidence(_ id: String, verified: Bool) -> EvidenceItem {
        EvidenceItem(
            id: id,
            url: "https://example.com/\(id)",
            canonicalURL: "https://example.com/\(id)",
            domain: "example.com",
            title: "来源 \(id)",
            publishedAt: now,
            quote: "引文 \(id)",
            quoteVerified: verified,
            stance: .supports,
            tier: .major,
            syndicationGroup: nil,
            fetchedAt: now
        )
    }

    func testClassifiesVerifiedUnverifiedAndUnsourcedNodes() {
        var report = BurstResearch(
            summary: "摘要",
            overview: "概述",
            timeline: [
                TimelineNode(date: "2026-10-01", title: "已核实", detail: "", evidenceIDs: ["E1"]),
                TimelineNode(date: "2026-10-02", title: "引文未过", detail: "", evidenceIDs: ["E2"]),
                TimelineNode(date: "2026-10-03", title: "无来源", detail: ""),
            ],
            evidence: [evidence("E1", verified: true), evidence("E2", verified: false)]
        )
        var verification = VerificationReport()
        verification.verdict = .mostlyConfirmed
        verification.strength = 3
        verification.claims = [
            ClaimCheck(claim: "主张", status: .supports, evidenceIDs: ["E1"], note: "")
        ]
        report.verification = verification

        let presentation = ReportPresentation(report: report)

        XCTAssertEqual(presentation.nodes.map(\.state), [.verified, .citedUnverified, .unsourced])
        XCTAssertEqual(presentation.verifiedNodeCount, 1)
        XCTAssertEqual(presentation.citedNodeCount, 2)
        XCTAssertEqual(presentation.citedUnverifiedNodeCount, 1)
        XCTAssertEqual(presentation.unsourcedNodeCount, 1)
        XCTAssertEqual(presentation.evidenceCount, 2)
        XCTAssertEqual(presentation.verifiedEvidenceCount, 1)
        XCTAssertEqual(presentation.claimCount, 1)
        XCTAssertTrue(presentation.hasUnverifiedTimeline)
        XCTAssertFalse(presentation.expandsVerificationByDefault)
    }

    func testEmptyTimelineAndLegacyReport() {
        let report = BurstResearch(summary: "旧报告")
        let presentation = ReportPresentation(report: report, isLegacy: true)

        XCTAssertTrue(presentation.nodes.isEmpty)
        XCTAssertEqual(presentation.verifiedNodeCount, 0)
        XCTAssertEqual(presentation.unsourcedNodeCount, 0)
        XCTAssertTrue(presentation.isLegacy)
        XCTAssertFalse(presentation.hasVerification)
    }

    func testMixedVerdictOrConflictExpandsVerification() {
        var report = BurstResearch(summary: "摘要")
        var verification = VerificationReport()
        verification.verdict = .mixed
        verification.conflicts = ["定价说法不一致"]
        report.verification = verification

        let presentation = ReportPresentation(report: report)

        XCTAssertTrue(presentation.expandsVerificationByDefault)
        XCTAssertEqual(presentation.conflictCount, 1)
        XCTAssertTrue(presentation.isUnverified == false)
    }

    // MARK: - Outcome

    func testZeroEvidenceWithSuccessfulSearchIsInsufficient() {
        var report = BurstResearch(summary: "背景梳理")
        report.searchStatus = .succeeded
        var verification = VerificationReport()
        verification.verdict = .unverified
        report.verification = verification

        let presentation = ReportPresentation(report: report)

        XCTAssertEqual(presentation.outcome, .insufficientEvidence)
        XCTAssertTrue(presentation.showsEvidenceGap)
        XCTAssertFalse(presentation.showsVerificationSection)
        XCTAssertFalse(presentation.expandsVerificationByDefault)
    }

    func testZeroEvidenceWithFailedSearchIsSearchUnavailable() {
        var report = BurstResearch(summary: "背景梳理")
        report.searchStatus = .failed

        let presentation = ReportPresentation(report: report)

        XCTAssertEqual(presentation.outcome, .searchUnavailable)
        XCTAssertTrue(presentation.showsEvidenceGap)
    }

    func testOnlyUnverifiedEvidenceIsPartialEvidence() {
        var report = BurstResearch(
            summary: "摘要",
            timeline: [TimelineNode(date: "2026-10-01", title: "节点", detail: "", evidenceIDs: ["E1"])],
            evidence: [evidence("E1", verified: false)]
        )
        report.searchStatus = .succeeded

        let presentation = ReportPresentation(report: report)

        XCTAssertEqual(presentation.outcome, .partialEvidence)
        XCTAssertTrue(presentation.showsVerificationSection)
        XCTAssertFalse(presentation.showsEvidenceGap)
    }

    func testVerifiedEvidenceIsComplete() {
        var report = BurstResearch(
            summary: "摘要",
            timeline: [TimelineNode(date: "2026-10-01", title: "节点", detail: "", evidenceIDs: ["E1"])],
            evidence: [evidence("E1", verified: true)]
        )
        report.searchStatus = .succeeded

        let presentation = ReportPresentation(report: report)

        XCTAssertEqual(presentation.outcome, .complete)
    }
}
