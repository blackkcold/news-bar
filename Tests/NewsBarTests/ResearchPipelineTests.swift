import XCTest
@testable import NewsBar

private final class ScriptedAIClient: AIChatClienting, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<AIChatResponse, AIChatError>]
    private var recorded: [AIChatRequest] = []

    init(responses: [Result<AIChatResponse, AIChatError>]) {
        self.script = responses
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
            aiDailyCap: aiCap,
            taskDailyCap: taskCap
        )
    }

    private func makePipeline(
        directory: URL,
        ai: ScriptedAIClient,
        hits: [SearchHit],
        searchError: SearchProviderError? = nil,
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

        XCTAssertEqual(
            progress.phases,
            [.planning, .searching, .searching, .reading, .reading, .extracting, .extracting, .synthesizing, .validating, .done]
        )
    }

    // MARK: - Failures and degradation

    func testAllSearchFailuresProduceUnverifiedPartialReport() async throws {
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

        XCTAssertNil(execution.error)
        XCTAssertTrue(execution.isPartial)
        XCTAssertEqual(execution.pagesRead, 0)
        XCTAssertEqual(execution.aiCalls, 2)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(execution.research.searchStatus, .failed)
        XCTAssertEqual(execution.research.verification?.verdict, .unverified)
        XCTAssertTrue(execution.research.evidence.isEmpty)
        XCTAssertTrue(
            execution.research.limitations.contains(
                L10n.string("research.limitation.notOnline", language: .en)
            )
        )
    }

    func testAIExhaustionStopsWithBudgetError() async throws {
        let directory = try researchTestDirectory()
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
        XCTAssertEqual(execution.research.verification?.verdict, .confirmed)
    }
}
