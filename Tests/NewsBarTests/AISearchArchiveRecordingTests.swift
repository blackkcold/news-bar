import XCTest
@testable import NewsBar

@MainActor
final class AISearchArchiveRecordingTests: XCTestCase {
    func testPolicyRejectsDisabledPrivateAndOfflineRuns() {
        XCTAssertFalse(AISearchArchivePolicy.shouldRecord(
            isEnabled: false,
            isPrivateSession: false,
            isPrivateReading: false,
            mode: .web
        ))
        XCTAssertFalse(AISearchArchivePolicy.shouldRecord(
            isEnabled: true,
            isPrivateSession: true,
            isPrivateReading: false,
            mode: .currentPage
        ))
        XCTAssertFalse(AISearchArchivePolicy.shouldRecord(
            isEnabled: true,
            isPrivateSession: false,
            isPrivateReading: true,
            mode: .web
        ))
        XCTAssertFalse(AISearchArchivePolicy.shouldRecord(
            isEnabled: true,
            isPrivateSession: false,
            isPrivateReading: false,
            mode: .offline
        ))
    }

    func testPolicyAllowsSuccessfulPublicOnlineRun() {
        XCTAssertTrue(AISearchArchivePolicy.shouldRecord(
            isEnabled: true,
            isPrivateSession: false,
            isPrivateReading: false,
            mode: .currentPage
        ))
        XCTAssertTrue(AISearchArchivePolicy.shouldRecord(
            isEnabled: true,
            isPrivateSession: false,
            isPrivateReading: false,
            mode: .web
        ))
    }

    func testReaderSearchRecordsOnceAfterSuccessfulCompletion() async {
        let controller = AISearchArchiveController(
            store: AISearchArchiveStore(persistence: MemoryAISearchArchivePersistence())
        )
        let context = AISearchPageContext(
            url: "https://reader.example/article?edition=zh",
            title: "Current article",
            text: "Current page text is only passed in memory."
        )
        let runnerPages = CapturedReaderPage()
        let model = AISearchPanelModel(runner: { question, scope, page, _ in
            await runnerPages.set(page)
            return recordingDocument("answer: \(question)", mode: scope == .currentPage ? .currentPage : .web)
        })
        model.pageContextProvider = { context }
        model.onCompletion = { query, scope, page, answer in
            await controller.record(AISearchArchiveEntry(
                query: query,
                scope: scope,
                origin: .readerSearch,
                pageTitle: page?.title,
                pageURL: page?.url,
                providerName: "Test provider",
                answer: answer
            ))
        }

        model.runInjected(question: "  query  ", scope: .web, page: nil)
        await waitUntil { model.state == .done && controller.entries.count == 1 }

        XCTAssertEqual(controller.entries.count, 1)
        XCTAssertEqual(controller.entries.first?.query, "query")
        XCTAssertEqual(controller.entries.first?.pageTitle, "Current article")
        XCTAssertEqual(controller.entries.first?.pageURL, "https://reader.example/article?edition=zh")
        XCTAssertEqual(controller.entries.first?.answer.providerName, "Test provider")
        let pagePassedToWebRunner = await runnerPages.value()
        XCTAssertNil(pagePassedToWebRunner)
    }

    func testReaderFailureAndCancellationDoNotRecord() async {
        var failureCallbacks = 0
        let failed = AISearchPanelModel(runner: { _, _, _, _ in
            throw AISearchError.noSourcesReadable
        })
        failed.onCompletion = { _, _, _, _ in failureCallbacks += 1 }
        failed.runInjected(question: "failure", scope: .web, page: nil)
        await waitUntil {
            if case .failed = failed.state { return true }
            return false
        }
        XCTAssertEqual(failureCallbacks, 0)

        let signal = ReaderRunnerSignal()
        var cancellationCallbacks = 0
        let cancelled = AISearchPanelModel(runner: { _, _, _, _ in
            await signal.markStarted()
            try await Task.sleep(for: .seconds(10))
            return recordingDocument("late answer", mode: .web)
        })
        cancelled.onCompletion = { _, _, _, _ in cancellationCallbacks += 1 }
        cancelled.runInjected(question: "cancel", scope: .web, page: nil)

        let deadline = Date().addingTimeInterval(2)
        while !(await signal.didStart()) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let runnerStarted = await signal.didStart()
        XCTAssertTrue(runnerStarted)
        cancelled.dismiss()
        try? await Task.sleep(for: .milliseconds(25))

        XCTAssertEqual(cancelled.state, .idle)
        XCTAssertEqual(cancellationCallbacks, 0)
    }

    func testSelectionOnlineLookupRecordsButOfflineAndFallbackDoNot() async {
        let settings = AppSettings()
        let oldMode = settings.selectionWebMode
        let oldProviders = settings.researchSearchProviders
        let oldSearchEnabled = settings.aiSearchEnabled
        defer {
            settings.selectionWebMode = oldMode
            settings.researchSearchProviders = oldProviders
            settings.aiSearchEnabled = oldSearchEnabled
        }
        settings.aiSearchEnabled = true
        settings.researchSearchProviders = [SearchProviderID.tavily.rawValue]

        var actualQueries: [String] = []
        let explicit = SelectionExplainModel(
            explainer: { text in recordingDocument("offline: \(text)", mode: .offline) },
            onlineAnswer: { query in recordingDocument("online: \(query)", mode: .web) }
        )
        explicit.onOnlineCompletion = { query, _ in actualQueries.append(query) }
        settings.selectionWebMode = .offline
        explicit.explain("selected text", settings: settings)
        await waitUntil { explicit.readyDocument != nil }
        explicit.requestLookUp()
        explicit.confirmLookUp(settings: settings)
        await waitUntil { actualQueries.count == 1 }
        XCTAssertEqual(actualQueries, ["selected text"])

        let offline = SelectionExplainModel(
            explainer: { text in recordingDocument("offline: \(text)", mode: .offline) },
            onlineAnswer: { query in recordingDocument("unexpected: \(query)", mode: .web) }
        )
        offline.onOnlineCompletion = { query, _ in actualQueries.append(query) }
        offline.explain("plain concept", settings: settings)
        await waitUntil { offline.readyDocument != nil }
        XCTAssertEqual(actualQueries, ["selected text"])

        settings.selectionWebMode = .auto
        let fallback = SelectionExplainModel(
            explainer: { text in recordingDocument("fallback: \(text)", mode: .offline) },
            planner: { _ in SelectionPlan(kind: .event, needsLookup: true, query: "failed actual query") },
            onlineAnswer: { _ in throw URLError(.notConnectedToInternet) }
        )
        fallback.onOnlineCompletion = { query, _ in actualQueries.append(query) }
        fallback.explain("news event", settings: settings)
        await waitUntil { fallback.lookupNotice == .lookupFailed && fallback.readyDocument != nil }
        XCTAssertEqual(actualQueries, ["selected text"])

        let automatic = SelectionExplainModel(
            explainer: { text in recordingDocument("offline: \(text)", mode: .offline) },
            planner: { _ in SelectionPlan(kind: .event, needsLookup: true, query: "actual planned query") },
            onlineAnswer: { query in recordingDocument("online: \(query)", mode: .web) }
        )
        automatic.onOnlineCompletion = { query, _ in actualQueries.append(query) }
        automatic.explain("another news event", settings: settings)
        await waitUntil { automatic.readyDocument?.mode == .web }
        XCTAssertEqual(actualQueries, ["selected text", "actual planned query"])
    }

    func testArchiveWriteFailureDoesNotChangeSuccessfulAnswerState() async {
        let controller = AISearchArchiveController(
            store: AISearchArchiveStore(persistence: FailingAISearchArchivePersistence())
        )
        let model = AISearchPanelModel(runner: { question, _, _, _ in
            recordingDocument("answer: \(question)", mode: .web)
        })
        model.onCompletion = { query, scope, page, answer in
            await controller.record(AISearchArchiveEntry(
                query: query,
                scope: scope,
                origin: .readerSearch,
                pageTitle: page?.title,
                pageURL: page?.url,
                providerName: "Test provider",
                answer: answer
            ))
        }

        model.runInjected(question: "write failure", scope: .web, page: nil)
        await waitUntil { model.state == .done && controller.storageError != nil }

        XCTAssertEqual(model.state, .done)
        XCTAssertNotNil(controller.storageError)
        XCTAssertTrue(controller.entries.isEmpty)
    }

    func testArchiveEnabledPreferenceDefaultsOnAndPersists() {
        let defaults = UserDefaults.standard
        let key = "aiSearchHistoryEnabled"
        let oldValue = defaults.object(forKey: key)
        let oldLanguage = L10n.currentLanguage
        defer {
            if let oldValue {
                defaults.set(oldValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            L10n.currentLanguage = oldLanguage
        }

        defaults.removeObject(forKey: key)
        XCTAssertTrue(AppSettings().aiSearchHistoryEnabled)
        let settings = AppSettings()
        settings.aiSearchHistoryEnabled = false
        XCTAssertFalse(AppSettings().aiSearchHistoryEnabled)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private func recordingDocument(_ text: String, mode: AnswerMode) -> AnswerDocument {
    AnswerDocument(
        kind: .event,
        oneLine: text,
        blocks: [AnswerBlock(id: 1, heading: "Heading", body: text)],
        sources: [],
        mode: mode,
        model: "test-model",
        thinking: .medium,
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        question: nil
    )
}

private actor MemoryAISearchArchivePersistence: AISearchArchivePersisting {
    private var data: Data?

    func load() async throws -> Data? { data }
    func save(_ data: Data) async throws { self.data = data }
    func clear() async throws { data = nil }
}

private actor FailingAISearchArchivePersistence: AISearchArchivePersisting {
    private enum Failure: Error { case writeFailed }

    func load() async throws -> Data? { nil }
    func save(_ data: Data) async throws { throw Failure.writeFailed }
    func clear() async throws {}
}

private actor CapturedReaderPage {
    private var page: AISearchPageContext?

    func set(_ page: AISearchPageContext?) { self.page = page }
    func value() -> AISearchPageContext? { page }
}

private actor ReaderRunnerSignal {
    private var started = false

    func markStarted() { started = true }
    func didStart() -> Bool { started }
}

private extension SelectionExplainModel {
    var readyDocument: AnswerDocument? {
        if case .ready(let answer) = state { return answer }
        return nil
    }
}
