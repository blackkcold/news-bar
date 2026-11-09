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

    private(set) var state: State = .idle
    private(set) var summary: PageSummary?
    private(set) var isPrivate = false
    private(set) var input: PageSummaryInput?
    private(set) var errorMessage: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let store: PageSummaryCacheStore

    init(store: PageSummaryCacheStore = .shared) {
        self.store = store
    }

    var isBusy: Bool { state.isBusy }

    func summarize(input: PageSummaryInput, settings: AppSettings) {
        self.input = input
        isPrivate = input.isPrivate
        task?.cancel()
        generation += 1
        let currentGeneration = generation
        state = .loading
        errorMessage = nil

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (configuration, providerName) = try await self.resolve(settings: settings)
                try Task.checkCancellation()
                guard self.generation == currentGeneration else { return }

                let key = input.cacheKey(
                    model: configuration.model,
                    providerID: configuration.providerID,
                    promptVersion: PageSummaryService.promptVersion
                )
                let token = await self.store.captureToken()

                if !input.isPrivate, let cached = await self.store.load(key: key) {
                    guard self.generation == currentGeneration, !Task.isCancelled else { return }
                    self.summary = cached
                    self.state = .ready
                    self.errorMessage = nil
                    return
                }

                let result = try await PageSummaryService.summarize(
                    input: input,
                    configuration: configuration,
                    providerName: providerName,
                    quotaPolicy: settings.aiQuotaPolicy,
                    thinking: settings.aiSearchThinking
                )
                try Task.checkCancellation()
                guard self.generation == currentGeneration else { return }

                self.summary = result
                self.state = .ready
                self.errorMessage = nil
                if !input.isPrivate {
                    await self.store.save(result, key: key, token: token)
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == currentGeneration else { return }
                let message = Self.message(for: error, language: settings.appLanguage)
                self.state = .failed(message)
                self.errorMessage = message
            }
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
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
