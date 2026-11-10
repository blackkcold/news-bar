import XCTest
@testable import NewsBar

final class EvidenceAssessorTests: XCTestCase {
    private actor AssessorTestClient: AIChatClienting {
        private(set) var requests: [AIChatRequest] = []
        private let responses: [Result<String, Error>]

        init(responses: [Result<String, Error>]) {
            self.responses = responses
        }

        func complete(_ request: AIChatRequest) async throws -> AIChatResponse {
            requests.append(request)
            guard !responses.isEmpty else {
                return AIChatResponse(text: "", truncated: false)
            }
            let index = min(requests.count - 1, responses.count - 1)
            switch responses[index] {
            case .success(let text):
                return AIChatResponse(text: text, truncated: false)
            case .failure(let error):
                throw error
            }
        }
    }

    private func source(
        _ index: Int,
        text: String,
        url: String? = nil,
        duplicateOf: String? = nil
    ) -> AISearchSource {
        AISearchSource(
            index: index,
            url: url ?? "https://source\(index).example/story",
            title: "Source \(index)",
            text: text,
            duplicateOf: duplicateOf
        )
    }

    private func payload(
        _ item: String,
        conflicts: String = "[]"
    ) -> String {
        "{\"sources\":[\(item)],\"conflicts\":\(conflicts)}"
    }

    private func item(
        index: Int,
        type: String = "primary",
        independence: String = "independent",
        adopt: String = "primary",
        quote: String,
        text: String = "claim",
        support: String = "direct"
    ) -> String {
        """
        {"index":\(index),"type":"\(type)","independence":"\(independence)","adopt":"\(adopt)","reason":"ok","claims":[{"text":"\(text)","quote":"\(quote)","support":"\(support)"}]}
        """
    }

    func testVerifiedQuoteMakesAPrimarySourceUsable() async {
        let text = "The page says the model was released in October. It also lists a price."
        let quote = "the model was released in October"
        let client = AssessorTestClient(responses: [
            .success(payload(item(index: 1, quote: quote))),
        ])
        let result = await EvidenceAssessor.assess(
            question: "When was it released?",
            pageTitle: nil,
            sources: [source(1, text: text)],
            client: client,
            language: .en
        )
        XCTAssertEqual(result.sources[0].assessment?.adoption, .primary)
        XCTAssertEqual(result.sources[0].assessment?.claims.count, 1)
        XCTAssertEqual(result.sources[0].assessment?.claims.first?.quote, quote)
    }

    func testInventedQuoteIsRejected() async {
        let client = AssessorTestClient(responses: [
            .success(payload(item(index: 1, quote: "this sentence is not in the page"))),
        ])
        let result = await EvidenceAssessor.assess(
            question: "q",
            pageTitle: nil,
            sources: [source(1, text: "The page says X. Nothing else.")],
            client: client,
            language: .en
        )
        XCTAssertEqual(result.sources[0].assessment?.adoption, .rejected)
        XCTAssertEqual(result.sources[0].assessment?.reason, .quoteNotVerifiable)
        XCTAssertTrue(result.sources[0].assessment?.claims.isEmpty ?? false)
    }

    func testAggregatorCannotBePrimary() async {
        let text = "The page says the event happened on Monday."
        let client = AssessorTestClient(responses: [
            .success(payload(item(index: 1, type: "aggregator", quote: "event happened on Monday"))),
        ])
        let result = await EvidenceAssessor.assess(
            question: "q",
            pageTitle: nil,
            sources: [source(1, text: text)],
            client: client,
            language: .en
        )
        XCTAssertEqual(result.sources[0].assessment?.adoption, .supporting)
        XCTAssertEqual(result.sources[0].assessment?.reason, .aggregator)
    }

    func testDuplicateSourceIsRejectedWithoutCallingTheModel() async {
        let client = AssessorTestClient(responses: [])
        let duplicate = source(
            1,
            text: String(repeating: "正文", count: 300),
            duplicateOf: "https://source0.example/story"
        )
        let result = await EvidenceAssessor.assess(
            question: "q",
            pageTitle: nil,
            sources: [duplicate],
            client: client,
            language: .zh
        )
        XCTAssertEqual(result.sources[0].assessment?.adoption, .rejected)
        XCTAssertEqual(result.sources[0].assessment?.reason, .duplicate)
        let calls = await client.requests.count
        XCTAssertEqual(calls, 0)
    }

    func testMalformedJSONRepairsOnceThenFallsBack() async {
        let text = String(repeating: "正文", count: 300)
        let client = AssessorTestClient(responses: [
            .success("not json"),
            .success("still not json"),
        ])
        let result = await EvidenceAssessor.assess(
            question: "q",
            pageTitle: nil,
            sources: [source(1, text: text)],
            client: client,
            language: .zh
        )
        XCTAssertEqual(result.sources[0].assessment?.adoption, .supporting)
        XCTAssertEqual(result.sources[0].assessment?.reason, .heuristic)
        XCTAssertTrue(result.notes.contains(.assessmentFailed))
        let calls = await client.requests.count
        XCTAssertEqual(calls, 2)
    }

    func testMalformedJSONRecoversOnTheRepairCall() async {
        let text = "The page says the model was released in October."
        let client = AssessorTestClient(responses: [
            .success("not json"),
            .success(payload(item(index: 1, quote: "model was released in October"))),
        ])
        let result = await EvidenceAssessor.assess(
            question: "q",
            pageTitle: nil,
            sources: [source(1, text: text)],
            client: client,
            language: .en
        )
        XCTAssertEqual(result.sources[0].assessment?.adoption, .primary)
        XCTAssertFalse(result.notes.contains(.assessmentFailed))
    }

    func testQuotaErrorFallsBackWithoutFailingTheSearch() async {
        let text = String(repeating: "正文", count: 300)
        let client = AssessorTestClient(responses: [.failure(AIChatError.quotaUnavailable)])
        let result = await EvidenceAssessor.assess(
            question: "q",
            pageTitle: nil,
            sources: [source(1, text: text)],
            client: client,
            language: .zh
        )
        XCTAssertEqual(result.sources[0].assessment?.adoption, .supporting)
        XCTAssertTrue(result.notes.contains(.assessmentSkipped))
    }

    func testConflictingSourcesAreDowngradedToSupporting() async {
        let firstText = "The release was in October 2025. The price is low."
        let secondText = "The release was in November 2025. The price is high."
        let items = [
            item(index: 1, quote: "release was in October"),
            item(index: 2, quote: "release was in November"),
        ].joined(separator: ",")
        let conflicts = """
        [{"claim":"release date","sources":[1,2],"note":"sources disagree"}]
        """
        let client = AssessorTestClient(responses: [
            .success(payload(items, conflicts: conflicts)),
        ])
        let result = await EvidenceAssessor.assess(
            question: "When was it released?",
            pageTitle: nil,
            sources: [source(1, text: firstText), source(2, text: secondText)],
            client: client,
            language: .en
        )
        XCTAssertEqual(result.sources[0].assessment?.adoption, .supporting)
        XCTAssertEqual(result.sources[1].assessment?.adoption, .supporting)
        XCTAssertEqual(result.sources[0].assessment?.reason, .conflict)
        XCTAssertTrue(result.notes.contains(.conflictingSources))
        XCTAssertEqual(result.conflicts.count, 1)
    }

    func testHeuristicRejectsDuplicatesAndShortPages() {
        let duplicate = source(
            1,
            text: String(repeating: "正文", count: 300),
            duplicateOf: "https://source0.example/story"
        )
        let short = source(2, text: "短")
        let readable = source(3, text: String(repeating: "正文", count: 300))
        let result = EvidenceAssessor.heuristic(
            question: "q",
            sources: [duplicate, short, readable]
        )
        XCTAssertEqual(result.sources[0].assessment?.adoption, .rejected)
        XCTAssertEqual(result.sources[0].assessment?.reason, .duplicate)
        XCTAssertEqual(result.sources[1].assessment?.adoption, .rejected)
        XCTAssertEqual(result.sources[1].assessment?.reason, .noMaterial)
        XCTAssertEqual(result.sources[2].assessment?.adoption, .supporting)
        XCTAssertEqual(result.sources[2].assessment?.reason, .heuristic)
        XCTAssertTrue(result.notes.isEmpty)
    }
}
