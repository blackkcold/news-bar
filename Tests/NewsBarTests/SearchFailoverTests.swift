import XCTest
@testable import NewsBar

private final class ScriptedSearchProvider: SearchProvider, @unchecked Sendable {
    let id: SearchProviderID
    let requiresKey: Bool

    private let lock = NSLock()
    private var script: [Result<[SearchHit], SearchProviderError>]
    private var calls = 0

    init(
        id: SearchProviderID,
        requiresKey: Bool = false,
        script: [Result<[SearchHit], SearchProviderError>] = []
    ) {
        self.id = id
        self.requiresKey = requiresKey
        self.script = script
    }

    func search(_ query: SearchQuery, key: String) async throws -> [SearchHit] {
        lock.lock()
        calls += 1
        let next: Result<[SearchHit], SearchProviderError>
        if script.isEmpty {
            next = .success([])
        } else {
            next = script.removeFirst()
        }
        lock.unlock()
        return try next.get()
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

final class SearchFailoverTests: XCTestCase {
    private var clock: ResearchTestClock!
    private var cache: ResearchCacheStore!

    override func setUp() async throws {
        clock = ResearchTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        cache = ResearchCacheStore(directoryURL: try researchTestDirectory())
    }

    private func hit(
        _ url: String,
        provider: SearchProviderID = .tavily,
        rank: Int = 1,
        title: String = "title"
    ) -> SearchHit {
        SearchHit(
            url: url,
            title: title,
            snippet: "snippet",
            publishedAt: nil,
            inlineContent: nil,
            provider: provider,
            providerRank: rank
        )
    }

    private func query(_ text: String = "某事件 时间线") -> SearchQuery {
        SearchQuery(text: text, recency: .week, maxResults: 5)
    }

    private func configuration(
        keys: [SearchProviderID: String] = [.tavily: "tavily-key", .brave: "brave-key"]
    ) -> SearchRouterConfiguration {
        SearchRouterConfiguration(enabled: Set(SearchProviderID.allCases), keys: keys)
    }

    private func router(
        tavily: ScriptedSearchProvider,
        firecrawl: ScriptedSearchProvider,
        brave: ScriptedSearchProvider
    ) -> SearchRouter {
        SearchRouter(
            providers: [tavily, firecrawl, brave],
            cache: cache,
            now: { [clock] in clock?.now ?? Date() }
        )
    }

    // MARK: - Ordering

    func testUsesTavilyFirstAndStopsOnSuccess() async throws {
        let tavily = ScriptedSearchProvider(
            id: .tavily,
            requiresKey: true,
            script: [.success([hit("https://www.reuters.com/a")])]
        )
        let firecrawl = ScriptedSearchProvider(id: .firecrawl)
        let brave = ScriptedSearchProvider(id: .brave, requiresKey: true)

        let batch = try await router(tavily: tavily, firecrawl: firecrawl, brave: brave)
            .search(query(), configuration: configuration())

        XCTAssertEqual(batch.providers, [.tavily])
        XCTAssertEqual(batch.hits.count, 1)
        XCTAssertEqual(batch.attempts, 1)
        XCTAssertEqual(batch.failovers, 0)
        XCTAssertEqual(tavily.callCount, 1)
        XCTAssertEqual(firecrawl.callCount, 0)
        XCTAssertEqual(brave.callCount, 0)
    }

    func testSkipsProviderWithoutRequiredKey() async throws {
        let tavily = ScriptedSearchProvider(id: .tavily, requiresKey: true, script: [])
        let firecrawl = ScriptedSearchProvider(
            id: .firecrawl,
            script: [.success([hit("https://www.bbc.com/a", provider: .firecrawl)])]
        )
        let brave = ScriptedSearchProvider(id: .brave, requiresKey: true)

        let batch = try await router(tavily: tavily, firecrawl: firecrawl, brave: brave)
            .search(query(), configuration: configuration(keys: [.brave: "b"]))

        XCTAssertEqual(batch.providers, [.firecrawl])
        XCTAssertEqual(tavily.callCount, 0)
        XCTAssertEqual(firecrawl.callCount, 1)
    }

    // MARK: - Quota

    func testQuotaFailureCoolsDownAndFailsOver() async throws {
        let tavily = ScriptedSearchProvider(
            id: .tavily,
            requiresKey: true,
            script: [.failure(.quotaExhausted)]
        )
        let firecrawl = ScriptedSearchProvider(
            id: .firecrawl,
            script: [
                .success([hit("https://www.reuters.com/a", provider: .firecrawl)]),
                .success([hit("https://www.reuters.com/b", provider: .firecrawl)]),
            ]
        )
        let brave = ScriptedSearchProvider(id: .brave, requiresKey: true)
        let router = router(tavily: tavily, firecrawl: firecrawl, brave: brave)

        let first = try await router.search(query(), configuration: configuration())
        XCTAssertEqual(first.providers, [.firecrawl])
        XCTAssertEqual(first.failovers, 1)
        XCTAssertEqual(first.attempts, 2)

        let remaining = await router.cooldownRemaining(for: .tavily)
        XCTAssertEqual(remaining, 15 * 60, accuracy: 1)

        // Cached results would hide the cooldown behavior.
        let second = try await router.search(query(), configuration: configuration(), useCache: false)
        XCTAssertEqual(second.providers, [.firecrawl])
        XCTAssertEqual(tavily.callCount, 1)
        XCTAssertEqual(firecrawl.callCount, 2)
    }

    func testSecondQuotaFailureExtendsCooldownToThirtyMinutes() async throws {
        let tavily = ScriptedSearchProvider(
            id: .tavily,
            requiresKey: true,
            script: [.failure(.quotaExhausted), .failure(.quotaExhausted)]
        )
        let firecrawl = ScriptedSearchProvider(id: .firecrawl, script: [.success([]), .success([]), .success([])])
        let brave = ScriptedSearchProvider(id: .brave, requiresKey: true)
        let router = router(tavily: tavily, firecrawl: firecrawl, brave: brave)

        _ = try await router.search(query(), configuration: configuration(), useCache: false)
        clock.advance(16 * 60)
        _ = try await router.search(query("另一个查询"), configuration: configuration(), useCache: false)

        let remaining = await router.cooldownRemaining(for: .tavily)
        XCTAssertEqual(remaining, 30 * 60, accuracy: 1)
    }

    // MARK: - Retry and invalid keys

    func testServerFailureRetriesOnce() async throws {
        let tavily = ScriptedSearchProvider(
            id: .tavily,
            requiresKey: true,
            script: [
                .failure(.server(503)),
                .success([hit("https://www.reuters.com/a")]),
            ]
        )
        let firecrawl = ScriptedSearchProvider(id: .firecrawl)
        let brave = ScriptedSearchProvider(id: .brave, requiresKey: true)

        let batch = try await router(tavily: tavily, firecrawl: firecrawl, brave: brave)
            .search(query(), configuration: configuration())

        XCTAssertEqual(batch.providers, [.tavily])
        XCTAssertEqual(batch.attempts, 2)
        XCTAssertEqual(tavily.callCount, 2)
    }

    func testUnauthorizedMarksKeyInvalidUntilKeyChanges() async throws {
        let tavily = ScriptedSearchProvider(
            id: .tavily,
            requiresKey: true,
            script: [.failure(.unauthorized)]
        )
        let firecrawl = ScriptedSearchProvider(
            id: .firecrawl,
            script: [
                .success([]),
                .success([]),
                .success([hit("https://www.reuters.com/c")]),
            ]
        )
        let brave = ScriptedSearchProvider(id: .brave, requiresKey: true)
        let router = router(tavily: tavily, firecrawl: firecrawl, brave: brave)

        _ = try await router.search(query(), configuration: configuration(), useCache: false)
        let invalid = await router.invalidProviders()
        XCTAssertEqual(invalid, [.tavily])

        _ = try await router.search(query(), configuration: configuration(), useCache: false)
        XCTAssertEqual(tavily.callCount, 1)

        let changed = try await router.search(
            query(),
            configuration: configuration(keys: [.tavily: "new-key", .brave: "b"]),
            useCache: false
        )
        XCTAssertEqual(tavily.callCount, 2)
        XCTAssertEqual(changed.providers, [.tavily])
    }

    // MARK: - All fail / budget

    func testAllProvidersFailThrowsWithReasons() async {
        let tavily = ScriptedSearchProvider(
            id: .tavily,
            requiresKey: true,
            script: [.failure(.quotaExhausted)]
        )
        let firecrawl = ScriptedSearchProvider(
            id: .firecrawl,
            script: [.failure(.server(500)), .failure(.server(500))]
        )
        let brave = ScriptedSearchProvider(
            id: .brave,
            requiresKey: true,
            script: [.failure(.quotaExhausted)]
        )

        do {
            _ = try await router(tavily: tavily, firecrawl: firecrawl, brave: brave)
                .search(query(), configuration: configuration())
            XCTFail("expected SearchUnavailableError")
        } catch let error as SearchUnavailableError {
            XCTAssertTrue(error.reasons.contains { $0.contains("tavily") })
            XCTAssertTrue(error.reasons.contains { $0.contains("firecrawl") })
            XCTAssertTrue(error.reasons.contains { $0.contains("brave") })
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testHTTPHardCapStopsBeforeNextAttempt() async {
        let tavily = ScriptedSearchProvider(
            id: .tavily,
            requiresKey: true,
            script: [.failure(.server(500)), .failure(.server(500))]
        )
        let firecrawl = ScriptedSearchProvider(id: .firecrawl)
        let brave = ScriptedSearchProvider(id: .brave, requiresKey: true)

        do {
            _ = try await router(tavily: tavily, firecrawl: firecrawl, brave: brave)
                .search(query(), configuration: configuration(), maxAttempts: 1)
            XCTFail("expected budget exhaustion")
        } catch let error as SearchUnavailableError {
            XCTAssertTrue(error.reasons.contains { $0.contains("budget") })
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(tavily.callCount, 1)
    }

    // MARK: - Cache and ranking

    func testCacheHitAvoidsProviderCall() async throws {
        let tavily = ScriptedSearchProvider(
            id: .tavily,
            requiresKey: true,
            script: [.success([hit("https://www.reuters.com/a")])]
        )
        let firecrawl = ScriptedSearchProvider(id: .firecrawl)
        let brave = ScriptedSearchProvider(id: .brave, requiresKey: true)
        let router = router(tavily: tavily, firecrawl: firecrawl, brave: brave)

        let first = try await router.search(query(), configuration: configuration())
        XCTAssertEqual(first.attempts, 1)

        let second = try await router.search(query(), configuration: configuration())
        XCTAssertEqual(second.attempts, 0)
        XCTAssertEqual(second.providers, [.tavily])
        XCTAssertEqual(second.hits, first.hits)
        XCTAssertEqual(tavily.callCount, 1)
    }

    func testDeduplicatesCanonicalURLsAndCapsDomainResults() async throws {
        let hits = [
            hit("https://example.com/a?utm_source=x", rank: 1),
            hit("https://example.com/a", rank: 2),
            hit("https://example.com/b", rank: 3),
            hit("https://example.com/c", rank: 4),
            hit("https://www.reuters.com/d", rank: 5),
        ]
        let tavily = ScriptedSearchProvider(id: .tavily, requiresKey: true, script: [.success(hits)])
        let firecrawl = ScriptedSearchProvider(id: .firecrawl)
        let brave = ScriptedSearchProvider(id: .brave, requiresKey: true)

        let batch = try await router(tavily: tavily, firecrawl: firecrawl, brave: brave)
            .search(query(), configuration: configuration())

        XCTAssertEqual(batch.hits.count, 3)
        XCTAssertEqual(Set(batch.hits.map(\.canonicalURL)).count, 3)
        XCTAssertEqual(batch.hits.filter { $0.domain == "example.com" }.count, 2)
    }
}
