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
        case ready(AnswerDocument)
        case noKey
        case quota
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var selection = ""
    /// Why `.auto` answered from model knowledge instead of the web. The badge
    /// row alone cannot say it: an offline answer reads the same whether the
    /// model judged it unnecessary or the search itself failed.
    private(set) var lookupNotice: LookupNotice?
    @ObservationIgnored private let reveal = AnswerReveal()
    /// The answer as far as it has been revealed. Non-nil while the model is
    /// still typing, which is when the panel should already show the card.
    var document: AnswerDocument? { reveal.document }
    var isRevealing: Bool { reveal.isStreaming }
    private(set) var isConfirmingLookUp = false

    enum LookupNotice: Equatable {
        /// Auto: the plan said a plain explanation is enough, so no search ran.
        case judgedOffline
        /// Auto: the search failed and the offline answer stood in for it.
        case lookupFailed
        /// Auto: no search provider is enabled, so a look-up could not run.
        case searchUnavailable
    }

    func setRevealEnabled(_ enabled: Bool) {
        reveal.isEnabled = enabled
    }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let explainer: ((String) async throws -> AnswerDocument)?
    @ObservationIgnored private let planner: ((String) async -> SelectionPlan?)?
    @ObservationIgnored private let onlineAnswer: ((String) async throws -> AnswerDocument)?
    @ObservationIgnored var onOnlineCompletion: (@MainActor (String, AnswerDocument) async -> Void)?
    @ObservationIgnored private var cachedService: SelectionExplainService?
    @ObservationIgnored private var cachedServiceIdentity: String?

    private typealias RunResult = (answer: AnswerDocument, onlineQuery: String?)

    init() {
        explainer = nil
        planner = nil
        onlineAnswer = nil
    }

    init(
        explainer: @escaping (String) async throws -> AnswerDocument,
        planner: ((String) async -> SelectionPlan?)? = nil,
        onlineAnswer: ((String) async throws -> AnswerDocument)? = nil
    ) {
        self.explainer = explainer
        self.planner = planner
        self.onlineAnswer = onlineAnswer
    }

    deinit {
        task?.cancel()
    }

    func explain(_ text: String, settings: AppSettings) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        task?.cancel()
        selection = trimmed
        lookupNotice = nil
        state = .loading
        reveal.reset()
        reveal.begin()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.run(trimmed, settings: settings)
                try Task.checkCancellation()
                self.reveal.finish(with: result.answer)
                self.state = .ready(result.answer)
                if let query = result.onlineQuery, !result.answer.isOffline {
                    await self.onOnlineCompletion?(query, result.answer)
                }
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

    /// The selection becomes a search query, which sends it to a search
    /// provider — a different disclosure than the AI provider alone. Ask first.
    func requestLookUp() {
        guard !selection.isEmpty else { return }
        isConfirmingLookUp = true
    }

    func cancelLookUp() {
        isConfirmingLookUp = false
    }

    func confirmLookUp(settings: AppSettings) {
        isConfirmingLookUp = false
        guard !selection.isEmpty else { return }
        task?.cancel()
        lookupNotice = nil
        state = .loading
        reveal.reset()
        reveal.begin()
        let query = selection
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.lookUp(query, settings: settings)
                try Task.checkCancellation()
                self.reveal.finish(with: result)
                self.state = .ready(result)
                if !result.isOffline {
                    await self.onOnlineCompletion?(query, result)
                }
            } catch is CancellationError {
                return
            } catch {
                self.reveal.reset()
                self.state = .failed(L10n.string("reader.selection.webFailed", language: settings.appLanguage))
            }
        }
    }

    func dismiss() {
        task?.cancel()
        task = nil
        state = .idle
        selection = ""
        lookupNotice = nil
        reveal.reset()
    }

    /// Routes one explanation according to the user's mode. Offline is the
    /// default; auto asks the model whether the passage needs sources; always
    /// skips the question. A failed look-up falls back to the offline answer
    /// instead of leaving the user with an error — and says so, because an
    /// unannounced fallback looks exactly like a deliberate offline answer.
    private func run(_ text: String, settings: AppSettings) async throws -> RunResult {
        switch settings.selectionWebMode {
        case .offline:
            return (try await answer(for: text, settings: settings), nil)
        case .always:
            let result = try await lookUp(text, settings: settings)
            return (result, result.isOffline ? nil : text)
        case .auto:
            // Without a provider the look-up cannot run at all. Say that up
            // front instead of spending a classification call and then falling
            // back for a reason the user cannot see.
            guard settings.aiSearchEnabled, !settings.researchSearchProviders.isEmpty else {
                lookupNotice = .searchUnavailable
                return (try await answer(for: text, settings: settings), nil)
            }
            let plan = await classify(text, settings: settings)
            guard SelectionLookupPolicy.shouldLookUp(plan, in: text) else {
                lookupNotice = .judgedOffline
                return (try await answer(for: text, settings: settings), nil)
            }
            let query = plan?.query.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            do {
                let actualQuery = query.isEmpty ? text : query
                let result = try await lookUp(actualQuery, settings: settings)
                return (result, result.isOffline ? nil : actualQuery)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lookupNotice = .lookupFailed
                return (try await answer(for: text, settings: settings), nil)
            }
        }
    }

    private func lookUp(_ query: String, settings: AppSettings) async throws -> AnswerDocument {
        if let onlineAnswer {
            return try await onlineAnswer(query)
        }
        let service = try await AISearchServiceFactory.make(
            settings: settings,
            profile: .selectionLookUp
        ) { document in
            Task { @MainActor [weak self] in
                self?.reveal.receive(document)
            }
        }
        return try await service.run(question: query, scope: .web, page: nil)
    }

    /// One small call, counted like any other. A parse failure means "look it
    /// up": a missing answer is worse than an extra search. `SelectionLookupPolicy`
    /// applies that rule, so a `nil` plan here is not a "no".
    private func classify(_ text: String, settings: AppSettings) async -> SelectionPlan? {
        if let planner {
            return await planner(text)
        }
        let key = await Self.resolveAPIKey(settings: settings)
        guard !key.isEmpty else { return nil }
        guard let configuration = await settings.validatedAIConfiguration(apiKey: key) else { return nil }
        guard AIQuotaStore.shared.snapshot().availability.isUsable else { return nil }
        guard AIQuotaStore.shared.reserve(.selection, policy: settings.aiQuotaPolicy) else { return nil }

        let client = HTTPAIChatClient(
            connection: configuration.connection,
            apiKey: configuration.apiKey,
            model: configuration.model,
            disableDeepSeekThinking: settings.aiDisableDeepSeekThinking,
            timeout: 20
        )
        let escaped = String(text.prefix(2_000))
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let request = AIChatRequest(messages: [
            AIChatMessage(role: .system, content: SelectionQueryPlanner.prompt(settings.appLanguage)),
            AIChatMessage(role: .user, content: "<untrusted_source>\n\(escaped)\n</untrusted_source>"),
        ], maxTokens: 300, temperature: 0)
        do {
            let response = try await client.complete(request)
            AIQuotaStore.shared.settle(
                reservedCostMicros: 0,
                usage: response.usage,
                price: client.price
            )
            // A cut-off JSON is not a plan. Hand back nil so the policy sends
            // the passage to the web instead of trusting half an answer.
            guard !response.truncated else { return nil }
            return SelectionQueryPlanner.parse(response.text)
        } catch {
            AIQuotaStore.shared.settle(reservedCostMicros: 0, usage: nil, price: client.price)
            return nil
        }
    }

    private func answer(for text: String, settings: AppSettings) async throws -> AnswerDocument {
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
                timeout: 60
            )
            // Reserve the call like any other: the input is the selection, the
            // output is the answer budget. Without this a cost-capped account
            // paid for every explanation and recorded none of them.
            let price = client.price
            let reserved = price.map {
                AICostEstimator.reserveMicros(
                    inputTokens: max(1, min(text.count, SelectionExplainService.maxSelectionCharacters)),
                    maxOutputTokens: SelectionExplainService.maxTokens,
                    price: $0
                )
            } ?? 0
            service = SelectionExplainService(
                client: client,
                modelName: configuration.model,
                reserve: {
                    AIQuotaStore.shared.reserve(
                        .selection,
                        policy: policy,
                        reservedCostMicros: reserved
                    )
                },
                settle: { response, price in
                    AIQuotaStore.shared.settle(
                        reservedCostMicros: reserved,
                        usage: response.usage,
                        price: price
                    )
                }
            )
            cachedService = service
            cachedServiceIdentity = identity
        }
        return try await service.explain(text, language: language) { document in
            Task { @MainActor [weak self] in
                self?.reveal.receive(document)
            }
        }
    }

    private static func resolveAPIKey(settings: AppSettings) async -> String {
        if let cached = settings.cachedAPIKey, !cached.isEmpty { return cached }
        let key = await EncryptedKeyStore().readAPIKey(account: settings.activeAPIKeyAccount) ?? ""
        if !key.isEmpty { settings.cachedAPIKey = key }
        return key
    }
}
