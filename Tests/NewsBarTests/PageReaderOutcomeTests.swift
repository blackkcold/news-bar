import XCTest
@testable import NewsBar

final class PageReaderOutcomeTests: XCTestCase {
    private func reader(
        scrape: @escaping PageReader.Scrape = { _, _ in "" },
        transport: @escaping DirectHTMLReader.Transport,
        isScrapeEnabled: Bool = false
    ) -> PageReader {
        PageReader(
            cache: ResearchCacheStore(),
            scrape: scrape,
            direct: DirectHTMLReader(
                transport: transport,
                resolver: { _ in ["93.184.216.34"] }
            ),
            isScrapeEnabled: isScrapeEnabled
        )
    }

    private func hit(
        _ url: String = "https://example.com/a",
        inline: String? = nil
    ) -> SearchHit {
        SearchHit(
            url: url,
            title: "A",
            snippet: "",
            inlineContent: inline,
            provider: .tavily,
            providerRank: 1
        )
    }

    func testShortInlineContentIsTooShort() async throws {
        let reader = reader(transport: { _ in throw URLError(.cannotConnectToHost) })
        let outcome = try await reader.readOutcome(hit("https://short-inline.example/a", inline: "短"), apiKey: "")
        XCTAssertEqual(outcome, .tooShort(1))
    }

    func testInlineContentAboveTheFloorIsADocument() async throws {
        let reader = reader(transport: { _ in throw URLError(.cannotConnectToHost) })
        let inline = String(repeating: "正文", count: 250)
        let outcome = try await reader.readOutcome(hit("https://long-inline.example/a", inline: inline), apiKey: "")
        guard case .document(let document) = outcome else {
            return XCTFail("expected a document, got \(outcome)")
        }
        XCTAssertEqual(document.source, .inline)
        XCTAssertEqual(document.url, "https://long-inline.example/a")
    }

    func testDirectTransportFailureIsTypedNotSwallowed() async throws {
        let reader = reader(transport: { _ in throw URLError(.cannotConnectToHost) })
        let outcome = try await reader.readOutcome(hit("https://direct-failure.example/a"), apiKey: "")
        XCTAssertEqual(outcome, .failed(.transport))
    }

    func testShortScrapeFallsThroughAndIsReportedAsTooShort() async throws {
        let reader = reader(
            scrape: { _, _ in "短" },
            transport: { _ in throw URLError(.cannotConnectToHost) },
            isScrapeEnabled: true
        )
        let outcome = try await reader.readOutcome(hit("https://short-scrape.example/a"), apiKey: "key")
        XCTAssertEqual(outcome, .tooShort(1))
    }

    func testReadWrapperStillReturnsNilForUnreadablePages() async throws {
        let reader = reader(transport: { _ in throw URLError(.cannotConnectToHost) })
        let document = try await reader.read(hit("https://read-wrapper.example/a"), apiKey: "")
        XCTAssertNil(document)
    }
}
