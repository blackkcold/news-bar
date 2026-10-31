import XCTest
@testable import NewsBar

private actor ManualSearchGatewayProvider: SearchProvider {
    enum Response: Sendable {
        case hits([SearchHit])
        case failure(SearchProviderError)
    }

    nonisolated let id: SearchProviderID
    private let response: Response
    private var queries: [SearchQuery] = []
    private var keys: [String] = []

    init(id: SearchProviderID, response: Response) {
        self.id = id
        self.response = response
    }

    func search(_ query: SearchQuery, key: String) async throws -> [SearchHit] {
        queries.append(query)
        keys.append(key)
        switch response {
        case .hits(let hits): return hits
        case .failure(let error): throw error
        }
    }

    func captured() -> (queries: [SearchQuery], keys: [String]) {
        (queries, keys)
    }
}

final class ManualSearchGatewayTests: XCTestCase {
    func testGatewayUsesMonthRecencyEightResultsAndSixAttemptTicket() async throws {
        let tavily = ManualSearchGatewayProvider(id: .tavily, response: .failure(.server(503)))
        let firecrawl = ManualSearchGatewayProvider(id: .firecrawl, response: .failure(.server(503)))
        let tinyfish = ManualSearchGatewayProvider(id: .tinyfish, response: .failure(.server(503)))
        let exa = ManualSearchGatewayProvider(id: .exa, response: .failure(.transport("offline")))
        let router = SearchRouter(
            providers: [tavily, firecrawl, tinyfish, exa],
            cache: ResearchCacheStore(directoryURL: try researchTestDirectory())
        )
        let gateway = ManualSearchGateway(router: router)

        do {
            _ = try await gateway.search(
                text: "manual search query",
                language: .en,
                enabledProviders: [.tavily, .firecrawl, .tinyfish, .exa],
                keys: [.tinyfish: "search-only-key", .exa: "search-only-key"]
            )
            XCTFail("expected all providers to fail")
        } catch is SearchUnavailableError {
            // The router reports exhaustion after the injected providers fail.
        }

        let tavilyCalls = await tavily.captured()
        let firecrawlCalls = await firecrawl.captured()
        let tinyfishCalls = await tinyfish.captured()
        let exaCalls = await exa.captured()
        let dispatchedQueries = tavilyCalls.queries + firecrawlCalls.queries + tinyfishCalls.queries

        XCTAssertEqual(dispatchedQueries.count, 6)
        XCTAssertEqual(dispatchedQueries.map(\.text), Array(repeating: "manual search query", count: 6))
        XCTAssertTrue(dispatchedQueries.allSatisfy { $0.recency == .month })
        XCTAssertTrue(dispatchedQueries.allSatisfy { $0.language == AppLanguage.en.bcp47 })
        XCTAssertTrue(dispatchedQueries.allSatisfy { $0.maxResults == 8 })
        XCTAssertEqual(tavilyCalls.queries.count, 2)
        XCTAssertEqual(firecrawlCalls.queries.count, 2)
        XCTAssertEqual(tinyfishCalls.queries.count, 2)
        XCTAssertTrue(exaCalls.queries.isEmpty)

        let slowProviders = [
            ManualSearchGatewayProvider(id: .tavily, response: .failure(.transport("offline"))),
            ManualSearchGatewayProvider(id: .firecrawl, response: .failure(.transport("offline"))),
            ManualSearchGatewayProvider(id: .tinyfish, response: .failure(.transport("offline"))),
            ManualSearchGatewayProvider(id: .exa, response: .failure(.transport("offline"))),
        ]
        let cappedGateway = ManualSearchGateway(router: SearchRouter(
            providers: slowProviders,
            cache: ResearchCacheStore(directoryURL: try researchTestDirectory())
        ))
        do {
            _ = try await cappedGateway.search(
                text: "provider cap query",
                language: .zh,
                enabledProviders: [.tavily, .firecrawl, .tinyfish, .exa],
                keys: [.tinyfish: "search-only-key", .exa: "search-only-key"]
            )
            XCTFail("expected all providers to fail")
        } catch is SearchUnavailableError {
            // The manual gateway should dispatch to no more than three providers.
        }
        let cappedCalls = await slowProviders.asyncMap { await $0.captured().queries.count }
        XCTAssertEqual(cappedCalls, [1, 1, 1, 0])
    }

    func testGatewayUsesOnlyEnabledSearchProvidersAndSearchKeys() async throws {
        let disabled = ManualSearchGatewayProvider(id: .tavily, response: .hits([]))
        let hit = SearchHit(
            url: "https://search.example/result",
            title: "Search result",
            snippet: "Snippet",
            provider: .exa,
            providerRank: 1
        )
        let enabled = ManualSearchGatewayProvider(id: .exa, response: .hits([hit]))
        let gateway = ManualSearchGateway(router: SearchRouter(
            providers: [disabled, enabled],
            cache: ResearchCacheStore(directoryURL: try researchTestDirectory())
        ))

        let batch = try await gateway.search(
            text: "independent web query",
            language: .zh,
            enabledProviders: [.exa],
            keys: [.exa: "search-only-key"]
        )

        let disabledCalls = await disabled.captured()
        let enabledCalls = await enabled.captured()
        XCTAssertTrue(disabledCalls.queries.isEmpty)
        XCTAssertEqual(enabledCalls.queries.count, 1)
        XCTAssertEqual(enabledCalls.keys, ["search-only-key"])
        XCTAssertEqual(enabledCalls.queries.first?.language, AppLanguage.zh.bcp47)
        XCTAssertEqual(batch.providers, [.exa])
        XCTAssertEqual(batch.hits, [hit])
    }

    func testGatewayRemovesControlCharactersBeforeDispatch() async throws {
        let provider = ManualSearchGatewayProvider(id: .tavily, response: .hits([]))
        let gateway = ManualSearchGateway(router: SearchRouter(
            providers: [provider],
            cache: ResearchCacheStore(directoryURL: try researchTestDirectory())
        ))

        _ = try await gateway.search(
            text: "\u{0001}manual query\u{0002}",
            language: .en,
            enabledProviders: [.tavily],
            keys: [:]
        )

        let captured = await provider.captured()
        XCTAssertEqual(captured.queries.map(\.text), ["manual query"])
    }

    func testGatewayRejectsQueryThatIsEmptyAfterSanitization() async throws {
        let provider = ManualSearchGatewayProvider(id: .tavily, response: .hits([]))
        let gateway = ManualSearchGateway(router: SearchRouter(
            providers: [provider],
            cache: ResearchCacheStore(directoryURL: try researchTestDirectory())
        ))

        do {
            _ = try await gateway.search(
                text: "\u{0001}\u{0002}",
                language: .en,
                enabledProviders: [.tavily],
                keys: [:]
            )
            XCTFail("a query emptied by sanitization must not be dispatched")
        } catch let error as SearchUnavailableError {
            XCTAssertEqual(error.failures, [
                SearchProviderFailure(provider: nil, reason: .emptyQuery),
            ])
        }

        let captured = await provider.captured()
        XCTAssertTrue(captured.queries.isEmpty)
    }
}

private extension Array where Element == ManualSearchGatewayProvider {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var values: [T] = []
        for element in self {
            values.append(await transform(element))
        }
        return values
    }
}
