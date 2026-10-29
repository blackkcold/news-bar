import Foundation
import Observation

/// Presentation state for the selected-text explanation card. Network access is
/// injected so the state machine can be tested without a provider.
@MainActor
@Observable
final class SelectionExplainModel {
    enum State: Equatable {
        case idle
        case loading
        case ready(String)
        case noKey
        case quota
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var selection = ""
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let explainer: ((String) async throws -> String)?
    @ObservationIgnored private var cachedService: SelectionExplainService?
    @ObservationIgnored private var cachedServiceIdentity: String?

    init() {
        explainer = nil
    }

    init(explainer: @escaping (String) async throws -> String) {
        self.explainer = explainer
    }

    deinit {
        task?.cancel()
    }

    func explain(_ text: String, settings: AppSettings) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        task?.cancel()
        selection = trimmed
        state = .loading
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await self.answer(for: trimmed, settings: settings)
                try Task.checkCancellation()
                self.state = .ready(answer)
            } catch is CancellationError {
                return
            } catch SelectionExplainService.Failure.quotaUnavailable {
                self.state = .quota
            } catch SelectionExplainService.Failure.emptyResponse {
                self.state = .failed(L10n.string("reader.selection.empty", language: settings.appLanguage))
            } catch AIChatError.emptyResponse {
                self.state = .failed(L10n.string("reader.selection.empty", language: settings.appLanguage))
            } catch AIChatError.unauthorized {
                self.state = .failed(L10n.string("reader.selection.unauthorized", language: settings.appLanguage))
            } catch AIChatError.rateLimited {
                self.state = .quota
            } catch {
                self.state = .failed(L10n.string("reader.selection.failed", language: settings.appLanguage))
            }
        }
    }

    func retry(settings: AppSettings) {
        guard !selection.isEmpty else { return }
        explain(selection, settings: settings)
    }

    func dismiss() {
        task?.cancel()
        task = nil
        state = .idle
        selection = ""
    }

    private func answer(for text: String, settings: AppSettings) async throws -> String {
        if let explainer {
            return try await explainer(text)
        }
        let key = await Self.resolveAPIKey(settings: settings)
        guard !key.isEmpty else {
            state = .noKey
            throw CancellationError()
        }
        let language = settings.appLanguage
        // The app-wide quota is the single authority. A selection explanation is
        // reserved and settled like any other AI call, so it cannot bypass the
        // user's count or cost limit. Reserve before dispatch; never refund.
        guard AIQuotaStore.shared.snapshot().availability.isUsable else {
            state = .failed(L10n.string("reader.selection.quotaUnavailable", language: language))
            throw CancellationError()
        }
        let policy = settings.aiQuotaPolicy
        guard let configuration = await settings.validatedAIConfiguration(apiKey: key) else {
            if let error = settings.modelCatalogError {
                state = .failed(error.message(language: language))
            } else {
                state = .noKey
            }
            throw CancellationError()
        }
        let identity = [
            configuration.connection.baseURL,
            configuration.model,
            policy.mode.rawValue,
            String(policy.countCap ?? -1),
            String(policy.costCapMicros ?? -1),
            language.rawValue,
            ContentIdentity.digest(key)
        ].joined(separator: "\n")
        let service: SelectionExplainService
        if let cachedService, cachedServiceIdentity == identity {
            service = cachedService
        } else {
            let client = HTTPAIChatClient(
                connection: configuration.connection,
                apiKey: configuration.apiKey,
                model: configuration.model,
                disableDeepSeekThinking: settings.aiDisableDeepSeekThinking,
                timeout: 25
            )
            service = SelectionExplainService(
                client: client,
                reserve: { AIQuotaStore.shared.reserve(.selection, policy: policy) },
                settle: { response, price in
                    AIQuotaStore.shared.settle(
                        reservedCostMicros: 0,
                        usage: response.usage,
                        price: price
                    )
                }
            )
            cachedService = service
            cachedServiceIdentity = identity
        }
        return try await service.explain(text, language: language)
    }

    private static func resolveAPIKey(settings: AppSettings) async -> String {
        if let cached = settings.cachedAPIKey, !cached.isEmpty { return cached }
        let key = await EncryptedKeyStore().readAPIKey(account: settings.activeAPIKeyAccount) ?? ""
        if !key.isEmpty { settings.cachedAPIKey = key }
        return key
    }
}
