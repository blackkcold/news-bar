import XCTest
@testable import NewsBar

/// A timeline title that carries a number is the single highest-value thing on
/// the popup's first screen: it turns "an event happened" into "sales fell 17%".
/// The risk is symmetric — the model can invent the number just as easily — so
/// the check is deterministic and the penalty is a limitation line, never a
/// deleted node.
final class TimelineTitleFiguresTests: XCTestCase {
    func testTitleNumberIsSupportedByItsCitedQuote() {
        let report = makeReport(
            title: "销量降 17%",
            quotes: ["苹果大中华区营收同比下滑 17%，为四个季度以来首次。"]
        )
        XCTAssertEqual(TimelineTitleFigures.unsupportedTitles(in: report), [])
    }

    func testTitleNumberMissingFromEveryCitedQuoteIsReported() {
        let report = makeReport(
            title: "销量降 17%",
            quotes: ["苹果大中华区营收出现下滑，公司未披露具体幅度。"]
        )
        XCTAssertEqual(
            TimelineTitleFigures.unsupportedTitles(in: report),
            ["销量降 17%"]
        )
    }

    /// A title without a number makes no numeric claim, so it cannot make a
    /// false one. The check must stay silent rather than treat every title as
    /// suspect.
    func testTitleWithoutNumbersIsNeverReported() {
        let report = makeReport(
            title: "公司确认新品发布",
            quotes: ["公司确认新品将于十月发布。"]
        )
        XCTAssertTrue(TimelineTitleFigures.unsupportedTitles(in: report).isEmpty)
    }

    /// Thousands separators differ by locale ("2,840" vs "2840"), and a number
    /// is not made up because the quote formats it differently.
    func testSeparatorDifferencesDoNotCountAsUnsupported() {
        let report = makeReport(
            title: "销量 2840 万台",
            quotes: ["今年双十一手机销量 2,840 万台。"]
        )
        XCTAssertTrue(TimelineTitleFigures.unsupportedTitles(in: report).isEmpty)
    }

    /// Every number in the title must be supported, not merely one of them:
    /// a title is a single claim, and half of it being true is not support.
    func testEveryNumberInTheTitleMustBeSupported() {
        let report = makeReport(
            title: "销量 2840 万台，同比降 17%",
            quotes: ["今年双十一手机销量 2,840 万台。"]
        )
        XCTAssertEqual(
            TimelineTitleFigures.unsupportedTitles(in: report),
            ["销量 2840 万台，同比降 17%"]
        )
    }

    /// The check reads only the quotes this node cites. A number that exists
    /// elsewhere in the report does not support this node's claim.
    func testOnlyTheCitedQuotesCount() {
        var report = makeReport(
            title: "销量降 17%",
            quotes: ["这段引文没有数字。"]
        )
        // A second node cites a quote that does contain 17%.
        report.timeline.append(
            TimelineNode(
                date: "10月9日",
                title: "另一件事",
                detail: "",
                evidenceIDs: ["E2"],
                confidence: .high
            )
        )
        report.evidence.append(makeEvidence(id: "E2", quote: " competitor 增长 17%。"))
        XCTAssertEqual(
            TimelineTitleFigures.unsupportedTitles(in: report),
            ["销量降 17%"],
            "A number in another node's quote must not launder this node's title."
        )
    }

    /// A node with no citations already has its own limitation ("no public
    /// source yet"). Repeating it as a numeric problem would report one defect
    /// twice and push the reader toward the wrong conclusion about the number.
    func testUncitedNodeIsNotReportedAsANumericProblem() {
        let report = BurstResearch(
            summary: "摘要。",
            timeline: [
                TimelineNode(date: "10月1日", title: "销量降 17%", detail: "", evidenceIDs: [])
            ],
            searchStatus: .succeeded
        )
        XCTAssertTrue(TimelineTitleFigures.unsupportedTitles(in: report).isEmpty)
    }

    /// A number that exists on the cited page still counts when the report
    /// folded that quote away.
    ///
    /// Measured on a real deep run: two of eight titles were flagged for figures
    /// their own pages did contain — "华为同比涨29%" and "荣耀10月安卓冠军".
    /// `mergeSameURL` keeps one row per page, so the quote carrying the figure
    /// was folded into the same row as a different quote from that page and the
    /// check could no longer see it. A warning that fires on correct titles is
    /// worse than no warning: it teaches the reader to skip the line.
    func testFigureFromAFoldedQuoteOnTheSamePageCounts() {
        var report = makeReport(
            title: "华为同比涨29%",
            quotes: ["Counterpoint 说整体销量暴跌 17%，不是微跌。"]
        )
        let canonical = report.evidence[0].canonicalURL
        XCTAssertEqual(
            TimelineTitleFigures.unsupportedTitles(
                in: report,
                extraQuotesByCanonicalURL: [canonical: ["华为是唯一正增长的主流厂商，同比涨29%。"]]
            ),
            []
        )
    }

    /// The escape hatch must not become a leak: quotes from other pages still
    /// cannot launder a title, or a report with many sources could never be
    /// wrong about a number.
    func testFoldedQuotesFromAnotherPageDoNotCount() {
        let report = makeReport(
            title: "华为同比涨29%",
            quotes: ["这段引文没有数字。"]
        )
        XCTAssertEqual(
            TimelineTitleFigures.unsupportedTitles(
                in: report,
                extraQuotesByCanonicalURL: ["https://other.example/page": ["华为同比涨29%。"]]
            ),
            ["华为同比涨29%"]
        )
    }

    // MARK: - Fixtures

    private func makeReport(title: String, quotes: [String]) -> BurstResearch {
        var evidence: [EvidenceItem] = []
        var ids: [String] = []
        for (index, quote) in quotes.enumerated() {
            let id = "E\(index + 1)"
            ids.append(id)
            evidence.append(makeEvidence(id: id, quote: quote))
        }
        return BurstResearch(
            summary: "摘要。",
            timeline: [
                TimelineNode(
                    date: "10月1日",
                    title: title,
                    detail: "",
                    evidenceIDs: ids,
                    confidence: .high
                )
            ],
            searchStatus: .succeeded,
            evidence: evidence
        )
    }

    private func makeEvidence(id: String, quote: String) -> EvidenceItem {
        EvidenceItem(
            id: id,
            url: "https://example.org/\(id.lowercased())",
            canonicalURL: "https://example.org/\(id.lowercased())",
            domain: "example.org",
            title: "Source \(id)",
            publishedAt: nil,
            quote: quote,
            quoteVerified: true,
            stance: .supports,
            tier: .major,
            syndicationGroup: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
