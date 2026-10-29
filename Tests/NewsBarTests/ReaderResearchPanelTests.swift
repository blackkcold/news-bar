import XCTest
@testable import NewsBar

@MainActor
final class ReaderResearchPanelTests: XCTestCase {
    func testCurrentPageMatchAndRecentResearch() async throws {
        let store = ResearchStore(directoryURL: try researchTestDirectory())
        let item = NewsItem(title: "Original", url: "https://example.org/original", source: .weibo)
        var original = researchTestRecord(title: "Original")
        original.seed.itemID = item.id
        original.seed.url = item.url
        try await store.save(original)
        for number in 1...6 {
            try await store.save(researchTestRecord(title: "Recent \(number)", updatedAt: Date().addingTimeInterval(Double(number))))
        }
        let model = ReaderResearchPanelModel(store: store)
        await model.refresh(item: item, requestURL: item.url, currentURL: item.url, title: item.title)
        XCTAssertEqual(model.match?.id, original.id)
        XCTAssertEqual(model.recent.count, 5)
        XCTAssertEqual(model.record?.id, original.id)

        await model.refresh(item: item, requestURL: item.url, currentURL: "https://example.org/other", title: "Other")
        XCTAssertNil(model.match)
        XCTAssertNil(model.record)
        XCTAssertEqual(model.recent.count, 5)
    }

    func testVerificationUsesCurrentPageNotPreviousArticle() throws {
        let item = NewsItem(title: "Original", url: "https://example.org/original", source: .weibo)
        let original = ReaderResearchPanelModel.verificationItem(
            original: item, requestURL: item.url, currentURL: item.url, title: item.title
        )
        XCTAssertEqual(original?.id, item.id)

        let current = try XCTUnwrap(ReaderResearchPanelModel.verificationItem(
            original: item, requestURL: item.url, currentURL: "https://example.org/other", title: "Other page"
        ))
        XCTAssertEqual(current.url, "https://example.org/other")
        XCTAssertEqual(current.title, "Other page")
        XCTAssertNotEqual(current.id, item.id)
        XCTAssertNil(ReaderResearchPanelModel.verificationItem(
            original: item, requestURL: item.url, currentURL: "file:///private/secret", title: "Other page"
        ))
    }
}
