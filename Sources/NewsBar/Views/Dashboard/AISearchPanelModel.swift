import Foundation
import Observation

/// Presentation state for the reader AI search overlay.
///
/// The model owns the state machine (idle → searching/reading → answering →
/// done/failed) and the live wiring; `AISearchService` owns the orchestration
/// and is injected in tests through `runner`.
@MainActor
@Observable
final class AISearchPanelModel {
    enum State: Equatable {
        case idle
        case searching
        case reading(index: Int, total: Int)
        case answering
        case done
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .searching, .reading, .answering: return true
            case .idle, .done, .failed: return false
            }
        }
    }

    var question = ""
    var scope: AISearchScope = .currentPage
    private(set) var state: State = .idle
    @ObservationIgnored private let reveal = AnswerReveal()
    var answer: AnswerDocument? { reveal.document }
    var isRevealing: Bool { reveal.isStreaming }

    /// Wired by the reader so Reduce Motion can bypass the typewriter.
    func setRevealEnabled(_ enabled: Bool) {
        reveal.isEnabled = enabled
    }
    private(set) var progress: Double = 0
    private(set) var lastQuestion = ""
    private(set) var lastScope: AISearchScope = .currentPage
    private(set) var hasAcknowledgedPrivacy: Bool
    var isPresented = false

    /// Supplied by the reader view. It captures the reader model only, so it
    /// can be called on the main actor without capturing a SwiftUI view.
    @ObservationIgnored var pageContextProvider: (@MainActor () async -> AISearchPageContext?)?
    @ObservationIgnored var onCompletion: (@MainActor (
        String,
        AISearchScope,
        AISearchPageContext?,
        AnswerDocument
    ) async -> Void)?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let runner: Runner?

    typealias Runner = @Sendable (
        _ question: String,
        _ scope: AISearchScope,
        _ page: AISearchPageContext?,
        _ onStage: @Sendable (AISearchStage) async -> Void
    ) async throws -> AnswerDocument

    init(runner: Runner? = nil) {
        self.runner = runner
        self.hasAcknowledgedPrivacy = UserDefaults.standard.bool(forKey: Self.privacyKey)
    }

    static let privacyKey = "aiSearchPrivacyAcknowledged"

    // MARK: - Presentation

    func present() {
        isPresented = true
    }

    func dismiss() {
        task?.cancel()
        task = nil
        isPresented = false
        state = .idle
        reveal.reset()
        progress = 0
    }

    func acknowledgePrivacy() {
        hasAcknowledgedPrivacy = true
        UserDefaults.standard.set(true, forKey: Self.privacyKey)
    }

    // MARK: - Actions

    func submit(settings: AppSettings) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        start(question: trimmed, scope: scope, settings: settings)
    }

    func retry(settings: AppSettings) {
        guard !lastQuestion.isEmpty else { return }
        start(question: lastQuestion, scope: lastScope, settings: settings)
    }

    /// Test seam: run an injected service without settings, keychain or network.
    func runInjected(
        question: String,
        scope: AISearchScope,
        page: AISearchPageContext?
    ) {
        guard let runner else { return }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        task?.cancel()
        lastQuestion = trimmed
        lastScope = scope
        reveal.reset()
        reveal.begin()
        state = .searching
        progress = 0.1
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let archiveContext = await self.pageContextProvider?() ?? page
                try Task.checkCancellation()
                let result = try await runner(trimmed, scope, page) { stage in
                    await MainActor.run { self.apply(stage) }
                }
                try Task.checkCancellation()
                self.reveal.finish(with: result)
                self.state = .done
                self.progress = 1
                await self.onCompletion?(trimmed, scope, archiveContext, result)
            } catch {
                self.handle(error, language: L10n.currentLanguage)
            }
        }
    }

    private func start(
        question: String,
        scope: AISearchScope,
        settings: AppSettings
    ) {
        task?.cancel()
        lastQuestion = question
        lastScope = scope
        reveal.reset()
        reveal.begin()
        state = .searching
        progress = 0.1
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let service = try await self.makeService(settings: settings)
                let archiveContext = await self.pageContextProvider?()
                try Task.checkCancellation()
                let page = scope == .currentPage ? archiveContext : nil
                let result = try await service.run(question: question, scope: scope, page: page) { stage in
                    await MainActor.run { self.apply(stage) }
                }
                try Task.checkCancellation()
                self.reveal.finish(with: result)
                self.state = .done
                self.progress = 1
                await self.onCompletion?(question, scope, archiveContext, result)
            } catch {
                self.handle(error, language: settings.appLanguage)
            }
        }
    }

    private func apply(_ stage: AISearchStage) {
        switch stage {
        case .searching:
            state = .searching
            progress = 0.15
        case .reading(let index, let total):
            state = .reading(index: index, total: total)
            progress = 0.2 + 0.5 * Double(index) / Double(max(1, total))
        case .answering:
            state = .answering
            progress = 0.8
        }
    }

    private func handle(_ error: Error, language: AppLanguage) {
        if error is CancellationError { return }
        if let searchError = error as? AISearchError {
            state = .failed(searchError.message(language))
        } else {
            state = .failed(AISearchError.modelFailed(error.localizedDescription).message(language))
        }
        progress = 0
    }

    // MARK: - Live wiring

    private func makeService(settings: AppSettings) async throws -> AISearchService {
        try await AISearchServiceFactory.make(settings: settings) { document in
            Task { @MainActor [weak self] in
                self?.reveal.receive(document)
            }
        }
    }
}
