import Foundation

/// Provider abstraction for web search. Firecrawl's keyless free tier is used
/// by default (no API key, IP rate-limited); an optional key raises the limits.
/// Search results are returned in-memory so the caller can stage them locally
/// and later decide which to scrape.
enum WebSearchService {

    struct Config: Sendable {
        let provider: WebSearchProvider
        /// Empty means keyless mode (Firecrawl allows unauthenticated requests).
        let apiKey: String
        let maxResults: Int
    }

    static func search(query: String, config: Config) async throws -> [WebSearchResult] {
        switch config.provider {
        case .firecrawl:
            return try await firecrawlSearch(query: query, config: config)
        }
    }

    /// Runs several query variants concurrently and merges the results,
    /// de-duplicating by URL. Used by burst research to gather a richer,
    /// multi-angle set of sources so timelines have enough material.
    /// A single variant failing is tolerated (its results are skipped) as long
    /// as at least one variant succeeds; if all fail the error is rethrown.
    static func searchMulti(queryVariants: [String], config: Config) async throws -> [WebSearchResult] {
        let variants = queryVariants.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !variants.isEmpty else { return [] }

        let limit = min(variants.count, 3)
        let aggregator = SearchResultAggregator()
        var lastError: Error?

        await withTaskGroup(of: Void.self) { group in
            for variant in variants.prefix(limit) {
                group.addTask {
                    do {
                        let results = try await Self.search(query: variant, config: config)
                        await aggregator.merge(results)
                    } catch {
                        lastError = error
                    }
                }
            }
        }

        let merged = await aggregator.snapshot()
        if merged.isEmpty, let lastError {
            throw lastError
        }
        return merged
    }

    /// Serialises concurrent writes of per-variant results into a URL-keyed map.
    private actor SearchResultAggregator {
        private var results: [String: WebSearchResult] = [:]

        func merge(_ items: [WebSearchResult]) {
            for r in items where !r.url.isEmpty {
                results[r.url] = r
            }
        }

        func snapshot() -> [WebSearchResult] {
            Array(results.values)
        }
    }

    // MARK: - Firecrawl

    private struct FirecrawlSearchResponse: Decodable {
        struct Result: Decodable {
            let url: String
            let title: String
            let description: String
        }
        struct Data: Decodable {
            let web: [Result]
        }
        let data: Data?
    }

    private static func firecrawlSearch(query: String, config: Config) async throws -> [WebSearchResult] {
        guard let url = URL(string: "https://api.firecrawl.dev/v2/search") else {
            throw NewsBarError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 20
        let body: [String: Any] = [
            "query": query,
            "limit": max(1, config.maxResults),
            "tbs": "qdr:w"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NewsBarError.requestFailed }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw NewsBarError.apiKeyInvalid }
            throw NewsBarError.requestFailed
        }

        guard let decoded = try? JSONDecoder().decode(FirecrawlSearchResponse.self, from: data),
              let web = decoded.data?.web else {
            throw NewsBarError.parseFailed
        }
        return web.map { WebSearchResult(url: $0.url, title: $0.title, description: $0.description) }
    }
}
