import XCTest
@testable import NewsBar

final class ResearchReportParserTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 12))!
    }

    func testPlanningParsesFencedJSONWithProse() {
        let text = """
        Here is the plan:
        ```json
        {"claims":["某公司于十月发布新品","新品定价低于上一代"],"queries":[{"text":"某公司 新品 发布","recency":"7d"},{"text":"某公司 新品 定价","recency":"30d"}]}
        ```
        """
        let plan = ResearchReportParser.plan(from: text)
        XCTAssertEqual(plan?.claims.count, 2)
        XCTAssertEqual(plan?.queries.count, 2)
        XCTAssertEqual(plan?.queries.first?.recency, .week)
        XCTAssertEqual(plan?.queries.last?.recency, .month)
    }

    func testExtractionParsesStanceAndDate() {
        let text = """
        {"evidence":[
          {"source":1,"quote":"公司确认新品将于十月发布。","claim":"十月发布","stance":"supports","publishedAt":"2026-10-01"},
          {"source":2,"quote":"渠道方否认了该定价。","claim":"定价低于上一代","stance":"refutes","publishedAt":"2026年10月3日"}
        ]}
        """
        let items = ResearchReportParser.evidence(from: text, now: now)
        XCTAssertEqual(items?.count, 2)
        XCTAssertEqual(items?.first?.sourceIndex, 1)
        XCTAssertEqual(items?.first?.stance, .supports)
        XCTAssertNotNil(items?.first?.publishedAt)
        XCTAssertEqual(items?.last?.stance, .refutes)
        XCTAssertNotNil(items?.last?.publishedAt)
    }

    func testSynthesisParsesTimelineClaimsAndInlineEvidence() {
        let text = """
        ```json
        {
          "summary": "事件已获多方确认。",
          "overview": "从发布到渠道确认的完整过程。",
          "timeline": [
            {"date":"2026-10-01","title":"发布","detail":"公司发布新品。","evidenceIDs":["E1"],"confidence":"high"},
            {"date":"10月3日","title":"渠道确认","detail":"渠道确认到货。","evidenceIDs":["E2","E9"],"confidence":"low"}
          ],
          "claims":[{"claim":"十月发布","status":"supports","evidenceIDs":["E1"],"note":""}],
          "evidence":[{"source":1,"quote":"公司确认新品将于十月发布。","claim":"十月发布","stance":"supports"}],
          "conflicts":["定价说法不一致"],
          "missing":["官方定价"],
          "limitations":"仅有公开报道。"
        }
        ```
        """
        let draft = ResearchReportParser.synthesis(from: text, now: now)
        XCTAssertEqual(draft?.summary, "事件已获多方确认。")
        XCTAssertEqual(draft?.timeline.count, 2)
        XCTAssertEqual(draft?.timeline.first?.evidenceIDs, ["E1"])
        XCTAssertEqual(draft?.timeline.first?.confidence, .high)
        XCTAssertEqual(
            draft?.timeline.last?.sortDate.map { TimelineDateParser.dayKey($0, calendar: calendar) },
            "2026-10-03"
        )
        XCTAssertEqual(draft?.claims.first?.status, .supports)
        XCTAssertEqual(draft?.inlineEvidence.count, 1)
        XCTAssertEqual(draft?.conflicts, ["定价说法不一致"])
        XCTAssertEqual(draft?.missing, ["官方定价"])
        XCTAssertEqual(draft?.limitations, "仅有公开报道。")
    }

    func testSynthesisRejectsObjectWithoutRenderableContent() {
        XCTAssertNil(ResearchReportParser.synthesis(from: #"{"summary":"","overview":"","timeline":[]}"#))
        XCTAssertNil(ResearchReportParser.synthesis(from: "not json"))
    }

    func testJSONExtractionIgnoresBracesInsideStrings() {
        let text = #"prefix {"summary":"brace } inside string","overview":"x"} suffix"#
        let object = ResearchJSON.object(from: text)
        XCTAssertEqual(object?["summary"] as? String, "brace } inside string")
    }

    func testJSONExtractionHandlesEscapedQuotes() {
        let text = #"{"summary":"he said \"ok\" {not a brace}","overview":"y"}"#
        let object = ResearchJSON.object(from: text)
        XCTAssertEqual(object?["summary"] as? String, #"he said "ok" {not a brace}"#)
    }
}
