import XCTest
@testable import NewsBar

/// The gap round exists to answer one question: after extraction, which reader
/// questions still have no answer, and what is the cheapest query that might
/// find one? Everything here is deterministic on purpose — it costs no AI call,
/// and a test can state exactly which query a gap produces.
final class ResearchGapRoundTests: XCTestCase {
    // MARK: - What counts as a gap

    /// An angle with zero facts and an angle with one fact are both gaps, but
    /// they are not the same gap: one needs a source, the other needs a second
    /// source. Both are worth a query; neither is worth two.
    func testUncoveredAndPartialAnglesBothProduceGaps() {
        let gaps = ResearchPipeline.gapAngles(
            covered: [.time],
            partial: [.structure]
        )
        XCTAssertEqual(Set(gaps), [.compare, .structure, .cause, .next])
    }

    func testNoGapWhenEveryAngleIsCovered() {
        XCTAssertTrue(
            ResearchPipeline.gapAngles(
                covered: Set(ResearchAngle.allCases),
                partial: []
            ).isEmpty
        )
    }

    // MARK: - Queries

    /// Each gap becomes one query naming the question, not a paraphrase of the
    /// event. "某事件 排名 份额" asks for something round one did not.
    func testEachGapBecomesOneQueryForThatQuestion() throws {
        let queries = ResearchPipeline.gapQueries(
            title: "双十一手机销量",
            angles: [.structure],
            language: .zh,
            excluding: [],
            limit: 4
        )
        let text = try XCTUnwrap(queries.first?.text)
        XCTAssertEqual(queries.count, 1)
        XCTAssertTrue(text.contains("双十一手机销量"))
        XCTAssertTrue(
            text.contains("排名"),
            "The query must name the missing question, not repeat the topic. Got: \(text)"
        )
    }

    /// A gap query that repeats round one spends money to fetch what is already
    /// in hand. Literal overlap is cheap to detect and worth rejecting.
    func testQueryRepeatingAnEarlierOneIsSkipped() {
        let first = ResearchPipeline.gapQueries(
            title: "双十一手机销量",
            angles: [.structure],
            language: .zh,
            excluding: [],
            limit: 4
        )
        let again = ResearchPipeline.gapQueries(
            title: "双十一手机销量",
            angles: [.structure, .cause],
            language: .zh,
            excluding: first.map(\.text),
            limit: 4
        )
        XCTAssertFalse(again.contains { $0.text == first.first?.text })
        XCTAssertEqual(again.count, 1, "Only the angle that was not already asked survives.")
    }

    /// The limit is a budget, not a suggestion: a deep run with five gaps and a
    /// budget of four must not emit five queries.
    func testLimitCapsTheQueryCount() {
        let queries = ResearchPipeline.gapQueries(
            title: "Event",
            angles: ResearchAngle.allCases,
            language: .en,
            excluding: [],
            limit: 2
        )
        XCTAssertEqual(queries.count, 2)
    }

    func testZeroLimitProducesNoQueries() {
        XCTAssertTrue(
            ResearchPipeline.gapQueries(
                title: "Event",
                angles: ResearchAngle.allCases,
                language: .en,
                excluding: [],
                limit: 0
            ).isEmpty
        )
    }

    /// Quick depth never runs a gap round, and the profile is where that is
    /// decided — not a scattered `if depth == .quick` at the call site.
    func testOnlyStandardAndDeepRunAGapRound() {
        XCTAssertEqual(DepthProfile.profile(for: .quick).gapQueryCount, 0)
        XCTAssertGreaterThan(DepthProfile.profile(for: .standard).gapQueryCount, 0)
        XCTAssertGreaterThan(DepthProfile.profile(for: .deep).gapQueryCount, 0)
    }

    /// The gap round is additive to the event search, and the request ceiling
    /// has to cover both rounds or the second one is silently starved.
    func testRequestCeilingCoversBothRounds() {
        let deep = DepthProfile.profile(for: .deep)
        XCTAssertGreaterThanOrEqual(
            DepthProfile.maxSearchHTTPCallsPerTask,
            deep.queryCount + deep.gapQueryCount,
            "A ceiling below the planned query count makes the gap round unreachable."
        )
    }

    // MARK: - Synthesis remedy

    /// Two AI calls are reserved for writing the report: the attempt and one
    /// remedy. Before this was bounded, a truncated response used the 16k retry
    /// and then — if that text still did not parse — asked for a repair, which
    /// is three calls against two reserved.
    ///
    /// Measured on a real deep run whose gap round had spent its allowance: the
    /// third call was refused by the budget guard and the whole pass failed with
    /// "AI request failed" after every page had already been read. Choosing one
    /// remedy keeps the worst case at exactly two.
    func testSynthesisPicksAtMostOneRemedy() {
        // Truncation is a length problem, so a larger budget is the remedy that
        // can actually fix it.
        XCTAssertEqual(
            ResearchPipeline.synthesisRemedy(truncated: true, parsed: false),
            .enlargeBudget
        )
        // Complete but unparseable text needs re-emission, not more room.
        XCTAssertEqual(
            ResearchPipeline.synthesisRemedy(truncated: false, parsed: false),
            .repair
        )
        // A response that already parsed needs no remedy at all.
        XCTAssertEqual(
            ResearchPipeline.synthesisRemedy(truncated: false, parsed: true),
            .none
        )
        // Truncated but still parseable: retry anyway. Parsing does not prove
        // the end of the report survived, and the enlarged budget is what
        // recovers it. Skipping this shipped incomplete reports as a limitation.
        XCTAssertEqual(
            ResearchPipeline.synthesisRemedy(truncated: true, parsed: true),
            .enlargeBudget
        )
    }

    /// One attempt plus one remedy can never exceed the two reserved calls, so
    /// the reservation and the code agree. This is the assertion that would have
    /// caught the original bug: the flow could reach three.
    func testSynthesisWorstCaseFitsTheReservation() {
        XCTAssertLessThanOrEqual(
            ResearchPipeline.maxSynthesisAICalls,
            ResearchPipeline.reservedAICallsForSynthesis,
            "Reserving fewer calls than synthesis can spend is what starved the gap round and then synthesis itself."
        )
    }

    // MARK: - Budget

    /// The gap round must never eat the calls that write the report. If there is
    /// not enough budget left for synthesis plus one repair, the round is
    /// skipped: a thin report beats no report.
    func testGapRoundIsSkippedWhenSynthesisBudgetIsAtRisk() {
        XCTAssertFalse(
            ResearchPipeline.canAffordGapRound(aiCalls: 6, aiCallLimit: 8),
            "Two calls left: one synthesis, one repair — nothing spare."
        )
        XCTAssertTrue(
            ResearchPipeline.canAffordGapRound(aiCalls: 3, aiCallLimit: 8),
            "Five calls left: one extraction batch, synthesis and repair all fit."
        )
    }

    /// Measured on a real deep run on this machine: planning took one AI call,
    /// four extraction batches took four, so five of eight were spent. The gap
    /// round then read five pages, which is three extraction batches, and spent
    /// the last three calls — leaving nothing for synthesis. The run ended
    /// `failed` with "AI request failed" and no report at all.
    ///
    /// `canAffordGapRound` was not wrong, it was insufficient: it asked "is
    /// there a spare call?" and never said how many. The round has to be given
    /// an allowance, and the allowance has to exclude the two calls synthesis
    /// and repair still need.
    func testGapRoundAllowanceExcludesTheSynthesisReserve() {
        // 8 total, 5 used, 3 left, 2 reserved → 1 spendable.
        XCTAssertEqual(ResearchPipeline.gapRoundAllowance(aiCalls: 5, aiCallLimit: 8), 1)
        XCTAssertEqual(ResearchPipeline.gapRoundAllowance(aiCalls: 2, aiCallLimit: 8), 4)
        XCTAssertEqual(ResearchPipeline.gapRoundAllowance(aiCalls: 6, aiCallLimit: 8), 0)
        XCTAssertEqual(ResearchPipeline.gapRoundAllowance(aiCalls: 8, aiCallLimit: 8), 0)
        // A negative allowance must never wrap into an enormous page budget.
        XCTAssertEqual(ResearchPipeline.gapRoundAllowance(aiCalls: 20, aiCallLimit: 8), 0)
    }

    /// One extraction batch is two pages and one AI call, so the page budget is
    /// derived from the call allowance rather than from `pageCount`. Without
    /// this, a deep pass reads up to eight gap pages — four batches — no matter
    /// how little budget is left.
    func testGapPageBudgetFollowsTheCallAllowance() {
        XCTAssertEqual(ResearchPipeline.gapPageBudget(allowance: 1, pageLimit: 8), 2)
        XCTAssertEqual(ResearchPipeline.gapPageBudget(allowance: 2, pageLimit: 8), 4)
        XCTAssertEqual(ResearchPipeline.gapPageBudget(allowance: 4, pageLimit: 8), 8)
        XCTAssertEqual(ResearchPipeline.gapPageBudget(allowance: 0, pageLimit: 8), 0)
        // The profile's page count stays a hard ceiling.
        XCTAssertEqual(ResearchPipeline.gapPageBudget(allowance: 9, pageLimit: 4), 4)
    }

    // MARK: - Signal

    /// Coverage is only meaningful when some fact carried an angle. A report
    /// whose facts are unlabelled and whose claims match no keyword has *no*
    /// signal: every angle looks empty, so a gap round would spend its whole
    /// allowance on a guess. No signal, no spend.
    func testNoAngleSignalMeansNoGapRound() {
        let document = makeDocument(text: "公司确认新品将于十月发布。")
        let candidates = [
            makeCandidate(quote: "公司确认新品将于十月发布。", angle: nil, claim: "十月发布")
        ]
        let coverage = ResearchAngleCoverage.evaluate(
            candidates,
            documents: [document.canonicalURL: document]
        )
        XCTAssertEqual(coverage.labelledFacts, 0)
        XCTAssertTrue(coverage.covered.isEmpty)
        XCTAssertTrue(coverage.partial.isEmpty)
    }

    func testLabelledFactsAreCountedAsSignal() {
        let document = makeDocument(text: "去年销量 2,840 万台。")
        let coverage = ResearchAngleCoverage.evaluate(
            [makeCandidate(quote: "去年销量 2,840 万台。", angle: .time)],
            documents: [document.canonicalURL: document]
        )
        XCTAssertEqual(coverage.labelledFacts, 1)
        XCTAssertEqual(coverage.partial, [.time])
    }

    // MARK: - Fixtures

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

    private func makeCandidate(
        quote: String,
        angle: ResearchAngle?,
        claim: String = ""
    ) -> EvidenceCandidate {
        EvidenceCandidate(
            url: "https://example.org/a",
            title: "Source",
            quote: quote,
            claim: claim,
            stance: .supports,
            angle: angle,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
