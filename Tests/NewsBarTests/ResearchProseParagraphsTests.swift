import XCTest
@testable import NewsBar

/// The overview is the popup's body copy, so its paragraph structure has to
/// survive the trip to the screen. Real records separate paragraphs with a
/// blank line; rendering the string as one `Text` erases that distinction.
final class ResearchProseParagraphsTests: XCTestCase {

    func testBlankLineSeparatesParagraphs() {
        let text = "第一段。\n\n第二段。\n\n第三段。"
        XCTAssertEqual(ResearchProseParagraphs.split(text), ["第一段。", "第二段。", "第三段。"])
        XCTAssertTrue(ResearchProseParagraphs.hasMultipleParagraphs(text))
    }

    func testSingleNewlineStaysInsideItsParagraph() {
        // The model sometimes wraps a list or a quotation with a single break;
        // treating that as a paragraph break would invent structure.
        let text = "第一行\n第二行\n\n第二段。"
        XCTAssertEqual(ResearchProseParagraphs.split(text), ["第一行\n第二行", "第二段。"])
    }

    func testCRLFIsNormalised() {
        let text = "第一段。\r\n\r\n第二段。"
        XCTAssertEqual(ResearchProseParagraphs.split(text), ["第一段。", "第二段。"])
    }

    func testEmptyAndWhitespaceOnlyInputProducesNoParagraphs() {
        XCTAssertEqual(ResearchProseParagraphs.split(""), [])
        XCTAssertEqual(ResearchProseParagraphs.split("   \n\n  \n\n "), [])
        XCTAssertFalse(ResearchProseParagraphs.hasMultipleParagraphs("   "))
    }

    func testExtraBlankLinesDoNotCreateEmptyParagraphs() {
        let text = "第一段。\n\n\n\n第二段。"
        XCTAssertEqual(ResearchProseParagraphs.split(text), ["第一段。", "第二段。"])
    }

    func testSingleParagraphIsReportedAsOne() {
        // The shortest real overview is 93 characters with no break at all;
        // the stacked layout must still draw it, just without extra gaps.
        XCTAssertEqual(ResearchProseParagraphs.split("只有一段。"), ["只有一段。"])
        XCTAssertFalse(ResearchProseParagraphs.hasMultipleParagraphs("只有一段。"))
    }

    func testRealOverviewShapesKeepTheirParagraphCount() {
        // Shapes taken from actual stored records: three and four paragraph
        // overviews are the common cases, one paragraph is the short tail.
        let three = "第一段，介绍发生了什么。\n\n第二段，说明为什么。\n\n第三段，说明影响。"
        let four = "一。\n\n二。\n\n三。\n\n四。"
        XCTAssertEqual(ResearchProseParagraphs.split(three).count, 3)
        XCTAssertEqual(ResearchProseParagraphs.split(four).count, 4)
    }
}
