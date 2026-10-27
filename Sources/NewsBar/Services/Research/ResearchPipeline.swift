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
    var aiDailyCap: Int
    var taskDailyCap: Int
    var seedSourceName: String?
    /// Re-checked at every phase boundary so a cancelled or superseded run
    /// stops before spending another network request.
    var isAllowed: @Sendable () async -> Bool

    init(
        record: ResearchRecord,
        depth: ResearchDepth,
        language: AppLanguage,
        trendContext: String,
        defaultRecency: ResearchDefaultRecency,
        searchConfiguration: SearchRouterConfiguration,
        firecrawlAPIKey: String,
        aiDailyCap: Int,
        taskDailyCap: Int,
        seedSourceName: String? = nil,
        isAllowed: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.record = record
        self.depth = depth
        self.language = language
        self.trendContext = trendContext
        self.defaultRecency = defaultRecency
        self.searchConfiguration = searchConfiguration
        self.firecrawlAPIKey = firecrawlAPIKey
        self.aiDailyCap = aiDailyCap
        self.taskDailyCap = taskDailyCap
        self.seedSourceName = seedSourceName
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

    let ai: any AIChatClienting
    let searchRouter: SearchRouter
    let pageReader: PageReader
    let ledger: ResearchLedger
    let now: @Sendable () -> Date

    init(
        ai: any AIChatClienting,
        searchRouter: SearchRouter,
        pageReader: PageReader,
        ledger: ResearchLedger = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ai = ai
        self.searchRouter = searchRouter
        self.pageReader = pageReader
        self.ledger = ledger
        self.now = now
    }

    func run(
        configuration: ResearchPipelineConfiguration,
        progress: @escaping ProgressHandler
    ) async -> ResearchExecution {
        let depth = configuration.depth
        let profile = DepthProfile.profile(for: depth)
        let origin = configuration.record.origin
        let language = configuration.language
        let startedAt = now()
        let state = ResearchRunState()

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
                startedAt: configuration.record.run.startedAt ?? startedAt,
                finishedAt: finished ? now() : nil,
                lastError: error
            )
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
            guard state.aiCalls < profile.aiCallLimit else {
                state.aiLimitReached = true
                return nil
            }
            guard ledger.reserve(.ai, origin: origin, cap: configuration.aiDailyCap) else {
                state.budgetExhausted = true
                return nil
            }
            state.aiCalls += 1
            do {
                return try await ai.complete(request)
            } catch is CancellationError {
                return nil
            } catch {
                return nil
            }
        }

        func budgetMessage() -> String {
            if ledger.snapshot().isCorrupt {
                return L10n.string("research.error.ledger", language: language)
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
        let plannedClaims = Array(plan.claims.prefix(5))

        // Stage 2 — search.
        await progress(snapshot(.searching))
        var hits: [SearchHit] = []
        var anySearchSucceeded = false
        var anySearchFailed = false

        for planned in plannedQueries {
            if let reason = await checkStop() { return await fail(reason) }
            let remainingCalls = DepthProfile.maxSearchHTTPCallsPerTask - state.searchCalls
            guard remainingCalls > 0 else {
                state.partial = true
                break
            }
            let query = SearchQuery(
                text: planned.text,
                recency: planned.recency ?? recency,
                language: language.bcp47,
                maxResults: 6
            )
            do {
                let batch = try await searchRouter.search(
                    query,
                    configuration: configuration.searchConfiguration,
                    maxAttempts: remainingCalls
                )
                anySearchSucceeded = true
                state.searchCalls += batch.attempts
                state.failovers += batch.failovers
                state.usedProviders.formUnion(batch.providers)
                ledger.recordSearchCalls(batch.attempts, origin: origin)
                hits.append(contentsOf: batch.hits)
            } catch is CancellationError {
                return await fail(L10n.string("research.error.cancelled", language: language))
            } catch {
                anySearchFailed = true
                // A failed query still sent HTTP requests to every enabled
                // provider. Charge them, or the per-task cap is enforced only
                // against successful calls.
                let attempted = min(
                    remainingCalls,
                    max(1, configuration.searchConfiguration.enabled.count)
                )
                state.searchCalls += attempted
                ledger.recordSearchCalls(attempted, origin: origin)
            }
            state.queriesCompleted += 1
            await progress(snapshot(.searching))
        }

        let searchStatus: BurstSearchStatus
        if anySearchSucceeded {
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
        let selected = Array(
            SearchResultRanking.deduplicated(hits).prefix(profile.pageCount)
        )

        // Stage 4 — read.
        await progress(snapshot(.reading))
        var readDocuments: [ResearchDocument] = []
        for start in stride(from: 0, to: selected.count, by: 3) {
            if let reason = await checkStop() { return await fail(reason) }
            let chunk = Array(selected[start..<min(start + 3, selected.count)])
            await withTaskGroup(of: ResearchDocument?.self) { group in
                for hit in chunk {
                    group.addTask {
                        await pageReader.read(hit, apiKey: configuration.firecrawlAPIKey)
                    }
                }
                for await document in group {
                    if let document { readDocuments.append(document) }
                }
            }
        }

        var byURL: [String: ResearchDocument] = [:]
        for document in readDocuments where byURL[document.canonicalURL] == nil {
            byURL[document.canonicalURL] = document
        }
        var orderedDocuments = selected.compactMap { byURL[$0.canonicalURL] }
        if orderedDocuments.count < selected.count {
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
        let fullTextDocuments = orderedDocuments.filter(\.isFullText)
        let extractionDocuments = fullTextDocuments.isEmpty
            ? orderedDocuments.filter { !$0.text.isEmpty }
            : fullTextDocuments

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
                            fetchedAt: document.fetchedAt
                        )
                    )
                }
                await progress(snapshot(.extracting))
            }
        }

        // Stage 6 — synthesize.
        await progress(snapshot(.synthesizing))
        if let reason = await checkStop() { return await fail(reason) }
        let cards = Self.evidenceCards(from: candidates)
        let claims = plannedClaims.isEmpty
            ? Array(Self.unique(candidates.map(\.claim).filter { !$0.isEmpty }).prefix(5))
            : plannedClaims
        let synthesisSystem = ResearchPrompts.synthesisSystemPrompt(language: language)
        let synthesisUser = ResearchPrompts.synthesisUserPrompt(
            seed: seed,
            claims: claims,
            evidence: cards,
            trendContext: configuration.trendContext,
            language: language
        )

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

        if response.truncated {
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
            } else {
                state.truncated = true
            }
            state.partial = state.truncated
        }

        var draft = ResearchReportParser.synthesis(from: response.text, now: now())
        if draft == nil {
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
        guard let draft else {
            return await fail(L10n.string("research.error.ai", language: language))
        }

        // Stage 7 — validate.
        await progress(snapshot(.validating))
        if let reason = await checkStop() { return await fail(reason) }
        var allowedURLs = Set(hits.map(\.canonicalURL))
        allowedURLs.formUnion(selected.map(\.canonicalURL))
        allowedURLs.formUnion(documents.keys)
        if let seedURL = configuration.record.seed.url {
            allowedURLs.insert(ContentIdentity.canonicalURL(seedURL))
        }

        let method = ResearchMethod(
            providers: SearchProviderID.failoverOrder
                .filter { state.usedProviders.contains($0) }
                .map(\.rawValue),
            queries: plannedQueries.map(\.text),
            pagesRead: state.pagesRead,
            recency: recency.rawValue,
            generatedAt: now(),
            promptVersion: ResearchPrompts.version,
            failovers: state.failovers
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

        // Stage 8 — persist (the coordinator does the write) and notify.
        await progress(snapshot(.done, finished: true))
        return ResearchExecution(
            research: report,
            error: nil,
            pagesRead: state.pagesRead,
            searchCalls: state.searchCalls,
            aiCalls: state.aiCalls,
            queries: plannedQueries.map(\.text),
            isPartial: state.partial
                || state.truncated
                || searchStatus != .succeeded
                || state.pagesRead == 0
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
        var seen: Set<String> = []
        var cards: [ResearchPrompts.EvidenceCard] = []
        for candidate in candidates {
            let quote = candidate.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !quote.isEmpty else { continue }
            let key = ContentIdentity.canonicalURL(candidate.url)
                + "\n"
                + QuoteVerifier.normalize(quote)
            guard seen.insert(key).inserted else { continue }
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
