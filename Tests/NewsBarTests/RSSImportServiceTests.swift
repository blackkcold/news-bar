import XCTest
@testable import NewsBar

final class RSSImportServiceTests: XCTestCase {

    // MARK: - OPML

    func test_parseOPML_preservesFolderPathAndFlatFeeds() throws {
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <body>
            <outline text="Tech">
              <outline text="Example A" type="rss" xmlUrl="https://example.com/a.xml"/>
            </outline>
            <outline text="Example B" type="rss" xmlUrl="https://example.com/b.xml"/>
          </body>
        </opml>
        """
        let candidates = try RSSImportService.parse(data: Data(opml.utf8), format: .opml)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].url, "https://example.com/a.xml")
        XCTAssertEqual(candidates[0].group, "Tech")
        XCTAssertNil(candidates[1].group)
    }

    // MARK: - JSON

    func test_parseJSON_acceptsEnvelopeAndBareArray() throws {
        let envelope = """
        {"schemaVersion":1,"sources":[
          {"name":"A","url":"https://example.com/a.xml","displayMode":"image"},
          {"title":"B","url":"https://example.com/b.xml"}
        ]}
        """
        let envelopeCandidates = try RSSImportService.parse(data: Data(envelope.utf8), format: .json)
        XCTAssertEqual(envelopeCandidates.count, 2)
        XCTAssertEqual(envelopeCandidates[0].displayMode, .image)
        XCTAssertEqual(envelopeCandidates[1].name, "B")

        let bare = """
        [{"url":"https://example.com/c.xml"}]
        """
        let bareCandidates = try RSSImportService.parse(data: Data(bare.utf8), format: .json)
        XCTAssertEqual(bareCandidates.count, 1)
        XCTAssertEqual(bareCandidates[0].name, "example.com")
    }

    // MARK: - TXT and CSV

    func test_parseText_supportsNamedAndPlainURLs() throws {
        let text = """
        # comment
        Alpha\thttps://example.com/a.xml
        https://example.com/b.xml
        """
        let candidates = try RSSImportService.parse(data: Data(text.utf8), format: .text)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].name, "Alpha")
        XCTAssertEqual(candidates[1].name, "example.com")
    }

    func test_parseCSV_supportsHeaderAndQuotedFields() throws {
        let csv = """
        name,url,displayMode
        "Quoted, Inc.",https://example.com/a.xml,image
        Plain,https://example.com/b.xml,text
        """
        let candidates = try RSSImportService.parse(data: Data(csv.utf8), format: .csv)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].name, "Quoted, Inc.")
        XCTAssertEqual(candidates[0].displayMode, .image)
        XCTAssertEqual(candidates[1].name, "Plain")
    }

    // MARK: - Plan

    func test_plan_deduplicatesAndRejectsBlockedAndInvalidURLs() {
        let existing = [
            RSSSourceConfig(name: "Existing", url: "https://example.com/duplicate.xml", displayMode: .text)
        ]
        let candidates = [
            RSSImportCandidate(name: "Duplicate", url: "https://example.com/duplicate.xml"),
            RSSImportCandidate(name: "Blocked", url: "http://localhost/feed.xml"),
            RSSImportCandidate(name: "Valid", url: "https://example.com/new.xml"),
            RSSImportCandidate(name: "Not a URL", url: "not a url"),
        ]
        let plan = RSSImportService.plan(candidates: candidates, existing: existing)

        XCTAssertEqual(plan.accepted.map(\.url), ["https://example.com/new.xml"])
        XCTAssertEqual(plan.duplicateCount, 1)
        XCTAssertEqual(plan.blockedCount, 1)
        XCTAssertEqual(plan.invalidCount, 1)
    }

    // MARK: - Google News

    func test_googleNewsSearchURL_encodesQueryAndLocale() throws {
        let url = try XCTUnwrap(RSSImportService.googleNewsSearchURL(query: "苹果 发布会"))
        XCTAssertTrue(url.hasPrefix("https://news.google.com/rss/search?"))
        XCTAssertTrue(url.contains("hl=zh-CN"))
        XCTAssertTrue(url.contains("gl=CN"))
        XCTAssertTrue(url.contains("ceid=CN:zh-Hans"))
        XCTAssertTrue(url.contains("q=%E8%8B%B9%E6%9E%9C%20%E5%8F%91%E5%B8%83%E4%BC%9A"))
    }

    // MARK: - Export

    func test_exportJSON_roundTripsThroughImportParser() throws {
        let sources = [
            RSSSourceConfig(name: "A", url: "https://example.com/a.xml", displayMode: .text),
            RSSSourceConfig(name: "B", url: "https://example.com/b.xml", displayMode: .image),
        ]
        let data = RSSImportService.exportJSON(sources: sources)
        let candidates = try RSSImportService.parse(data: data, format: .json)
        XCTAssertEqual(candidates.map(\.name), ["A", "B"])
        XCTAssertEqual(candidates.map(\.displayMode), [.text, .image])
    }

    // MARK: - OPML export groups

    func test_opmlExport_nestsFoldersAndRoundTrips() throws {
        let subscriptions = [
            OPMLSubscription(title: "A", url: "https://example.com/a.xml", group: "Tech"),
            OPMLSubscription(title: "B", url: "https://example.com/b.xml"),
        ]
        let data = OPMLService.export(subscriptions)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("<outline text=\"Tech\""))
        let parsed = try OPMLService.parse(data)
        XCTAssertEqual(parsed.first { $0.url.hasSuffix("a.xml") }?.group, "Tech")
        XCTAssertNil(parsed.first { $0.url.hasSuffix("b.xml") }?.group)
    }
}
