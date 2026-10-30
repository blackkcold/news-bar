import XCTest
@testable import NewsBar

final class SelectionQueryPlannerTests: XCTestCase {
    func testParsesPlainJSON() {
        let plan = SelectionQueryPlanner.parse(#"{"kind":"event","needsLookup":true,"query":"微软 LG 电视 Copilot"}"#)
        XCTAssertEqual(plan?.kind, .event)
        XCTAssertEqual(plan?.needsLookup, true)
        XCTAssertEqual(plan?.query, "微软 LG 电视 Copilot")
    }

    func testParsesJSONInsideProseAndClampsQuery() {
        let long = String(repeating: "字", count: 120)
        let plan = SelectionQueryPlanner.parse("好的：{\"kind\":\"term\",\"needsLookup\":false,\"query\":\"\(long)\"}")
        XCTAssertEqual(plan?.kind, .term)
        XCTAssertEqual(plan?.needsLookup, false)
        XCTAssertEqual(plan?.query.count, 80)
    }

    func testUnknownKindFallsBackAndDefaultsToLookup() {
        let plan = SelectionQueryPlanner.parse(#"{"kind":"gossip","query":""}"#)
        XCTAssertEqual(plan?.kind, .term)
        XCTAssertEqual(plan?.needsLookup, true)
    }

    func testGarbageIsNotAPlan() {
        XCTAssertNil(SelectionQueryPlanner.parse("not json"))
        XCTAssertNil(SelectionQueryPlanner.parse(""))
    }

    func testDefaultModeIsOffline() {
        XCTAssertEqual(AppSettings().selectionWebMode, .offline)
    }
}
