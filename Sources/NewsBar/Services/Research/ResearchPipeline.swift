import Foundation

struct ResearchPipelineConfiguration: Sendable {
    var record: ResearchRecord
    var depth: ResearchDepth
    var language: AppLanguage
    var trendContext: String
    var defaultRecency: ResearchDefaultRecency
    var searchConfiguration: SearchRouterConfiguration
    /// Firecrawl key used only for the page-reading fallback; may be empty.
    var firecrawlAPIKey: String
    /// The app-wide AI limit captured at task creation. The quota ledger is the
    /// only gate; the research ledger keeps per-origin counts for display.
    var quotaPolicy: AIQuotaPolicy
    var taskDailyCap: Int
    /// Request-count cap for automatic search dispatches. This is independent
    /// of the currency-based AI quota policy.
    var automaticSearchDailyLimit: Int
    var seedSourceName: String?
    /// Re-checked at every phase boundary so a cancelled or superseded run
    /// stops before spending another network request.
    var isAllowed: @Sendable () async -> Bool
    /// When present, the run re-analyses a previous report instead of doing a
    /// full plan/search/extract pass. New materials are the only new inputs.
    var incremental: ResearchIncrementalContext?
    /// Explicit full re-research: bypass the page cache as well as the report
    /// reuse path.
    var forceRefresh: Bool

    init(
        record: ResearchRecord,
        depth: ResearchDepth,
        language: AppLanguage,
        trendContext: String,
        defaultRecency: ResearchDefaultRecency,
        searchConfiguration: SearchRouterConfiguration,
        firecrawlAPIKey: String,
        quotaPolicy: AIQuotaPolicy,
        taskDailyCap: Int,
        automaticSearchDailyLimit: Int = 20,
        seedSourceName: String? = nil,
        incremental: ResearchIncrementalContext? = nil,
        forceRefresh: Bool = false,
        isAllowed: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.record = record
        self.depth = depth
        self.language = language
        self.trendContext = trendContext
        self.defaultRecency = defaultRecency
        self.searchConfiguration = searchConfiguration
        self.firecrawlAPIKey = firecrawlAPIKey
        self.quotaPolicy = quotaPolicy
        self.taskDailyCap = taskDailyCap
        self.automaticSearchDailyLimit = AppSettings.validResearchAutoSearchDailyLimits
            .contains(automaticSearchDailyLimit) ? automaticSearchDailyLimit : 20
        self.seedSourceName = seedSourceName
        self.incremental = incremental
        self.forceRefresh = forceRefresh
        self.isAllowed = isAllowed
    }
}

private final class ResearchRunState {
    var aiCalls = 0
    var searchCalls = 0
    var pagesRead = 0
    var queriesCompleted = 0
    var failovers = 0
    var budgetExhausted = false
    var aiLimitReached = false
    var truncated = false
    var partial = false
    var usedProviders: Set<SearchProviderID> = []
}

/// The eight-stage evidence-backed pipeline. All side effects are injected so
/// the pipeline itself stays deterministic and testable: no URLSession, no
/// Keychain, no singleton reads.
struct ResearchPipeline: Sendable {
    typealias ProgressHandler = @Sendable (ResearchRun) async -> Void

    // MARK: - Gap round

    /// Angles that still need work after the first extraction pass. A partial
    /// angle (one verified fact) and an uncovered angle (none) are both gaps;
    /// the difference only decides how badly they are needed, not whether the
    /// question is worth asking.
    static func gapAngles(
        covered: Set<ResearchAngle>,
        partial: Set<ResearchAngle>
    ) -> [ResearchAngle] {
        ResearchAngle.allCases.filter { !covered.contains($0) || partial.contains($0) }
    }

    /// One query per missing question, phrased as the question rather than as a
    /// paraphrase of the event. A query naming the same question as an earlier
    /// one would buy the same pages again, so it is dropped.
    static func gapQueries(
        title: String,
        angles: [ResearchAngle],
        language: AppLanguage,
        excluding earlierQueries: [String],
        limit: Int
    ) -> [PlannedQuery] {
        guard limit > 0 else { return [] }
        var used = Set(earlierQueries.map(normalizeQuery))
        var queries: [PlannedQuery] = []

        for angle in angles where queries.count < limit {
            let text = gapQueryText(title: title, angle: angle, language: language)
            let key = normalizeQuery(text)
            guard !key.isEmpty, used.insert(key).inserted else { continue }
            queries.append(PlannedQuery(text: text, recency: nil))
        }
        return queries
    }

    /// Whitespace- and case-insensitive comparison of two query strings.
    /// Punctuation is kept: "销量 排名" and "销量  排名" are the same request,
    /// while "份额" and "占比" are legitimately different phrasings.
    static func normalizeQuery(_ text: String) -> String {
        text
            .folding(
                options: [.widthInsensitive, .caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    /// The question itself, in the search language. These are the same five
    /// questions the extraction prompt labels, so a gap query and an angle label
    /// cannot drift apart.
    static func gapQueryText(
        title: String,
        angle: ResearchAngle,
        language: AppLanguage
    ) -> String {
        if language == .en {
            switch angle {
            case .time: return "\(title) last year comparison"
            case .compare: return "\(title) compare other markets competitors"
            case .structure: return "\(title) rankings market share breakdown"
            case .cause: return "\(title) why cause policy impact"
            case .next: return "\(title) what happens next outlook"
            }
        }
        switch angle {
        case .time: return "\(title) 去年 同比 对比"
        case .compare: return "\(title) 其他市场 同行 对比"
        case .structure: return "\(title) 排名 份额 占比"
        case .cause: return "\(title) 原因 政策 影响"
        case .next: return "\(title) 接下来 预计 展望"
        }
    }

    /// One call is reserved for synthesis and one for a single remedy after it.
    /// The gap round only runs when a call remains beyond those two: a thin
    /// report beats no report.
    static let reservedAICallsForSynthesis = 2

    /// What to do when the synthesis response was not usable.
    ///
    /// Exactly one remedy is allowed, so that the worst case is the attempt plus
    /// one call — the two that `reservedAICallsForSynthesis` actually reserves.
    /// Before this was bounded, a truncated response used the enlarged-budget
    /// retry and then asked for a repair as well: three calls against two
    /// reserved, so the third was refused and the pass failed with "AI request
    /// failed" after every page had already been read and paid for.
    enum SynthesisRemedy: Equatable {
        /// Re-ask with a larger token budget. Truncation is a length problem, so
        /// more room is the remedy that can actually fix it.
        case enlargeBudget
        /// Re-emit from the broken text. Complete but unparseable output needs a
        /// second attempt at the same length, not more room.
        case repair
        /// The response is usable as it stands.
        case none
    }

    /// One attempt plus one remedy is the whole budget for writing a report.
    static let maxSynthesisAICalls = 1 + 1

    static func synthesisRemedy(truncated: Bool, parsed: Bool) -> SynthesisRemedy {
        // Truncation wins over parseability. A response can parse and still have
        // had content cut off the end, and the enlarged-budget retry is the only
        // thing that can recover it — skipping it would ship a silently
        // incomplete report as a limitation.
        if truncated { return .enlargeBudget }
        if parsed { return .none }
        return .repair
    }

    static func canAffordGapRound(aiCalls: Int, aiCallLimit: Int) -> Bool {
        gapRoundAllowance(aiCalls: aiCalls, aiCallLimit: aiCallLimit) > 0
    }

    /// How many AI calls the gap round may actually spend.
    ///
    /// `canAffordGapRound` only answered yes/no, and the round then derived its
    /// own page budget from `pageCount` — so a deep run with one spare call could
    /// still read eight pages, which is four extraction batches. Measured on a
    /// real deep run: planning plus four batches spent five of eight calls, the
    /// round passed the yes/no check, spent the remaining three, and synthesis
    /// failed with no report. The allowance is therefore an amount, not a flag.
    static func gapRoundAllowance(aiCalls: Int, aiCallLimit: Int) -> Int {
        max(0, aiCallLimit - aiCalls - reservedAICallsForSynthesis)
    }

    /// How many gap pages may be read, given the call allowance.
    ///
    /// One extraction batch is two pages and one AI call, so the page budget is
    /// the allowance times two. The profile's page count stays a hard ceiling:
    /// the round never widens the reading window beyond a normal pass.
    static func gapPageBudget(allowance: Int, pageLimit: Int) -> Int {
        max(0, min(pageLimit, allowance * 2))
    }

    /// How many stage-2 queries may be in flight at once. Search providers
    /// rate-limit per account, and a burst that trips 429s costs more wall clock
    /// than the queue it replaced, so this stays small: three is enough to turn
    /// six serial dispatches into two waves.
    static let searchConcurrencyLimit = 3

    /// What one concurrent query reports back. A wave collects these instead of
    /// mutating the run counters from inside the task group, which keeps the
    /// accounting single-threaded and the hit order identical to planned order.
    private struct SearchWaveOutcome: Sendable {
        let offset: Int
        let batch: SearchBatch?
        let failed: Bool
        let forbiddenProviders: [SearchProviderID]
    }

    /// One dispatch inside a wave. Provider errors are answers, not failures: a
    /// query that exhausted every provider must not cancel its siblings, so
    /// only cancellation escapes.
    private static func dispatchSearch(
        router: SearchRouter,
        query: SearchQuery,
        configuration: SearchRouterConfiguration,
        forceRefresh: Bool,
        ticket: SearchAttemptTicket,
        offset: Int
    ) async throws -> SearchWaveOutcome {
        do {
            let batch = try await router.search(
                query,
                configuration: configuration,
                useCache: !forceRefresh,
                ticket: ticket
            )
            let forbidden = batch.failures.compactMap { failure -> SearchProviderID? in
                failure.reason == .forbidden ? failure.provider : nil
            }
            return SearchWaveOutcome(
                offset: offset,
                batch: batch,
                failed: false,
                forbiddenProviders: forbidden
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let unavailable as SearchUnavailableError {
            let forbidden = unavailable.failures.compactMap { failure -> SearchProviderID? in
                failure.reason == .forbidden ? failure.provider : nil
            }
            return SearchWaveOutcome(
                offset: offset,
                batch: nil,
                failed: true,
                forbiddenProviders: forbidden
            )
        } catch {
            return SearchWaveOutcome(
                offset: offset,
                batch: nil,
                failed: true,
                forbiddenProviders: []
            )
        }
    }

    // MARK: - Search rounds

    /// Why a search round stopped before its plan was exhausted.
    private enum SearchRoundAbort: Error {
        case cancelled
        case stopped(String)
        /// The ledger could not record the spent requests. Continuing would
        /// spend budget the app cannot account for.
        case ledger
    }

    /// Everything one round reports back. The caller applies it to the run
    /// state so the accounting stays in one place, and both the event round and
    /// the gap round feed it the same way.
    private struct SearchWaveResult: Sendable {
        var hits: [SearchHit] = []
        var forbidden: Set<SearchProviderID> = []
        var failovers = 0
        var providers: Set<SearchProviderID> = []
        var anySucceeded = false
        var anyFailed = false
        var completed = 0
        var budgetExhausted = false
    }

    /// Runs a plan through bounded-concurrency waves against one shared budget
    /// ticket. Extracted from stage 2 because the gap round issues its own plan
    /// and must behave identically: same cap, same budget, same planned-order
    /// hit list, same cancellation and ledger semantics.
    private func runSearchWaves(
        _ plan: [PlannedQuery],
        ticket: SearchAttemptTicket,
        blockedProviders: inout Set<SearchProviderID>,
        configuration: ResearchPipelineConfiguration,
        recency: SearchRecency,
        language: AppLanguage,
        settle: () -> Bool,
        onWave: (_ completedInWave: Int) async -> Void,
        stopReason: () async -> String?
    ) async throws -> SearchWaveResult {
        var result = SearchWaveResult()
        var offset = 0

        while offset < plan.count {
            if let reason = await stopReason() { throw SearchRoundAbort.stopped(reason) }
            // A query needs at least one dispatch, so a wave wider than the
            // remaining budget would only manufacture budget-exhausted failures
            // that say nothing about the providers.
            let waveSize = min(
                Self.searchConcurrencyLimit,
                ticket.remaining,
                plan.count - offset
            )
            guard waveSize > 0 else {
                result.budgetExhausted = true
                break
            }

            var queryConfiguration = configuration.searchConfiguration
            queryConfiguration.enabled.subtract(blockedProviders)
            let wave = Array(plan[offset..<(offset + waveSize)])
            let queries = wave.map { planned in
                SearchQuery(
                    text: planned.text,
                    recency: planned.recency ?? recency,
                    language: language.bcp47,
                    maxResults: 6
                )
            }

            let outcomes: [SearchWaveOutcome]
            do {
                outcomes = try await withThrowingTaskGroup(
                    of: SearchWaveOutcome.self
                ) { group in
                    for (index, query) in queries.enumerated() {
                        group.addTask {
                            try await Self.dispatchSearch(
                                router: searchRouter,
                                query: query,
                                configuration: queryConfiguration,
                                forceRefresh: configuration.forceRefresh,
                                ticket: ticket,
                                offset: offset + index
                            )
                        }
                    }
                    var collected: [SearchWaveOutcome] = []
                    collected.reserveCapacity(queries.count)
                    for try await outcome in group {
                        collected.append(outcome)
                    }
                    return collected
                }
            } catch is CancellationError {
                throw SearchRoundAbort.cancelled
            }

            guard settle() else { throw SearchRoundAbort.ledger }
            // Apply in planned order, not completion order: the hit list feeds
            // ranking, and a completion-order list would make the same report
            // come out differently on every run.
            for outcome in outcomes.sorted(by: { $0.offset < $1.offset }) {
                if let batch = outcome.batch {
                    result.anySucceeded = true
                    result.failovers += batch.failovers
                    result.providers.formUnion(batch.providers)
                    result.hits.append(contentsOf: batch.hits)
                } else if outcome.failed {
                    result.anyFailed = true
                }
                result.forbidden.formUnion(outcome.forbiddenProviders)
            }
            blockedProviders.formUnion(result.forbidden)
            result.completed += outcomes.count
            await onWave(outcomes.count)
            offset += waveSize
            if ticket.remaining <= 0, offset < plan.count {
                result.budgetExhausted = true
                break
            }
        }
        return result
    }

    let ai: any AIChatClienting
    let searchRouter: SearchRouter
    let pageReader: PageReader
    let ledger: ResearchLedger
    let quota: AIQuotaStore
    let now: @Sendable () -> Date

    init(
        ai: any AIChatClienting,
        searchRouter: SearchRouter,
        pageReader: PageReader,
        ledger: ResearchLedger = .shared,
        quota: AIQuotaStore = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ai = ai
        self.searchRouter = searchRouter
        self.pageReader = pageReader
        self.ledger = ledger
        self.quota = quota
        self.now = now
    }

    func run(
        configuration: ResearchPipelineConfiguration,
        progress: @escaping ProgressHandler
    ) async -> ResearchExecution {
        let depth = configuration.depth
        let profile = DepthProfile.profile(for: depth)
        let origin = configuration.record.run.origin
        let language = configuration.language
        let startedAt = now()
        let state = ResearchRunState()
        let incremental = configuration.incremental
        var progressFacts: [ResearchRunFact] = []

        var plannedQueries: [PlannedQuery] = []
        var plannedQueryCount = 0

        func snapshot(
            _ phase: ResearchRun.Phase,
            error: String? = nil,
            finished: Bool = false
        ) -> ResearchRun {
            ResearchRun(
                phase: phase,
                depth: depth,
                origin: origin,
                queriesPlanned: plannedQueryCount,
                queriesCompleted: state.queriesCompleted,
                pagesRead: state.pagesRead,
                aiCalls: state.aiCalls,
                searchCalls: state.searchCalls,
                progressFacts: progressFacts.isEmpty ? nil : progressFacts,
                startedAt: configuration.record.run.startedAt ?? startedAt,
                finishedAt: finished ? now() : nil,
                lastError: error
            )
        }

        func appendProgressFact(_ fact: ResearchRunFact) {
            guard !progressFacts.contains(where: { $0.id == fact.id }) else { return }
            progressFacts.append(fact)
            if progressFacts.count > 30 {
                progressFacts.removeFirst(progressFacts.count - 30)
            }
        }

        func fail(_ message: String) async -> ResearchExecution {
            await progress(snapshot(.done, error: message, finished: true))
            return .failure(message)
        }

        func checkStop() async -> String? {
            if Task.isCancelled {
                return L10n.string("research.error.cancelled", language: language)
            }
            if await configuration.isAllowed() == false {
                return L10n.string("research.error.cancelled", language: language)
            }
            if now().timeIntervalSince(startedAt) > DepthProfile.taskTimeout {
                return L10n.string("research.error.timeout", language: language)
            }
            return nil
        }

        func callAI(_ request: AIChatRequest) async -> AIChatResponse? {
            guard !Task.isCancelled else { return nil }
            guard state.aiCalls < profile.aiCallLimit else {
                state.aiLimitReached = true
                return nil
            }
            let price = ai.price
            let system = request.messages
                .filter { $0.role == .system }
                .map(\.content)
                .joined(separator: "\n\n")
            let user = request.messages
                .filter { $0.role != .system }
                .map(\.content)
                .joined(separator: "\n\n")
            let estimatedInput = AICostEstimator.estimateInputTokens(system: system, user: user)
            let reserved = price.map {
                AICostEstimator.reserveMicros(
                    inputTokens: estimatedInput,
                    maxOutputTokens: request.maxTokens,
                    price: $0
                )
            } ?? 0

            guard let reservation = quota.reserveTracked(
                .research,
                policy: configuration.quotaPolicy,
                reservedCostMicros: reserved
            ) else {
                state.budgetExhausted = true
                return nil
            }
            if Task.isCancelled {
                quota.settle(
                    reservation, actualCostMicros: 0,
                    inputTokens: 0, outputTokens: 0, priced: true
                )
                return nil
            }
            _ = ledger.recordAICalls(1, origin: origin)
            state.aiCalls += 1
            do {
                let response = try await ai.complete(request)
                quota.settle(
                    reservation,
                    usage: response.usage,
                    price: price
                )
                return response
            } catch {
                // Once the client has been called, cancellation and errors do
                // not prove that the provider failed to bill the request.
                quota.settle(reservation, usage: nil, price: price)
                return nil
            }
        }

        func budgetMessage() -> String {
            let quotaSnapshot = quota.snapshot()
            guard ledger.snapshot().availability.isUsable, quotaSnapshot.isUsable else {
                return L10n.string("research.error.ledger", language: language)
            }
            if configuration.quotaPolicy.mode == .cost {
                return L10n.string(
                    "research.error.costBudget",
                    language: language,
                    AICostFormat.yuan(quotaSnapshot.costMicros),
                    AICostFormat.yuan(configuration.quotaPolicy.costCapMicros ?? 0)
                )
            }
            return L10n.string("research.error.budget", language: language)
        }

        // Stage 0 — seed.
        let title = configuration.record.seed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return await fail(L10n.string("research.error.empty", language: language))
        }
        guard ledger.reserve(.task, origin: origin, cap: configuration.taskDailyCap) else {
            return await fail(budgetMessage())
        }

        let seed = ResearchPrompts.SeedContext(
            record: configuration.record,
            sourceName: configuration.seedSourceName
        )
        let recency = Self.resolveRecency(
            configuration.defaultRecency,
            publishedAt: configuration.record.seed.publishedAt,
            profile: profile,
            now: now()
        )

        // Stage 1 — plan.
        await progress(snapshot(.planning))
        if let reason = await checkStop() { return await fail(reason) }

        var plan = ResearchPlan(claims: [], queries: [])
        var plannedClaims: [String] = []
        if let incremental {
            // Incremental runs reuse the prior claims/queries instead of
            // spending an AI call to re-plan the same subject.
            plannedClaims = Array(
                (incremental.priorReport.verification?.claims.map(\.claim) ?? []).prefix(5)
            )
            plannedQueries = (incremental.priorReport.method?.queries ?? []).map {
                PlannedQuery(text: $0, recency: nil)
            }
            plannedQueryCount = plannedQueries.count
        } else {
            if let response = await callAI(
                AIChatRequest(
                    messages: [
                        AIChatMessage(
                            role: .system,
                            content: ResearchPrompts.planningSystemPrompt(language: language)
                        ),
                        AIChatMessage(
                            role: .user,
                            content: ResearchPrompts.planningUserPrompt(
                                seed: seed,
                                trendContext: configuration.trendContext,
                                depth: depth,
                                recency: recency,
                                language: language
                            )
                        ),
                    ],
                    maxTokens: 1_500,
                    temperature: 0.2
                )
            ) {
                plan = ResearchReportParser.plan(from: response.text) ?? plan
            }
            if state.budgetExhausted {
                return await fail(budgetMessage())
            }

            plannedQueries = Self.resolvedQueries(
                plan: plan,
                title: title,
                language: language,
                recency: recency,
                limit: profile.queryCount
            )
            plannedQueryCount = plannedQueries.count
            plannedClaims = Array(plan.claims.prefix(5))
        }

        // Stage 2 — search.
        await progress(snapshot(.searching))
        var hits: [SearchHit] = []
        var anySearchSucceeded = false
        var anySearchFailed = false
        var ledgerWriteFailed = false
        /// A 403 is not retried for the rest of this research pass, but it is
        /// not remembered across passes either.
        var blockedProviders: Set<SearchProviderID> = []

        // One ticket for the whole pass — not one per query, and not one per
        // round. The budget is global: per-query tickets would each read the
        // same unspent balance and collectively overspend the moment they run
        // at once, and a per-round ticket would hand the gap round a second
        // full ceiling on top of the first.
        let searchTicket = SearchAttemptTicket(
            limit: DepthProfile.maxSearchHTTPCallsPerTask,
            trafficClass: origin.isAutomatic ? .automaticSearch : .manual,
            automaticDailyLimit: origin.isAutomatic
                ? configuration.automaticSearchDailyLimit : nil
        )
        var settledSearchCalls = 0
        /// Records what the ticket consumed since the last settle. `false` means
        /// the ledger could not write, and the pass must stop: continuing would
        /// spend budget the app cannot account for.
        func settleSearchCalls() -> Bool {
            let total = searchTicket.used
            let used = total - settledSearchCalls
            guard used > 0 else { return !ledgerWriteFailed }
            settledSearchCalls = total
            state.searchCalls += used
            if !ledger.recordSearchCalls(used, origin: origin) {
                ledgerWriteFailed = true
            }
            return !ledgerWriteFailed
        }

        if incremental == nil {
            do {
                let round = try await runSearchWaves(
                    plannedQueries,
                    ticket: searchTicket,
                    blockedProviders: &blockedProviders,
                    configuration: configuration,
                    recency: recency,
                    language: language,
                    settle: settleSearchCalls,
                    onWave: { completed in
                        state.queriesCompleted += completed
                        await progress(snapshot(.searching))
                    },
                    stopReason: checkStop
                )
                anySearchSucceeded = round.anySucceeded
                anySearchFailed = round.anyFailed
                hits.append(contentsOf: round.hits)
                state.failovers += round.failovers
                state.usedProviders.formUnion(round.providers)
                if round.budgetExhausted { state.partial = true }
            } catch SearchRoundAbort.cancelled {
                _ = settleSearchCalls()
                return await fail(L10n.string("research.error.cancelled", language: language))
            } catch let SearchRoundAbort.stopped(reason) {
                _ = settleSearchCalls()
                return await fail(reason)
            } catch SearchRoundAbort.ledger {
                return await fail(budgetMessage())
            } catch {
                // Pattern-matched catches do not make a `do` exhaustive for the
                // compiler; this arm is unreachable and exists only to prove it.
                _ = settleSearchCalls()
                return await fail(L10n.string("research.error.searchFailed", language: language))
            }
        }

        let searchStatus: BurstSearchStatus
        if incremental != nil {
            // A prior validated report already supplies grounded pages. No new
            // search is issued for an unchanged subject; candidates are the
            // explicit new materials and their cached pages.
            anySearchSucceeded = true
            searchStatus = .succeeded
            state.queriesCompleted = plannedQueries.count
        } else if anySearchSucceeded {
            searchStatus = .succeeded
        } else if anySearchFailed || !plannedQueries.isEmpty {
            searchStatus = .failed
        } else {
            searchStatus = .none
        }
        if !anySearchSucceeded {
            state.partial = true
        }

        // Stage 3 — select pages.
        let selected: [SearchHit] = incremental == nil
            ? Array(SearchResultRanking.deduplicated(hits).prefix(profile.pageCount))
            : []

        // Stage 4 — read.
        await progress(snapshot(.reading))
        var readDocuments: [ResearchDocument] = []
        for start in stride(from: 0, to: selected.count, by: 3) {
            if let reason = await checkStop() { return await fail(reason) }
            let chunk = Array(selected[start..<min(start + 3, selected.count)])
            do {
                try await withThrowingTaskGroup(of: ResearchDocument?.self) { group in
                    for hit in chunk {
                        group.addTask {
                            try await pageReader.read(
                                hit,
                                apiKey: configuration.firecrawlAPIKey,
                                useCache: !configuration.forceRefresh
                            )
                        }
                    }
                    for try await document in group {
                        if let document { readDocuments.append(document) }
                    }
                }
            } catch is CancellationError {
                return await fail(
                    L10n.string("research.error.cancelled", language: language)
                )
            } catch {
                // Page reading only throws cancellation; anything else is a
                // chunk-level failure and degrades to snippet documents below.
                continue
            }
        }

        var byURL: [String: ResearchDocument] = [:]
        for document in readDocuments where byURL[document.canonicalURL] == nil {
            byURL[document.canonicalURL] = document
        }
        var orderedDocuments = selected.compactMap { byURL[$0.canonicalURL] }
        if incremental == nil, orderedDocuments.count < selected.count {
            for hit in selected where byURL[hit.canonicalURL] == nil {
                let snippet = hit.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !snippet.isEmpty else { continue }
                let document = ResearchDocument(
                    url: hit.url,
                    title: hit.title,
                    text: snippet,
                    publishedAt: hit.publishedAt,
                    fetchedAt: now(),
                    source: .snippet
                )
                orderedDocuments.append(document)
                byURL[document.canonicalURL] = document
            }
        }

        if let incremental {
            // Cached prior pages are read from local storage only. New
            // materials may hit the same cache first; only a cache miss is a
            // network read.
            var merged: [String: ResearchDocument] = [:]
            for evidence in incremental.priorReport.evidence {
                if let cached = await pageReader.cachedDocument(
                    canonicalURL: evidence.canonicalURL
                ) {
                    merged[cached.canonicalURL] = cached
                }
            }
            for material in incremental.newMaterials {
                if let reason = await checkStop() { return await fail(reason) }
                if let cached = await pageReader.cachedDocument(
                    canonicalURL: material.canonicalURL
                ) {
                    merged[cached.canonicalURL] = cached
                    continue
                }
                do {
                    let outcome = try await pageReader.readOutcome(
                        PageReadRequest(
                            url: material.url,
                            title: material.title,
                            snippet: material.snippet,
                            publishedAt: material.publishedAt,
                            useCache: !configuration.forceRefresh
                        ),
                        apiKey: configuration.firecrawlAPIKey
                    )
                    if case let .document(document) = outcome {
                        merged[document.canonicalURL] = document
                        continue
                    }
                } catch is CancellationError {
                    return await fail(
                        L10n.string("research.error.cancelled", language: language)
                    )
                } catch {
                    // A failed new page falls back to its snippet below.
                }
                let snippet = material.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
                if !snippet.isEmpty {
                    let document = ResearchDocument(
                        url: material.url,
                        title: material.title,
                        text: snippet,
                        publishedAt: material.publishedAt,
                        fetchedAt: now(),
                        source: .snippet
                    )
                    merged[document.canonicalURL] = document
                }
            }
            orderedDocuments = merged.values.sorted {
                $0.canonicalURL < $1.canonicalURL
            }
        }

        for document in orderedDocuments where document.isFullText {
            guard SecurityPolicies.validatePublicHTTPURL(document.url).url != nil else { continue }
            let factID = "source:\(ContentIdentity.digest(document.canonicalURL))"
            appendProgressFact(ResearchRunFact(
                id: factID,
                kind: .sourceLocated,
                title: String(document.title.prefix(240)),
                url: document.url,
                quote: nil,
                claim: nil,
                recordedAt: now()
            ))
        }

        state.pagesRead = orderedDocuments.filter(\.isFullText).count
        orderedDocuments = Self.cappedDocuments(
            orderedDocuments,
            maxCharacters: DepthProfile.maxTotalCharacters
        )
        var documents: [String: ResearchDocument] = [:]
        for document in orderedDocuments {
            documents[document.canonicalURL] = document
        }
        if state.pagesRead == 0 {
            state.partial = true
        }
        await progress(snapshot(.reading))

        // Stage 5 — extract evidence in batches of two pages.
        var candidates: [EvidenceCandidate] = []

        if let incremental {
            // Reuse an old quote only when the current local body still
            // contains it verbatim. A missing body is not trusted; the old
            // version file keeps that history visible.
            let claimByEvidence = Dictionary(
                (incremental.priorReport.verification?.claims ?? []).flatMap { claim in
                    claim.evidenceIDs.map { ($0, claim.claim) }
                },
                uniquingKeysWith: { first, _ in first }
            )
            for item in incremental.priorReport.evidence {
                guard let document = documents[item.canonicalURL] else { continue }
                guard QuoteVerifier.verified(quote: item.quote, in: document.text) else {
                    continue
                }
                candidates.append(
                    EvidenceCandidate(
                        url: item.url,
                        title: item.title,
                        quote: item.quote,
                        claim: claimByEvidence[item.id] ?? "",
                        stance: item.stance,
                        publishedAt: item.publishedAt,
                        fetchedAt: item.fetchedAt
                    )
                )
            }
        }

        let extractionDocuments: [ResearchDocument]
        if let incremental {
            let priorURLs = Set(incremental.priorReport.evidence.map(\.canonicalURL))
            let priorGenerated = incremental.priorReport.generatedAt ?? .distantPast
            extractionDocuments = orderedDocuments.filter { document in
                !priorURLs.contains(document.canonicalURL)
                    || document.fetchedAt > priorGenerated
            }
        } else {
            let fullTextDocuments = orderedDocuments.filter(\.isFullText)
            extractionDocuments = fullTextDocuments.isEmpty
                ? orderedDocuments.filter { !$0.text.isEmpty }
                : fullTextDocuments
        }

        if !extractionDocuments.isEmpty {
            await progress(snapshot(.extracting))
            var start = 0
            var batchIndex = 0
            while start < extractionDocuments.count, batchIndex < profile.extractionBatchCount {
                if let reason = await checkStop() { return await fail(reason) }
                let batch = Array(
                    extractionDocuments[start..<min(start + 2, extractionDocuments.count)]
                )
                start += 2
                batchIndex += 1

                guard let response = await callAI(
                    AIChatRequest(
                        messages: [
                            AIChatMessage(
                                role: .system,
                                content: ResearchPrompts.extractionSystemPrompt(language: language)
                            ),
                            AIChatMessage(
                                role: .user,
                                content: ResearchPrompts.extractionUserPrompt(
                                    documents: batch,
                                    claims: plannedClaims,
                                    language: language
                                )
                            ),
                        ],
                        maxTokens: 4_096,
                        temperature: 0.1
                    )
                ) else {
                    state.partial = true
                    if state.budgetExhausted || state.aiLimitReached { break }
                    continue
                }

                guard let items = ResearchReportParser.evidence(from: response.text, now: now()) else {
                    continue
                }
                for item in items {
                    guard let document = Self.resolveDocument(item, in: batch) else { continue }
                    candidates.append(
                        EvidenceCandidate(
                            url: document.url,
                            title: document.title,
                            quote: String(item.quote.prefix(300)),
                            claim: item.claim,
                            stance: item.stance,
                            publishedAt: item.publishedAt ?? document.publishedAt,
                            angle: item.angle,
                            fetchedAt: document.fetchedAt
                        )
                    )
                }
                await progress(snapshot(.extracting))
            }

            // One simpler retry when the first pass produced nothing. Asking
            // only for verbatim sentences is much easier to satisfy than the
            // claim/stance schema, and it keeps a formatting miss from turning
            // the whole report into "no evidence".
            if candidates.isEmpty {
                if let reason = await checkStop() { return await fail(reason) }
                if let response = await callAI(
                    AIChatRequest(
                        messages: [
                            AIChatMessage(
                                role: .system,
                                content: ResearchPrompts.extractionSystemPrompt(language: language)
                            ),
                            AIChatMessage(
                                role: .user,
                                content: ResearchPrompts.extractionFallbackUserPrompt(
                                    documents: extractionDocuments,
                                    language: language
                                )
                            ),
                        ],
                        maxTokens: 2_048,
                        temperature: 0.1
                    )
                ), let items = ResearchReportParser.evidence(from: response.text, now: now()) {
                    for item in items {
                        guard let document = Self.resolveDocument(item, in: extractionDocuments) else { continue }
                        candidates.append(
                            EvidenceCandidate(
                                url: document.url,
                                title: document.title,
                                quote: String(item.quote.prefix(300)),
                                claim: item.claim,
                                stance: item.stance,
                                publishedAt: item.publishedAt ?? document.publishedAt,
                                fetchedAt: document.fetchedAt
                            )
                        )
                    }
                }
            }
        }

        // Stage 5b — the gap round.
        //
        // The event round answers what the plan guessed the subject was about.
        // Extraction is the first point where the report can tell which reader
        // questions are still open, because every verified fact now carries the
        // question it answers. This round asks only those, and it is bounded
        // three ways: the depth profile's allowance, the pass's shared request
        // ticket, and the AI budget that synthesis and repair still need.
        var gapHits: [SearchHit] = []
        /// Queries the gap round actually dispatched. `method.queries` is the
        /// report's own account of what was searched, so a second round that
        /// never appears there would make the method section understate the work.
        var gapQueriesIssued: [String] = []
        /// How many AI calls the gap round may spend. Computed as an amount, not
        /// a yes/no: the round reads pages, and an extraction batch is one call
        /// per two pages, so a boolean check let a deep pass read eight pages on
        /// one spare call and leave synthesis nothing. Measured on a real deep
        /// run before this bound existed: the report failed outright.
        let gapAllowance = Self.gapRoundAllowance(
            aiCalls: state.aiCalls,
            aiCallLimit: profile.aiCallLimit
        )
        let gapPageLimit = Self.gapPageBudget(
            allowance: gapAllowance,
            pageLimit: profile.pageCount
        )
        let coverage = ResearchAngleCoverage.evaluate(candidates, documents: documents)
        if incremental == nil,
           profile.gapQueryCount > 0,
           gapPageLimit > 0,
           // No angle signal means every angle looks empty, and a round would
           // spend its whole allowance chasing a guess. A report whose facts are
           // unlabelled and whose claims match no keyword gets no second round.
           coverage.labelledFacts > 0 {
            let gapPlan = Self.gapQueries(
                title: title,
                angles: Self.gapAngles(covered: coverage.covered, partial: coverage.partial),
                language: language,
                excluding: plannedQueries.map(\.text),
                limit: profile.gapQueryCount
            )
            if !gapPlan.isEmpty {
                // Planned means planned: the gap round decides these queries
                // before it dispatches them, so the counter has to include them
                // from that moment. Measured on a real deep run before this
                // line existed: the progress row read "7 of 6", because only the
                // event round was ever counted.
                plannedQueryCount += gapPlan.count
                await progress(snapshot(.searching))
                do {
                    let round = try await runSearchWaves(
                        gapPlan,
                        ticket: searchTicket,
                        blockedProviders: &blockedProviders,
                        configuration: configuration,
                        recency: recency,
                        language: language,
                        settle: settleSearchCalls,
                        onWave: { completed in
                            state.queriesCompleted += completed
                            await progress(snapshot(.searching))
                        },
                        stopReason: checkStop
                    )
                    gapHits = round.hits
                    // Only the queries the round actually dispatched. When the
                    // shared ticket runs dry the loop breaks early, and listing
                    // the rest would tell the reader those angles were searched
                    // when they were not — the method section is the report's own
                    // account of what it looked for.
                    gapQueriesIssued = Array(gapPlan.prefix(round.completed).map(\.text))
                    state.failovers += round.failovers
                    state.usedProviders.formUnion(round.providers)
                    if round.budgetExhausted { state.partial = true }
                } catch SearchRoundAbort.cancelled {
                    _ = settleSearchCalls()
                    return await fail(L10n.string("research.error.cancelled", language: language))
                } catch let SearchRoundAbort.stopped(reason) {
                    _ = settleSearchCalls()
                    return await fail(reason)
                } catch SearchRoundAbort.ledger {
                    return await fail(budgetMessage())
                } catch {
                    // A gap round that fails is a thinner report, not a failed
                    // one: everything the first round found is still in hand.
                    _ = settleSearchCalls()
                    state.partial = true
                }
            }
        }

        // Read and extract the gap round's new pages. Only URLs the pass has
        // not already read are touched; re-reading a page to ask it a second
        // question is what the extraction label was for, not a reason to spend
        // another request.
        if !gapHits.isEmpty {
            hits.append(contentsOf: gapHits)
            let known = Set(orderedDocuments.map(\.canonicalURL))
            let fresh = Array(
                SearchResultRanking.deduplicated(gapHits)
                    .filter { !known.contains($0.canonicalURL) }
                    // Bounded by the AI calls left, not by the profile's page
                    // count. One extraction batch is two pages and one call, so
                    // reading more pages than the allowance can pay for leaves
                    // the extra batches unextracted — and, before this bound
                    // existed, left nothing for synthesis at all.
                    .prefix(gapPageLimit)
            )
            var gapRead: [ResearchDocument] = []
            if !fresh.isEmpty {
                await progress(snapshot(.reading))
                for start in stride(from: 0, to: fresh.count, by: 3) {
                    if let reason = await checkStop() { return await fail(reason) }
                    let chunk = Array(fresh[start..<min(start + 3, fresh.count)])
                    do {
                        try await withThrowingTaskGroup(of: ResearchDocument?.self) { group in
                            for hit in chunk {
                                group.addTask {
                                    try await pageReader.read(
                                        hit,
                                        apiKey: configuration.firecrawlAPIKey,
                                        useCache: !configuration.forceRefresh
                                    )
                                }
                            }
                            for try await document in group {
                                if let document { gapRead.append(document) }
                            }
                        }
                    } catch is CancellationError {
                        return await fail(
                            L10n.string("research.error.cancelled", language: language)
                        )
                    } catch {
                        continue
                    }
                }
            }

            for document in gapRead where documents[document.canonicalURL] == nil {
                documents[document.canonicalURL] = document
                orderedDocuments.append(document)
            }
            state.pagesRead = orderedDocuments.filter(\.isFullText).count
            state.partial = state.pagesRead == 0

            let gapDocuments = gapRead.filter(\.isFullText)
            if !gapDocuments.isEmpty {
                await progress(snapshot(.extracting))
                for start in stride(from: 0, to: gapDocuments.count, by: 2) {
                    if let reason = await checkStop() { return await fail(reason) }
                    let batch = Array(gapDocuments[start..<min(start + 2, gapDocuments.count)])
                    guard let response = await callAI(
                        AIChatRequest(
                            messages: [
                                AIChatMessage(
                                    role: .system,
                                    content: ResearchPrompts.extractionSystemPrompt(language: language)
                                ),
                                AIChatMessage(
                                    role: .user,
                                    content: ResearchPrompts.extractionUserPrompt(
                                        documents: batch,
                                        claims: plannedClaims,
                                        language: language
                                    )
                                ),
                            ],
                            maxTokens: 4_096,
                            temperature: 0.1
                        )
                    ) else {
                        state.partial = true
                        if state.budgetExhausted || state.aiLimitReached { break }
                        continue
                    }
                    guard let items = ResearchReportParser.evidence(from: response.text, now: now()) else {
                        continue
                    }
                    for item in items {
                        guard let document = Self.resolveDocument(item, in: batch) else { continue }
                        candidates.append(
                            EvidenceCandidate(
                                url: document.url,
                                title: document.title,
                                quote: String(item.quote.prefix(300)),
                                claim: item.claim,
                                stance: item.stance,
                                publishedAt: item.publishedAt ?? document.publishedAt,
                                angle: item.angle,
                                fetchedAt: document.fetchedAt
                            )
                        )
                    }
                    await progress(snapshot(.extracting))
                }
            }
        }

        for candidate in candidates {
            let canonicalURL = ContentIdentity.canonicalURL(candidate.url)
            guard let document = documents[canonicalURL],
                  document.isFullText,
                  !candidate.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  QuoteVerifier.verified(quote: candidate.quote, in: document.text),
                  SecurityPolicies.validatePublicHTTPURL(candidate.url).url != nil else { continue }
            let factID = "quote:\(ContentIdentity.digest("\(canonicalURL)\n\(candidate.quote)"))"
            appendProgressFact(ResearchRunFact(
                id: factID,
                kind: .quoteVerified,
                title: String(candidate.title.prefix(240)),
                url: candidate.url,
                quote: String(candidate.quote.prefix(300)),
                claim: String(candidate.claim.prefix(300)),
                recordedAt: now()
            ))
        }
        if !progressFacts.isEmpty { await progress(snapshot(.extracting)) }

        // No readable page and no snippet means there is nothing to synthesize.
        // Failing here is what keeps a report made only of meta-commentary from
        // being saved as a partial success.
        if orderedDocuments.isEmpty {
            let message = searchStatus == .failed
                ? L10n.string("research.error.searchFailed", language: language)
                : L10n.string("research.error.noSources", language: language)
            return await fail(message)
        }

        // Stage 6 — synthesize. Evidence cards and the validator must use the
        // exact same whitelist, deduplication and order, or the model's E-numbers
        // point at different quotes after validation.
        await progress(snapshot(.synthesizing))
        if let reason = await checkStop() { return await fail(reason) }
        var allowedURLs = Set(hits.map(\.canonicalURL))
        allowedURLs.formUnion(selected.map(\.canonicalURL))
        allowedURLs.formUnion(documents.keys)
        if let incremental {
            allowedURLs.formUnion(incremental.priorReport.evidence.map(\.canonicalURL))
            allowedURLs.formUnion(incremental.newMaterials.map(\.canonicalURL))
        }
        if let seedURL = configuration.record.seed.url {
            allowedURLs.insert(ContentIdentity.canonicalURL(seedURL))
        }
        let eligibleCandidates = EvidenceIdentity.ordered(candidates, allowedURLs: allowedURLs)
        let cards = Self.evidenceCards(from: eligibleCandidates)
        let claims = plannedClaims.isEmpty
            ? Array(Self.unique(eligibleCandidates.map(\.claim).filter { !$0.isEmpty }).prefix(5))
            : plannedClaims
        // The dossier restores the context the old single-pass research had.
        // It is explicitly background-only: the model may use it to describe
        // the chain of events, but only evidence cards can be cited.
        let dossier = Self.cappedDocuments(orderedDocuments, maxCharacters: 9_000)
        let hasEvidence = !cards.isEmpty
        let synthesisSystem = ResearchPrompts.synthesisSystemPrompt(
            language: language,
            hasEvidence: hasEvidence
        )
        var synthesisUser = ResearchPrompts.synthesisUserPrompt(
            seed: seed,
            claims: hasEvidence ? claims : [],
            evidence: cards,
            dossier: dossier,
            trendContext: configuration.trendContext,
            language: language
        )
        if let incremental {
            // Background only: the model updates the prior account, but only
            // the evidence cards above may be cited in the new report.
            let priorSummary = incremental.priorReport.summary
            let priorOverview = incremental.priorReport.overview
            synthesisUser += "\n\n上一版报告（仅作更新背景，不得当作新证据引用）：\n"
                + "摘要：\(priorSummary)\n"
                + "概述：\(priorOverview)\n"
                + "请只使用本次证据卡与页面资料更新事实、时间线与结论。"
        }

        guard var response = await callAI(
            AIChatRequest(
                messages: [
                    AIChatMessage(role: .system, content: synthesisSystem),
                    AIChatMessage(role: .user, content: synthesisUser),
                ],
                maxTokens: 8_192,
                temperature: 0.2
            )
        ) else {
            return await fail(
                state.budgetExhausted
                    ? budgetMessage()
                    : L10n.string("research.error.ai", language: language)
            )
        }

        /// At most one remedy, so the worst case is the attempt plus one call —
        /// exactly what `reservedAICallsForSynthesis` reserves. Running the
        /// enlarged-budget retry and then a repair made three, and the third was
        /// refused after every page had already been read and paid for.
        var draft = ResearchReportParser.synthesis(from: response.text, now: now())
        switch Self.synthesisRemedy(
            truncated: response.truncated,
            parsed: draft != nil
        ) {
        case .none:
            // Either it parsed, or there is nothing a second call would add.
            state.truncated = response.truncated
            state.partial = state.truncated

        case .enlargeBudget:
            let retryRequest = AIChatRequest(
                messages: [
                    AIChatMessage(role: .system, content: synthesisSystem),
                    AIChatMessage(role: .user, content: synthesisUser),
                ],
                maxTokens: 16_384,
                temperature: 0.2
            )
            if let retry = await callAI(retryRequest) {
                response = retry
                state.truncated = retry.truncated
                draft = ResearchReportParser.synthesis(from: retry.text, now: now())
            } else {
                state.truncated = true
            }
            state.partial = state.truncated

        case .repair:
            let repair = ResearchPrompts.repairUserPrompt(
                brokenOutput: response.text,
                language: language
            )
            if let repaired = await callAI(
                AIChatRequest(
                    messages: [
                        AIChatMessage(role: .system, content: synthesisSystem),
                        AIChatMessage(role: .user, content: repair),
                    ],
                    maxTokens: 8_192,
                    temperature: 0.1
                )
            ) {
                draft = ResearchReportParser.synthesis(from: repaired.text, now: now())
            }
        }
        guard var draft = draft else {
            return await fail(L10n.string("research.error.ai", language: language))
        }

        // One bounded rewrite when the model still described its own pipeline.
        // Structural fields (dates, evidenceIDs, statuses) must survive; if the
        // rewrite does not come back clean, ReportValidator hides the offending
        // fields instead of showing engineering vocabulary to the reader.
        if !ReaderFacingText.findings(in: draft).isEmpty {
            let rewrite = ResearchPrompts.readerRewriteUserPrompt(
                rawOutput: response.text,
                language: language
            )
            let candidate = await callAI(
                AIChatRequest(
                    messages: [
                        AIChatMessage(role: .system, content: synthesisSystem),
                        AIChatMessage(role: .user, content: rewrite),
                    ],
                    maxTokens: 8_192,
                    temperature: 0.1
                )
            ).flatMap { ResearchReportParser.synthesis(from: $0.text, now: now()) }
            if let candidate, ReaderFacingText.findings(in: candidate).isEmpty {
                draft = candidate
            } else {
                NSLog(
                    "[ResearchPipeline] reader-facing rewrite failed; hiding offending fields"
                )
            }
        }

        // Stage 7 — validate.
        await progress(snapshot(.validating))
        if let reason = await checkStop() { return await fail(reason) }

        let method = ResearchMethod(
            providers: incremental?.priorReport.method?.providers
                ?? SearchProviderID.failoverOrder
                    .filter { state.usedProviders.contains($0) }
                    .map(\.rawValue),
            queries: incremental?.priorReport.method?.queries
                ?? plannedQueries.map(\.text) + gapQueriesIssued,
            pagesRead: state.pagesRead,
            recency: incremental?.priorReport.method?.recency ?? recency.rawValue,
            generatedAt: now(),
            promptVersion: ResearchPrompts.version,
            failovers: incremental?.priorReport.method?.failovers ?? state.failovers
        )
        let validationInput = ReportValidationInput(
            draft: draft,
            candidates: candidates,
            plannedClaims: plannedClaims,
            documents: documents,
            allowedURLs: allowedURLs,
            searchStatus: searchStatus,
            pagesRead: state.pagesRead,
            truncated: state.truncated,
            depth: depth,
            method: method,
            now: now(),
            language: language
        )
        let report = ReportValidator.validate(validationInput)
        guard BurstResearchParser.hasUsableContent(report) else {
            return await fail(L10n.string("research.error.empty", language: language))
        }

        let reportEvidence = Dictionary(
            report.evidence.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let reportDocuments = Dictionary(
            documents.values.map { ($0.canonicalURL, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for evidence in report.evidence where evidence.quoteVerified {
            guard let document = reportDocuments[evidence.canonicalURL],
                  document.isFullText,
                  QuoteVerifier.verified(quote: evidence.quote, in: document.text),
                  SecurityPolicies.validatePublicHTTPURL(evidence.url).url != nil else { continue }
            let factID = "quote:\(ContentIdentity.digest("\(evidence.canonicalURL)\n\(evidence.quote)"))"
            let claimText = report.verification?.claims
                .first(where: { $0.evidenceIDs.contains(evidence.id) })
                .map { String($0.claim.prefix(300)) }
            appendProgressFact(ResearchRunFact(
                id: factID,
                kind: .quoteVerified,
                title: String(evidence.title.prefix(240)),
                url: evidence.url,
                quote: String(evidence.quote.prefix(300)),
                claim: claimText,
                recordedAt: now()
            ))
        }
        for claim in report.verification?.claims ?? [] where claim.status == .supports {
            for evidenceID in claim.evidenceIDs {
                guard let evidence = reportEvidence[evidenceID],
                      evidence.quoteVerified,
                      let document = reportDocuments[evidence.canonicalURL],
                      document.isFullText,
                      QuoteVerifier.verified(quote: evidence.quote, in: document.text),
                      SecurityPolicies.validatePublicHTTPURL(evidence.url).url != nil else { continue }
                let factID = "claim:\(ContentIdentity.digest("\(claim.claim)\n\(evidence.canonicalURL)\n\(evidence.quote)"))"
                appendProgressFact(ResearchRunFact(
                    id: factID,
                    kind: .claimSupported,
                    title: String(evidence.title.prefix(240)),
                    url: evidence.url,
                    quote: String(evidence.quote.prefix(300)),
                    claim: String(claim.claim.prefix(300)),
                    recordedAt: now()
                ))
            }
        }
        await progress(snapshot(.validating))

        // Stage 8 — persist (the coordinator does the write) and notify.
        await progress(snapshot(.done, finished: true))
        return ResearchExecution(
            research: report,
            error: nil,
            pagesRead: state.pagesRead,
            searchCalls: state.searchCalls,
            aiCalls: state.aiCalls,
            queries: plannedQueries.map(\.text) + gapQueriesIssued,
            isPartial: state.partial
                || state.truncated
                || searchStatus != .succeeded
                || state.pagesRead == 0
                || !report.hasGroundedContent
                || report.evidence.isEmpty
        )
    }

    // MARK: - Helpers

    static func resolveRecency(
        _ preference: ResearchDefaultRecency,
        publishedAt: Date?,
        profile: DepthProfile,
        now: Date
    ) -> SearchRecency {
        if let explicit = preference.explicit { return explicit }
        guard let publishedAt else {
            switch profile.defaultRecencyDays {
            case ...7: return .week
            case ...30: return .month
            case ...90: return .quarter
            default: return .year
            }
        }
        let days = max(
            1,
            min(365, Int(ceil(now.timeIntervalSince(publishedAt) / 86_400)))
        )
        switch days {
        case ...7: return .week
        case ...30: return .month
        case ...90: return .quarter
        default: return .year
        }
    }

    static func resolvedQueries(
        plan: ResearchPlan,
        title: String,
        language: AppLanguage,
        recency: SearchRecency,
        limit: Int
    ) -> [PlannedQuery] {
        let planned = plan.queries
            .map { PlannedQuery(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), recency: $0.recency) }
            .filter { !$0.text.isEmpty }
        if !planned.isEmpty {
            return Array(planned.prefix(limit))
        }
        return Array(templateQueries(title: title, language: language, recency: recency).prefix(limit))
    }

    static func templateQueries(
        title: String,
        language: AppLanguage,
        recency: SearchRecency
    ) -> [PlannedQuery] {
        let variants: [String]
        if language == .en {
            variants = [
                "\(title) timeline",
                "\(title) latest news",
                "\(title) official response",
                "\(title) fact check",
                "\(title) background",
                "\(title) controversy",
            ]
        } else {
            variants = [
                "\(title) 事件 时间线",
                "\(title) 最新进展",
                "\(title) 官方回应",
                "\(title) 事实核查",
                "\(title) 背景",
                "\(title) 争议",
            ]
        }
        return variants.map { PlannedQuery(text: $0, recency: recency) }
    }

    static func resolveDocument(_ item: RawEvidence, in batch: [ResearchDocument]) -> ResearchDocument? {
        if let index = item.sourceIndex, (1...batch.count).contains(index) {
            return batch[index - 1]
        }
        if let url = item.url {
            let canonical = ContentIdentity.canonicalURL(url)
            return batch.first { $0.canonicalURL == canonical }
        }
        return nil
    }

    static func evidenceCards(from candidates: [EvidenceCandidate]) -> [ResearchPrompts.EvidenceCard] {
        var cards: [ResearchPrompts.EvidenceCard] = []
        for candidate in EvidenceIdentity.ordered(candidates) {
            let quote = candidate.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            cards.append(
                ResearchPrompts.EvidenceCard(
                    id: "E\(cards.count + 1)",
                    title: candidate.title,
                    url: candidate.url,
                    quote: quote,
                    stance: candidate.stance,
                    publishedAt: candidate.publishedAt
                )
            )
            if cards.count >= 24 { break }
        }
        return cards
    }

    static func cappedDocuments(
        _ documents: [ResearchDocument],
        maxCharacters: Int
    ) -> [ResearchDocument] {
        var remaining = maxCharacters
        var output: [ResearchDocument] = []
        for document in documents {
            guard remaining > 0 else { break }
            let text = String(document.text.prefix(remaining))
            guard !text.isEmpty else { continue }
            output.append(
                ResearchDocument(
                    url: document.url,
                    title: document.title,
                    text: text,
                    publishedAt: document.publishedAt,
                    fetchedAt: document.fetchedAt,
                    source: document.source
                )
            )
            remaining -= text.count
        }
        return output
    }

    static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }
}
