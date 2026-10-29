import XCTest
@testable import NewsBar

private final class ExpansionProvider: SearchProvider, @unchecked Sendable {
    let id: SearchProviderID
    private let lock = NSLock()
    private var script: [Result<[SearchHit], SearchProviderError>]
    private var calls = 0

    init(id: SearchProviderID, script: [Result<[SearchHit], SearchProviderError>] = []) {
        self.id = id
        self.script = script
    }

    func search(_ query: SearchQuery, key: String) async throws -> [SearchHit] {
        lock.lock()
        calls += 1
        let next = script.isEmpty ? .success([]) : script.removeFirst()
        lock.unlock()
        return try next.get()
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

final class SearchProviderExpansionTests: XCTestCase {
    private var clock: ResearchTestClock!
    private var cache: ResearchCacheStore!

    override func setUp() async throws {
        clock = ResearchTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        cache = ResearchCacheStore(directoryURL: try researchTestDirectory())
    }

    private func http(
        _ status: Int,
        headers: [String: String]? = nil
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.example.com")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    private func query(
        _ text: String = "某事件 时间线",
        recency: SearchRecency = .week,
        language: String? = "zh-Hans"
    ) -> SearchQuery {
        SearchQuery(text: text, recency: recency, language: language, maxResults: 5)
    }

    private func hit(_ url: String, provider: SearchProviderID) -> SearchHit {
        SearchHit(
            url: url,
            title: "title",
            snippet: "snippet",
            publishedAt: nil,
            inlineContent: nil,
            provider: provider,
            providerRank: 1
        )
    }

    private func router(_ providers: [any SearchProvider], quota: SearchQuotaStore? = nil) -> SearchRouter {
        SearchRouter(
            providers: providers,
            cache: cache,
            now: { [clock] in clock?.now ?? Date() },
            ledger: nil,
            quota: quota
        )
    }

    // MARK: - Tavily keyless

    func testTavilyKeylessUsesAccessModeHeader() async throws {
        let recorder = RequestRecorder()
        let provider = TavilySearchProvider(transport: { request in
            recorder.append(request)
            return (Data(#"{"results":[]}"#.utf8), self.http(200))
        })

        _ = try await provider.search(query(), key: "")

        let request = try XCTUnwrap(recorder.last)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Tavily-Access-Mode"), "keyless")
    }

    // MARK: - Exa

    func testExaRequestAndResponse() async throws {
        let recorder = RequestRecorder()
        let payload = """
        {"results":[
          {"title":"Exa A","url":"https://www.reuters.com/a","publishedDate":"2026-10-01T08:00:00Z","highlights":["第一段","第二段"]}
        ]}
        """
        let provider = ExaSearchProvider(
            transport: { request in
                recorder.append(request)
                return (Data(payload.utf8), self.http(200))
            },
            now: { [clock] in clock?.now ?? Date() }
        )

        let hits = try await provider.search(query(), key: "exa-key")

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].provider, .exa)
        XCTAssertEqual(hits[0].snippet, "第一段 第二段")
        XCTAssertEqual(hits[0].publishedAt.map { TimelineDateParser.dayKey($0) }, "2026-10-01")

        let request = try XCTUnwrap(recorder.last)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "exa-key")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["query"] as? String, "某事件 时间线")
        XCTAssertEqual(body["numResults"] as? Int, 5)
        XCTAssertEqual(body["type"] as? String, "auto")
        XCTAssertNotNil(body["startPublishedDate"] as? String)
    }

    func testExaRequiresKey() async {
        let provider = ExaSearchProvider(transport: { _ in (Data(), self.http(200)) })
        do {
            _ = try await provider.search(query(), key: "")
            XCTFail("expected missing key")
        } catch let error as SearchProviderError {
            XCTAssertEqual(error, .missingKey)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - Parallel

    func testParallelRequestAndResponse() async throws {
        let recorder = RequestRecorder()
        let payload = """
        {"results":[{"url":"https://www.bbc.com/a","title":"Parallel A","publish_date":"2026-10-02","excerpts":["摘录一","摘录二"]}]}
        """
        let provider = ParallelSearchProvider(transport: { request in
            recorder.append(request)
            return (Data(payload.utf8), self.http(200))
        })

        let hits = try await provider.search(query(), key: "parallel-key")

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].snippet, "摘录一\n\n摘录二")
        XCTAssertEqual(hits[0].publishedAt.map { TimelineDateParser.dayKey($0) }, "2026-10-02")

        let request = try XCTUnwrap(recorder.last)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "parallel-key")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["objective"] as? String, "某事件 时间线")
        XCTAssertEqual(body["search_queries"] as? [String], ["某事件 时间线"])
        XCTAssertEqual(body["mode"] as? String, "fast")
    }

    // MARK: - TinyFish

    func testTinyFishRequestAndResponse() async throws {
        let recorder = RequestRecorder()
        let payload = """
        {"results":[{"position":1,"title":"Tiny A","url":"https://www.reuters.com/a","snippet":"摘要","date":"2026-10-03"}]}
        """
        let provider = TinyFishSearchProvider(transport: { request in
            recorder.append(request)
            return (Data(payload.utf8), self.http(200))
        })

        let hits = try await provider.search(query(), key: "tiny-key")

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].snippet, "摘要")
        XCTAssertEqual(hits[0].providerRank, 1)
        XCTAssertEqual(hits[0].publishedAt.map { TimelineDateParser.dayKey($0) }, "2026-10-03")

        let request = try XCTUnwrap(recorder.last)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "tiny-key")
        let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["query"], "某事件 时间线")
        XCTAssertEqual(items["recency_minutes"], "10080")
        XCTAssertEqual(items["domain_type"], "news")
        XCTAssertEqual(items["language"], "zh")
    }

    // MARK: - Rate-limit mapping

    func testRetryAfterSecondsIsPreserved() async {
        let provider = TavilySearchProvider(transport: { _ in
            (Data(), self.http(429, headers: ["Retry-After": "120"]))
        })
        do {
            _ = try await provider.search(query(), key: "k")
            XCTFail("expected rate limit")
        } catch let error as SearchProviderError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 120))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testBodyLevelRateLimitIsDetected() async {
        let provider = FirecrawlSearchProvider(transport: { _ in
            (
                Data(#"{"error":{"code":429,"message":"slow down"}}"#.utf8),
                self.http(200)
            )
        })
        do {
            _ = try await provider.search(query(), key: "")
            XCTFail("expected rate limit")
        } catch let error as SearchProviderError {
            XCTAssertEqual(error, .rateLimited(retryAfter: nil))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - Router guards

    func testRouterHonorsRetryAfterAndSkipsDuringCooldown() async throws {
        let provider = ExpansionProvider(
            id: .tavily,
            script: [.failure(.rateLimited(retryAfter: 120)), .success([hit("https://a.com", provider: .tavily)])]
        )
        let router = router([provider])
        let configuration = SearchRouterConfiguration(
            enabled: [.tavily],
            keys: [.tavily: "key"]
        )

        do {
            _ = try await router.search(query(), configuration: configuration, useCache: false)
            XCTFail("expected unavailable")
        } catch is SearchUnavailableError {}

        XCTAssertEqual(provider.callCount, 1)

        clock.advance(30)
        do {
            _ = try await router.search(query(), configuration: configuration, useCache: false)
            XCTFail("expected cooldown")
        } catch {}
        XCTAssertEqual(provider.callCount, 1, "a cooling provider must not be contacted")

        clock.advance(100)
        let batch = try await router.search(query(), configuration: configuration, useCache: false)
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertEqual(batch.hits.count, 1)
    }

    func testRouterParksQuotaExhaustionUntilMonthlyReset() async throws {
        let provider = ExpansionProvider(
            id: .tavily,
            script: [.failure(.quotaExhausted)]
        )
        let router = router([provider])
        let configuration = SearchRouterConfiguration(
            enabled: [.tavily],
            keys: [.tavily: "key"]
        )

        do {
            _ = try await router.search(query(), configuration: configuration, useCache: false)
            XCTFail("expected unavailable")
        } catch {}

        clock.advance(24 * 3600)
        do {
            _ = try await router.search(query(), configuration: configuration, useCache: false)
            XCTFail("expected still parked")
        } catch {}
        XCTAssertEqual(provider.callCount, 1)

        let statuses = await router.statusSnapshot(configuration: configuration)
        let tavily = try XCTUnwrap(statuses.first { $0.provider == .tavily })
        XCTAssertEqual(tavily.state, .cooling)
        XCTAssertGreaterThan(tavily.cooldownUntil ?? .distantPast, clock.now)
    }

    func testPerQueryProviderAttemptLimit() async throws {
        let providers: [ExpansionProvider] = [
            ExpansionProvider(id: .tavily, script: [.failure(.malformedResponse)]),
            ExpansionProvider(id: .firecrawl, script: [.failure(.malformedResponse)]),
            ExpansionProvider(id: .tinyfish, script: [.failure(.malformedResponse)]),
            ExpansionProvider(id: .exa, script: [.failure(.malformedResponse)]),
        ]
        let router = router(providers)
        let configuration = SearchRouterConfiguration(
            enabled: Set(providers.map(\.id)),
            keys: [.tinyfish: "a", .exa: "b"]
        )

        do {
            _ = try await router.search(
                query(),
                configuration: configuration,
                maxProviderAttempts: 3,
                useCache: false
            )
            XCTFail("expected unavailable")
        } catch {}

        // Only the first three are dispatched; the fourth is skipped without
        // spending the rest of the task budget.
        XCTAssertEqual(providers[0].callCount, 1)
        XCTAssertEqual(providers[1].callCount, 1)
        XCTAssertEqual(providers[2].callCount, 1)
        XCTAssertEqual(providers[3].callCount, 0)
    }

    func testLocalQuotaGateSkipsWithoutRequest() async throws {
        let file = try researchTestDirectory().appendingPathComponent("quota.json")
        let store = SearchQuotaStore(fileURL: file, now: { [clock] in clock?.now ?? Date() })
        await store.exhaust(for: .tavily, keyed: true)

        let provider = ExpansionProvider(id: .tavily, script: [])
        let router = router([provider], quota: store)
        let configuration = SearchRouterConfiguration(
            enabled: [.tavily],
            keys: [.tavily: "key"]
        )

        do {
            _ = try await router.search(query(), configuration: configuration, useCache: false)
            XCTFail("expected unavailable")
        } catch {}

        XCTAssertEqual(provider.callCount, 0)
    }

    func testCacheKeyChangesWithDispatchableProviderSet() {
        let base = SearchRouterConfiguration(
            enabled: [.tavily, .firecrawl],
            keys: [.tavily: "k"]
        )
        let disabled = SearchRouterConfiguration(
            enabled: [.tavily],
            keys: [.tavily: "k"]
        )
        XCTAssertNotEqual(
            SearchRouter.cacheKey(for: query(), configuration: base),
            SearchRouter.cacheKey(for: query(), configuration: disabled)
        )
        // A provider that needs a key is not dispatchable until the key exists.
        let noKey = SearchRouterConfiguration(enabled: [.tavily, .exa], keys: [.tavily: "k"])
        let withKey = SearchRouterConfiguration(enabled: [.tavily, .exa], keys: [.tavily: "k", .exa: "e"])
        XCTAssertNotEqual(
            SearchRouter.cacheKey(for: query(), configuration: noKey),
            SearchRouter.cacheKey(for: query(), configuration: withKey)
        )
    }

    // MARK: - Quota windows

    func testQuotaWindowsResetAndExhaust() async throws {
        let file = try researchTestDirectory().appendingPathComponent("quota-window.json")
        let store = SearchQuotaStore(fileURL: file, now: { [clock] in clock?.now ?? Date() })

        // Firecrawl with a key allows 10 per minute.
        for _ in 0..<10 {
            let allowed = await store.consume(for: .firecrawl, keyed: true)
            XCTAssertTrue(allowed)
        }
        let blocked = await store.consume(for: .firecrawl, keyed: true)
        XCTAssertFalse(blocked)

        clock.advance(61)
        let afterMinute = await store.consume(for: .firecrawl, keyed: true)
        XCTAssertTrue(afterMinute)

        let snapshot = await store.snapshot(for: .firecrawl, keyed: true)
        XCTAssertEqual(snapshot.usedToday, 11)
        XCTAssertEqual(snapshot.dailyLimit, 30)
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        values.append(request)
        lock.unlock()
    }

    var last: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return values.last
    }
}
