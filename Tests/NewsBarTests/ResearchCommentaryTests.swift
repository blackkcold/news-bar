import XCTest
@testable import NewsBar

/// Commentary is the easiest part of a research report to fake: "some experts
/// say" costs the model nothing. Every claim here is therefore checked by
/// deterministic code, never by the model's own declaration:
///
/// 1. the speaker must appear in the cited page's body,
/// 2. the page must be reachable and must have actually been read this pass,
/// 3. the quote must appear verbatim (with the same verifier quotes already use).
///
/// Failing 1 or 2 drops the item; failing 3 downgrades it to a paraphrase and
/// says so. Silence is better than a sentence with no author.
final class ResearchCommentaryTests: XCTestCase {
    // MARK: - Schema

    /// Four quadrants: past/present × domestic/foreign. They are independent of
    /// evidence: commentary answers "what do people think", evidence answers
    /// "what happened".
    func testQuadrantsArePastPresentTimesDomesticForeign() {
        XCTAssertEqual(CommentaryEra.allCases, [.past, .present])
        XCTAssertEqual(CommentaryOrigin.allCases, [.domestic, .foreign])
    }

    /// A report written before this field existed must decode unchanged, and an
    /// empty commentary list must not render a section.
    func testCommentaryDefaultsToEmptyAndDecodesLegacyReports() throws {
        let legacy = #"{"summary":"旧报告","overview":"背景"}"#
        let report = try JSONDecoder().decode(BurstResearch.self, from: Data(legacy.utf8))
        XCTAssertTrue(report.commentary.isEmpty)
    }

    // MARK: - Gate 1: the speaker must be findable

    /// The attribution is the whole point. A quote whose speaker cannot be found
    /// in the page is unattributable, so it is dropped rather than shown with a
    /// name the source never mentions.
    func testSpeakerAbsentFromThePageIsDropped() {
        let document = makeDocument(
            text: "公司高管表示，本季度销量好于预期。"
        )
        let kept = ResearchCommentaryValidator.accepted(
            [raw(speaker: "某位未具名分析师", quote: "公司高管表示，本季度销量好于预期。")],
            documents: [document.canonicalURL: document],
            language: .zh
        )
        XCTAssertTrue(kept.isEmpty)
    }

    func testSpeakerPresentInThePageIsKept() throws {
        let document = makeDocument(
            text: "分析师张伟表示，本季度销量好于预期。"
        )
        let kept = ResearchCommentaryValidator.accepted(
            [raw(speaker: "张伟", quote: "本季度销量好于预期。")],
            documents: [document.canonicalURL: document],
            language: .zh
        )
        let item = try XCTUnwrap(kept.first)
        XCTAssertEqual(item.speaker, "张伟")
        XCTAssertFalse(item.isParaphrase)
        XCTAssertTrue(item.quoteVerified)
    }

    // MARK: - Gate 2: the page must have been read this pass

    /// A URL that looks fine but was never fetched cannot vouch for anything.
    /// This is what stops the model from citing a plausible-looking page it
    /// never read.
    func testUnreadPageIsDropped() {
        let kept = ResearchCommentaryValidator.accepted(
            [raw(speaker: "张伟", quote: "本季度销量好于预期。")],
            documents: [:],
            language: .zh
        )
        XCTAssertTrue(kept.isEmpty)
    }

    /// The same reachability rule the reader uses for links: https only, public
    /// host, no credentials. A commentary link is a link the reader can click.
    func testUnreachableURLIsDropped() {
        let document = makeDocument(text: "分析师张伟表示，本季度销量好于预期。")
        for url in [
            "http://example.org/a",
            "https://localhost/a",
            "https://127.0.0.1/a",
        ] {
            let candidate = CommentaryCandidate(
                era: .present,
                origin: .domestic,
                speaker: "张伟",
                role: nil,
                quote: "本季度销量好于预期。",
                url: url,
                publishedAt: nil,
                evidenceID: nil
            )
            XCTAssertTrue(
                ResearchCommentaryValidator.accepted(
                    [candidate],
                    documents: [document.canonicalURL: document],
                    language: .zh
                ).isEmpty,
                "\(url) must not pass the reachability gate."
            )
        }
    }

    // MARK: - Gate 3: verbatim or paraphrase

    /// A quote that is *partly* verbatim keeps the item: the model shortened or
    /// joined a real sentence, and the position may still be worth reading. It
    /// is downgraded to a paraphrase so the UI never presents an approximation
    /// in quote marks.
    ///
    /// This used to accept a quote with **nothing** in common with the page.
    /// That was the hole: a line the model wrote for a person the page happens
    /// to name survived as "a paraphrase from a named expert", and the only
    /// visible difference from a real quotation was the missing 「」. A
    /// paraphrase now has to share text with the source; see
    /// `testInventedLineThatSharesNothingWithThePageIsDropped`.
    func testPartlyVerbatimQuoteIsDowngradedToParaphrase() throws {
        let document = makeDocument(
            text: "分析师张伟表示，本季度销量好于预期，尤其是高端机型。"
        )
        let kept = ResearchCommentaryValidator.accepted(
            [raw(
                speaker: "张伟",
                quote: "本季度销量好于预期……渠道商普遍反映备货意愿不强。"
            )],
            documents: [document.canonicalURL: document],
            language: .zh
        )
        let item = try XCTUnwrap(kept.first)
        XCTAssertTrue(item.isParaphrase)
        XCTAssertFalse(item.quoteVerified)
    }

    /// A paraphrase still has to be about something the page said. The failure
    /// this guards against is not a loose quotation — it is a line the model
    /// wrote for a person whose name happens to appear in the source. Before
    /// this gate, such a line reached the report labelled as a paraphrase from
    /// a named expert, and the UI difference from a real quote was two details:
    /// no 「」 and a secondary text colour.
    func testInventedLineThatSharesNothingWithThePageIsDropped() throws {
        let document = makeDocument(
            text: "分析师张伟表示，本季度销量好于预期，尤其是高端机型。"
        )
        let kept = ResearchCommentaryValidator.accepted(
            [raw(speaker: "张伟", quote: "这类补贴退坡在 2016 年也发生过。")],
            documents: [document.canonicalURL: document],
            language: .zh
        )
        XCTAssertTrue(
            kept.isEmpty,
            "a line the page shares no text with is an invention, not a paraphrase"
        )
    }

    /// The gate must not throw away a real sentence the model merely shortened.
    /// One overlap is enough to keep it; the verbatim threshold still decides
    /// whether it renders in quote marks.
    func testShortenedRealSentenceStaysAsParaphrase() throws {
        let document = makeDocument(
            text: "分析师张伟表示，本季度销量好于预期，尤其是高端机型。"
        )
        let kept = ResearchCommentaryValidator.accepted(
            [raw(speaker: "张伟", quote: "本季度销量好于预期，尤其是高端机型，经销商补货意愿强烈。")],
            documents: [document.canonicalURL: document],
            language: .zh
        )
        let item = try XCTUnwrap(kept.first)
        XCTAssertFalse(item.quoteVerified, "the added clause is the model's, not the page's")
    }

    /// A short quotation is below the segment length, so a flat eight-character
    /// run test would drop it for being brief rather than for being invented.
    /// The required run scales down with the quote instead.
    func testShortRealQuoteSharesARunWithThePage() {
        let document = makeDocument(text: "张伟：销量好于预期。")
        let match = QuoteVerifier.match(quote: "销量好于预期", in: document.text)
        XCTAssertTrue(match.sharesRun)
        XCTAssertEqual(QuoteVerifier.requiredRun(for: "销量好于预期"), 3)
    }

    // MARK: - Quadrant composition

    /// At most one item per quadrant. "古今中外" is four positions, not a pile of
    /// quotes: two items in the same cell would just be the same view twice.
    func testAtMostOneItemPerQuadrant() {
        let document = makeDocument(
            text: "分析师张伟表示，本季度销量好于预期。分析师李娜表示，明年仍将增长。"
        )
        let kept = ResearchCommentaryValidator.accepted(
            [
                raw(speaker: "张伟", quote: "本季度销量好于预期。"),
                raw(speaker: "李娜", quote: "明年仍将增长。"),
            ],
            documents: [document.canonicalURL: document],
            language: .zh
        )
        XCTAssertEqual(kept.count, 1)
    }

    /// The reader-facing order is fixed: past-domestic, past-foreign,
    /// present-domestic, present-foreign. Rendering order must not depend on the
    /// model's array order, or the same report reads differently each run.
    func testOrderIsFixedByQuadrant() {
        let text = """
        历史学家王明表示，这类补贴退坡在 2016 年也发生过。
        外媒记者 John Smith 写道，类似的退坡在美国亦有先例。
        分析师张伟表示，本季度销量好于预期。
        Reuters 的 Alice Brown 认为，中国市场仍是关键。
        """
        let document = makeDocument(text: text)
        let kept = ResearchCommentaryValidator.accepted(
            [
                raw(speaker: "Alice Brown", quote: "中国市场仍是关键。",
                    era: .present, origin: .foreign),
                raw(speaker: "张伟", quote: "本季度销量好于预期。"),
                raw(speaker: "John Smith", quote: "类似的退坡在美国亦有先例。",
                    era: .past, origin: .foreign),
                raw(speaker: "王明", quote: "这类补贴退坡在 2016 年也发生过。",
                    era: .past, origin: .domestic),
            ],
            documents: [document.canonicalURL: document],
            language: .zh
        )
        XCTAssertEqual(
            kept.map(\.speaker),
            ["王明", "John Smith", "张伟", "Alice Brown"]
        )
    }

    /// IDs are numbered after filtering, so the reader sees C1…Cn with no holes.
    func testIdsAreRenumberedAfterRejectedItems() {
        let document = makeDocument(text: "分析师张伟表示，本季度销量好于预期。")
        let kept = ResearchCommentaryValidator.accepted(
            [
                raw(speaker: "不存在的人", quote: "本季度销量好于预期。"),
                raw(speaker: "张伟", quote: "本季度销量好于预期。"),
            ],
            documents: [document.canonicalURL: document],
            language: .zh
        )
        XCTAssertEqual(kept.map(\.id), ["C1"])
    }

    // MARK: - Report wiring

    /// Commentary reaches the report only through the validator. This is the
    /// composition test: the gates above are useless if nothing calls them, and
    /// a report carrying an unchecked opinion is exactly the failure the whole
    /// feature must avoid.
    func testValidatorWritesOnlyAcceptedCommentaryIntoTheReport() {
        let pageText = "分析师张伟表示，本季度销量好于预期。" + String(repeating: "补充背景。", count: 30)
        let document = ResearchDocument(
            url: "https://example.org/a",
            title: "Source",
            text: pageText,
            publishedAt: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: .direct
        )

        var draft = ResearchDraft()
        draft.summary = "摘要"
        draft.overview = "背景"
        draft.commentary = [
            CommentaryCandidate(
                era: .present,
                origin: .domestic,
                speaker: "张伟",
                role: "分析师",
                quote: "本季度销量好于预期。",
                url: "https://example.org/a",
                publishedAt: nil,
                evidenceID: nil
            ),
            CommentaryCandidate(
                era: .present,
                origin: .foreign,
                speaker: "Nobody Real",
                role: nil,
                quote: "这段话是编的。",
                url: "https://example.org/a",
                publishedAt: nil,
                evidenceID: nil
            ),
        ]

        let report = ReportValidator.validate(
            ReportValidationInput(
                draft: draft,
                candidates: [],
                plannedClaims: [],
                documents: [document.canonicalURL: document],
                allowedURLs: [document.canonicalURL],
                searchStatus: .succeeded,
                pagesRead: 1,
                truncated: false,
                depth: .deep,
                method: ResearchMethod(
                    providers: ["tavily"],
                    queries: ["q"],
                    pagesRead: 1,
                    recency: "30d",
                    generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    promptVersion: ResearchPrompts.version,
                    failovers: 0
                ),
                now: Date(timeIntervalSince1970: 1_700_000_000),
                language: .zh
            )
        )

        XCTAssertEqual(report.commentary.count, 1)
        XCTAssertEqual(report.commentary.first?.speaker, "张伟")
        XCTAssertEqual(report.commentary.first?.id, "C1")
        XCTAssertEqual(report.commentary.first?.role, "分析师")
    }

    /// A snippet is not a page. Gate 1 asks whether the speaker appears in the
    /// source body, and a search snippet is too short to answer that question —
    /// so commentary never survives on snippet-only material.
    func testCommentaryIsDroppedWhenOnlyASnippetWasAvailable() {
        let snippet = ResearchDocument(
            url: "https://example.org/a",
            title: "Source",
            text: "分析师张伟表示，本季度销量好于预期。",
            publishedAt: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: .snippet
        )
        var draft = ResearchDraft()
        draft.summary = "摘要"
        draft.commentary = [
            CommentaryCandidate(
                era: .present,
                origin: .domestic,
                speaker: "张伟",
                role: nil,
                quote: "本季度销量好于预期。",
                url: "https://example.org/a",
                publishedAt: nil,
                evidenceID: nil
            ),
        ]
        let report = ReportValidator.validate(
            ReportValidationInput(
                draft: draft,
                candidates: [],
                plannedClaims: [],
                documents: [snippet.canonicalURL: snippet],
                allowedURLs: [snippet.canonicalURL],
                searchStatus: .succeeded,
                pagesRead: 0,
                truncated: false,
                depth: .deep,
                method: ResearchMethod(
                    providers: ["tavily"],
                    queries: ["q"],
                    pagesRead: 0,
                    recency: "30d",
                    generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    promptVersion: ResearchPrompts.version,
                    failovers: 0
                ),
                now: Date(timeIntervalSince1970: 1_700_000_000),
                language: .zh
            )
        )
        XCTAssertTrue(report.commentary.isEmpty)
    }

    // MARK: - Rendering order

    /// The popup reads: facts (timeline) → what people think (commentary) →
    /// how it was checked (verification) → where it came from (sources).
    ///
    /// Commentary must not become a `ResearchReportSection`: `allCases` drives
    /// the workbench's chapter tab bar, and adding a case there would change a
    /// surface this work is required to leave untouched. It is an inserted
    /// block inside the popup's detail area instead.
    func testCommentaryRendersBetweenTimelineAndVerification() {
        let blocks = ResearchReportReader.detailBlocks(
            chapters: [.timeline, .verification, .sources],
            hasCommentary: true
        )
        XCTAssertEqual(blocks, [.chapter(.timeline), .commentary, .chapter(.verification), .chapter(.sources)])
    }

    /// A report with no surviving commentary must render nothing at all — no
    /// heading, no placeholder, no empty box. Four empty cells are worse than
    /// silence.
    func testEmptyCommentaryRendersNoBlock() {
        let blocks = ResearchReportReader.detailBlocks(
            chapters: [.timeline, .verification, .sources],
            hasCommentary: false
        )
        XCTAssertEqual(blocks, [.chapter(.timeline), .chapter(.verification), .chapter(.sources)])
    }

    /// The block is placed after whatever precedes verification, even when the
    /// timeline chapter is absent (a report whose nodes were all filtered out).
    func testCommentaryFallsAfterTheLastChapterBeforeVerification() {
        let blocks = ResearchReportReader.detailBlocks(
            chapters: [.verification, .sources],
            hasCommentary: true
        )
        XCTAssertEqual(blocks, [.commentary, .chapter(.verification), .chapter(.sources)])
    }

    // MARK: - Fixtures

    private func raw(
        speaker: String,
        quote: String,
        era: CommentaryEra = .present,
        origin: CommentaryOrigin = .domestic
    ) -> CommentaryCandidate {
        CommentaryCandidate(
            era: era,
            origin: origin,
            speaker: speaker,
            role: nil,
            quote: quote,
            url: "https://example.org/a",
            publishedAt: nil,
            evidenceID: nil
        )
    }

    private func makeDocument(text: String) -> ResearchDocument {
        ResearchDocument(
            url: "https://example.org/a",
            title: "Source",
            text: text,
            publishedAt: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: .direct
        )
    }
}
