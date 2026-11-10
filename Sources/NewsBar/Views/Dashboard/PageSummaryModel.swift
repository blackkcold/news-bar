import Foundation
import Observation

/// Presentation state for one page overview. A new rail owns a new model, so
/// one page's request can never publish into another page's card.
@MainActor
@Observable
final class PageSummaryModel {
    enum State: Equatable {
        case idle
        case loading
        case ready
        case failed(String)

        var isBusy: Bool {
            if case .loading = self { return true }
            return false
        }
    }

    /// Optional external-evidence stages. The panel turns these into the
    /// compact "search › read › assess › summarize" row.
    enum Stage: Equatable {
        case idle
        case searchingExternal
        case reading(index: Int, total: Int)
        case assessingExternal
        case summarizing
    }

    private(set) var state: State = .idle
    private(set) var summary: PageSummary?
    private(set) var isPrivate = false
    private(set) var input: PageSummaryInput?
    private(set) var errorMessage: String?
    private(set) var stage: Stage = .idle

    /// Per-run toggle. The rail sets the initial value from the user's setting
    /// when the page is prepared; private reading forces it off.
    var webSupplementEnabled = true

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let store: PageSummaryCacheStore

    init(store: PageSummaryCacheStore = .shared) {
        self.store = store
    }

    var isBusy: Bool { state.isBusy }

    func summarize(
        input: PageSummaryInput,
        settings: AppSettings,
        forceRefresh: Bool = false
    ) {
        self.input = input
        isPrivate = input.isPrivate
        task?.cancel()
        generation += 1
        let currentGeneration = generation
        state = .loading
        errorMessage = nil
        stage = .idle

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (configuration, providerName) = try await self.resolve(settings: settings)
                try Task.checkCancellation()
                guard self.generation == currentGeneration else { return }

                // Freeze the level before the cache lookup so the key and the
                // request can never disagree if the setting changes while the
                // async request is in flight.
                let thinking = settings.aiOverviewThinking
                let effectiveStyle = AIThinkingResolver.effectiveStyle(
                    connection: configuration.connection,
                    model: configuration.model
                )
                let webSupplement = PageSummaryEvidencePolicy.shouldSearch(
                    isPrivate: input.isPrivate,
                    webSupplement: self.webSupplementEnabled,
                    scope: input.scope
                )
                let providerIDs = settings.researchSearchProviders.sorted()
                let key = input.cacheKey(
                    model: configuration.model,
                    providerID: configuration.providerID,
                    promptVersion: PageSummaryService.promptVersion,
                    thinking: thinking,
                    thinkingStyle: effectiveStyle,
                    webSupplement: webSupplement,
                    searchProviderIDs: providerIDs,
                    evidenceAssessmentEnabled: settings.aiEvidenceAssessmentEnabled
                )
                let token = await self.store.captureToken()

                if !input.isPrivate, !forceRefresh,
                   let cached = await self.store.load(key: key) {
                    guard self.generation == currentGeneration, !Task.isCancelled else { return }
                    self.summary = cached
                    self.state = .ready
                    self.errorMessage = nil
                    self.stage = .idle
                    return
                }

                var evidence = PageSummaryEvidence.pageOnly
                var ttl = PageSummaryEvidencePolicy.cacheTTL(
                    webSupplement: false,
                    adoptedExternalCount: 0
                )
                if webSupplement {
                    let provider = await PageSummaryEvidenceFactory.make(
                        settings: settings,
                        configuration: configuration
                    )
                    let result = await provider.collect(
                        title: input.title,
                        excerpt: String((input.articleText ?? "").prefix(500)),
                        currentPageURL: input.url ?? "",
                        language: settings.appLanguage
                    ) { [weak self] stage in
                        await MainActor.run {
                            guard let self, self.generation == currentGeneration else { return }
                            self.stage = Self.stage(from: stage)
                        }
                    }
                    try Task.checkCancellation()
                    guard self.generation == currentGeneration else { return }
                    evidence = result.evidence
                    ttl = PageSummaryEvidencePolicy.cacheTTL(
                        webSupplement: true,
                        adoptedExternalCount: evidence.retrieval?.adoptedCount ?? 0
                    )
                }

                self.stage = .summarizing
                let result = try await PageSummaryService.summarize(
                    input: input,
                    configuration: configuration,
                    providerName: providerName,
                    quotaPolicy: settings.aiQuotaPolicy,
                    thinking: thinking,
                    evidence: evidence
                )
                try Task.checkCancellation()
                guard self.generation == currentGeneration else { return }

                self.summary = result
                self.state = .ready
                self.errorMessage = nil
                self.stage = .idle
                if !input.isPrivate {
                    await self.store.save(
                        result,
                        key: key,
                        token: token,
                        ttl: ttl
                    )
                }
            } catch is CancellationError {
                self.stage = .idle
                return
            } catch {
                guard self.generation == currentGeneration else { return }
                let message = Self.message(for: error, language: settings.appLanguage)
                self.state = .failed(message)
                self.errorMessage = message
                self.stage = .idle
            }
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        stage = .idle
        if state.isBusy {
            state = summary == nil ? .idle : .ready
        }
    }

    /// Clears everything owned by this page overview. Used when the reader
    /// navigates to another page; a close keeps a finished summary so the same
    /// page can be reopened without a second request.
    func reset() {
        generation += 1
        task?.cancel()
        task = nil
        state = .idle
        summary = nil
        isPrivate = false
        input = nil
        errorMessage = nil
        stage = .idle
    }

    private static func stage(from stage: PageSummaryEvidenceStage) -> Stage {
        switch stage {
        case .searching:
            return .searchingExternal
        case .reading(let index, let total):
            return .reading(index: index, total: total)
        case .assessing:
            return .assessingExternal
        }
    }

    private func resolve(settings: AppSettings) async throws -> (ValidatedAIConfiguration, String) {
        let expected = settings.aiKeyContext
        let bound: ProviderBoundKey
        do {
            bound = try await settings.resolveBoundAPIKey(expected: expected)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PageSummaryError.noKey
        }
        guard settings.isCurrentAIKey(bound) else {
            throw PageSummaryError.configurationChanged
        }
        guard !bound.key.isEmpty || settings.aiProvider == AIProvider.ollamaCloud.rawValue else {
            throw PageSummaryError.noKey
        }
        guard let configuration = await settings.validatedAIConfiguration(boundKey: bound) else {
            throw settings.aiModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? PageSummaryError.noModel
                : PageSummaryError.configurationChanged
        }
        return (configuration, settings.providerDisplayName(forID: configuration.providerID))
    }

    private static func message(for error: Error, language: AppLanguage) -> String {
        if let error = error as? PageSummaryError {
            return error.message(language)
        }
        if let error = error as? AIChatError {
            switch error {
            case .unauthorized: return PageSummaryError.unauthorized.message(language)
            case .quotaUnavailable: return PageSummaryError.quotaUnavailable.message(language)
            case .timeout, .transport, .server, .rateLimited, .malformedResponse, .emptyResponse:
                return PageSummaryError.modelFailed(error.localizedDescription).message(language)
            case .invalidURL:
                return PageSummaryError.configurationChanged.message(language)
            }
        }
        return PageSummaryError.modelFailed(error.localizedDescription).message(language)
    }
}
