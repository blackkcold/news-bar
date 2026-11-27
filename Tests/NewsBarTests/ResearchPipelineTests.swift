import XCTest
@testable import NewsBar

private final class ScriptedAIClient: AIChatClienting, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<AIChatResponse, AIChatError>]
    private var recorded: [AIChatRequest] = []
    let price: ModelPrice?

    init(responses: [Result<AIChatResponse, AIChatError>], price: ModelPrice? = nil) {
        self.script = responses
        self.price = price
    }

    func complete(_ request: AIChatRequest) async throws -> AIChatResponse {
        lock.lock()
        recorded.append(request)
        let next: Result<AIChatResponse, AIChatError>
        if script.isEmpty {
            next = .success(AIChatResponse(text: #"{"summary":"fallback","overview":"fallback"}"#, truncated: false))
        } else {
            next = script.removeFirst()
        }
        lock.unlock()
        return try next.get()
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded.count
    }
}

private struct ResettingQuotaAIClient: AIChatClienting {
    let quota: AIQuotaStore
    let price: ModelPrice?

    func complete(_ request: AIChatRequest) async throws -> AIChatResponse {
        guard quota.resetToday(),
              quota.reserveTracked(.summary, policy: .unlimited, reservedCostMicros: 500) != nil else {
            throw AIChatError.malformedResponse
        }
        throw AIChatError.timeout
    }
}

private final class PipelineSearchProvider: SearchProvider, @unchecked Sendable {
    let id: SearchProviderID
    let requiresKey: Bool

    private let lock = NSLock()
    private let hits: [SearchHit]
    private let error: SearchProviderError?
    private var calls = 0

    init(
        id: SearchProviderID = .tavily,
        requiresKey: Bool = true,
        hits: [SearchHit] = [],
        error: SearchProviderError? = nil
    ) {
        self.id = id
        self.requiresKey = requiresKey
        self.hits = hits
        self.error = error
    }

    func search(_ query: SearchQuery, key: String) async throws -> [SearchHit] {
        lock.lock()
        calls += 1
        lock.unlock()
        if let error { throw error }
        return hits
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ResearchRun] = []

    func append(_ run: ResearchRun) {
        lock.lock()
        values.append(run)
        lock.unlock()
    }

    var phases: [ResearchRun.Phase] {
        lock.lock()
        defer { lock.unlock() }
        return values.map(\.phase)
    }

    var latest: ResearchRun? {
        lock.lock()
        defer { lock.unlock() }
        return values.last
    }
}

/// Records how many searches are in flight at once. A serial stage peaks at
/// one; the point of stage-2 concurrency is that the peak rises without the
/// request count changing — which is the only optimisation here that buys wall
/// clock without spending anything.
private final class ConcurrencyTrackingProvider: SearchProvider, @unchecked Sendable {
    let id: SearchProviderID = .tavily
    let requiresKey: Bool = true

    private let lock = NSLock()
    private let hits: [SearchHit]
    private var inFlight = 0
    private var peak = 0
    private var calls = 0

    init(hits: [SearchHit]) {
        self.hits = hits
    }

    func search(_ query: SearchQuery, key: String) async throws -> [SearchHit] {
        lock.lock()
        calls += 1
        inFlight += 1
        peak = max(peak, inFlight)
        lock.unlock()

        // Long enough for a second dispatch to overlap, short enough that a
        // genuinely serial stage still finishes quickly.
        try? await Task.sleep(nanoseconds: 40_000_000)

        lock.lock()
        inFlight -= 1
        lock.unlock()
        _ = query
        return hits
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var peakConcurrency: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }
}

final class ResearchPipelineTests: XCTestCase {
    private let reutersURL = "https://www.reuters.com/a"
    private let bbcURL = "https://www.bbc.com/b"
    private let reutersText = "公司确认新品将于十月发布。" + String(repeating: "补充背景材料。", count: 30)
    private let bbcText = "另一家媒体确认新品将于十月发布。" + String(repeating: "补充背景材料。", count: 30)

    private func hit(
        _ url: String,
        title: String,
        snippet: String = "snippet",
        rank: Int = 1
    ) -> SearchHit {
        SearchHit(
            url: url,
            title: title,
            snippet: snippet,
            publishedAt: nil,
            inlineContent: nil,
            provider: .tavily,
            providerRank: rank
        )
    }

    private func failingDirect() -> DirectHTMLReader {
        DirectHTMLReader(
            transport: { _ in throw PageReadError.http(500) },
            resolver: { _ in ["93.184.216.34"] },
            now: { Date() }
        )
    }

    private func configuration(
        record: ResearchRecord,
        depth: ResearchDepth = .standard,
        aiCap: Int = 30,
        taskCap: Int = 3
    ) -> ResearchPipelineConfiguration {
        ResearchPipelineConfiguration(
            record: record,
            depth: depth,
            language: .en,
            trendContext: "",
            defaultRecency: .month,
            searchConfiguration: SearchRouterConfiguration(
                enabled: [.tavily],
                keys: [.tavily: "tavily-key"]
            ),
            firecrawlAPIKey: "",
            quotaPolicy: AIQuotaPolicy(mode: .count, countCap: aiCap),
            taskDailyCap: taskCap
        )
    }

    private func makePipeline(
        directory: URL,
        ai: any AIChatClienting,
        hits: [SearchHit],
        searchError: SearchProviderError? = nil,
        quota: AIQuotaStore? = nil,
        scrape: @escaping PageReader.Scrape
    ) -> (ResearchPipeline, PipelineSearchProvider) {
        let clock = ResearchTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let cache = ResearchCacheStore(directoryURL: directory)
        let provider = PipelineSearchProvider(hits: hits, error: searchError)
        let router = SearchRouter(
            providers: [provider],
            cache: cache,
            now: { clock.now }
        )
        let reader = PageReader(
            cache: cache,
            scrape: scrape,
            direct: failingDirect(),
            now: { clock.now }
        )
        let ledger = ResearchLedger(fileURL: directory.appendingPathComponent("ledger.json"))
        let pipeline = ResearchPipeline(
            ai: ai,
            searchRouter: router,
            pageReader: reader,
            ledger: ledger,
            quota: quota ?? AIQuotaStore(fileURL: directory.appendingPathComponent("quota.json")),
            now: { clock.now }
        )
        return (pipeline, provider)
    }

    // MARK: - Fixtures

    private var planningJSON: String {
        #"{"claims":["十月发布"],"queries":[{"text":"Event timeline","recency":"7d"}]}"#
    }

    private var extractionJSON: String {
        """
        {"evidence":[
          {"source":1,"quote":"\(reutersText)","claim":"十月发布","stance":"supports","publishedAt":"2026-10-01"},
          {"source":2,"quote":"\(bbcText)","claim":"十月发布","stance":"supports","publishedAt":"2026-10-02"}
        ]}
        """
    }

    private var synthesisJSON: String {
        """
        {"summary":"两家独立媒体确认了发布。","overview":"公司发布新品，随后两家媒体确认。",
         "timeline":[{"date":"2026-10-01","title":"发布","detail":"公司发布新品","evidenceIDs":["E1","E2"],"confidence":"high"}],
         "claims":[{"claim":"十月发布","status":"supports","evidenceIDs":["E1","E2"],"note":""}],
         "conflicts":[],"missing":[],"limitations":""}
        """
    }

    private var aiOnlySynthesisJSON: String {
        #"{"summary":"未联网，仅有话题信息。","overview":"无法核查。","timeline":[],"claims":[],"conflicts":[],"missing":[],"limitations":"未联网。"}"#
    }

    // MARK: - Full run

    func testRunsAllStagesAndProducesVerifiedReport() async throws {
        let directory = try researchTestDirectory()
        let ai = ScriptedAIClient(responses: [
            .success(AIChatResponse(text: planningJSON, truncated: false)),
            .success(AIChatResponse(text: extractionJSON, truncated: false)),
            .success(AIChatResponse(text: synthesisJSON, truncated: false)),
        ])
        let (pipeline, provider) = makePipeline(
            directory: directory,
            ai: ai,
            hits: [hit(reutersURL, title: "Reuters", rank: 1), hit(bbcURL, title: "BBC", rank: 2)],
            scrape: { url, _ in
                if url.contains("reuters") { return self.reutersText }
                if url.contains("bbc") { return self.bbcText }
                throw NewsBarError.requestFailed
            }
        )
        let progress = ProgressRecorder()

        let execution = await pipeline.run(
            configuration: configuration(record: researchTestRecord(title: "Event", status: .queued)),
            progress: { progress.append($0) }
        )

        XCTAssertNil(execution.error)
        XCTAssertEqual(execution.pagesRead, 2)
        XCTAssertEqual(execution.aiCalls, 3)
        XCTAssertEqual(execution.searchCalls, 1)
        XCTAssertEqual(execution.queries, ["Event timeline"])
        XCTAssertFalse(execution.isPartial)
        XCTAssertEqual(provider.callCount, 1)

        let report = execution.research
        XCTAssertEqual(report.promptVersion, ResearchPrompts.version)
        XCTAssertEqual(report.depth, .standard)
        XCTAssertEqual(report.searchStatus, .succeeded)
        XCTAssertEqual(report.evidence.count, 2)
        XCTAssertTrue(report.evidence.allSatisfy(\.quoteVerified))
        XCTAssertEqual(report.verification?.verdict, .confirmed)
        XCTAssertEqual(report.verification?.strength, 3)
        XCTAssertEqual(report.verification?.independentSources, 2)
        XCTAssertEqual(report.timeline.count, 1)
        XCTAssertEqual(report.timeline.first?.evidenceIDs, ["E1", "E2"])
        XCTAssertEqual(report.method?.providers, ["tavily"])
        XCTAssertEqual(report.method?.queries, ["Event timeline"])
        XCTAssertTrue(
            progress.latest?.progressFacts?.contains(where: { $0.kind == .claimSupported }) == true
        )

        XCTAssertEqual(
            progress.phases,
            [.planning, .searching, .searching, .reading, .reading, .extracting, .extracting, .extracting, .synthesizing, .validating, .validating, .done]
        )
    }

    // MARK: - Stage 2 concurrency

    /// Stage 2 used to dispatch one query at a time. On this machine's 28 deep
    /// records the first source landed at 33.1s — 58% of the whole run — because
    /// six queries queued behind each other before any page was read. Running
    /// them concurrently costs nothing extra: same queries, same request count,
    /// same budget ticket. It only removes the queueing.
    func testSearchStageDispatchesQueriesConcurrently() async throws {
        let directory = try researchTestDirectory()
        try? FileManager.default.removeItem(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let plan = """
        {"claims":["十月发布"],"queries":[
          {"text":"Event timeline","recency":"7d"},
          {"text":"Official response","recency":"7d"},
          {"text":"Fact check","recency":"7d"},
          {"text":"Background","recency":"7d"}
        ]}
        """
        let ai = ScriptedAIClient(responses: [
            .success(AIChatResponse(text: plan, truncated: false)),
            .success(AIChatResponse(text: extractionJSON, truncated: false)),
            .success(AIChatResponse(text: synthesisJSON, truncated: false)),
        ])
        let clock = ResearchTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let cache = ResearchCacheStore(directoryURL: directory)
        let provider = ConcurrencyTrackingProvider(hits: [
            hit(reutersURL, title: "Reuters", rank: 1),
            hit(bbcURL, title: "BBC", rank: 2),
        ])
        let router = SearchRouter(providers: [provider], cache: cache, now: { clock.now })
        let reader = PageReader(
            cache: cache,
            scrape: { url, _ in
                if url.contains("reuters") { return self.reutersText }
                if url.contains("bbc") { return self.bbcText }
                throw NewsBarError.requestFailed
            },
            direct: failingDirect(),
            now: { clock.now }
        )
        let pipeline = ResearchPipeline(
            ai: ai,
            searchRouter: router,
            pageReader: reader,
            ledger: ResearchLedger(fileURL: directory.appendingPathComponent("ledger.json")),
            quota: AIQuotaStore(fileURL: directory.appendingPathComponent("quota.json")),
            now: { clock.now }
        )

        let execution = await pipeline.run(
            configuration: configuration(record: researchTestRecord(title: "Event", status: .queued)),
            progress: { _ in }
        )

        XCTAssertNil(execution.error)
        // Four planned queries, four dispatches: concurrency must not add or
        // drop a single request.
        XCTAssertEqual(provider.callCount, 4)
        XCTAssertEqual(execution.searchCalls, 4)
        XCTAssertEqual(execution.queries.count, 4)
        XCTAssertGreaterThan(
            provider.peakConcurrency, 1,
            "Stage 2 dispatched queries one at a time; four queries must overlap."
        )
    }

    /// The cap exists so a deep run does not fan out into the whole query list
    /// at once: search providers rate-limit per account, and a burst that trips
    /// 429s costs more wall clock than the queue it replaced.
    func testSearchStageRespectsTheConcurrencyCap() async throws {
        let directory = try researchTestDirectory()
        try? FileManager.default.removeItem(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let queries = (1...6)
            .map { #"{"text":"Query \#($0)","recency":"7d"}"# }
            .joined(separator: ",")
        let plan = #"{"claims":["十月发布"],"queries":[\#(queries)]}"#
        let ai = ScriptedAIClient(responses: [
            .success(AIChatResponse(text: plan, truncated: false)),
            .success(AIChatResponse(text: extractionJSON, truncated: false)),
            .success(AIChatResponse(text: synthesisJSON, truncated: false)),
        ])
        let clock = ResearchTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let cache = ResearchCacheStore(directoryURL: directory)
        let provider = ConcurrencyTrackingProvider(hits: [
            hit(reutersURL, title: "Reuters", rank: 1),
            hit(bbcURL, title: "BBC", rank: 2),
        ])
        let router = SearchRouter(providers: [provider], cache: cache, now: { clock.now })
        let reader = PageReader(
            cache: cache,
            scrape: { url, _ in
                if url.contains("reuters") { return self.reutersText }
                if url.contains("bbc") { return self.bbcText }
                throw NewsBarError.requestFailed
            },
            direct: failingDirect(),
            now: { clock.now }
        )
        let pipeline = ResearchPipeline(
            ai: ai,
            searchRouter: router,
            pageReader: reader,
            ledger: ResearchLedger(fileURL: directory.appendingPathComponent("ledger.json")),
            quota: AIQuotaStore(fileURL: directory.appendingPathComponent("quota.json")),
            now: { clock.now }
        )

        _ = await pipeline.run(
            // Deep plans six queries; standard caps at four, which would make
            // this test measure the depth profile instead of the cap.
            configuration: configuration(
                record: researchTestRecord(title: "Event", status: .queued),
                depth: .deep
            ),
            progress: { _ in }
        )
        XCTAssertLessThanOrEqual(
            provider.peakConcurrency, ResearchPipeline.searchConcurrencyLimit,
            "The cap is the only protection against provider rate limits."
        )
        XCTAssertGreaterThan(provider.peakConcurrency, 1)
    }

    /// The gap round has to actually reach the network. A composition that
    /// computes coverage and then spends nothing would pass every pure test
    /// while changing nothing in the product, so this drives the real pipeline
    /// and counts dispatches.
    ///
    /// The fixture labels one `time` fact and one `structure` fact, which
    /// leaves compare / cause / next uncovered and both labelled angles partial.
    /// A standard pass may spend two follow-up queries.
    func testGapRoundDispatchesFollowUpQueriesWhenAnglesAreMissing() async throws {
        let directory = try researchTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let plan = """
        {"claims":["销量下降"],"queries":[{"text":"Event timeline","recency":"7d"}]}
        """
        let quoteA = "去年同期的销量是 2,840 万台，今年降至 2,400 万台。"
        let quoteC = "排名方面，前五名全部是 iPhone。"
        let extraction = """
        {"evidence":[
          {"source":1,"quote":"\(quoteA)","claim":"同比","stance":"supports","angle":"time"},
          {"source":2,"quote":"\(quoteC)","claim":"排名","stance":"supports","angle":"structure"}
        ]}
        """
        let synthesis = """
        {"summary":"销量下降。","overview":"销量下降。",
         "timeline":[{"date":"2026-10-01","title":"销量 2400 万台","detail":"","evidenceIDs":["E1"],"confidence":"high"}],
         "claims":[{"claim":"销量下降","status":"supports","evidenceIDs":["E1"],"note":""}],
         "conflicts":[],"missing":[],"limitations":""}
        """
        let ai = ScriptedAIClient(responses: [
            .success(AIChatResponse(text: plan, truncated: false)),
            .success(AIChatResponse(text: extraction, truncated: false)),
            .success(AIChatResponse(text: synthesis, truncated: false)),
        ])
        let clock = ResearchTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let cache = ResearchCacheStore(directoryURL: directory)
        let provider = PipelineSearchProvider(hits: [
            hit(reutersURL, title: "Reuters", rank: 1),
            hit(bbcURL, title: "BBC", rank: 2),
        ])
        let router = SearchRouter(providers: [provider], cache: cache, now: { clock.now })
        let reader = PageReader(
            cache: cache,
            // Both URLs must clear `PageReader.minScrapedCharacters`, or the
            // page degrades to its snippet, the quotes stop verifying, and the
            // gap round is correctly skipped for lack of signal.
            scrape: { url, _ in
                let padding = String(repeating: "补充背景材料。", count: 40)
                return url.contains("reuters") ? quoteA + padding : quoteC + padding
            },
            direct: failingDirect(),
            now: { clock.now }
        )
        let pipeline = ResearchPipeline(
            ai: ai,
            searchRouter: router,
            pageReader: reader,
            ledger: ResearchLedger(fileURL: directory.appendingPathComponent("ledger.json")),
            quota: AIQuotaStore(fileURL: directory.appendingPathComponent("quota.json")),
            now: { clock.now }
        )

        let recorder = ProgressRecorder()
        let execution = await pipeline.run(
            configuration: configuration(record: researchTestRecord(title: "Event", status: .queued)),
            progress: { recorder.append($0) }
        )

        XCTAssertNil(execution.error)
        XCTAssertGreaterThan(
            provider.callCount, 1,
            "A report with three uncovered angles must ask at least one of them."
        )
        XCTAssertLessThanOrEqual(provider.callCount, 3, "The profile's allowance is the cap.")
        XCTAssertEqual(
            execution.queries.count, provider.callCount,
            "Every dispatch must appear in the run's query list."
        )

        // Measured on a real deep run: `queriesPlanned` said 6 while 7 queries
        // had been dispatched, so the progress row read "7 of 6". The gap round
        // plans its queries after extraction, and nothing added them to the
        // planned count — a counter that exceeds its own total is not a
        // progress indicator, it is a contradiction.
        let latest = try XCTUnwrap(recorder.latest)
        XCTAssertLessThanOrEqual(
            latest.queriesCompleted, latest.queriesPlanned,
            "The progress row must never read more completed than planned."
        )
        XCTAssertEqual(
            latest.queriesPlanned, provider.callCount,
            "Every dispatched query has to be planned, including the gap round."
        )
    }

    // MARK: - Failures and degradation

    func testAllSearchFailuresFailBeforeSynthesis() async throws {
        let directory = try researchTestDirectory()
        let ai = ScriptedAIClient(responses: [
            .success(AIChatResponse(text: planningJSON, truncated: false)),
            .success(AIChatResponse(text: aiOnlySynthesisJSON, truncated: false)),
        ])
        let (pipeline, provider) = makePipeline(
            directory: directory,
            ai: ai,
            hits: [],
            searchError: .quotaExhausted,
            scrape: { _, _ in throw NewsBarError.requestFailed }
        )

        let execution = await pipeline.run(
            configuration: configuration(record: researchTestRecord(title: "Event", status: .queued)),
            progress: { _ in }
        )

        // No readable source means there is nothing to synthesize. Producing an
        // AI-only "report" here is what made zero-evidence records look usable.
        // The failure value zeroes the run counters, so the client itself is the
        // evidence that only the planning call was made.
        XCTAssertEqual(execution.error, L10n.string("research.error.searchFailed", language: .en))
        XCTAssertEqual(execution.pagesRead, 0)
        XCTAssertEqual(ai.callCount, 1)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertFalse(BurstResearchParser.hasUsableContent(execution.research))
    }

    func testFailedResearchDispatchKeepsItsReservationAndMarksCostUnknown() async throws {
        let directory = try researchTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let price = ModelPrice(
            provider: "fictional", modelPrefix: "fixture", inputPerMTok: 1, outputPerMTok: 2,
            cacheReadPerMTok: nil, cacheWritePerMTok: nil, currency: "CNY", updatedAt: "fixture"
        )
        let ai = ScriptedAIClient(responses: [.failure(.timeout)], price: price)
        let (pipeline, _) = makePipeline(
            directory: directory,
            ai: ai,
            hits: [],
            searchError: .quotaExhausted,
            scrape: { _, _ in throw NewsBarError.requestFailed }
        )
        _ = await pipeline.run(
            configuration: configuration(record: researchTestRecord(title: "Fictional event", status: .queued)),
            progress: { _ in }
        )

        let snapshot = pipeline.quota.snapshot()
        XCTAssertEqual(ai.callCount, 1)
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertGreaterThan(snapshot.costMicros, 0)
        XCTAssertEqual(snapshot.unpricedCalls, 1)
    }

    func testLateResearchFailureCannotSettleAgainstResetBudget() async throws {
        let directory = try researchTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let quota = AIQuotaStore(fileURL: directory.appendingPathComponent("quota.json"))
        let price = ModelPrice(
            provider: "fictional", modelPrefix: "fixture", inputPerMTok: 1, outputPerMTok: 2,
            cacheReadPerMTok: nil, cacheWritePerMTok: nil, currency: "CNY", updatedAt: "fixture"
        )
        let (pipeline, _) = makePipeline(
            directory: directory, ai: ResettingQuotaAIClient(quota: quota, price: price),
            hits: [], searchError: .quotaExhausted, quota: quota,
            scrape: { _, _ in throw NewsBarError.requestFailed }
        )
        _ = await pipeline.run(
            configuration: configuration(record: researchTestRecord(title: "Fictional event", status: .queued)),
            progress: { _ in }
        )
        let snapshot = quota.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.costMicros, 500)
        XCTAssertEqual(snapshot.unpricedCalls, 0)
    }

    func testZeroEvidenceKeepsSourceDossierAsBackgroundBrief() async throws {
        let directory = try researchTestDirectory()
        let backgroundBrief = #"{"summary":"背景梳理：公司预告十月发布新品。","overview":"公司先预告，媒体随后报道，具体日期尚未确认。","timeline":[{"date":"2026-10-01","title":"公司预告","detail":"公司确认十月发布新品","confidence":"low"}],"claims":[],"conflicts":[],"missing":[],"limitations":""}"#
        let ai = ScriptedAIClient(responses: [
            .success(AIChatResponse(text: planningJSON, truncated: false)),
            .success(AIChatResponse(text: #"{"evidence":[]}"#, truncated: false)),
            .success(AIChatResponse(text: #"{"evidence":[]}"#, truncated: false)),
            .success(AIChatResponse(text: backgroundBrief, truncated: false)),
        ])
        let (pipeline, _) = makePipeline(
            directory: directory,
            ai: ai,
            hits: [hit(reutersURL, title: "Reuters")],
            scrape: { _, _ in self.reutersText }
        )

        let execution = await pipeline.run(
            configuration: configuration(record: researchTestRecord(title: "Event", status: .queued)),
            progress: { _ in }
        )

        // A page was read, so the run is not a hard failure: it keeps a short
        // background brief from the dossier, but must not invent claims.
        XCTAssertNil(execution.error)
        XCTAssertTrue(execution.isPartial)
        XCTAssertEqual(execution.aiCalls, 4)
        XCTAssertEqual(execution.research.summary, "背景梳理：公司预告十月发布新品。")
        XCTAssertTrue(execution.research.evidence.isEmpty)
        XCTAssertEqual(execution.research.verification?.claims.count, 0)
        XCTAssertTrue(execution.research.timeline.allSatisfy { $0.evidenceIDs.isEmpty })
        XCTAssertTrue(
            execution.research.limitations.contains(
                L10n.string("research.limitation.noEvidence", language: .en)
            )
        )
    }

    func testAIExhaustionStopsWithBudgetError() async throws {        let directory = try researchTestDirectory()
        let ai = ScriptedAIClient(responses: [
            .success(AIChatResponse(text: planningJSON, truncated: false)),
        ])
        let (pipeline, _) = makePipeline(
            directory: directory,
            ai: ai,
            hits: [hit(reutersURL, title: "Reuters")],
            scrape: { _, _ in self.reutersText }
        )

        let execution = await pipeline.run(
            configuration: configuration(
                record: researchTestRecord(title: "Event", status: .queued),
                aiCap: 1
            ),
            progress: { _ in }
        )

        XCTAssertEqual(execution.error, L10n.string("research.error.budget", language: .en))
        XCTAssertEqual(execution.aiCalls, 0)
        XCTAssertFalse(BurstResearchParser.hasUsableContent(execution.research))
    }

    func testTaskBudgetExhaustionFailsBeforeAnyNetworkCall() async throws {
        let directory = try researchTestDirectory()
        let ai = ScriptedAIClient(responses: [])
        let (pipeline, provider) = makePipeline(
            directory: directory,
            ai: ai,
            hits: [hit(reutersURL, title: "Reuters")],
            scrape: { _, _ in self.reutersText }
        )

        let execution = await pipeline.run(
            configuration: configuration(
                record: researchTestRecord(title: "Event", status: .queued),
                taskCap: 0
            ),
            progress: { _ in }
        )

        XCTAssertEqual(execution.error, L10n.string("research.error.budget", language: .en))
        XCTAssertEqual(ai.callCount, 0)
        XCTAssertEqual(provider.callCount, 0)
    }

    func testPageFailureFallsBackToSnippetAndStaysUnverified() async throws {
        let directory = try researchTestDirectory()
        let snippet = "仅有搜索摘要的一行文字，无法读取原文正文。"
        let ai = ScriptedAIClient(responses: [
            .success(AIChatResponse(text: planningJSON, truncated: false)),
            .success(AIChatResponse(
                text: """
                {"evidence":[{"source":1,"quote":"\(snippet)","claim":"摘要","stance":"supports"}]}
                """,
                truncated: false
            )),
            .success(AIChatResponse(text: aiOnlySynthesisJSON, truncated: false)),
        ])
        let (pipeline, _) = makePipeline(
            directory: directory,
            ai: ai,
            hits: [hit(reutersURL, title: "Reuters", snippet: snippet)],
            scrape: { _, _ in throw NewsBarError.requestFailed }
        )

        let execution = await pipeline.run(
            configuration: configuration(record: researchTestRecord(title: "Event", status: .queued)),
            progress: { _ in }
        )

        XCTAssertNil(execution.error)
        XCTAssertTrue(execution.isPartial)
        XCTAssertEqual(execution.pagesRead, 0)
        XCTAssertEqual(execution.research.evidence.count, 1)
        XCTAssertEqual(execution.research.evidence.first?.quoteVerified, true)
        XCTAssertEqual(execution.research.verification?.verdict, .unverified)
    }

    // MARK: - Retries

    func testTruncatedSynthesisRetriesOnceWithLargerBudget() async throws {
        let directory = try researchTestDirectory()
        let truncated = AIChatResponse(text: synthesisJSON, truncated: true)
        let ai = ScriptedAIClient(responses: [
            .success(AIChatResponse(text: planningJSON, truncated: false)),
            .success(AIChatResponse(text: extractionJSON, truncated: false)),
            .success(truncated),
            .success(AIChatResponse(text: synthesisJSON, truncated: false)),
        ])
        let (pipeline, _) = makePipeline(
            directory: directory,
            ai: ai,
            hits: [hit(reutersURL, title: "Reuters"), hit(bbcURL, title: "BBC")],
            scrape: { url, _ in
                url.contains("reuters") ? self.reutersText : self.bbcText
            }
        )

        let execution = await pipeline.run(
            configuration: configuration(record: researchTestRecord(title: "Event", status: .queued)),
            progress: { _ in }
        )

        XCTAssertNil(execution.error)
        XCTAssertEqual(execution.aiCalls, 4)
        XCTAssertFalse(execution.isPartial)
        XCTAssertFalse(execution.research.limitations.contains(
            L10n.string("research.limitation.truncated", language: .en)
        ))
    }

    func testInvalidSynthesisUsesOneRepairCall() async throws {
        let directory = try researchTestDirectory()
        let ai = ScriptedAIClient(responses: [
            .success(AIChatResponse(text: planningJSON, truncated: false)),
            .success(AIChatResponse(text: extractionJSON, truncated: false)),
            .success(AIChatResponse(text: "this is not json", truncated: false)),
            .success(AIChatResponse(text: synthesisJSON, truncated: false)),
        ])
        let (pipeline, _) = makePipeline(
            directory: directory,
            ai: ai,
            hits: [
                hit(reutersURL, title: "Reuters", rank: 1),
                hit(bbcURL, title: "BBC", rank: 2),
            ],
            scrape: { url, _ in
                url.contains("reuters") ? self.reutersText : self.bbcText
            }
        )

        let execution = await pipeline.run(
            configuration: configuration(record: researchTestRecord(title: "Event", status: .queued)),
            progress: { _ in }
        )

        XCTAssertNil(execution.error)
        XCTAssertEqual(execution.aiCalls, 4)
        XCTAssertEqual(execution.research.verification?.verdict, .confirmed)
    }
}
