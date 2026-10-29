import XCTest
@testable import NewsBar

/// Golden tests for the native side of reader mode.
///
/// The JS extractor itself is exercised manually from Settings → Developer →
/// reader-mode self-check (it needs a real WebKit page). These fixtures are
/// payload captures for six page shapes and assert decoding, ordering, heading
/// recognition, boilerplate removal, caps and URL sanitization only.
final class ReaderModeParserTests: XCTestCase {
    private func fixtureData(_ name: String) throws -> Data {
        let fileName = name.hasSuffix(".json") ? name : name + ".json"
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ReaderMode/\(fileName)")
        return try Data(contentsOf: url)
    }

    private func fixturePayload(_ name: String) throws -> [String: Any] {
        let data = try fixtureData(name)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func document(_ name: String, expectedURL: String? = nil) throws -> ReaderModeDocument {
        let payload = try fixturePayload(name)
        let url = try XCTUnwrap(payload["url"] as? String)
        return try XCTUnwrap(ReaderModeDocument(payload: payload, expectedURL: expectedURL ?? url), name)
    }

    private var longParagraph: String { String(repeating: "正文内容足够长，用于通过可用性检查。", count: 30) }

    private func payload(blocks: [[String: Any]], url: String = "https://example.com/story") -> [String: Any] {
        [
            "ok": true,
            "reason": NSNull(),
            "url": url,
            "title": "Fixture",
            "byline": NSNull(),
            "siteName": NSNull(),
            "publishedAt": NSNull(),
            "lang": "zh-CN",
            "wordCount": 500,
            "score": 1200,
            "selector": "heuristic",
            "blocks": blocks,
        ]
    }

    // MARK: - Six page shapes

    func testNewsPortalKeepsReadingOrderAndDropsBoilerplate() throws {
        let doc = try document("news-portal.json")
        XCTAssertTrue(doc.isUsable)
        XCTAssertEqual(doc.title, "国产大模型发布新一代推理引擎 - IT之家")
        XCTAssertEqual(doc.blocks.first?.kind, .paragraph)
        XCTAssertTrue(doc.blocks.first?.text?.contains("IT之家") == true)

        let headings = doc.blocks.filter { $0.kind == .heading2 }.map(\.text)
        XCTAssertEqual(headings, ["推理速度与成本", "开放节奏"])

        let texts = doc.textBlocks.map(\.plainText)
        XCTAssertFalse(texts.contains("广告"))
        XCTAssertFalse(texts.contains("相关阅读"))
        XCTAssertFalse(texts.contains("责任编辑：李明"))
        XCTAssertFalse(texts.contains { $0.contains("广告") })

        // Order is the extractor's document order; ids stay dense and ascending.
        XCTAssertEqual(doc.blocks.map(\.id), Array(0..<doc.blocks.count))
        let list = try XCTUnwrap(doc.blocks.first { $0.kind == .orderedList })
        XCTAssertEqual(list.items.count, 3)
        XCTAssertTrue(list.items[0].contains("长文本摘要"))
        XCTAssertTrue(doc.blocks.contains { $0.kind == .image && $0.src == "https://img.ithome.com/newsuploadfiles/2026/10/engine.png" })
    }

    func testBlogFixtureRecognizesHeadingsQuotePreAndFigure() throws {
        let doc = try document("blog.json")
        let kinds = Set(doc.blocks.map(\.kind))
        XCTAssertTrue(kinds.contains(.heading2))
        XCTAssertTrue(kinds.contains(.heading3))
        XCTAssertTrue(kinds.contains(.quote))
        XCTAssertTrue(kinds.contains(.pre))
        XCTAssertTrue(kinds.contains(.figure))

        let figure = try XCTUnwrap(doc.blocks.first { $0.kind == .figure })
        XCTAssertEqual(figure.src, "https://blog.example.dev/assets/pipeline.webp")
        XCTAssertEqual(figure.caption, "把阶段拆开后，取消信号会沿着任务树向下传播。")

        // Illegal links never survive: http and javascript are both rejected,
        // while the paragraph text itself may remain as plain prose.
        XCTAssertTrue(doc.blocks.allSatisfy { let href = $0.href ?? ""; return href.isEmpty || href.hasPrefix("https://") })
        XCTAssertTrue(doc.blocks.allSatisfy { !($0.href ?? "").lowercased().hasPrefix("javascript:") })
        XCTAssertTrue(doc.blocks.allSatisfy { let src = $0.src ?? ""; return src.isEmpty || src.hasPrefix("https://") })
        // localhost and plain-http images are dropped entirely.
        XCTAssertFalse(doc.blocks.contains { ($0.src ?? "").contains("localhost") })
        XCTAssertFalse(doc.blocks.contains { ($0.src ?? "").hasPrefix("http://") })
        // Share boilerplate is removed.
        XCTAssertFalse(doc.textBlocks.contains { $0.plainText == "分享这篇文章" })
    }

    func testForumFixtureKeepsThreadOrderAndLists() throws {
        let doc = try document("forum.json")
        XCTAssertEqual(doc.blocks.first?.kind, .paragraph)
        let headings = doc.blocks.filter { $0.kind == .heading2 }.map(\.text)
        XCTAssertEqual(headings, ["回复 1", "回复 2"])
        let lists = doc.blocks.filter { $0.kind == .unorderedList }
        XCTAssertEqual(lists.count, 1)
        XCTAssertEqual(lists[0].items.count, 4)
        XCTAssertFalse(doc.textBlocks.contains { $0.plainText == "登录后回复" })
        XCTAssertTrue(doc.blocks.allSatisfy { ($0.href ?? "").isEmpty || $0.href?.hasPrefix("https://") == true })
    }

    func testWechatStyleFixtureKeepsLongProseAndDropsReadOriginalLink() throws {
        let doc = try document("wechat.json")
        XCTAssertTrue(doc.characterCount > 500)
        XCTAssertTrue(doc.blocks.contains { $0.kind == .heading2 && $0.text == "沿岸的旧房子" })
        XCTAssertFalse(doc.textBlocks.contains { $0.plainText == "阅读原文" })
        XCTAssertFalse(doc.textBlocks.contains { $0.plainText.contains("微信扫一扫") })
        let images = doc.imageBlocks
        XCTAssertEqual(images.count, 2)
        XCTAssertNil(images[0].alt)
        XCTAssertEqual(images[1].caption, "傍晚的河岸，树影落在步道上。")
    }

    func testEnglishMediaFixturePreservesBylineAndFigure() throws {
        let doc = try document("english-media.json")
        XCTAssertEqual(doc.byline, "Jane Doe")
        XCTAssertEqual(doc.siteName, "BBC News")
        XCTAssertEqual(doc.publishedAt, "2026-10-28T22:10:00Z")
        XCTAssertEqual(doc.lang, "en")
        XCTAssertEqual(doc.blocks.filter { $0.kind == .heading2 }.map(\.text), ["A mayor for the night"])
        XCTAssertEqual(doc.blocks.filter { $0.kind == .heading3 }.map(\.text), ["Who counts as a night worker?"])
        XCTAssertFalse(doc.textBlocks.contains { $0.plainText == "Sign up for our newsletter" })
        XCTAssertFalse(doc.textBlocks.contains { $0.plainText == "Related articles" })
        let figure = try XCTUnwrap(doc.blocks.first { $0.kind == .figure })
        XCTAssertEqual(figure.caption, "Late-night workers are often left out of consultations.")
    }

    func testImageHeavyFixtureCapsImagesAtTwenty() throws {
        let doc = try document("image-heavy.json")
        XCTAssertEqual(doc.imageBlocks.count, ReaderModeDocument.maxImages)
        XCTAssertTrue(doc.blocks.count <= ReaderModeDocument.maxBlocks)
        XCTAssertTrue(doc.textBlocks.count >= 3)
        // Images keep their document order; the cap drops the tail.
        XCTAssertEqual(doc.imageBlocks.first?.src, "https://images.example.com/gallery/00.jpg")
        XCTAssertEqual(doc.imageBlocks.last?.src, "https://images.example.com/gallery/19.jpg")
    }

    // MARK: - Caps

    func testBlockCountCapTruncates() throws {
        let blocks = (0..<500).map { index in
            ["type": "p", "text": "第 \(index) 段，内容足够长以便通过清洗，同时用于验证块数上限。"]
        }
        let doc = try XCTUnwrap(ReaderModeDocument(payload: payload(blocks: blocks), expectedURL: "https://example.com/story"))
        XCTAssertEqual(doc.blocks.count, ReaderModeDocument.maxBlocks)
        XCTAssertEqual(doc.blocks.last?.id, ReaderModeDocument.maxBlocks - 1)
    }

    func testTotalCharacterCapTruncates() throws {
        let paragraph = String(repeating: "字", count: 20_000)
        let blocks = (0..<10).map { _ in ["type": "p", "text": paragraph] }
        let doc = try XCTUnwrap(ReaderModeDocument(payload: payload(blocks: blocks), expectedURL: "https://example.com/story"))
        XCTAssertLessThanOrEqual(doc.characterCount, ReaderModeDocument.maxTotalCharacters)
        // Each block is cut to 8 000 characters first, so 7 fit under 60 000
        // and the eighth would cross the total cap.
        XCTAssertEqual(doc.blocks.count, 7)
    }

    func testPerBlockCapTruncates() throws {
        let blocks = [
            ["type": "p", "text": String(repeating: "A", count: 10_000)],
            ["type": "p", "text": "第二段"],
            ["type": "p", "text": "第三段"],
        ]
        let doc = try XCTUnwrap(ReaderModeDocument(payload: payload(blocks: blocks), expectedURL: "https://example.com/story"))
        XCTAssertEqual(doc.blocks.first?.text?.count, ReaderModeDocument.maxTextPerBlock)
    }

    func testListItemsAreBoundedAndClean() throws {
        let items = (0..<80).map { "项目 \($0)" }
        let blocks = [
            ["type": "ul", "items": items],
            ["type": "p", "text": longParagraph],
            ["type": "p", "text": longParagraph],
            ["type": "p", "text": longParagraph],
        ]
        let doc = try XCTUnwrap(ReaderModeDocument(payload: payload(blocks: blocks, url: "https://example.com/story"), expectedURL: "https://example.com/story"))
        XCTAssertEqual(doc.blocks.first?.items.count, ReaderModeDocument.maxListItems)
    }

    // MARK: - Rejection

    func testURLMismatchIsRejected() throws {
        let data = try fixtureData("news-portal.json")
        let doc = ReaderModeDocument(json: data, expectedURL: "https://example.com/other")
        XCTAssertNil(doc)
    }

    func testFailedExtractionIsRejected() throws {
        var object = try fixturePayload("news-portal.json")
        object["ok"] = false
        object["reason"] = "too_short"
        let data = try JSONSerialization.data(withJSONObject: object)
        let url = try XCTUnwrap(object["url"] as? String)
        XCTAssertNil(ReaderModeDocument(json: data, expectedURL: url))
    }

    func testThinDocumentIsRejectedInsteadOfShowingABlankPage() throws {
        let blocks = [
            ["type": "p", "text": String(repeating: "短", count: 300)],
            ["type": "p", "text": String(repeating: "文", count: 300)],
        ]
        XCTAssertNil(ReaderModeDocument(payload: payload(blocks: blocks), expectedURL: "https://example.com/story"))
    }

    func testUnknownBlockTypesAreDropped() throws {
        let blocks: [[String: Any]] = [
            ["type": "video", "src": "https://example.com/v.mp4"],
            ["type": "p", "text": longParagraph],
            ["type": "p", "text": longParagraph],
            ["type": "p", "text": longParagraph],
        ]
        let doc = try XCTUnwrap(ReaderModeDocument(payload: payload(blocks: blocks), expectedURL: "https://example.com/story"))
        XCTAssertEqual(doc.blocks.count, 3)
        XCTAssertFalse(doc.blocks.contains { $0.kind == .image })
    }

    func testNonHTTPSImageAndPortURLsAreDropped() throws {
        let blocks: [[String: Any]] = [
            ["type": "img", "src": "http://example.com/a.jpg"],
            ["type": "img", "src": "https://localhost/a.jpg"],
            ["type": "img", "src": "https://example.com:8443/a.jpg"],
            ["type": "img", "src": "https://example.com/ok.jpg"],
            ["type": "p", "text": longParagraph],
            ["type": "p", "text": longParagraph],
            ["type": "p", "text": longParagraph],
        ]
        let doc = try XCTUnwrap(ReaderModeDocument(payload: payload(blocks: blocks), expectedURL: "https://example.com/story"))
        XCTAssertEqual(doc.imageBlocks.map(\.src), ["https://example.com/ok.jpg"])
    }

    // MARK: - Text

    func testPreBlockPreservesLineBreaks() throws {
        let blocks: [[String: Any]] = [
            ["type": "pre", "text": "line one\nline two\n\nline four"],
            ["type": "p", "text": longParagraph],
            ["type": "p", "text": longParagraph],
            ["type": "p", "text": longParagraph],
        ]
        let doc = try XCTUnwrap(ReaderModeDocument(payload: payload(blocks: blocks), expectedURL: "https://example.com/story"))
        XCTAssertEqual(doc.blocks.first?.text, "line one\nline two\n\nline four")
    }

    func testPlainTextJoinsOnlyReadableBlocks() throws {
        let doc = try document("news-portal.json")
        let text = doc.plainText
        XCTAssertTrue(text.contains("推理速度与成本"))
        XCTAssertFalse(text.contains("广告"))
        XCTAssertFalse(text.contains("https://"))
        XCTAssertFalse(text.contains("<p>"))
    }
}
