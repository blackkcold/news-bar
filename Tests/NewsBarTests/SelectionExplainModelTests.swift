import XCTest
@testable import NewsBar

@MainActor
final class SelectionExplainModelTests: XCTestCase {
    func testExplainMovesFromLoadingToReady() async throws {
        let model = SelectionExplainModel(explainer: { text in
            try await Task.sleep(for: .milliseconds(10))
            return self.document("explained: \(text)")
        })
        model.explain("hello", settings: AppSettings())
        XCTAssertEqual(model.state, .loading)
        await waitUntil { model.readyDocument != nil }
        XCTAssertEqual(model.readyDocument?.oneLine, "explained: hello")
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
            return self.document("late")
        })
        model.explain("hello", settings: AppSettings())
        model.dismiss()
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.selection, "")
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertEqual(model.state, .idle)
    }

    func testEmptySelectionIsIgnored() {
        let model = SelectionExplainModel(explainer: { _ in self.document("unused") })
        model.explain("  \n ", settings: AppSettings())
        XCTAssertEqual(model.state, .idle)
    }

    func testReadyDocumentIsAlwaysOfflineWithNoSources() {
        let document = self.document("一句")
        XCTAssertTrue(document.isOffline)
        XCTAssertTrue(document.sources.isEmpty)
        XCTAssertEqual(document.evidence.citedCount, 0)
    }

    // MARK: - Automatic mode routing

    func testAutoWithAJudgedTermExplainsOffline() async {
        let scope = AutoSettingsScope()
        defer { scope.restore() }

        let model = SelectionExplainModel(
            explainer: { _ in self.document("offline") },
            planner: { _ in SelectionPlan(kind: .term, needsLookup: false, query: "熵") },
            onlineAnswer: { _ in self.webDocument("online") }
        )
        model.explain("熵是热力学中衡量系统无序程度的物理量。", settings: scope.settings)
        await waitUntil { model.readyDocument != nil }

        XCTAssertEqual(model.readyDocument?.oneLine, "offline")
        XCTAssertEqual(model.lookupNotice, .judgedOffline)
    }

    func testAutoSearchesWhenTheClassificationFails() async {
        let scope = AutoSettingsScope()
        defer { scope.restore() }

        let model = SelectionExplainModel(
            explainer: { _ in self.document("offline") },
            planner: { _ in nil },
            onlineAnswer: { _ in self.webDocument("online") }
        )
        model.explain("一条看起来需要核实的消息。", settings: scope.settings)
        await waitUntil { model.readyDocument != nil }

        XCTAssertEqual(model.readyDocument?.oneLine, "online")
        XCTAssertNil(model.lookupNotice)
    }

    func testAutoLooksUpAnEventEvenWhenTheModelSaysItIsNotNeeded() async {
        let scope = AutoSettingsScope()
        defer { scope.restore() }

        let model = SelectionExplainModel(
            explainer: { _ in self.document("offline") },
            planner: { _ in SelectionPlan(kind: .event, needsLookup: false, query: "发布") },
            onlineAnswer: { _ in self.webDocument("online") }
        )
        model.explain("HomePod mini 2 时隔六年更新。", settings: scope.settings)
        await waitUntil { model.readyDocument != nil }

        XCTAssertEqual(model.readyDocument?.oneLine, "online")
    }

    func testAutoWithoutASearchProviderSaysWhyItStayedOffline() async {
        let scope = AutoSettingsScope(providers: [])
        defer { scope.restore() }

        let model = SelectionExplainModel(
            explainer: { _ in self.document("offline") },
            planner: { _ in
                XCTFail("a provider-less look-up must not spend a classification call")
                return nil
            },
            onlineAnswer: { _ in self.webDocument("online") }
        )
        model.explain("一条看起来需要核实的消息。", settings: scope.settings)
        await waitUntil { model.readyDocument != nil }

        XCTAssertEqual(model.readyDocument?.oneLine, "offline")
        XCTAssertEqual(model.lookupNotice, .searchUnavailable)
    }

    func testAutoFallsBackAndSaysWhyWhenTheLookUpFails() async {
        let scope = AutoSettingsScope()
        defer { scope.restore() }

        let model = SelectionExplainModel(
            explainer: { _ in self.document("offline") },
            planner: { _ in SelectionPlan(kind: .event, needsLookup: true, query: "发布") },
            onlineAnswer: { _ in throw URLError(.notConnectedToInternet) }
        )
        model.explain("HomePod mini 2 时隔六年更新。", settings: scope.settings)
        await waitUntil { model.readyDocument != nil }

        XCTAssertEqual(model.readyDocument?.oneLine, "offline")
        XCTAssertEqual(model.lookupNotice, .lookupFailed)
    }

    private func webDocument(_ text: String) -> AnswerDocument {
        AnswerDocument(
            kind: .event,
            oneLine: text,
            blocks: [AnswerBlock(id: 0, heading: nil, body: text)],
            sources: [],
            mode: .web,
            model: "m",
            thinking: .off,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            question: nil
        )
    }

    private func document(_ text: String) -> AnswerDocument {
        AnswerDocument(
            kind: .term,
            oneLine: text,
            blocks: [AnswerBlock(id: 0, heading: nil, body: text)],
            sources: [],
            mode: .offline,
            model: "m",
            thinking: .off,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            question: nil
        )
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private extension SelectionExplainModel {
    var readyDocument: AnswerDocument? {
        if case .ready(let document) = state { return document }
        return nil
    }
}

/// Switches the app's persisted settings to automatic mode for one test and
/// puts them back afterwards, so `testDefaultModeIsOffline` and any reader test
/// still see the user's real configuration.
@MainActor
private final class AutoSettingsScope {
    let settings: AppSettings
    private let previousMode: SelectionWebMode
    private let previousProviders: [String]
    private let previousSearchEnabled: Bool

    init(providers: [String] = [SearchProviderID.brave.rawValue]) {
        let settings = AppSettings()
        self.settings = settings
        previousMode = settings.selectionWebMode
        previousProviders = settings.researchSearchProviders
        previousSearchEnabled = settings.aiSearchEnabled
        settings.selectionWebMode = .auto
        settings.researchSearchProviders = providers
        settings.aiSearchEnabled = true
    }

    func restore() {
        settings.selectionWebMode = previousMode
        settings.researchSearchProviders = previousProviders
        settings.aiSearchEnabled = previousSearchEnabled
    }
}
