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

        let model = settings.effectiveAISearchModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AISearchError.noModel }

        let key: String
        if let cached = settings.cachedAPIKey, !cached.isEmpty {
            key = cached
        } else {
            key = await EncryptedKeyStore().readAPIKey(account: settings.activeAPIKeyAccount) ?? ""
            if !key.isEmpty { settings.cachedAPIKey = key }
        }
        guard !key.isEmpty || settings.aiProvider == AIProvider.ollamaCloud.rawValue else {
            throw AISearchError.noKey
        }

        let connection = settings.resolvedAIConnection
        let language = settings.appLanguage
        let pageCount = settings.aiSearchPageCount
        let thinking = settings.aiSearchThinking
        let policy = settings.aiQuotaPolicy

        // Search providers reuse the same configuration and key vault as
        // research. The ticket caps this run at six HTTP attempts.
        let providerIDs = Set(settings.researchSearchProviders.compactMap(SearchProviderID.init(rawValue:)))
        let searchKeys = await SearchKeyStore.loadAll()
        let searchConfiguration = SearchRouterConfiguration(enabled: providerIDs, keys: searchKeys)
        let router = SearchRouter()
        let firecrawlKey = searchKeys[.firecrawl] ?? ""
        let pageReader = PageReader(isScrapeEnabled: !firecrawlKey.isEmpty)

        let client = HTTPAIChatClient(
            connection: connection,
            apiKey: key,
            model: model,
            thinking: thinking,
            timeout: 45
        )

        let price = connection.customPrice
            ?? AIPriceCatalog.price(for: connection.providerID, model: model)
        let reserved = price.map {
            AICostEstimator.reserveMicros(
                // Prompt caps are 6 000 characters per page and 24 000 in total.
                // One Chinese character costs about one token here, so a page
                // can be 6 000 tokens; 1 200 under-reserved cost-capped accounts
                // by 5x. The shared 24 000-character budget makes this a ceiling,
                // never a charge.
                inputTokens: max(1, pageCount * 6_000),
                maxOutputTokens: AISearchService.answerTokens,
                price: $0
            )
        } ?? 0

        return AISearchService(
            search: { query, limit in
                let key = [
                    query,
                    SearchRecency.month.rawValue,
                    providerIDs.map(\.rawValue).sorted().joined(separator: ","),
                ].joined(separator: "|")
                if let cached = await SearchHitCache.shared.hits(for: key) {
                    return cached
                }
                let batch = try await router.search(
                    SearchQuery(
                        text: query,
                        recency: .month,
                        language: language.bcp47,
                        maxResults: limit
                    ),
                    configuration: searchConfiguration,
                    maxAttempts: 6,
                    maxProviderAttempts: 3,
                    useCache: false,
                    ticket: SearchAttemptTicket(limit: 6)
                )
                await SearchHitCache.shared.store(batch.hits, for: key)
                return batch.hits
            },
            read: { hit in
                try await pageReader.read(hit, apiKey: firecrawlKey)
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
            reserve: {
                AIQuotaStore.shared.reserve(.aiSearch, policy: policy, reservedCostMicros: reserved)
            },
            settle: { response in
                AIQuotaStore.shared.settle(
                    reservedCostMicros: reserved,
                    usage: response.usage,
                    price: price
                )
            },
            preflight: {
                let snapshot = AIQuotaStore.shared.snapshot()
                guard snapshot.isUsable else { return false }
                return !policy.blocks(
                    count: snapshot.count,
                    costMicros: snapshot.costMicros + reserved
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
            onPartial: onPartial,
            now: { Date() },
            pageCount: pageCount,
            thinking: thinking,
            model: model,
            language: language,
            profile: profile
        )
    
    }
}
