import XCTest
@testable import NewsBar

final class QueryPlannerTests: XCTestCase {
    private func plan(
        _ question: String,
        page: AISearchPageContext? = nil
    ) -> EvidenceQueryPlan {
        QueryPlanner.plan(
            question: question,
            scope: .web,
            page: page,
            language: .zh
        )
    }

    func testExplicitTimeWordsWin() {
        XCTAssertEqual(plan("今天有什么新进展？").recency, .day)
        XCTAssertEqual(plan("刚刚发布的模型怎么样？").recency, .day)
        XCTAssertEqual(plan("本周有哪些更新？").recency, .week)
        XCTAssertEqual(plan("今年有哪些变化？").recency, .year)
    }

    func testConceptualQuestionsUseAllTime() {
        XCTAssertEqual(plan("量子计算是什么？").recency, .all)
        XCTAssertEqual(plan("这两个方案有什么区别？").recency, .all)
        XCTAssertEqual(plan("它是如何工作的？").recency, .all)
    }

    func testDefaultNewsQuestionStaysAMonth() {
        XCTAssertEqual(plan("苹果发布新机").recency, .month)
    }

    func testMultiClauseAddsAtMostTwoVariants() {
        let result = plan("苹果发布新机？价格是多少？什么时候开卖？")
        XCTAssertEqual(result.queries.count, 3)
        XCTAssertEqual(result.queries.map(\.role), [.original, .clause, .clause])
        XCTAssertEqual(result.queries[0].text, "苹果发布新机？价格是多少？什么时候开卖？")
    }

    func testQuotedPhraseAddsOneEntityQuery() {
        let result = plan("“量子计算”有什么新进展？")
        XCTAssertEqual(result.queries.count, 2)
        XCTAssertEqual(result.queries.last?.role, .quotedEntity)
        XCTAssertEqual(result.queries.last?.text, "量子计算")
    }

    func testDeicticQuestionWithPageTitleAddsTitleQuery() {
        let result = plan(
            "这个怎么用？",
            page: AISearchPageContext(
                url: "https://example.com/a",
                title: "新功能说明",
                text: "正文"
            )
        )
        XCTAssertEqual(result.queries.count, 2)
        XCTAssertEqual(result.queries.last?.role, .pageTitle)
        XCTAssertEqual(result.queries.last?.text, "新功能说明")
    }

    func testNonDeicticQuestionDoesNotAddPageTitle() {
        let result = plan(
            "苹果发布新机？",
            page: AISearchPageContext(
                url: "https://example.com/a",
                title: "新功能说明",
                text: "正文"
            )
        )
        XCTAssertEqual(result.queries.count, 1)
        XCTAssertEqual(result.queries.first?.role, .original)
    }

    func testQueriesAreDeduplicatedAfterNormalization() {
        let result = plan(
            "“量子计算”这个怎么用？",
            page: AISearchPageContext(
                url: "https://example.com/a",
                title: "量子计算",
                text: "正文"
            )
        )
        XCTAssertEqual(result.queries.count, 2)
        XCTAssertEqual(result.queries.filter { $0.text == "量子计算" }.count, 1)
    }

    func testEmptyQuestionReturnsEmptyPlan() {
        XCTAssertTrue(plan("   ").queries.isEmpty)
        XCTAssertTrue(QueryPlanner.plan(
            question: "",
            scope: .currentPage,
            page: nil,
            language: .en
        ).queries.isEmpty)
    }

    func testCurrentPageScopeKeepsOneQuery() {
        let result = QueryPlanner.plan(
            question: "这个怎么用？",
            scope: .currentPage,
            page: AISearchPageContext(url: "https://e.com/a", title: "T", text: "正文"),
            language: .zh
        )
        XCTAssertEqual(result.queries.count, 1)
        XCTAssertEqual(result.queries.first?.role, .original)
    }

    // MARK: - Page overview

    func testOverviewUsesTitleAndFirstSentence() {
        let result = QueryPlanner.planOverview(
            title: "苹果发布会",
            excerpt: "新机将在十月发布。价格尚未公布。",
            language: .zh
        )
        XCTAssertEqual(result.queries.count, 2)
        XCTAssertEqual(result.queries[0].role, .original)
        XCTAssertEqual(result.queries[0].text, "苹果发布会")
        XCTAssertEqual(result.queries[1].role, .clause)
        XCTAssertEqual(result.queries[1].text, "新机将在十月发布")
        XCTAssertEqual(result.recency, .month)
    }

    func testOverviewWithoutTitleUsesExcerptAsOriginal() {
        let result = QueryPlanner.planOverview(
            title: "   ",
            excerpt: "第一句。第二句。",
            language: .zh
        )
        XCTAssertEqual(result.queries.count, 1)
        XCTAssertEqual(result.queries.first?.role, .original)
        XCTAssertEqual(result.queries.first?.text, "第一句")
    }

    func testOverviewEmptyInputReturnsEmptyPlan() {
        XCTAssertTrue(
            QueryPlanner.planOverview(title: "", excerpt: "  ", language: .en).queries.isEmpty
        )
    }

    func testOverviewCapsAtTwoQueries() {
        let result = QueryPlanner.planOverview(
            title: String(repeating: "标题", count: 200),
            excerpt: "第一句。第二句。第三句。",
            language: .zh
        )
        XCTAssertEqual(result.queries.count, 2)
    }
}
