import XCTest
@testable import NewsBar

@MainActor
final class SelectionExplainModelTests: XCTestCase {
    func testExplainMovesFromLoadingToReady() async throws {
        let model = SelectionExplainModel(explainer: { text in
            try await Task.sleep(for: .milliseconds(10))
            return "explained: \(text)"
        })
        model.explain("hello", settings: AppSettings())
        XCTAssertEqual(model.state, .loading)
        await waitUntil { model.state == .ready("explained: hello") }
        XCTAssertEqual(model.state, .ready("explained: hello"))
        XCTAssertEqual(model.selection, "hello")
    }

    func testQuotaDenialBecomesQuotaState() async {
        let model = SelectionExplainModel(explainer: { _ in
            throw SelectionExplainService.Failure.quotaUnavailable
        })
        model.explain("hello", settings: AppSettings())
        await waitUntil { model.state == .quota }
        XCTAssertEqual(model.state, .quota)
    }

    func testUnauthorizedKeyBecomesActionableFailure() async {
        let model = SelectionExplainModel(explainer: { _ in
            throw AIChatError.unauthorized
        })
        let settings = AppSettings()
        model.explain("hello", settings: settings)
        await waitUntil {
            if case .failed = model.state { return true }
            return false
        }
        guard case .failed(let message) = model.state else {
            return XCTFail("expected a failed state")
        }
        XCTAssertEqual(message, L10n.string("reader.selection.unauthorized", language: settings.appLanguage))
    }

    func testDismissResetsAndIgnoresLateAnswer() async throws {
        let model = SelectionExplainModel(explainer: { _ in
            try await Task.sleep(for: .milliseconds(80))
            return "late"
        })
        model.explain("hello", settings: AppSettings())
        model.dismiss()
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.selection, "")
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertEqual(model.state, .idle)
    }

    func testEmptySelectionIsIgnored() {
        let model = SelectionExplainModel(explainer: { _ in "unused" })
        model.explain("  \n ", settings: AppSettings())
        XCTAssertEqual(model.state, .idle)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
