import Foundation

/// Adapts the shared search router for user-initiated web searches.
/// The router stays alive for the gateway's lifetime so cache and cooldown
/// state can be reused between searches.
struct ManualSearchGateway: Sendable {
    private let router: SearchRouter

    init(router: SearchRouter = SearchRouter()) {
        self.router = router
    }

    func search(
        text: String,
        language: AppLanguage,
        enabledProviders: Set<SearchProviderID>,
        keys: [SearchProviderID: String]
    ) async throws -> SearchBatch {
        let sanitizedText = SecurityPolicies.sanitizeUserInput(text)
        guard !sanitizedText.isEmpty else {
            throw SearchUnavailableError(failures: [
                SearchProviderFailure(provider: nil, reason: .emptyQuery),
            ])
        }
        let query = SearchQuery(
            text: sanitizedText,
            recency: .month,
            language: language.bcp47,
            maxResults: 8
        )
        let configuration = SearchRouterConfiguration(
            enabled: enabledProviders,
            keys: keys
        )

        return try await router.search(
            query,
            configuration: configuration,
            maxAttempts: 6,
            maxProviderAttempts: 3,
            useCache: true,
            ticket: SearchAttemptTicket(limit: 6)
        )
    }
}
