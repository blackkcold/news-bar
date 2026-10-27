import XCTest
@testable import NewsBar

final class ReportValidatorTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 12))!
    }

    private func method() -> ResearchMethod {
        ResearchMethod(
            providers: ["tavily"],
            queries: ["某事件 时间线"],
            pagesRead: 2,
            recency: "30d",
            generatedAt: now,
            promptVersion: ResearchPrompts.version,
            failovers: 0
        )
    }

    private func document(
        _ url: String,
        title: String,
        text: String,
        publishedAt: Date? = nil,
        source: PageContentSource = .firecrawl
    ) -> ResearchDocument {
        ResearchDocument(
            url: url,
            title: title,
            text: text,
            publishedAt: publishedAt,
            fetchedAt: now,
            source: source
        )
    }

    private func input(
        draft: ResearchDraft,
        candidates: [EvidenceCandidate],
        documents: [ResearchDocument],
        allowedURLs: Set<String>? = nil,
        searchStatus: BurstSearchStatus = .succeeded,
        pagesRead: Int = 2,
        truncated: Bool = false,
        plannedClaims: [String] = []
    ) -> ReportValidationInput {
        var documentsByURL: [String: ResearchDocument] = [:]
        for document in documents {
            documentsByURL[document.canonicalURL] = document
        }
        let allowed = allowedURLs ?? Set(documents.map(\.canonicalURL))
            .union(candidates.map { ContentIdentity.canonicalURL($0.url) })
        return ReportValidationInput(
            draft: draft,
            candidates: candidates,
            plannedClaims: plannedClaims,
            documents: documentsByURL,
            allowedURLs: allowed,
            searchStatus: searchStatus,
            pagesRead: pagesRead,
            truncated: truncated,
            depth: .standard,
            method: method(),
            now: now,
            language: .en
        )
    }

    // MARK: - Quotes

    func testQuoteVerifierHitRatio() {
        let quote = "第一段引文内容足够长……第二段引文内容也足够长"
        let onlyFirst = "正文开头。第一段引文内容足够长。结尾。"
        XCTAssertFalse(QuoteVerifier.verified(quote: quote, in: onlyFirst))

        let both = "第一段引文内容足够长，第二段引文内容也足够长。"
        XCTAssertTrue(QuoteVerifier.verified(quote: quote, in: both))

        XCTAssertFalse(QuoteVerifier.verified(quote: "短引文", in: "短引文"))
    }

    // MARK: - Evidence

    func testEvidenceOutsideAllowedURLsIsDropped() {
        let candidate = EvidenceCandidate(
            url: "https://evil.example.com/story",
            title: "Untrusted",
            quote: "这是一段足够长的引文内容。",
            claim: "某事发生",
            stance: .supports,
            fetchedAt: now
        )
        var draft = ResearchDraft()
        draft.summary = "摘要"
        draft.overview = "概述"

        let report = ReportValidator.validate(
            input(
                draft: draft,
                candidates: [candidate],
                documents: [],
                allowedURLs: ["https://www.reuters.com/story"]
            )
        )

        XCTAssertTrue(report.evidence.isEmpty)
        XCTAssertEqual(report.verification?.verdict, .unverified)
    }

    func testSameURLMergesEvidenceAndRemapsIDs() {
        let url = "https://www.reuters.com/story"
        let text = "公司确认新品将于十月发布。渠道随后确认了到货时间。"
        let candidates = [
            EvidenceCandidate(
                url: url,
                title: "Reuters",
                quote: "公司确认新品将于十月发布。",
                claim: "十月发布",
                stance: .supports,
                fetchedAt: now
            ),
            EvidenceCandidate(
                url: url,
                title: "Reuters",
                quote: "渠道随后确认了到货时间。",
                claim: "十月发布",
                stance: .supports,
                fetchedAt: now
            ),
        ]
        var draft = ResearchDraft()
        draft.summary = "摘要"
        draft.overview = "概述"
        draft.claims = [
            ClaimCheck(claim: "十月发布", status: .supports, evidenceIDs: ["E1", "E2"], note: ""),
        ]

        let report = ReportValidator.validate(
            input(
                draft: draft,
                candidates: candidates,
                documents: [document(url, title: "Reuters", text: text)]
            )
        )

        XCTAssertEqual(report.evidence.count, 1)
        XCTAssertEqual(report.evidence.first?.id, "E1")
        XCTAssertEqual(report.verification?.claims.first?.evidenceIDs, ["E1"])
        XCTAssertTrue(report.evidence.first?.quoteVerified == true)
    }

    // MARK: - Timeline

    func testTimelineDropsNodesWithoutValidEvidence() {
        let url = "https://www.reuters.com/story"
        let candidates = [
            EvidenceCandidate(
                url: url,
                title: "Reuters",
                quote: "公司确认新品将于十月发布。",
                claim: "十月发布",
                stance: .supports,
                fetchedAt: now
            ),
        ]
        var draft = ResearchDraft()
        draft.summary = "摘要"
        draft.overview = "概述"
        draft.timeline = [
            TimelineNode(date: "2026-10-01", title: "发布", detail: "发布", evidenceIDs: ["E1"]),
            TimelineNode(date: "2026-10-02", title: "无据", detail: "无据", evidenceIDs: []),
            TimelineNode(date: "2026-10-03", title: "坏引用", detail: "坏引用", evidenceIDs: ["E404"]),
        ]

        let report = ReportValidator.validate(
            input(
                draft: draft,
                candidates: candidates,
                documents: [document(url, title: "Reuters", text: "公司确认新品将于十月发布。")]
            )
        )

        XCTAssertEqual(report.timeline.map(\.title), ["发布"])
        XCTAssertTrue(report.limitations.contains(L10n.string("research.limitation.noTimeline", language: .en)))
    }

    func testTimelineSortsAndMergesSameDayTitle() {
        let url = "https://www.reuters.com/story"
        let candidates = [
            EvidenceCandidate(
                url: url,
                title: "Reuters",
                quote: "公司确认新品将于十月发布。",
                claim: "十月发布",
                stance: .supports,
                fetchedAt: now
            ),
        ]
        var draft = ResearchDraft()
        draft.summary = "摘要"
        draft.overview = "概述"
        draft.timeline = [
            TimelineNode(date: "2026-10-05", title: "后续", detail: "后续", evidenceIDs: ["E1"]),
            TimelineNode(date: "2026-10-01", title: "发布", detail: "发布", evidenceIDs: ["E1"]),
            TimelineNode(date: "2026-10-05", title: "后续", detail: "重复", evidenceIDs: ["E1"]),
        ]

        let report = ReportValidator.validate(
            input(
                draft: draft,
                candidates: candidates,
                documents: [document(url, title: "Reuters", text: "公司确认新品将于十月发布。")]
            )
        )

        XCTAssertEqual(report.timeline.map(\.title), ["发布", "后续"])
        XCTAssertEqual(report.timeline.first?.sortDate.map { TimelineDateParser.dayKey($0, calendar: calendar) }, "2026-10-01")
    }

    func testOutOfRangeDateIsClearedAndConfidenceLowered() {
        let url = "https://www.reuters.com/story"
        let candidates = [
            EvidenceCandidate(
                url: url,
                title: "Reuters",
                quote: "公司确认新品将于十月发布。",
                claim: "十月发布",
                stance: .supports,
                fetchedAt: now
            ),
        ]
        var draft = ResearchDraft()
        draft.summary = "摘要"
        draft.overview = "概述"
        draft.timeline = [
            TimelineNode(
                date: "1970-01-01",
                title: "旧日期",
                detail: "旧日期",
                sortDate: Date(timeIntervalSince1970: 0),
                precision: .day,
                evidenceIDs: ["E1"],
                confidence: .high
            ),
        ]

        let report = ReportValidator.validate(
            input(
                draft: draft,
                candidates: candidates,
                documents: [document(url, title: "Reuters", text: "公司确认新品将于十月发布。")]
            )
        )

        XCTAssertNil(report.timeline.first?.sortDate)
        XCTAssertEqual(report.timeline.first?.confidence, .medium)
    }

    // MARK: - Verdict

    private func confirmableDraft() -> ResearchDraft {
        var draft = ResearchDraft()
        draft.summary = "两家独立媒体确认了发布。"
        draft.overview = "公司发布新品，随后多家媒体确认。"
        draft.claims = [
            ClaimCheck(claim: "十月发布", status: .supports, evidenceIDs: ["E1", "E2"], note: ""),
        ]
        draft.timeline = [
            TimelineNode(date: "2026-10-01", title: "发布", detail: "公司发布新品", evidenceIDs: ["E1"]),
            TimelineNode(date: "2026-10-02", title: "确认", detail: "第二家媒体确认", evidenceIDs: ["E2"]),
            TimelineNode(date: "2026-10-03", title: "跟进", detail: "后续报道", evidenceIDs: ["E1"]),
        ]
        return draft
    }

    private func confirmableCandidates(refutesSecond: Bool = false) -> [EvidenceCandidate] {
        [
            EvidenceCandidate(
                url: "https://www.reuters.com/story",
                title: "Reuters",
                quote: "公司确认新品将于十月发布。",
                claim: "十月发布",
                stance: .supports,
                fetchedAt: now
            ),
            EvidenceCandidate(
                url: "https://www.bbc.com/story",
                title: "BBC",
                quote: refutesSecond ? "公司否认了十月发布的说法。" : "公司确认新品将于十月发布。",
                claim: "十月发布",
                stance: refutesSecond ? .refutes : .supports,
                fetchedAt: now
            ),
        ]
    }

    private func confirmableDocuments() -> [ResearchDocument] {
        [
            document("https://www.reuters.com/story", title: "Reuters", text: "公司确认新品将于十月发布。"),
            document("https://www.bbc.com/story", title: "BBC", text: "公司确认新品将于十月发布。"),
        ]
    }

    func testConfirmedVerdictWithTwoIndependentTierOneSources() {
        let report = ReportValidator.validate(
            input(draft: confirmableDraft(), candidates: confirmableCandidates(), documents: confirmableDocuments())
        )

        XCTAssertEqual(report.verification?.verdict, .confirmed)
        XCTAssertEqual(report.verification?.strength, 3)
        XCTAssertEqual(report.verification?.independentSources, 2)
        XCTAssertEqual(report.verification?.claims.first?.status, .supports)
        XCTAssertEqual(report.searchStatus, .succeeded)
        XCTAssertEqual(report.promptVersion, ResearchPrompts.version)
    }

    func testMixedVerdictWhenTierOneSourcesDisagree() {
        let report = ReportValidator.validate(
            input(
                draft: confirmableDraft(),
                candidates: confirmableCandidates(refutesSecond: true),
                documents: [
                    document("https://www.reuters.com/story", title: "Reuters", text: "公司确认新品将于十月发布。"),
                    document("https://www.bbc.com/story", title: "BBC", text: "公司否认了十月发布的说法。"),
                ]
            )
        )

        XCTAssertEqual(report.verification?.verdict, .mixed)
        XCTAssertEqual(report.verification?.claims.first?.status, .unclear)
    }

    func testPagesReadZeroForcesUnverified() {
        let report = ReportValidator.validate(
            input(
                draft: confirmableDraft(),
                candidates: confirmableCandidates(),
                documents: confirmableDocuments(),
                pagesRead: 0
            )
        )

        XCTAssertEqual(report.verification?.verdict, .unverified)
        XCTAssertTrue(report.limitations.contains(L10n.string("research.limitation.notOnline", language: .en)))
    }

    func testSearchFailureForcesUnverified() {
        let report = ReportValidator.validate(
            input(
                draft: confirmableDraft(),
                candidates: confirmableCandidates(),
                documents: confirmableDocuments(),
                searchStatus: .failed
            )
        )

        XCTAssertEqual(report.verification?.verdict, .unverified)
    }

    func testSyndicatedCopiesCountAsOneIndependentSource() {
        let body = String(repeating: "同一篇通稿的正文内容，用于识别转载。", count: 40)
        let urlA = "https://www.reuters.com/story"
        let urlB = "https://www.bbc.com/story"
        let candidates = [
            EvidenceCandidate(
                url: urlA,
                title: "公司发布新品",
                quote: "公司确认新品将于十月发布。",
                claim: "十月发布",
                stance: .supports,
                fetchedAt: now
            ),
            EvidenceCandidate(
                url: urlB,
                title: "公司发布新品",
                quote: "公司确认新品将于十月发布。",
                claim: "十月发布",
                stance: .supports,
                fetchedAt: now
            ),
        ]
        var draft = confirmableDraft()
        draft.claims = [
            ClaimCheck(claim: "十月发布", status: .supports, evidenceIDs: ["E1", "E2"], note: ""),
        ]

        let report = ReportValidator.validate(
            input(
                draft: draft,
                candidates: candidates,
                documents: [
                    document(urlA, title: "公司发布新品", text: body),
                    document(urlB, title: "公司发布新品", text: body),
                ]
            )
        )

        XCTAssertEqual(report.evidence.compactMap(\.syndicationGroup).count, 2)
        XCTAssertEqual(report.verification?.independentSources, 1)
        XCTAssertNotEqual(report.verification?.verdict, .confirmed)
    }

    func testTruncationAddsLimitation() {
        let report = ReportValidator.validate(
            input(
                draft: confirmableDraft(),
                candidates: confirmableCandidates(),
                documents: confirmableDocuments(),
                truncated: true
            )
        )

        XCTAssertTrue(report.limitations.contains(L10n.string("research.limitation.truncated", language: .en)))
    }
}
