import XCTest
@testable import NewsBar

/// The answer contract between the model and the canvas.
///
/// Every case here is a failure a real provider produces: a missing meta line,
/// a code fence, a heading the prompt never asked for, a citation number that
/// points at nothing. The parser is allowed to degrade, never to crash and
/// never to show an uncitable citation as if it were a source.
final class AnswerProtocolTests: XCTestCase {
    // MARK: - Meta

    func testMetaLineCarriesKindAndOneLine() {
        let raw = """
        @@ {"kind":"event","oneLine":"一款新芯片在本周发布。"}
        ## 时间线
        3 月 4 日发布。
        """
        let parsed = AnswerParser.parse(raw, fallbackKind: .term)
        XCTAssertEqual(parsed.kind, .event)
        XCTAssertEqual(parsed.oneLine, "一款新芯片在本周发布。")
        XCTAssertEqual(parsed.blocks.count, 1)
        XCTAssertEqual(parsed.blocks.first?.heading, "时间线")
        XCTAssertEqual(parsed.blocks.first?.body, "3 月 4 日发布。")
    }

    func testUnknownKindFallsBackInsteadOfDroppingTheAnswer() {
        let raw = """
        @@ {"kind":"gossip","oneLine":"一句话"}
        ## 要点
        正文
        """
        let parsed = AnswerParser.parse(raw, fallbackKind: .number)
        XCTAssertEqual(parsed.kind, .number)
        XCTAssertEqual(parsed.oneLine, "一句话")
        XCTAssertEqual(parsed.blocks.first?.body, "正文")
    }

    func testMalformedMetaKeepsTheProse() {
        let raw = """
        @@ {kind:event}
        ## 概览
        正文仍然要保留。
        """
        let parsed = AnswerParser.parse(raw, fallbackKind: .term)
        XCTAssertEqual(parsed.kind, .term)
        XCTAssertEqual(parsed.blocks.count, 1)
        XCTAssertEqual(parsed.blocks.first?.body, "正文仍然要保留。")
        XCTAssertFalse(parsed.oneLine.isEmpty)
    }

    func testAnswerWithoutMetaDerivesOneLineFromTheFirstSentence() {
        let raw = """
        ## 定义
        这是一个定义。后面还有解释。
        """
        let parsed = AnswerParser.parse(raw, fallbackKind: .term)
        XCTAssertEqual(parsed.kind, .term)
        XCTAssertEqual(parsed.oneLine, "这是一个定义。")
        XCTAssertEqual(parsed.blocks.first?.body, "这是一个定义。后面还有解释。")
    }

    func testAnswerWithNoStructureStillBecomesOneBlock() {
        let parsed = AnswerParser.parse("只有一段话。", fallbackKind: .term)
        XCTAssertEqual(parsed.blocks.count, 1)
        XCTAssertNil(parsed.blocks.first?.heading)
        XCTAssertEqual(parsed.oneLine, "只有一段话。")
    }

    func testEmptyOutputProducesNoBlocks() {
        let parsed = AnswerParser.parse("   \n\n ", fallbackKind: .term)
        XCTAssertTrue(parsed.blocks.isEmpty)
        XCTAssertTrue(parsed.oneLine.isEmpty)
    }

    // MARK: - Sanitising the shape

    func testCodeFenceAroundTheWholeAnswerIsRemoved() {
        let raw = """
        ```
        @@ {"kind":"term","oneLine":"一句"}
        ## 定义
        正文
        ```
        """
        let parsed = AnswerParser.parse(raw, fallbackKind: .term)
        XCTAssertEqual(parsed.kind, .term)
        XCTAssertEqual(parsed.oneLine, "一句")
        XCTAssertEqual(parsed.blocks.first?.body, "正文")
    }

    func testStrayMetaLineInsideBodyIsIgnored() {
        let raw = """
        @@ {"kind":"term","oneLine":"一句"}
        ## 定义
        第一段
        @@ {"kind":"event","oneLine":"伪造"}
        第二段
        """
        let parsed = AnswerParser.parse(raw, fallbackKind: .term)
        XCTAssertEqual(parsed.kind, .term)
        XCTAssertEqual(parsed.oneLine, "一句")
        XCTAssertFalse(parsed.blocks.first?.body.contains("@@") ?? true)
    }

    func testBlockCountAndLengthAreCapped() {
        var raw = "@@ {\"kind\":\"term\",\"oneLine\":\"一句\"}\n"
        for index in 0..<20 {
            raw += "## 小节 \(index)\n"
            raw += String(repeating: "字", count: 2_000) + "\n"
        }
        let parsed = AnswerParser.parse(raw, fallbackKind: .term)
        XCTAssertLessThanOrEqual(parsed.blocks.count, AnswerParser.maxBlocks)
        XCTAssertTrue(parsed.blocks.allSatisfy { $0.body.count <= AnswerParser.maxBlockCharacters })
    }

    func testHeadingWithoutBodyIsDropped() {
        let raw = """
        @@ {"kind":"term","oneLine":"一句"}
        ## 空小节
        ## 定义
        正文
        """
        let parsed = AnswerParser.parse(raw, fallbackKind: .term)
        XCTAssertEqual(parsed.blocks.map(\.heading), ["定义"])
    }

    // MARK: - Citations

    func testCitationScannerOnlyMarksNumbersThatExist() {
        let segments = AnswerCitationScanner.segments(in: "看到 [1] 和 [9]，还有 [2][3]。", sourceCount: 3)
        XCTAssertEqual(segments, [
            .text("看到 "),
            .citation(1),
            .text(" 和 [9]，还有 "),
            .citation(2),
            .citation(3),
            .text("。"),
        ])
    }

    func testCitationsBecomePlainTextWhenThereIsNoSource() {
        let segments = AnswerCitationScanner.segments(in: "没有来源的 [1]。", sourceCount: 0)
        XCTAssertEqual(segments, [.text("没有来源的 [1]。")])
    }

    func testDocumentCollectsDistinctCitedIndicesInOrder() {
        let document = makeDocument(
            blocks: [
                AnswerBlock(id: 0, heading: "前因", body: "甲[2]，乙[1]。"),
                AnswerBlock(id: 1, heading: "后果", body: "丙[2][9]。"),
            ],
            sourceCount: 2
        )
        XCTAssertEqual(document.citationIndices, [2, 1])
        XCTAssertEqual(document.evidence.citedCount, 2)
        XCTAssertEqual(document.evidence.sourceCount, 2)
        XCTAssertEqual(document.evidence.mode, .web)
    }

    func testOfflineDocumentReportsNoSourcesAndNoCitations() {
        let document = AnswerDocument(
            kind: .term,
            oneLine: "一句",
            blocks: [AnswerBlock(id: 0, heading: nil, body: "正文[1]")],
            sources: [],
            mode: .offline,
            model: "m",
            thinking: .off,
            generatedAt: Date(),
            question: nil
        )
        XCTAssertEqual(document.citationIndices, [])
        XCTAssertEqual(document.evidence.sourceCount, 0)
        XCTAssertTrue(document.isOffline)
    }

    // MARK: - Plain text for the copy button

    func testPlainTextKeepsHeadingsCitationsAndSourceURLs() {
        let document = makeDocument(
            blocks: [
                AnswerBlock(id: 0, heading: "时间线", body: "3 月 4 日发布[1]。"),
            ],
            sourceCount: 1
        )
        let text = document.plainText(.zh)
        XCTAssertTrue(text.hasPrefix("一句话"))
        XCTAssertTrue(text.contains("## 时间线"))
        XCTAssertTrue(text.contains("3 月 4 日发布[1]。"))
        XCTAssertTrue(text.contains("[1] 来源标题"))
        XCTAssertTrue(text.contains("https://source1.example/story"))
    }

    func testPlainTextForOfflineAnswerHasNoSourceSection() {
        let document = AnswerDocument(
            kind: .term,
            oneLine: "一句",
            blocks: [AnswerBlock(id: 0, heading: nil, body: "正文")],
            sources: [],
            mode: .offline,
            model: "m",
            thinking: .off,
            generatedAt: Date(),
            question: nil
        )
        XCTAssertFalse(document.plainText(.zh).contains("来源"))
    }

    // MARK: - Line formatting inside a block

    func testFormatterClassifiesBulletsDefinitionsAndQuotes() {
        let body = """
        这是一段正文，跨了两行
        仍然属于同一段。
        - 第一条
        - 价格：¥299
        > 引用原话
        """
        let lines = AnswerFormatter.lines(body)
        XCTAssertEqual(lines, [
            .paragraph("这是一段正文，跨了两行仍然属于同一段。"),
            .bullet("第一条"),
            .definition("价格", "¥299"),
            .quote("引用原话"),
        ])
    }

    func testFormatterKeepsEnglishWordsSeparatedWhenJoiningWrappedLines() {
        let lines = AnswerFormatter.lines("A wrapped line\ncontinues here.")
        XCTAssertEqual(lines, [.paragraph("A wrapped line continues here.")])
    }

    func testFormatterDoesNotTreatASentenceWithAColonAsADefinition() {
        let lines = AnswerFormatter.lines("- 他说：这件事还没有结束。")
        XCTAssertEqual(lines, [.bullet("他说：这件事还没有结束。")])
    }

    func testFormatterKeepsBlankLineAsParagraphBreak() {
        let lines = AnswerFormatter.lines("第一段\n\n第二段")
        XCTAssertEqual(lines, [.paragraph("第一段"), .paragraph("第二段")])
    }

    /// A quotation draws one rule per `.quote`, so consecutive `>` lines have to
    /// arrive as one line item or a three-line quote reads as three quotations.
    func testFormatterMergesConsecutiveQuoteLinesIntoOneQuotation() {
        let lines = AnswerFormatter.lines("""
        > 这一代换了封装，散热是重点。
        > 我们也在现场做了实测。
        > 具体数据会在评测里公布。
        """)
        XCTAssertEqual(lines, [
            .quote("这一代换了封装，散热是重点。\n我们也在现场做了实测。\n具体数据会在评测里公布。"),
        ])
    }

    func testFormatterStartsANewQuotationAfterABlankLine() {
        let lines = AnswerFormatter.lines("> 第一段\n\n> 第二段")
        XCTAssertEqual(lines, [.quote("第一段"), .quote("第二段")])
    }

    func testFormatterEndsAQuotationBeforeOrdinaryText() {
        let lines = AnswerFormatter.lines("> 引用原话\n紧接着的正文")
        XCTAssertEqual(lines, [.quote("引用原话"), .paragraph("紧接着的正文")])
    }

    func testFormatterTreatsUnknownMarkersAsText() {
        let lines = AnswerFormatter.lines("### 不是标题\n\n1. 也不是列表")
        XCTAssertEqual(lines, [.paragraph("### 不是标题"), .paragraph("1. 也不是列表")])
    }

    // MARK: - Helpers

    private func makeDocument(blocks: [AnswerBlock], sourceCount: Int) -> AnswerDocument {
        let sources = (1...max(1, sourceCount)).map { index in
            AISearchSource(
                index: index,
                url: "https://source\(index).example/story",
                title: "来源标题 \(index)",
                text: String(repeating: "正文", count: 200)
            )
        }
        let limited = Array(sources.prefix(sourceCount))
        return AnswerDocument(
            kind: .event,
            oneLine: "一句话",
            blocks: blocks,
            sources: limited,
            mode: .web,
            model: "m",
            thinking: .medium,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            question: "发生了什么？"
        )
    }
}
