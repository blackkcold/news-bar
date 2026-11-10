import XCTest
@testable import NewsBar

final class EvidenceRetrieverTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        var query: SearchQuery?
        var calls = 0
    }

    private func query(
        _ text: String,
        role: EvidenceQuery.Role = .original,
        recency: SearchRecency = .month
    ) -> EvidenceQuery {
        EvidenceQuery(text: text, recency: recency, role: role)
    }

    private func hit(_ number: Int, rank: Int? = nil) -> SearchHit {
        SearchHit(
            url: "https://source\(number).example/story",
            title: "Source \(number)",
            snippet: "",
            provider: .tavily,
            providerRank: rank ?? number
        )
    }

    private func plan(
        _ queries: [EvidenceQuery],
        recency: SearchRecency = .month
    ) -> EvidenceQueryPlan {
        EvidenceQueryPlan(queries: queries, recency: recency)
    }

    func testVariantsShareOneTicket() async {
        let ticket = SearchAttemptTicket(limit: 6)
        let result = await EvidenceRetriever.retrieve(
            plan: plan([
                query("a"),
                query("b", role: .clause),
                query("c", role: .quotedEntity),
            ]),
            search: { _, ticket in
                // The real router charges up to two dispatches per query. The
                // fake charges the same ceiling so the shared budget is visible.
                _ = ticket.consume()
                _ = ticket.consume()
                throw SearchUnavailableError(failures: [])
            },
            ticket: ticket,
            candidateCap: 6,
            language: .zh
        )
        XCTAssertEqual(ticket.used, 6)
        XCTAssertEqual(result.attemptsUsed, 6)
        XCTAssertTrue(result.searchUnavailable)
        XCTAssertEqual(result.outcomes.filter(\.failed).count, 3)
    }

    func testVariantFindsWhenOriginalIsEmpty() async {
        let found = hit(1)
        let result = await EvidenceRetriever.retrieve(
            plan: plan([
                query("original"),
                query("variant", role: .clause),
            ]),
            search: { query, _ in
                query.text == "original" ? [] : [found]
            },
            ticket: SearchAttemptTicket(limit: 6),
            candidateCap: 5,
            language: .zh
        )
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates.first?.hit.url, found.url)
        XCTAssertEqual(result.candidates.first?.discoveredBy, .clause)
        XCTAssertEqual(result.foundCount, 1)
        XCTAssertFalse(result.searchUnavailable)
    }

    func testDuplicateHitsKeepTheBestRank() async {
        let weaker = hit(1, rank: 4)
        let better = hit(1, rank: 1)
        let result = await EvidenceRetriever.retrieve(
            plan: plan([
                query("original"),
                query("variant", role: .clause),
            ]),
            search: { query, _ in
                query.text == "original" ? [weaker] : [better]
            },
            ticket: SearchAttemptTicket(limit: 6),
            candidateCap: 5,
            language: .zh
        )
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates.first?.hit.providerRank, 1)
        XCTAssertEqual(result.uniqueCount, 1)
    }

    func testSearchQueryUsesPlanRecencyAndCandidateCap() async {
        let box = Box()
        _ = await EvidenceRetriever.retrieve(
            plan: plan([query("今天的新消息", recency: .day)], recency: .day),
            search: { query, _ in
                box.query = query
                return []
            },
            ticket: SearchAttemptTicket(limit: 6),
            candidateCap: 5,
            language: .zh
        )
        XCTAssertEqual(box.query?.recency, .day)
        XCTAssertEqual(box.query?.maxResults, 5)
        XCTAssertEqual(box.query?.language, AppLanguage.zh.bcp47)
    }

    func testEmptyPlanDoesNotCallSearch() async {
        let box = Box()
        let result = await EvidenceRetriever.retrieve(
            plan: .empty,
            search: { _, _ in
                box.calls += 1
                return []
            },
            ticket: SearchAttemptTicket(limit: 6),
            candidateCap: 5,
            language: .zh
        )
        XCTAssertEqual(box.calls, 0)
        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertFalse(result.searchUnavailable)
    }
}
