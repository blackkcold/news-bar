import XCTest
@testable import NewsBar

final class ResearchAngleCoverageTests: XCTestCase {
    // MARK: - Parsing

    /// `angle` is an addition to an existing contract: a model that has never
    /// heard of it must keep working, so a missing or unknown value is nil
    /// rather than a parse failure.
    func testParserReadsAngleAndToleratesItsAbsence() throws {
        let text = """
        {"evidence":[
          {"source":1,"quote":"去年销量 2,840 万台。","claim":"销量","stance":"supports","angle":"time"},
          {"source":2,"quote":"黑五增长 6%。","claim":"对比","stance":"supports","angle":"compare"},
          {"source":2,"quote":"没有角度的旧格式。","claim":"旧","stance":"unclear"},
          {"source":3,"quote":"模型编了一个角度。","claim":"怪","stance":"supports","angle":"vibes"}
        ]}
        """
        let evidence = try XCTUnwrap(ResearchReportParser.evidence(from: text))
        XCTAssertEqual(evidence.count, 4)
        XCTAssertEqual(evidence[0].angle, .time)
        XCTAssertEqual(evidence[1].angle, .compare)
        XCTAssertNil(evidence[2].angle)
        XCTAssertNil(evidence[3].angle, "An unknown angle is not a crash; it is just unlabelled.")
    }

    /// The five angles are the questions a reader actually asks. Their raw
    /// values are the prompt's vocabulary, so they must not drift.
    func testAnglesAreTheFiveReaderQuestions() {
        XCTAssertEqual(
            ResearchAngle.allCases.map(\.rawValue),
            ["time", "compare", "structure", "cause", "next"]
        )
    }

    // MARK: - Coverage

    /// A is the count of covered angles, and one quote is not coverage: two
    /// independent facts are what makes an angle worth reading. This is the
    /// gate the old plan got wrong by paying two queries per angle.
    func testAnAngleNeedsTwoVerifiedFactsToCount() {
        let document = makeDocument(text: "去年销量 2,840 万台。今年销量 2,400 万台。黑五增长 6%。")
        let one = [makeCandidate(quote: "去年销量 2,840 万台。", angle: .time)]
        XCTAssertEqual(
            ResearchAngleCoverage.covered(one, documents: [document.canonicalURL: document]),
            []
        )

        let two = one + [makeCandidate(quote: "今年销量 2,400 万台。", angle: .time)]
        XCTAssertEqual(
            ResearchAngleCoverage.covered(two, documents: [document.canonicalURL: document]),
            [.time]
        )
    }

    /// A quote that the page does not literally contain proves nothing, so it
    /// must not cover an angle. Same verifier as `EvidenceItem.quoteVerified`.
    func testUnverifiedQuotesDoNotCoverAnAngle() {
        let document = makeDocument(text: "去年销量 2,840 万台。")
        let candidates = [
            makeCandidate(quote: "去年销量 2,840 万台。", angle: .time),
            makeCandidate(quote: "这段原文并不在页面里。", angle: .time),
        ]
        XCTAssertEqual(
            ResearchAngleCoverage.covered(candidates, documents: [document.canonicalURL: document]),
            []
        )
    }

    /// The same quote twice is one fact, not two. Extraction repeats a good
    /// quote across batches often enough that this would otherwise hand out
    /// coverage for free.
    func testDuplicateQuotesCountOnce() {
        let document = makeDocument(text: "去年销量 2,840 万台。")
        let candidates = [
            makeCandidate(quote: "去年销量 2,840 万台。", angle: .time),
            makeCandidate(quote: "去年销量 2,840 万台。", angle: .time),
        ]
        XCTAssertEqual(
            ResearchAngleCoverage.covered(candidates, documents: [document.canonicalURL: document]),
            []
        )
    }

    /// Unlabelled facts still answer questions. Rather than throwing them away,
    /// they are read as whichever angle the claim is closest to, so an older
    /// or simpler model does not score zero.
    func testUnlabelledEvidenceIsInferredFromItsClaim() {
        let document = makeDocument(text: "去年销量 2,840 万台。前年销量 3,100 万台。")
        let candidates = [
            makeCandidate(quote: "去年销量 2,840 万台。", angle: nil, claim: "去年销量是多少"),
            makeCandidate(quote: "前年销量 3,100 万台。", angle: nil, claim: "前年销量"),
        ]
        XCTAssertEqual(
            ResearchAngleCoverage.covered(candidates, documents: [document.canonicalURL: document]),
            [.time],
            "Both claims ask about a previous period, which is the time angle."
        )
    }

    // MARK: - Persistence

    /// The angle has to survive the round trip, or the only place it exists is
    /// the run that produced it. It is optional in the schema so every report
    /// written before this field stays readable.
    func testEvidenceAngleSurvivesEncodingAndDecoding() throws {
        let original = EvidenceItem(
            id: "E1",
            url: "https://example.org/a",
            canonicalURL: "https://example.org/a",
            domain: "example.org",
            title: "Source",
            publishedAt: nil,
            quote: "去年销量 2,840 万台。",
            quoteVerified: true,
            stance: .supports,
            tier: .major,
            syndicationGroup: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            angle: .time
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EvidenceItem.self, from: data)
        XCTAssertEqual(decoded.angle, .time)
    }

    /// A report written before angle labelling existed must decode with a nil
    /// angle instead of failing. This is the whole reason the field is optional.
    func testEvidenceWithoutAngleStillDecodes() throws {
        let legacy = """
        {"id":"E1","url":"https://example.org/a","domain":"example.org",
         "title":"Source","quote":"原文","quoteVerified":true,
         "stance":"supports","tier":2,"fetchedAt":0}
        """
        let decoded = try JSONDecoder().decode(
            EvidenceItem.self,
            from: Data(legacy.utf8)
        )
        XCTAssertNil(decoded.angle)
        XCTAssertEqual(decoded.id, "E1")
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
        claim: String = "销量"
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
