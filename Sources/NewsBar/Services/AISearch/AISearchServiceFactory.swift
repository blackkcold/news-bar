import Foundation

/// One place that turns settings into a reader AI search run.
///
/// Both entries use it: the ⌘K panel and the selected-text look-up. Keeping the
/// provider, key, search-router and quota wiring here means a change in one
/// entry cannot silently drift from the other.
@MainActor
enum AISearchServiceFactory {
    static func make(
        settings: AppSettings,
        profile: SearchProfile = .readerSearch,
        onPartial: @escaping @Sendable (AnswerDocument) -> Void = { _ in }
    ) async throws -> AISearchService {

        let expected = settings.aiKeyContext
        let connection = settings.resolvedAIConnection
        let model = settings.effectiveAISearchModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AISearchError.noModel }

        let bound = try await settings.resolveBoundAPIKey(expected: expected)
        try Task.checkCancellation()
        guard settings.isCurrentAIKey(bound) else { throw AISearchError.configurationChanged }
        let key = bound.key
        guard !key.isEmpty || settings.aiProvider == AIProvider.ollamaCloud.rawValue else {
            throw AISearchError.noKey
        }

        let language = settings.appLanguage
        let pageCount = settings.aiSearchPageCount
        let thinking = settings.aiSearchThinking
        let policy = settings.aiQuotaPolicy

        // Search providers reuse the same configuration and key vault as
        // research. The ticket caps this run at six HTTP attempts.
        let providerIDs = Set(settings.researchSearchProviders.compactMap(SearchProviderID.init(rawValue:)))
        let searchKeys = await SearchKeyStore.loadAll()
        try Task.checkCancellation()
        guard settings.isCurrentAIKey(bound) else { throw AISearchError.configurationChanged }
        let searchConfiguration = SearchRouterConfiguration(enabled: providerIDs, keys: searchKeys)
        // AI search is a first-class search consumer: it must obey the same
        // local per-provider rate guards as research, not only the AI quota.
        // The router is the single production instance; its cache, epoch and
        // provider state are shared with research and page summary.
        let router = ResearchServiceAssembly.shared.searchRouter
        let firecrawlKey = searchKeys[.firecrawl] ?? ""
        let pageReader = ResearchServiceAssembly.shared.pageReader(
            isScrapeEnabled: !firecrawlKey.isEmpty
        )

        let price = connection.customPrice
            ?? AIPriceCatalog.price(for: connection.providerID, model: model)

        let client = AIChatClientFactory.metered(
            origin: .aiSearch,
            policy: policy,
            price: price,
            connection: connection,
            apiKey: key,
            model: model,
            thinking: thinking,
            timeout: 45
        )
        // The assessor is a separate call with its own output ceiling. It does
        // not carry the answer's thinking level: auditing quotations is a
        // short, factual task, and reasoning tokens would only add cost.
        let assessClient: HTTPAIChatClient? = settings.aiEvidenceAssessmentEnabled
            ? AIChatClientFactory.metered(
                origin: .aiSearch,
                policy: policy,
                price: price,
                connection: connection,
                apiKey: key,
                model: model,
                thinking: nil,
                timeout: 45
            )
            : nil

        let estimatedSourceCharacters = min(
            max(1, profile.maxTotalCharacters),
            max(1, pageCount) * max(1, profile.maxSourceCharacters)
        )
        let preflightOutputTokens = effectiveOutputTokens(
            connection: connection, model: model, thinking: thinking, requested: AISearchService.answerTokens
        )
        let preflightReservation = price.map {
            AICostEstimator.reserveMicros(
                // Before retrieval the prompt is not yet known. Include room
                // for source metadata and instructions in this preflight only.
                inputTokens: estimatedSourceCharacters + max(1, pageCount) * 1_024 + 2_048,
                maxOutputTokens: preflightOutputTokens,
                price: $0
            )
        } ?? 0
        // Assessment is one extra call. The preflight must not let a run start
        // when that call cannot be paid for; the assessor still degrades to the
        // heuristic if the budget runs out mid-run.
        let assessmentReservation = settings.aiEvidenceAssessmentEnabled
            ? (price.map {
                AICostEstimator.reserveMicros(
                    inputTokens: EvidencePrompts.maxTotalCharacters + 2_048,
                    maxOutputTokens: 1_200,
                    price: $0
                )
            } ?? 0)
            : 0

        var assessHandler: AISearchService.AssessHandler? = nil
        if let assessClient {
            assessHandler = { question, pageTitle, sources in
                await EvidenceAssessor.assess(
                    question: question,
                    pageTitle: pageTitle,
                    sources: sources,
                    client: assessClient,
                    language: language
                )
            }
        }

        return AISearchService(
            search: { query, ticket in
                // Same key, file and write epoch as research: the router builds
                // the key from the query and the dispatchable provider set.
                // `maxAge` preserves the 10-minute window AI search always had,
                // so sharing the 12-hour research snapshot cannot serve an old
                // answer. A cached hit does not consume the ticket.
                let batch = try await router.search(
                    query,
                    configuration: searchConfiguration,
                    maxAttempts: EvidenceRetriever.maxAttemptsPerQuery,
                    maxProviderAttempts: EvidenceRetriever.maxProviderAttemptsPerQuery,
                    useCache: true,
                    maxAge: SearchHitCache.aiSearchMaxAge,
                    ticket: ticket
                )
                return batch.hits
            },
            read: { hit in
                try await pageReader.readOutcome(hit, apiKey: firecrawlKey)
            },
            answer: { system, user, maxTokens in
                try await client.complete(AIChatRequest(
                    messages: [
                        AIChatMessage(role: .system, content: system),
                        AIChatMessage(role: .user, content: user),
                    ],
                    maxTokens: maxTokens,
                    temperature: 0.2
                ))
            },
            preflight: {
                let snapshot = AIQuotaStore.shared.snapshot()
                guard snapshot.isUsable else { return false }
                return !policy.blocks(
                    count: snapshot.count,
                    costMicros: snapshot.costMicros + preflightReservation + assessmentReservation
                )
            },
            streamAnswer: { system, user, maxTokens in
                client.stream(AIChatRequest(
                    messages: [
                        AIChatMessage(role: .system, content: system),
                        AIChatMessage(role: .user, content: user),
                    ],
                    maxTokens: maxTokens,
                    temperature: 0.2
                ))
            },
            assess: assessHandler,
            onPartial: onPartial,
            now: { Date() },
            pageCount: pageCount,
            thinking: thinking,
            model: model,
            language: language,
            profile: profile
        )
    
    }

    nonisolated private static func effectiveOutputTokens(
        connection: ResolvedAIConnection, model: String, thinking: AIThinkingLevel, requested: Int
    ) -> Int {
        var body: [String: Any] = [:]
        // Must mirror AIRequestBuilder.build exactly, including the model-family
        // gate; otherwise the preflight reservation can under-count tokens.
        let style = AIThinkingResolver.effectiveStyle(connection: connection, model: model)
        return AIThinkingApplication.apply(
            style: style, level: thinking, body: &body, maxTokens: max(1, requested)
        ).maxTokens
    }
}
