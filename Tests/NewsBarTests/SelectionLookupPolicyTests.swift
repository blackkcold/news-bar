import XCTest
@testable import NewsBar

/// The `.auto` contract: Settings promises that news, figures and uncertain
/// claims go online, so the planner's own `needsLookup` flag cannot be the last
/// word. These cases are the boundary between "explain it" and "look it up".
final class SelectionLookupPolicyTests: XCTestCase {
    private func plan(
        _ kind: AnswerKind,
        needsLookup: Bool,
        query: String = "检索词"
    ) -> SelectionPlan {
        SelectionPlan(kind: kind, needsLookup: needsLookup, query: query)
    }

    func testEventsFiguresAndComparisonsLookUpEvenWhenTheModelSaysNo() {
        for kind in [AnswerKind.event, .number, .comparison] {
            XCTAssertTrue(
                SelectionLookupPolicy.shouldLookUp(plan(kind, needsLookup: false), in: "普通的一段话"),
                "\(kind) must not be talked out of a look-up"
            )
        }
    }

    func testAPlainTermStaysOffline() {
        let text = "熵是热力学中衡量系统无序程度的物理量。"
        XCTAssertFalse(
            SelectionLookupPolicy.shouldLookUp(
                plan(.term, needsLookup: false, query: "熵"),
                in: text
            )
        )
    }

    func testATermThatNamesAReleaseGoesOnline() {
        let text = "HomePod mini 2 时隔六年更新，售价 749 元。"
        XCTAssertTrue(
            SelectionLookupPolicy.shouldLookUp(
                plan(.term, needsLookup: false, query: "HomePod mini 2"),
                in: text
            )
        )
    }

    func testAYearInThePassageIsEnoughToGoOnline() {
        XCTAssertTrue(SelectionLookupPolicy.hasFreshnessCue(in: "2026 年上市"))
        XCTAssertTrue(SelectionLookupPolicy.hasFreshnessCue(in: "2026年上市"))
        XCTAssertFalse(SelectionLookupPolicy.hasFreshnessCue(in: "熵的定义"))
    }

    func testAMissingPlanIsNotANo() {
        XCTAssertTrue(
            SelectionLookupPolicy.shouldLookUp(nil, in: "随便一段话"),
            "a failed classification must fall forward to the web"
        )
    }

    func testAnEmptyQueryGoesOnline() {
        XCTAssertTrue(
            SelectionLookupPolicy.shouldLookUp(
                plan(.term, needsLookup: false, query: "   "),
                in: "熵"
            ),
            "a plan without a query cannot be searched, so the text is the query"
        )
    }

    func testAHowToWithoutAProductCueStaysOffline() {
        XCTAssertFalse(
            SelectionLookupPolicy.shouldLookUp(
                plan(.howto, needsLookup: false, query: "怎么煮咖啡"),
                in: "先磨豆，再注水。"
            )
        )
    }
}
