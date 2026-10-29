import XCTest
@testable import NewsBar

private final class AccountingProvider: SearchProvider, @unchecked Sendable {
    let id: SearchProviderID
    let requiresKey: Bool

    private let lock = NSLock()
    private let error: Error?
    private var calls = 0

    init(id: SearchProviderID, requiresKey: Bool = false, error: Error? = nil) {
        self.id = id
        self.requiresKey = requiresKey
        self.error = error
    }

    func search(_ query: SearchQuery, key: String) async throws -> [SearchHit] {
        lock.lock()
        calls += 1
        lock.unlock()
        if let error { throw error }
        throw SearchProviderError.server(503)
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private final class CancellingProvider: SearchProvider, @unchecked Sendable {
    let id: SearchProviderID = .tavily
    let requiresKey = false

    func search(_ query: SearchQuery, key: String) async throws -> [SearchHit] {
        throw CancellationError()
    }
}

final class SearchAttemptAccountingTests: XCTestCase {
    private var clock: ResearchTestClock!

    override func setUp() {
        clock = ResearchTestClock(Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func router(
        _ providers: [any SearchProvider],
        directory: URL
    ) -> SearchRouter {
        SearchRouter(
            providers: providers,
            cache: ResearchCacheStore(directoryURL: directory),
            now: { [clock] in clock?.now ?? Date() }
        )
    }

    private func configuration(
        enabled: Set<SearchProviderID> = [.tavily],
        keys: [SearchProviderID: String] = [.tavily: "key"]
    ) -> SearchRouterConfiguration {
        SearchRouterConfiguration(enabled: enabled, keys: keys)
    }

    private func query(_ text: String = "事件 时间线") -> SearchQuery {
        SearchQuery(text: text, recency: .week, maxResults: 5)
    }

    func testPersistentServerFailuresStopAtTicketLimit() async throws {
        let directory = try researchTestDirectory()
        let tavily = AccountingProvider(id: .tavily, requiresKey: true)
        let router = router([tavily], directory: directory)
        let ticket = SearchAttemptTicket(limit: 5)

        for _ in 0..<10 {
            _ = try? await router.search(
                query(),
                configuration: configuration(),
                useCache: false,
                ticket: ticket
            )
        }

        // Retry on 5xx costs two calls per query; the ticket, not provider
        // identity, is the hard ceiling.
        XCTAssertEqual(tavily.callCount, 5)
        XCTAssertEqual(ticket.used, 5)
    }

    func testSkippedProvidersAndCacheHitsConsumeNothing() async throws {
        let directory = try researchTestDirectory()
        let tavily = AccountingProvider(id: .tavily, requiresKey: true)
        let subject = router([tavily], directory: directory)

        let skippedTicket = SearchAttemptTicket(limit: 4)
        _ = try? await subject.search(
            query(),
            configuration: configuration(enabled: [], keys: [:]),
            useCache: false,
            ticket: skippedTicket
        )
        XCTAssertEqual(skippedTicket.used, 0)

        let missingKeyTicket = SearchAttemptTicket(limit: 4)
        _ = try? await subject.search(
            query(),
            configuration: configuration(enabled: [.tavily], keys: [:]),
            useCache: false,
            ticket: missingKeyTicket
        )
        XCTAssertEqual(missingKeyTicket.used, 0)

        // A successful call primes the cache; the same query must then be free.
        let hitURL = "https://www.reuters.com/a"
        let success = ScriptedSuccessProvider(
            id: .tavily,
            requiresKey: true,
            hits: [
                SearchHit(
                    url: hitURL,
                    title: "Reuters",
                    snippet: "s",
                    publishedAt: nil,
                    inlineContent: nil,
                    provider: .tavily,
                    providerRank: 1
                ),
            ]
        )
        let cachingRouter = router([success], directory: directory)
        let first = try await cachingRouter.search(
            query("缓存查询"),
            configuration: configuration(),
            ticket: SearchAttemptTicket(limit: 4)
        )
        XCTAssertEqual(first.attempts, 1)

        let cachedTicket = SearchAttemptTicket(limit: 4)
        let cached = try await cachingRouter.search(
            query("缓存查询"),
            configuration: configuration(),
            ticket: cachedTicket
        )
        XCTAssertEqual(cached.attempts, 0)
        XCTAssertEqual(cachedTicket.used, 0)
        XCTAssertEqual(success.callCount, 1)
    }

    func testCancellationAfterDispatchIsStillCharged() async throws {
        let directory = try researchTestDirectory()
        let router = router([CancellingProvider()], directory: directory)
        let ticket = SearchAttemptTicket(limit: 3)

        do {
            _ = try await router.search(
                query(),
                configuration: configuration(enabled: [.tavily], keys: [:]),
                useCache: false,
                ticket: ticket
            )
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }

        XCTAssertEqual(ticket.used, 1)
    }

    func testKeylessUnauthorizedIsNotRemembered() async throws {
        let directory = try researchTestDirectory()
        let provider = AccountingProvider(
            id: .firecrawl,
            requiresKey: false,
            error: SearchProviderError.unauthorized
        )
        let router = router([provider], directory: directory)
        let config = configuration(enabled: [.firecrawl], keys: [:])

        _ = try? await router.search(query(), configuration: config, useCache: false)
        _ = try? await router.search(query("另一个"), configuration: config, useCache: false)

        XCTAssertEqual(provider.callCount, 2)
        let invalid = await router.invalidProviders()
        XCTAssertTrue(invalid.isEmpty)
    }

    func testForbiddenIsNotAPermanentKeyFailure() async throws {
        let directory = try researchTestDirectory()
        let provider = AccountingProvider(
            id: .tavily,
            requiresKey: true,
            error: SearchProviderError.forbidden
        )
        let router = router([provider], directory: directory)

        _ = try? await router.search(query(), configuration: configuration(), useCache: false)
        _ = try? await router.search(query("另一个"), configuration: configuration(), useCache: false)

        XCTAssertEqual(provider.callCount, 2)
        let invalid = await router.invalidProviders()
        XCTAssertTrue(invalid.isEmpty)
        let snapshot = await router.statusSnapshot(configuration: configuration())
        XCTAssertEqual(snapshot.first { $0.provider == .tavily }?.state, .forbidden)
    }

    func testStatusSnapshotCoversDisabledMissingKeyAndAttemptedStates() async throws {
        let directory = try researchTestDirectory()
        let tavily = AccountingProvider(id: .tavily, requiresKey: true)
        let firecrawl = AccountingProvider(id: .firecrawl, requiresKey: false)
        let brave = AccountingProvider(id: .brave, requiresKey: true)
        let router = router([tavily, firecrawl, brave], directory: directory)

        let initial = await router.statusSnapshot(
            configuration: configuration(enabled: [.tavily, .firecrawl], keys: [.tavily: "k"])
        )
        XCTAssertEqual(initial.first { $0.provider == .tavily }?.state, .unattempted)
        XCTAssertEqual(initial.first { $0.provider == .firecrawl }?.state, .unattempted)
        XCTAssertEqual(initial.first { $0.provider == .brave }?.state, .disabled)

        let missing = await router.statusSnapshot(configuration: configuration(keys: [:]))
        XCTAssertEqual(missing.first { $0.provider == .tavily }?.state, .missingKey)
    }

    func testForbiddenProviderIsNotRetriedWithinTheSameResearch() async throws {
        let directory = try researchTestDirectory()
        let provider = ForbiddenProvider()
        let router = router([provider], directory: directory)
        let pipeline = ResearchPipeline(
            ai: SilentAIClient(),
            searchRouter: router,
            pageReader: PageReader(
                cache: ResearchCacheStore(directoryURL: directory),
                scrape: { _, _ in throw PageReadError.http(500) },
                direct: DirectHTMLReader(
                    transport: { _ in throw PageReadError.http(500) },
                    resolver: { _ in ["93.184.216.34"] },
                    now: { Date() }
                ),
                now: { self.clock.now }
            ),
            ledger: ResearchLedger(fileURL: directory.appendingPathComponent("ledger.json")),
            quota: AIQuotaStore(fileURL: directory.appendingPathComponent("quota.json")),
            now: { self.clock.now }
        )
        let recorder = RunRecorder()

        _ = await pipeline.run(
            configuration: ResearchPipelineConfiguration(
                record: researchTestRecord(title: "Event", status: .queued),
                depth: .deep,
                language: .en,
                trendContext: "",
                defaultRecency: .month,
                searchConfiguration: configuration(),
                firecrawlAPIKey: "",
                quotaPolicy: AIQuotaPolicy(mode: .count, countCap: 30),
                taskDailyCap: 3
            ),
            progress: { recorder.append($0) }
        )

        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(recorder.latest?.searchCalls, 1)
    }

    func testForbiddenProviderIsNotRetriedEvenWhenAnotherSucceeds() async throws {
        let directory = try researchTestDirectory()
        let forbidden = ForbiddenProvider()
        let success = ScriptedSuccessProvider(
            id: .firecrawl,
            requiresKey: false,
            hits: []
        )
        let router = router([forbidden, success], directory: directory)
        let pipeline = ResearchPipeline(
            ai: SilentAIClient(),
            searchRouter: router,
            pageReader: PageReader(
                cache: ResearchCacheStore(directoryURL: directory),
                scrape: { _, _ in throw PageReadError.http(500) },
                direct: DirectHTMLReader(
                    transport: { _ in throw PageReadError.http(500) },
                    resolver: { _ in ["93.184.216.34"] },
                    now: { Date() }
                ),
                now: { self.clock.now }
            ),
            ledger: ResearchLedger(fileURL: directory.appendingPathComponent("ledger.json")),
            quota: AIQuotaStore(fileURL: directory.appendingPathComponent("quota.json")),
            now: { self.clock.now }
        )

        _ = await pipeline.run(
            configuration: ResearchPipelineConfiguration(
                record: researchTestRecord(title: "Event", status: .queued),
                depth: .deep,
                language: .en,
                trendContext: "",
                defaultRecency: .month,
                searchConfiguration: SearchRouterConfiguration(
                    enabled: [.tavily, .firecrawl],
                    keys: [.tavily: "key"]
                ),
                firecrawlAPIKey: "",
                quotaPolicy: AIQuotaPolicy(mode: .count, countCap: 30),
                taskDailyCap: 3
            ),
            progress: { _ in }
        )

        XCTAssertEqual(forbidden.callCount, 1)
        XCTAssertEqual(success.callCount, DepthProfile.profile(for: .deep).queryCount)
    }

    func testPipelineChargesOnlyDispatchedRequests() async throws {
        let directory = try researchTestDirectory()
        let provider = AccountingProvider(id: .tavily, requiresKey: true)
        let router = router([provider], directory: directory)
        let ai = SilentAIClient()
        let pipeline = ResearchPipeline(
            ai: ai,
            searchRouter: router,
            pageReader: PageReader(
                cache: ResearchCacheStore(directoryURL: directory),
                scrape: { _, _ in throw PageReadError.http(500) },
                direct: DirectHTMLReader(
                    transport: { _ in throw PageReadError.http(500) },
                    resolver: { _ in ["93.184.216.34"] },
                    now: { Date() }
                ),
                now: { self.clock.now }
            ),
            ledger: ResearchLedger(fileURL: directory.appendingPathComponent("ledger.json")),
            quota: AIQuotaStore(fileURL: directory.appendingPathComponent("quota.json")),
            now: { self.clock.now }
        )

        let recorder = RunRecorder()
        let execution = await pipeline.run(
            configuration: ResearchPipelineConfiguration(
                record: researchTestRecord(title: "Event", status: .queued),
                depth: .deep,
                language: .en,
                trendContext: "",
                defaultRecency: .month,
                searchConfiguration: configuration(),
                firecrawlAPIKey: "",
                quotaPolicy: AIQuotaPolicy(mode: .count, countCap: 30),
                taskDailyCap: 3
            ),
            progress: { recorder.append($0) }
        )

        // The terminal failure execution zeroes its counters; the last progress
        // snapshot carries the real, charged totals.
        let searchCalls = recorder.latest?.searchCalls ?? -1
        XCTAssertNotNil(execution.error)
        XCTAssertEqual(searchCalls, provider.callCount)
        XCTAssertEqual(provider.callCount, DepthProfile.maxSearchHTTPCallsPerTask)
        XCTAssertLessThanOrEqual(searchCalls, DepthProfile.maxSearchHTTPCallsPerTask)
    }
}

private final class ScriptedSuccessProvider: SearchProvider, @unchecked Sendable {
    let id: SearchProviderID
    let requiresKey: Bool
    private let hits: [SearchHit]
    private let lock = NSLock()
    private var calls = 0

    init(id: SearchProviderID, requiresKey: Bool, hits: [SearchHit]) {
        self.id = id
        self.requiresKey = requiresKey
        self.hits = hits
    }

    func search(_ query: SearchQuery, key: String) async throws -> [SearchHit] {
        lock.lock()
        calls += 1
        lock.unlock()
        return hits
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private final class ForbiddenProvider: SearchProvider, @unchecked Sendable {
    let id: SearchProviderID = .tavily
    let requiresKey = true
    private let lock = NSLock()
    private var calls = 0

    func search(_ query: SearchQuery, key: String) async throws -> [SearchHit] {
        lock.lock()
        calls += 1
        lock.unlock()
        throw SearchProviderError.forbidden
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private final class RunRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [ResearchRun] = []

    func append(_ run: ResearchRun) {
        lock.lock()
        runs.append(run)
        lock.unlock()
    }

    var latest: ResearchRun? {
        lock.lock()
        defer { lock.unlock() }
        return runs.last
    }
}

private final class SilentAIClient: AIChatClienting, @unchecked Sendable {
    func complete(_ request: AIChatRequest) async throws -> AIChatResponse {
        AIChatResponse(text: #"{"claims":[],"queries":[]}"#, truncated: false)
    }
}
