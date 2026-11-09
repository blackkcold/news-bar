import XCTest
@testable import NewsBar

@MainActor
final class ReaderAuxiliaryModelTests: XCTestCase {
    private func context(
        title: String = "A page",
        url: String = "https://example.com/a",
        isPrivate: Bool = false,
        language: AppLanguage = .en
    ) -> ReaderOverviewContext {
        ReaderOverviewContext(title: title, url: url, isPrivate: isPrivate, language: language)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testToggleSameTabClosesAndSwitchingKeepsSearchSurface() {
        let model = ReaderAuxiliaryModel()
        XCTAssertFalse(model.isOpen)

        model.open(.search)
        XCTAssertEqual(model.tab, .search)
        model.toggle(.search)
        XCTAssertNil(model.tab)
        XCTAssertFalse(model.isOpen)

        model.searchSurface = .web
        model.open(.overview)
        XCTAssertEqual(model.tab, .overview)
        model.open(.search)
        XCTAssertEqual(model.tab, .search)
        XCTAssertEqual(model.searchSurface, .web)
    }

    func testPrepareOverviewExtractsBodyAndStopsAtDisclosure() async {
        let model = ReaderAuxiliaryModel()
        model.open(.overview)
        model.prepareOverview(context: context()) { "page body" }

        await waitUntil { model.overviewInput != nil }

        XCTAssertEqual(model.overviewInput?.articleText, "page body")
        XCTAssertEqual(model.overviewInput?.scope, .article)
        XCTAssertEqual(model.phase, .disclosure)
        XCTAssertTrue(model.isPreparingOverview == false)
    }

    func testUnreadableTextBecomesUnavailable() async {
        let model = ReaderAuxiliaryModel()
        model.open(.overview)
        model.prepareOverview(context: context()) { "   \n" }

        await waitUntil {
            if case .unavailable = model.phase { return true }
            return false
        }

        guard case .unavailable(let message) = model.phase else {
            return XCTFail("expected unavailable, got \(model.phase)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(model.overviewInput)
    }

    func testCloseCancelsPreparationWithoutPublishingLateText() async {
        let model = ReaderAuxiliaryModel()
        model.open(.overview)
        model.prepareOverview(context: context()) {
            try? await Task.sleep(for: .milliseconds(80))
            return "late body"
        }

        model.close()
        try? await Task.sleep(for: .milliseconds(160))

        XCTAssertNil(model.overviewInput)
        XCTAssertFalse(model.isPreparingOverview)
        XCTAssertNil(model.tab)
    }

    func testReopeningTheSamePageReusesTheExtractedBody() async {
        let model = ReaderAuxiliaryModel()
        var calls = 0
        let ctx = context()

        model.open(.overview)
        model.prepareOverview(context: ctx) {
            calls += 1
            return "first body"
        }
        await waitUntil { model.overviewInput != nil }
        XCTAssertEqual(calls, 1)

        model.close()
        model.open(.overview)
        model.prepareOverview(context: ctx) {
            calls += 1
            return "second body"
        }
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.overviewInput?.articleText, "first body")
        XCTAssertEqual(model.phase, .disclosure)
    }

    func testAcknowledgmentIsPerPageAndClearedByNavigation() async {
        let model = ReaderAuxiliaryModel()
        let ctx = context()
        model.open(.overview)
        model.prepareOverview(context: ctx) { "body" }
        await waitUntil { model.overviewInput != nil }

        XCTAssertFalse(model.isAcknowledged)
        model.acknowledgeOverview()
        XCTAssertTrue(model.isAcknowledged)
        XCTAssertEqual(model.phase, .readyToGenerate)

        model.close()
        model.open(.overview)
        model.prepareOverview(context: ctx) { "body" }
        XCTAssertTrue(model.isAcknowledged)
        XCTAssertEqual(model.phase, .readyToGenerate)

        model.resetForNavigation()
        XCTAssertFalse(model.isAcknowledged)
        XCTAssertNil(model.overviewContext)
        XCTAssertNil(model.overviewInput)
        XCTAssertNil(model.tab)
    }

    func testNewPageStartsWithDisclosureAgain() async {
        let model = ReaderAuxiliaryModel()
        model.open(.overview)
        model.prepareOverview(context: context(url: "https://example.com/a")) { "body a" }
        await waitUntil { model.overviewInput != nil }
        model.acknowledgeOverview()
        XCTAssertTrue(model.isAcknowledged)

        model.prepareOverview(context: context(url: "https://example.com/b")) { "body b" }
        await waitUntil { model.overviewInput?.articleText == "body b" }

        XCTAssertFalse(model.isAcknowledged)
        XCTAssertEqual(model.phase, .disclosure)
    }
}
