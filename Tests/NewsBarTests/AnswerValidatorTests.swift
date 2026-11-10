import XCTest
@testable import NewsBar

final class AnswerValidatorTests: XCTestCase {
    private func source(
        _ index: Int,
        origin: EvidenceOrigin = .web,
        adoption: SourceAdoption = .supporting,
        independence: SourceIndependence = .unknown
    ) -> AISearchSource {
        var source = AISearchSource(
            index: index,
            url: "https://source\(index).example/story",
            title: "Source \(index)",
            text: "text",
            origin: origin
        )
        source.assessment = SourceAssessment(
            independence: independence,
            adoption: adoption,
            reason: .assessed
        )
        return source
    }

    private func currentPage() -> AISearchSource {
        AISearchSource(
            index: 1,
            url: "https://example.com/page",
            title: "Page",
            text: "text",
            origin: .currentPage
        )
    }

    private func block(_ body: String) -> [AnswerBlock] {
        [AnswerBlock(id: 0, heading: nil, body: body)]
    }

    func testZeroCitationsWithAdoptedSourcesIsUnverified() {
        let sources = [source(1)]
        let blocks = block("没有任何引用的一句话。")
        let validation = AnswerValidator.validate(blocks: blocks, sources: sources)
        XCTAssertTrue(validation.validCitations.isEmpty)
        XCTAssertEqual(
            AnswerValidator.basis(sources: sources, blocks: blocks, validation: validation),
            .noVerifiedCitations
        )
    }

    func testTwoIndependentSupportingSourcesAreSupported() {
        let sources = [
            source(1, adoption: .supporting, independence: .independent),
            source(2, adoption: .supporting, independence: .independent),
        ]
        let blocks = block("事实一[1]，事实二[2]。")
        let validation = AnswerValidator.validate(blocks: blocks, sources: sources)
        XCTAssertEqual(validation.validCitations, [1, 2])
        XCTAssertEqual(
            AnswerValidator.basis(sources: sources, blocks: blocks, validation: validation),
            .externalSupported
        )
    }

    func testSingleSupportingSourceIsLimited() {
        let sources = [source(1)]
        let blocks = block("事实[1]。")
        let validation = AnswerValidator.validate(blocks: blocks, sources: sources)
        XCTAssertEqual(
            AnswerValidator.basis(sources: sources, blocks: blocks, validation: validation),
            .externalLimited
        )
    }

    func testRejectedCitationIsCountedAndStaysPlainText() {
        let sources = [source(1, adoption: .rejected)]
        let body = "事实[1]。"
        let blocks = block(body)
        let validation = AnswerValidator.validate(blocks: blocks, sources: sources)
        XCTAssertTrue(validation.validCitations.isEmpty)
        XCTAssertEqual(validation.invalidCitations, 1)

        let allowed = AnswerValidator.allowedIndices(sources)
        let segments = AnswerCitationScanner.segments(
            in: body,
            sourceCount: sources.count,
            allowed: allowed
        )
        XCTAssertEqual(segments, [.text(body)])
        XCTAssertEqual(
            AnswerValidator.basis(sources: sources, blocks: blocks, validation: validation),
            .insufficientMaterial
        )
    }

    func testCurrentPageWithCitationIsCurrentPageOnly() {
        let sources = [currentPage()]
        let blocks = block("页面里的事实[1]。")
        let validation = AnswerValidator.validate(blocks: blocks, sources: sources)
        XCTAssertEqual(
            AnswerValidator.basis(sources: sources, blocks: blocks, validation: validation),
            .currentPageOnly
        )
    }

    func testCurrentPageZeroCitationsIsUnverified() {
        let sources = [currentPage()]
        let blocks = block("页面里的事实，没有引用。")
        let validation = AnswerValidator.validate(blocks: blocks, sources: sources)
        XCTAssertEqual(
            AnswerValidator.basis(sources: sources, blocks: blocks, validation: validation),
            .noVerifiedCitations
        )
    }

    func testFactualSentencesWithoutCitationsAreCounted() {
        let sources = [source(1)]
        let blocks = block("增长 12%，没有引用。另一句没有数字。")
        let validation = AnswerValidator.validate(blocks: blocks, sources: sources)
        XCTAssertEqual(validation.uncitedFactualSentences, 1)
    }

    func testOutOfRangeCitationIsNotAnInvalidCitation() {
        let sources = [source(1)]
        let validation = AnswerValidator.validate(
            blocks: block("事实[9]。"),
            sources: sources
        )
        XCTAssertTrue(validation.validCitations.isEmpty)
        XCTAssertEqual(validation.invalidCitations, 0)
    }
}
